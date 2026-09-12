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
import "vendor:stb/truetype"
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

// FALLBACK_SLOT_COUNT is the number of dynamic slots (271..511).
FALLBACK_SLOT_COUNT :: 241

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

// atlas_destroy frees the atlas pixel buffer and GPU resources.
atlas_destroy :: proc(a: ^Atlas, allocator: runtime.Allocator = context.allocator) {
	if a.pixels != nil {
		delete(a.pixels)
		a.pixels = nil
	}

	// Note: GPU resources are released by the backend when the device is destroyed.
	// We just clear the handles here.
	a.gpu_texture = gpu.Gpu_Texture(nil)
	a.gpu_view = gpu.Gpu_TextureView(nil)
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

		_atlas_rasterize_into_slot(a, rasterizer, u32(codepoint), idx)
		a.pinned_count += 1
	}

	a.gpu_dirty = true
}

// _atlas_rasterize_into_slot rasterizes a glyph into a specific atlas slot.
_atlas_rasterize_into_slot :: proc(
	a: ^Atlas,
	rasterizer: ^Font_Rasterizer,
	codepoint: u32,
	slot_index: int,
) {
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
	slot.u1 = f32(x0 + int(rasterizer.metrics.cell_width)) / tex_w
	slot.v1 = f32(y0 + int(rasterizer.metrics.cell_height)) / tex_h
	slot.advance = rasterizer.metrics.cell_width
	slot.valid = true

	// Rasterize glyph directly into atlas pixel buffer
	font_rasterize_glyph_into(
		rasterizer,
		codepoint,
		a.pixels,
		a.tex_width,
		x0, y0,
		glyph_size, glyph_size,
	)
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
	if font_index < 0 || font_index >= chain.count || font_index >= FALLBACK_MAX_FONTS {
		return 0, false
	}
	f := &chain.fonts[font_index]
	if f.font_data == nil {
		return 0, false
	}
	if truetype.FindGlyphIndex(&f.info, rune(shaped)) == 0 {
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

	base_bmp := font_rasterize_glyph(f, shaped)
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

	_atlas_setup_dynamic_slot(a, slot, f.metrics.cell_width)
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
	wide := termgrid.wcwidth(rune(key.base)) == 2
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

	_atlas_setup_dynamic_slot(a, slot, c.advance)
	a.gpu_dirty = true

	if _atlas_slot_rect_empty(a, slot) && c.shaped != 0x20 {
		a.slots[slot].valid = false
		return _atlas_apply_tofu(a, cache, c.key, chain, counters)
	}
	a.slots[slot].valid = true
	wide := termgrid.wcwidth(c.key.base) == 2
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
			if f.font_data == nil {
				continue
			}
			if truetype.FindGlyphIndex(&f.info, rune(codepoint)) == 0 {
				continue
			}
			_atlas_rasterize_into_slot(a, f, u32(codepoint), idx)
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
			if f.font_data == nil {
				continue
			}
			if truetype.FindGlyphIndex(&f.info, rune(codepoint)) == 0 {
				continue
			}
			_atlas_rasterize_into_slot(a, f, u32(codepoint), idx)
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
		if f.font_data == nil {
			continue
		}
		if truetype.FindGlyphIndex(&f.info, mark) != 0 {
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
// dynamic slot (mirrors _atlas_rasterize_into_slot metadata, valid set by
// the caller after the bitmap check).
_atlas_setup_dynamic_slot :: proc(a: ^Atlas, slot_index: int, advance: f32) {
	slot := &a.slots[slot_index]
	col := slot_index % ATLAS_COLS
	row := slot_index / ATLAS_COLS
	glyph_size := a.glyph_size
	x0 := col * glyph_size
	y0 := row * glyph_size
	tex_w := f32(a.tex_width)
	tex_h := f32(a.tex_height)
	slot.u0 = f32(x0) / tex_w
	slot.v0 = f32(y0) / tex_h
	slot.u1 = f32(x0 + a.cell_width) / tex_w
	slot.v1 = f32(y0 + a.cell_height) / tex_h
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
