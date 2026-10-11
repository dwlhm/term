package render

// Fixed-slot font atlas with 512 slots.
// Each slot holds a single glyph's texture coordinates in the atlas texture.
// Pinned glyphs (ASCII, box drawing, block elements, powerline) are prewarmed
// at initialization time using a font rasterizer.
//
// The atlas texture is a single 2D texture (R8 format) where each glyph
// is rasterized into a fixed-size cell. Slots are addressed via O(1) range
// checks for pinned codepoints.

import "base:runtime"
import "core:math"
import "core:sync"
import "gpu"
import termgrid "../terminal"

// ATLAS_SLOT_COUNT is the total number of glyph slots in the atlas.
ATLAS_SLOT_COUNT :: 512

// ATLAS_GLYPH_SIZE is the pixel dimensions of each glyph cell (width and height).
ATLAS_GLYPH_SIZE :: 64

// ATLAS_COLS is the number of glyph columns in the atlas texture.
ATLAS_COLS :: 16

// ATLAS_ROWS is the number of glyph rows in the atlas texture.
ATLAS_ROWS :: 32

// Atlas_Slot holds texture coordinates for a single glyph.
Atlas_Slot :: struct {
	u0: f32, // left texcoord (u)
	v0: f32, // top texcoord (v)
	u1: f32, // right texcoord (u)
	v1: f32, // bottom texcoord (v)
	advance: f32, // horizontal advance width in pixels
	valid: bool,  // whether this slot contains a rasterized glyph
}

// FALLBACK_SLOT_BASE is the first dynamic slot (== PINNED_TOTAL).
FALLBACK_SLOT_BASE :: PINNED_TOTAL

// FALLBACK_SLOT_COUNT is the number of dynamic slots (PINNED_TOTAL..511).
FALLBACK_SLOT_COUNT :: ATLAS_SLOT_COUNT - FALLBACK_SLOT_BASE

// ATLAS_CAP_REFERENCE_PREFERRED is the primary-face glyph whose rendered ink
// calibrates the primary's optical cap height. A Latin capital is flat-topped
// and reaches the cap line in every text face.
ATLAS_CAP_REFERENCE_PREFERRED :: u32('H')

// ATLAS_CAP_REFERENCE_FALLBACK is used when the primary face carries no
// Latin capital; digits share the cap line in essentially every text face.
ATLAS_CAP_REFERENCE_FALLBACK :: u32('0')

// ATLAS_FALLBACK_MAX_SCALE bounds how far a fallback glyph may be scaled up
// to reach the primary's cap height. Symbol faces draw small outlines inside
// a large em, so real UI glyphs need a sizeable boost; the bound keeps a
// pathologically small outline from running past the atlas cell.
ATLAS_FALLBACK_MAX_SCALE :: 4.0

// ATLAS_FALLBACK_FIT_STEP is the multiplicative step used to shrink an
// oversized fallback bitmap until it fits the cell, mirroring the fit loop in
// font_rasterize_glyph_fitted.
ATLAS_FALLBACK_FIT_STEP :: 0.95

// ATLAS_FALLBACK_FIT_STEPS bounds that shrink loop.
ATLAS_FALLBACK_FIT_STEPS :: 24

// Atlas is a fixed-slot font atlas.
Atlas :: struct {
	slots:      [ATLAS_SLOT_COUNT]Atlas_Slot,
	pixels:     []u8,           // atlas texture pixel data (R8 format)
	tex_width:  int,
	tex_height: int,
	glyph_size: int,
	cell_width: int,
	cell_height: int,
	slot_count: int,

	// GPU resources (created by atlas_upload_gpu)
	gpu_texture: gpu.Gpu_Texture,
	gpu_view:    gpu.Gpu_TextureView,
	gpu_dirty:   bool,  // true if pixels changed since last upload

	// Pinned glyph tracking
	pinned_count: int,  // number of pinned glyphs successfully prewarmed

	// Primary-face optical calibration, measured once in atlas_init. Slots
	// filled from the fallback chain are scaled to primary_cap_px and
	// bottom-aligned to primary_baseline_px, so UI chrome drawn by a symbol
	// face shares the text face's baseline and optical size. primary_cap_px
	// == 0 means "uncalibrated": fallback glyphs keep face-local placement.
	primary_baseline_px: int,  // reference ink bottom row within a cell
	primary_cap_px: int,  // primary cap height in px (measured ink height)

	// Dynamic fallback region (FIFO): slots FALLBACK_SLOT_BASE..511 hold
	// rasterized fallback glyphs. tag is (u64(font_index) << 32) | shaped;
	// 0 means empty. Writes here never touch pinned slots 0..270.
	fallback_fifo:   [FALLBACK_SLOT_COUNT]u32,
	fallback_cursor: int,
	fallback_tag:    [FALLBACK_SLOT_COUNT]u64,

	// Phase 18 pressure tap (render-thread only, no alloc). Nil means
	// uninstrumented: the _p wrappers behave bit-identically to legacy.
	pressure: ^Atlas_Pressure,
}

// atlas_init initializes the font atlas with prewarmed glyphs from a font rasterizer.
atlas_init :: proc(a: ^Atlas, rasterizer: ^Font_Rasterizer, allocator: runtime.Allocator = context.allocator) {
	atlas_cols := ATLAS_COLS
	atlas_rows := ATLAS_ROWS
	glyph_size := ATLAS_GLYPH_SIZE

	a.tex_width  = atlas_cols * glyph_size
	a.tex_height = atlas_rows * glyph_size
	a.glyph_size = glyph_size
	a.cell_width = int(rasterizer.metrics.cell_width)
	a.cell_height = int(rasterizer.metrics.cell_height)
	a.slot_count = ATLAS_SLOT_COUNT
	a.pinned_count = 0
	a.gpu_dirty = true

	// Primary-face optical calibration (once, init only): the fallback chain
	// fills pinned slots the primary left blank, and those glyphs must be
	// placed against the primary's baseline and optical size.
	a.primary_cap_px, a.primary_baseline_px = _atlas_calibrate_reference(rasterizer)

	// Allocate pixel buffer (R8 format, single channel)
	pixel_count := a.tex_width * a.tex_height
	a.pixels = make([]u8, pixel_count, allocator)

	// Clear to zero (transparent)
	for i in 0..<pixel_count {
		a.pixels[i] = 0
	}

	// Initialize all slots as invalid
	for i in 0..<ATLAS_SLOT_COUNT {
		a.slots[i] = Atlas_Slot{valid = false}
	}

	// Initialize the dynamic fallback region as empty
	for i in 0..<FALLBACK_SLOT_COUNT {
		a.fallback_fifo[i] = 0
		a.fallback_tag[i] = 0
	}
	a.fallback_cursor = 0

	// Initialize GPU resources as nil
	a.gpu_texture = gpu.Gpu_Texture(nil)
	a.gpu_view = gpu.Gpu_TextureView(nil)

	// Prewarm pinned glyphs
	atlas_prewarm(a, rasterizer)
}

// _atlas_calibrate_reference measures the primary face's cap height and its
// baseline row from the rendered ink of a reference glyph.
//
// Cap height is not exposed by Font_Metrics, so it is measured instead: a
// Latin capital (or a digit where the face has no capital) is flat-topped and
// rises to the cap line in every text face, which makes its ink height the
// primary's own cap height at the configured pixel size. Its ink bottom row
// is the primary's baseline within an atlas cell. Measuring ink (not a font
// table) keeps both targets valid for any primary font the app ships,
// including hinted faces whose reported metrics round differently.
//
// Returns (0, -1) when the face covers neither reference, which leaves
// fallback glyphs on their face-local placement.
_atlas_calibrate_reference :: proc(rasterizer: ^Font_Rasterizer) -> (cap_px, baseline_px: int) {
	references := [2]u32{ATLAS_CAP_REFERENCE_PREFERRED, ATLAS_CAP_REFERENCE_FALLBACK}
	for cp in references {
		if !font_rasterizer_has_glyph(rasterizer, cp) {
			continue
		}
		_, height, _, bottom, ok := font_measure_glyph_ink_box(rasterizer, cp)
		if ok {
			return height, bottom
		}
	}
	return 0, -1
}

// atlas_destroy frees the atlas pixel buffer and GPU resources.
atlas_destroy :: proc(a: ^Atlas, backend: ^gpu.Gpu_Backend_VTable = nil, allocator: runtime.Allocator = context.allocator) {
	if a == nil do return
	if backend != nil {
		if rawptr(a.gpu_view) != nil {
			backend.destroy_texture_view(a.gpu_view)
		}
		if rawptr(a.gpu_texture) != nil {
			backend.destroy_texture(a.gpu_texture)
		}
	}
	a.gpu_texture = gpu.Gpu_Texture(nil)
	a.gpu_view = gpu.Gpu_TextureView(nil)

	if a.pixels != nil {
		delete(a.pixels, allocator)
		a.pixels = nil
	}
}

// atlas_get_slot returns the atlas slot for a given codepoint.
// Uses O(1) range-based lookup for pinned codepoints.
atlas_get_slot :: proc(a: ^Atlas, codepoint: u32) -> (index: int, slot: ^Atlas_Slot) {
	// Try pinned lookup first
	if idx, ok := atlas_pinned_slot_index(codepoint); ok {
		return idx, &a.slots[idx]
	}

	// Fallback: use modulo for non-pinned codepoints
	index = int(codepoint % ATLAS_SLOT_COUNT)
	return index, &a.slots[index]
}

// atlas_prewarm rasterizes all pinned codepoints into the atlas.
atlas_prewarm :: proc(a: ^Atlas, rasterizer: ^Font_Rasterizer) {
	if rasterizer == nil {
		return
	}

	set := atlas_prewarm_set()
	defer delete(set)

	for codepoint in set {
		idx, ok := atlas_pinned_slot_index(u32(codepoint))
		if !ok {
			continue
		}

		if _atlas_rasterize_into_slot(a, rasterizer, u32(codepoint), idx, true) {
			a.pinned_count += 1
		}
	}

	a.gpu_dirty = true
}

// _atlas_rasterize_fallback_fitted rasterizes a fallback-sourced pinned glyph
// scaled so its ink height matches the primary's calibrated cap height, then
// blits it centered in the cell with its ink bottom on the primary's
// baseline.
//
// Two things about the fallback face are deliberately discarded:
//
//   - its own ascender. A symbol face carries a much larger ascender than a
//     text face (Apple Symbols reports roughly 11px against Maple Mono's 17px
//     at the same pixel size), so anchoring against it lands the glyph high —
//     a superscript next to normal-height text.
//
//   - its own design baseline offset (bitmap_top). That offset is per glyph,
//     not per face: within one symbol face a control caret sits rows above the
//     baseline while a return arrow dips below it. Bottom alignment instead
//     pins every fallback glyph's ink bottom to one row — the primary's.
//
// This diverges on purpose from the Powerline branch in
// _atlas_rasterize_into_slot, which routes through font_rasterize_glyph_fitted
// + _atlas_blit_bitmap and therefore preserves bitmap_top. That is correct
// there: a Powerline caret is a standalone decorative separator whose glyph is
// designed to hang off the cell edge at its own height, and flattening it
// onto the text baseline would detach it from the frame it draws. Inline UI
// symbols are the opposite case — they are read as part of a text line, so the
// text baseline wins over the source face's design offset.
//
// A slot's UVs span exactly one cell, so an oversized bitmap would be
// clipped: the scaled size is shrunk (and only the scaled size; glyphs below
// the optical target keep it) until the ink fits (cell_width, cell_height),
// bounded by ATLAS_FALLBACK_MAX_SCALE upward and ATLAS_FALLBACK_FIT_STEPS
// downward. A glyph still taller than the rows above the baseline after that
// fit is top-clamped by the blit instead of being clipped. When the atlas
// carries no calibration or the glyph has no measurable ink, placement falls
// back to the face-local path.
_atlas_rasterize_fallback_fitted :: proc(
	a: ^Atlas,
	rasterizer: ^Font_Rasterizer,
	codepoint: u32,
	dst_x, dst_y: int,
	slot_size: int,
) {
	base_w, base_h, measured := font_measure_glyph_ink(rasterizer, codepoint)
	if a.primary_cap_px <= 0 || a.primary_baseline_px < 0 || !measured || base_w <= 0 || base_h <= 0 {
		font_rasterize_glyph_into(
			rasterizer,
			codepoint,
			a.pixels,
			a.tex_width,
			dst_x, dst_y,
			slot_size, slot_size,
		)
		return
	}

	size := rasterizer.metrics.pixel_size * f32(a.primary_cap_px) / f32(base_h)
	size = min(size, rasterizer.metrics.pixel_size * ATLAS_FALLBACK_MAX_SCALE)

	ink_w, ink_h, _ := font_measure_glyph_ink(rasterizer, codepoint, size)
	steps := 0
	for (ink_w > a.cell_width || ink_h > a.cell_height) && steps < ATLAS_FALLBACK_FIT_STEPS {
		size *= ATLAS_FALLBACK_FIT_STEP
		ink_w, ink_h, measured = font_measure_glyph_ink(rasterizer, codepoint, size)
		if !measured || ink_h <= 0 {
			break
		}
		steps += 1
	}

	font_rasterize_glyph_sized_into(
		rasterizer,
		codepoint,
		size,
		a.pixels,
		a.tex_width,
		dst_x, dst_y,
		slot_size, slot_size,
		a.primary_baseline_px,
		a.cell_width,
	)
}

// _atlas_rasterize_into_slot rasterizes a glyph into a specific atlas slot
// and reports whether this rasterizer's face actually covers it.
//
// UV fields are written unconditionally, so an uncovered codepoint still
// leaves correct coordinates behind for a later fallback fill. `valid` is
// only raised when the face really covers the glyph: FreeType otherwise
// silently rasterizes glyph index 0 (.notdef), and claiming validity for
// that blank would permanently block atlas_prewarm_chain / atlas_pin_audit
// from promoting the slot from the fallback chain.
//
// Ligature-slot codepoints address a glyph index directly rather than a
// codepoint, so there is no coverage query for them; they stay
// unconditionally valid.
//
// is_primary states whether rasterizer is the atlas's primary face. Primary
// glyphs are placed exactly as before; fallback-sourced glyphs are scaled to
// the primary's cap height and bottom-aligned to the primary's baseline
// (_atlas_rasterize_fallback_fitted), since a symbol face's ascender and its
// per-glyph baseline offsets do not match the cell the atlas was laid out
// for. The flag is explicit rather than inferred, so the branch cannot
// silently follow a pointer change.
_atlas_rasterize_into_slot :: proc(
	a: ^Atlas,
	rasterizer: ^Font_Rasterizer,
	codepoint: u32,
	slot_index: int,
	is_primary: bool,
) -> (covered: bool) {
	slot := &a.slots[slot_index]

	col := slot_index % ATLAS_COLS
	row := slot_index / ATLAS_COLS

	glyph_size := a.glyph_size
	x0 := col * glyph_size
	y0 := row * glyph_size

	// Calculate texture coordinates
	tex_w := f32(a.tex_width)
	tex_h := f32(a.tex_height)
	slot.u0 = f32(x0) / tex_w
	slot.v0 = f32(y0) / tex_h
	slot.u1 = f32(x0 + a.cell_width) / tex_w
	slot.v1 = f32(y0 + a.cell_height) / tex_h
	slot.advance = f32(a.cell_width)

	// Rasterize glyph directly into atlas pixel buffer
	if codepoint >= CONTENT_LIGATURE_BASE && codepoint < 0x1FFFFF {
		slot.valid = true
		g_idx := codepoint - CONTENT_LIGATURE_BASE
		font_rasterize_glyph_index_into(
			rasterizer,
			g_idx,
			a.pixels,
			a.tex_width,
			x0, y0,
			glyph_size, glyph_size,
		)
		return true
	}

	// Codepoint-addressed paths: only claim validity when the face covers
	// the codepoint, otherwise leave the slot for the fallback chain.
	if !font_rasterizer_has_glyph(rasterizer, codepoint) {
		return false
	}
	slot.valid = true

	if codepoint >= PINNED_POWERLINE_START && codepoint <= PINNED_POWERLINE_END {
		cw := a.cell_width
		ch := a.cell_height
		bmp := font_rasterize_glyph_fitted(rasterizer, codepoint, cw, ch)
		if bmp.pixels != nil {
			_atlas_blit_bitmap(a, &bmp, slot_index, false, int(math.round(rasterizer.metrics.ascent)))
			delete(bmp.pixels)
		}
	} else if is_primary {
		font_rasterize_glyph_into(
			rasterizer,
			codepoint,
			a.pixels,
			a.tex_width,
			x0, y0,
			glyph_size, glyph_size,
		)
	} else {
		_atlas_rasterize_fallback_fitted(a, rasterizer, codepoint, x0, y0, glyph_size)
	}
	return true
}

// atlas_lookup returns the atlas slot for a given codepoint.
// This is the public API for looking up glyphs during rendering.
atlas_lookup :: proc(a: ^Atlas, codepoint: u32) -> (index: int, slot: ^Atlas_Slot) {
	return atlas_get_slot(a, codepoint)
}

// atlas_upload_gpu uploads the atlas pixel data to the GPU.
// This should be called after atlas_init or when gpu_dirty is true.
atlas_upload_gpu :: proc(
	a: ^Atlas,
	backend: ^gpu.Gpu_Backend_VTable,
	device: gpu.Gpu_Device,
	queue: gpu.Gpu_Queue,
) {
	if backend == nil || rawptr(device) == nil || rawptr(queue) == nil {
		return
	}
	if a.gpu_dirty {
		// Create texture if it doesn't exist
		if rawptr(a.gpu_texture) == nil {
			a.gpu_texture = backend.create_texture(
				device,
				u32(a.tex_width),
				u32(a.tex_height),
				gpu.Gpu_Format.R8_Unorm,
				gpu.Gpu_Texture_Usage.Texture_Binding | gpu.Gpu_Texture_Usage.Copy_Dst,
			)

			a.gpu_view = backend.create_texture_view(a.gpu_texture)
		}

		// Upload pixel data
		backend.write_texture(queue, a.gpu_texture, a.pixels, u32(a.tex_width), u32(a.tex_height))

		a.gpu_dirty = false
	}
}

// ============================================================================
// Dynamic fallback region (slots 271..511, FIFO eviction).
// Pinned slots 0..270 are never rewritten here.
// ============================================================================

// atlas_dynamic_lookup scans the 241 dynamic tags for (font_index, shaped).
// Hit requires the slot to be valid. Slow-path only.
atlas_dynamic_lookup :: proc(a: ^Atlas, font_index: int, shaped: u32) -> (slot: int, hit: bool) {
	return atlas_dynamic_lookup_p(a, font_index, shaped, nil)
}

// atlas_dynamic_lookup_p is the counted lookup wrapper: identical lookup
// logic, plus hit/miss accounting when p is non-nil. A miss records no
// atlas mutation.
atlas_dynamic_lookup_p :: proc(a: ^Atlas, font_index: int, shaped: u32, p: ^Atlas_Pressure) -> (slot: int, hit: bool) {
	slot, hit = _atlas_dynamic_lookup_inner(a, font_index, shaped)
	if p != nil {
		if hit {
			atlas_pressure_note_hit(p)
		} else {
			p.dynamic_miss += 1
		}
	}
	return slot, hit
}

// _atlas_dynamic_lookup_inner holds the single lookup implementation both
// the legacy and the counted wrapper share.
_atlas_dynamic_lookup_inner :: proc(a: ^Atlas, font_index: int, shaped: u32) -> (slot: int, hit: bool) {
	if a == nil || font_index < 0 || font_index >= FALLBACK_MAX_FONTS {
		return 0, false
	}
	want := (u64(font_index) << 32) | u64(shaped)
	for i in 0..<FALLBACK_SLOT_COUNT {
		tag := a.fallback_tag[i]
		if tag == 0 || tag != want {
			continue
		}
		slot = FALLBACK_SLOT_BASE + i
		if slot < ATLAS_SLOT_COUNT && a.slots[slot].valid {
			return slot, true
		}
		return 0, false
	}
	return 0, false
}

// atlas_dynamic_claim rasterizes (font_index, shaped) plus overstruck marks
// into the next FIFO dynamic slot, evicting the oldest entry when full.
// Marks are composited with max-blend so cross-font base+mark pairs share
// ONE slot. gpu_dirty is set. ok is false only for a zero bitmap of a
// non-space glyph (the caller falls back to tofu inside ensure).
atlas_dynamic_claim :: proc(
	a: ^Atlas,
	chain: ^Fallback_Chain,
	font_index: int,
	shaped: u32,
	marks: []rune,
) -> (slot: int, ok: bool) {
	return atlas_dynamic_claim_p(a, chain, font_index, shaped, marks, nil)
}

// atlas_dynamic_claim_p is the counted claim wrapper: identical rasterize
// path, plus evicted_tag/wrap accounting when p is non-nil.
atlas_dynamic_claim_p :: proc(
	a: ^Atlas,
	chain: ^Fallback_Chain,
	font_index: int,
	shaped: u32,
	marks: []rune,
	p: ^Atlas_Pressure,
) -> (slot: int, ok: bool) {
	if a == nil || chain == nil {
		return 0, false
	}
	sync.mutex_lock(&chain.mutex)
	defer sync.mutex_unlock(&chain.mutex)
	if font_index < 0 || font_index >= chain.count || font_index >= FALLBACK_MAX_FONTS {
		return 0, false
	}
	f := &chain.fonts[font_index]
	if f.face == nil {
		return 0, false
	}
	if shaped >= CONTENT_LIGATURE_BASE && shaped < 0x1FFFFF {
		g_idx := shaped - CONTENT_LIGATURE_BASE
		if g_idx == 0 {
			return 0, false
		}
	} else if font_rasterizer_find_glyph_index(f, shaped) == 0 {
		return 0, false
	}

	pos := a.fallback_cursor % FALLBACK_SLOT_COUNT
	old_cursor := a.fallback_cursor
	a.fallback_cursor = (a.fallback_cursor + 1) % FALLBACK_SLOT_COUNT
	if p != nil {
		atlas_pressure_note_claim(p, a.fallback_tag[pos], a.fallback_cursor < old_cursor)
		p.last_cursor = a.fallback_cursor
	}
	slot = FALLBACK_SLOT_BASE + pos
	a.fallback_fifo[pos] = shaped
	a.fallback_tag[pos] = (u64(font_index) << 32) | u64(shaped)

	_atlas_clear_slot_rect(a, slot)

	wide := termgrid.wcwidth(rune(shaped)) == 2
	max_w := int(a.cell_width) * 2 if wide else int(a.cell_width)
	max_h := int(a.cell_height)
	base_bmp: Glyph_Bitmap
	if shaped >= CONTENT_LIGATURE_BASE && shaped < 0x1FFFFF {
		g_idx := shaped - CONTENT_LIGATURE_BASE
		base_bmp = font_rasterize_glyph_index_fitted(f, g_idx, max_w, max_h)
	} else {
		base_bmp = font_rasterize_glyph_fitted(f, shaped, max_w, max_h)
	}
	base_advance := f32(base_bmp.advance)
	if base_bmp.pixels != nil {
		_atlas_blit_bitmap(a, &base_bmp, slot, false, int(math.round(f.metrics.ascent)))
		delete(base_bmp.pixels)
	}
	for m in marks {
		if m == 0 {
			continue
		}
		mf, covered := _fallback_font_for_mark(chain, m)
		if !covered {
			continue
		}
		mark_bmp := font_rasterize_glyph(mf, u32(m))
		if mark_bmp.pixels != nil {
			_atlas_blit_bitmap(a, &mark_bmp, slot, true, int(math.round(mf.metrics.ascent)))
			delete(mark_bmp.pixels)
		}
	}

	adv := f32(a.cell_width * 2 if wide else a.cell_width)
	_atlas_setup_dynamic_slot(a, slot, base_advance if base_advance > 0 else adv, wide)
	a.gpu_dirty = true

	if _atlas_slot_rect_empty(a, slot) && shaped != 0x20 {
		a.slots[slot].valid = false
		return slot, false
	}
	a.slots[slot].valid = true
	return slot, true
}

// atlas_ensure_glyph is the single sync ensure: tag hit returns the cached
// slot, otherwise claim rasterizes and inserts into the shape cache. When
// rasterization yields no bitmap, tofu is claimed inside; when tofu itself
// is uncovered anywhere, tofu_missing counts and an UNRESOLVED glyph returns
// (expands to bg only, never panics).
atlas_ensure_glyph :: proc(
	a: ^Atlas,
	chain: ^Fallback_Chain,
	cache: ^Shape_Cache,
	key: Cluster_Key,
	font_index: int,
	shaped: u32,
	marks: []rune,
	counters: ^Fallback_Counters,
) -> Shaped_Glyph {
	wide := termgrid.wcwidth(rune(key.runes[0])) == 2
	press := (^Atlas_Pressure)(nil)
	if a != nil {
		press = a.pressure
	}
	if slot, hit := atlas_dynamic_lookup_p(a, font_index, shaped, press); hit {
		g := Shaped_Glyph{
			font_index       = u8(font_index),
			shaped_codepoint = shaped,
			atlas_slot       = u16(slot),
			wide             = wide,
		}
		shape_cache_insert(cache, key, g)
		return g
	}
	if slot, ok := atlas_dynamic_claim_p(a, chain, font_index, shaped, marks, press); ok {
		g := Shaped_Glyph{
			font_index       = u8(font_index),
			shaped_codepoint = shaped,
			atlas_slot       = u16(slot),
			wide             = wide,
		}
		shape_cache_insert(cache, key, g)
		return g
	}
	// Raster produced no bitmap: claim tofu inside.
	if tfi, tcov := fallback_resolve(chain, FALLBACK_TOFU_PRIMARY, counters); tcov {
		if tslot, tok := atlas_dynamic_claim_p(a, chain, tfi, FALLBACK_TOFU_PRIMARY, nil, press); tok {
			g := Shaped_Glyph{
				font_index       = u8(tfi),
				shaped_codepoint = FALLBACK_TOFU_PRIMARY,
				atlas_slot       = u16(tslot),
				wide             = false,
			}
			shape_cache_insert(cache, key, g)
			return g
		}
	}
	if sfi, scov := fallback_resolve(chain, FALLBACK_TOFU_SECONDARY, counters); scov {
		if sslot, sok := atlas_dynamic_claim_p(a, chain, sfi, FALLBACK_TOFU_SECONDARY, nil, press); sok {
			g := Shaped_Glyph{
				font_index       = u8(sfi),
				shaped_codepoint = FALLBACK_TOFU_SECONDARY,
				atlas_slot       = u16(sslot),
				wide             = false,
			}
			shape_cache_insert(cache, key, g)
			return g
		}
	}
	if counters != nil {
		counters.tofu_missing += 1
	}
	return Shaped_Glyph{
		font_index       = u8(font_index),
		shaped_codepoint = shaped,
		atlas_slot       = RENDER_CELL_V2_SLOT_UNRESOLVED,
		wide             = wide,
	}
}

// atlas_apply_completion applies one worker completion on the render
// thread: FIFO slot claim at drain, clear + copy + tag +
// shape_cache_insert + gpu_dirty. No slot is assigned at enqueue, so FIFO
// eviction between enqueue and drain cannot corrupt the result. ok=false
// (zero bitmap or uncovered glyph) takes the existing sync tofu path, so
// the outcome is Phase-11-identical.
atlas_apply_completion :: proc(
	a: ^Atlas,
	cache: ^Shape_Cache,
	c: ^Raster_Completion,
	chain: ^Fallback_Chain = nil,
	counters: ^Fallback_Counters = nil,
) -> (slot: int, ok: bool) {
	if a == nil || c == nil {
		return 0, false
	}
	if !c.ok || c.pixels == nil {
		return _atlas_apply_tofu(a, cache, c.key, chain, counters)
	}
	pos := a.fallback_cursor % FALLBACK_SLOT_COUNT
	old_cursor := a.fallback_cursor
	a.fallback_cursor = (a.fallback_cursor + 1) % FALLBACK_SLOT_COUNT
	if a.pressure != nil {
		atlas_pressure_note_claim(a.pressure, a.fallback_tag[pos], a.fallback_cursor < old_cursor)
		a.pressure.last_cursor = a.fallback_cursor
	}
	slot = FALLBACK_SLOT_BASE + pos
	a.fallback_fifo[pos] = c.shaped
	a.fallback_tag[pos] = (u64(c.font_index) << 32) | u64(c.shaped)

	_atlas_clear_slot_rect(a, slot)

	x0, y0 := _atlas_slot_origin(a, slot)
	for gy in 0..<c.height {
		for gx in 0..<c.width {
			dx := x0 + gx
			dy := y0 + gy
			if dx < 0 || dx >= a.tex_width || dy < 0 || dy >= a.tex_height {
				continue
			}
			di := dy * a.tex_width + dx
			si := gy * c.width + gx
			if di < len(a.pixels) && si < len(c.pixels) {
				a.pixels[di] = c.pixels[si]
			}
		}
	}

	wide := termgrid.wcwidth(c.key.runes[0]) == 2
	_atlas_setup_dynamic_slot(a, slot, c.advance, wide)
	a.gpu_dirty = true

	if _atlas_slot_rect_empty(a, slot) && c.shaped != 0x20 {
		a.slots[slot].valid = false
		return _atlas_apply_tofu(a, cache, c.key, chain, counters)
	}
	a.slots[slot].valid = true
	g := Shaped_Glyph{
		font_index       = u8(c.font_index),
		shaped_codepoint = c.shaped,
		atlas_slot       = u16(slot),
		wide             = wide,
	}
	shape_cache_insert(cache, c.key, g)
	return slot, true
}

// _atlas_apply_tofu claims the tofu glyph inside the drain (render thread,
// sync) or counts tofu_missing when tofu itself is uncovered. Mirrors the
// tail of atlas_ensure_glyph so worker-failure outcomes stay identical.
_atlas_apply_tofu :: proc(
	a: ^Atlas,
	cache: ^Shape_Cache,
	key: Cluster_Key,
	chain: ^Fallback_Chain,
	counters: ^Fallback_Counters,
) -> (slot: int, ok: bool) {
	if a != nil && chain != nil {
		if tfi, tcov := fallback_resolve(chain, FALLBACK_TOFU_PRIMARY, counters); tcov {
			if tslot, tok := atlas_dynamic_claim_p(a, chain, tfi, FALLBACK_TOFU_PRIMARY, nil, a.pressure); tok {
				g := Shaped_Glyph{
					font_index       = u8(tfi),
					shaped_codepoint = FALLBACK_TOFU_PRIMARY,
					atlas_slot       = u16(tslot),
					wide             = false,
				}
				shape_cache_insert(cache, key, g)
				return tslot, true
			}
		}
		if sfi, scov := fallback_resolve(chain, FALLBACK_TOFU_SECONDARY, counters); scov {
			if sslot, sok := atlas_dynamic_claim_p(a, chain, sfi, FALLBACK_TOFU_SECONDARY, nil, a.pressure); sok {
				g := Shaped_Glyph{
					font_index       = u8(sfi),
					shaped_codepoint = FALLBACK_TOFU_SECONDARY,
					atlas_slot       = u16(sslot),
					wide             = false,
				}
				shape_cache_insert(cache, key, g)
				return sslot, true
			}
		}
	}
	if counters != nil {
		counters.tofu_missing += 1
	}
	return 0, false
}

// atlas_pin_audit fills pinned slots the primary left invalid from the
// first covering fallback font and returns the promoted count. One-time
// startup/font-change audit, never per-frame. Only pinned slots 0..270
// are written; the dynamic region is never touched.
atlas_pin_audit :: proc(a: ^Atlas, chain: ^Fallback_Chain) -> (promoted: int) {
	if a == nil || chain == nil {
		return 0
	}
	set := atlas_prewarm_set()
	defer delete(set)

	for codepoint in set {
		idx, ok := atlas_pinned_slot_index(u32(codepoint))
		if !ok {
			continue
		}
		if a.slots[idx].valid {
			continue
		}
		for fi in 0..<chain.count {
			f := &chain.fonts[fi]
			if f.face == nil {
				continue
			}
			if font_rasterizer_find_glyph_index(f, u32(codepoint)) == 0 {
				continue
			}
			_atlas_rasterize_into_slot(a, f, u32(codepoint), idx, false)
			promoted += 1
			break
		}
	}

	if promoted > 0 {
		a.gpu_dirty = true
	}
	return promoted
}

// atlas_prewarm_chain fills pinned slots the primary left invalid from the
// first covering fallback font. Slots the primary already rasterized are
// kept. pinned_count ends as the total valid pinned glyph count.
atlas_prewarm_chain :: proc(a: ^Atlas, chain: ^Fallback_Chain) {
	if a == nil || chain == nil {
		return
	}
	set := atlas_prewarm_set()
	defer delete(set)

	for codepoint in set {
		idx, ok := atlas_pinned_slot_index(u32(codepoint))
		if !ok {
			continue
		}
		if a.slots[idx].valid {
			continue
		}
		for fi in 0..<chain.count {
			f := &chain.fonts[fi]
			if f.face == nil {
				continue
			}
			if font_rasterizer_find_glyph_index(f, u32(codepoint)) == 0 {
				continue
			}
			_atlas_rasterize_into_slot(a, f, u32(codepoint), idx, false)
			break
		}
	}

	pinned := 0
	for codepoint in set {
		if idx, ok := atlas_pinned_slot_index(u32(codepoint)); ok {
			if a.slots[idx].valid {
				pinned += 1
			}
		}
	}
	a.pinned_count = pinned
	a.gpu_dirty = true
}

// _fallback_font_for_mark finds the first chain font covering a combining
// mark without touching counters (mark misses count as mark_drop at the
// call site, never as fallback_miss).
_fallback_font_for_mark :: proc(chain: ^Fallback_Chain, mark: rune) -> (f: ^Font_Rasterizer, covered: bool) {
	if chain == nil {
		return nil, false
	}
	for i in 0..<chain.count {
		f := &chain.fonts[i]
		if f.face == nil {
			continue
		}
		if font_rasterizer_find_glyph_index(f, u32(mark)) != 0 {
			return f, true
		}
	}
	return nil, false
}

// _atlas_slot_origin returns the pixel origin of a slot's glyph rect.
_atlas_slot_origin :: proc(a: ^Atlas, slot_index: int) -> (x0: int, y0: int) {
	col := slot_index % ATLAS_COLS
	row := slot_index / ATLAS_COLS
	return col * a.glyph_size, row * a.glyph_size
}

// _atlas_clear_slot_rect zeroes a dynamic slot's pixel rect so evicted glyph
// pixels can never ghost through the newly claimed glyph.
_atlas_clear_slot_rect :: proc(a: ^Atlas, slot_index: int) {
	x0, y0 := _atlas_slot_origin(a, slot_index)
	for y in 0..<a.glyph_size {
		for x in 0..<a.glyph_size {
			dx := x0 + x
			dy := y0 + y
			if dx < 0 || dx >= a.tex_width || dy < 0 || dy >= a.tex_height {
				continue
			}
			di := dy * a.tex_width + dx
			if di < len(a.pixels) {
				a.pixels[di] = 0
			}
		}
	}
}

// _atlas_blit_bitmap copies a tight glyph bitmap into a slot rect using baseline anchoring.
// blend_max overstrikes (marks composite over the base); otherwise assigns.
_atlas_blit_bitmap :: proc(a: ^Atlas, bmp: ^Glyph_Bitmap, slot_index: int, blend_max: bool, ascent_px: int) {
	if bmp.width <= 0 || bmp.height <= 0 || bmp.pixels == nil {
		return
	}
	x0, y0 := _atlas_slot_origin(a, slot_index)
	ox := x0 + int(bmp.bearing_x)
	oy := y0 + ascent_px + int(bmp.bearing_y)
	for gy in 0..<bmp.height {
		for gx in 0..<bmp.width {
			dx := ox + gx
			dy := oy + gy
			if dx < x0 || dx >= x0 + a.glyph_size || dy < y0 || dy >= y0 + a.glyph_size {
				continue
			}
			if dx < 0 || dx >= a.tex_width || dy < 0 || dy >= a.tex_height {
				continue
			}
			di := dy * a.tex_width + dx
			si := gy * bmp.width + gx
			if di < len(a.pixels) && si < len(bmp.pixels) {
				if blend_max {
					if bmp.pixels[si] > a.pixels[di] {
						a.pixels[di] = bmp.pixels[si]
					}
				} else {
					a.pixels[di] = bmp.pixels[si]
				}
			}
		}
	}
}

// _atlas_setup_dynamic_slot assigns texture coordinates and advance for a
// dynamic slot. Dynamic slots for wide characters span a double-cell width (a.cell_width * 2)
// in texture space, eliminating truncation of wide glyphs.
_atlas_setup_dynamic_slot :: proc(a: ^Atlas, slot_index: int, advance: f32, wide: bool = false) {
	slot := &a.slots[slot_index]
	col := slot_index % ATLAS_COLS
	row := slot_index / ATLAS_COLS
	glyph_size := a.glyph_size
	x0 := col * glyph_size
	y0 := row * glyph_size
	tex_w := f32(a.tex_width)
	tex_h := f32(a.tex_height)
	slot_w := a.cell_width * 2 if wide else a.cell_width
	slot_h := a.cell_height
	slot.u0 = f32(x0) / tex_w
	slot.v0 = f32(y0) / tex_h
	slot.u1 = f32(x0 + slot_w) / tex_w
	slot.v1 = f32(y0 + slot_h) / tex_h
	slot.advance = advance
}

// _atlas_slot_rect_empty reports whether a slot's pixel rect is all zero.
_atlas_slot_rect_empty :: proc(a: ^Atlas, slot_index: int) -> bool {
	x0, y0 := _atlas_slot_origin(a, slot_index)
	for y in 0..<a.glyph_size {
		for x in 0..<a.glyph_size {
			dx := x0 + x
			dy := y0 + y
			if dx < 0 || dx >= a.tex_width || dy < 0 || dy >= a.tex_height {
				continue
			}
			di := dy * a.tex_width + dx
			if di < len(a.pixels) && a.pixels[di] != 0 {
				return false
			}
		}
	}
	return true
}
