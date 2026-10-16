package term

// System Font Discovery & FreeType Fallback Loader
// Part of Tier 3 Application Shell (src/app/term/*).

import "core:math"
import "core:os"
import cell "../../core/terminal/cell"
import helper "../../cmd/harness_helper"

FONT_DISCOVERY_PATHS := []string{
	"assets/fonts/MapleMono-NF-Regular.ttf",
	"assets/fonts/MapleMono-Regular.ttf",
	"assets/fonts/SymbolsNerdFontMono-Regular.ttf",
	"/Library/Fonts/MesloLGS NF Regular.ttf",
	"/Library/Fonts/JetBrainsMonoNerdFont-Regular.ttf",
	"/System/Library/Fonts/SFNSMono.ttf",
	"/System/Library/Fonts/Menlo.ttc",
	"/System/Library/Fonts/Monaco.ttf",
	"/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
}

MAX_FALLBACKS :: 8

FALLBACK_DISCOVERY_PATHS := []string{
	"assets/fonts/SymbolsNerdFontMono-Regular.ttf",
	"/System/Library/Fonts/Apple Color Emoji.ttc",
	"/System/Library/Fonts/SFNSMono.ttf",
	"/System/Library/Fonts/Apple Symbols.ttf",
	"/System/Library/Fonts/Menlo.ttc",
	"/System/Library/Fonts/Monaco.ttf",
	"/Library/Fonts/Arial Unicode.ttf",
}

Font_Context :: struct {
	rasterizer:         helper.Font_Rasterizer,
	has_font:           bool,
	fallbacks:          [MAX_FALLBACKS]helper.Font_Rasterizer,
	fallback_paths:     [MAX_FALLBACKS]string,
	fallback_count:     int,
	pixel_size:         f32,
	active_path:        string,
	primary_cap_px:     int,
	primary_baseline_px: int,
}

font_context_init :: proc(fc: ^Font_Context, pixel_size: f32 = 32.0) -> bool {
	if fc == nil do return false
	fc.pixel_size = pixel_size
	fc.has_font = false
	fc.active_path = ""
	fc.fallback_count = 0

	// 1. Discover Primary Font
	for p in FONT_DISCOVERY_PATHS {
		if os.is_file(p) {
			err: helper.Font_Error
			if helper.font_rasterizer_init(&fc.rasterizer, p, pixel_size, &err) {
				fc.has_font = true
				fc.active_path = p
				break
			}
		}
	}

	if !fc.has_font do return false

	// Calibrate the primary face's optical cap height and baseline once, so
	// fallback faces (symbol fonts, Nerd Font icons) can be scaled and
	// bottom-aligned to the same visual baseline as the text face.
	fc.primary_cap_px, fc.primary_baseline_px = _calibrate_reference(&fc.rasterizer)

	// 2. Discover Fallback Fonts (Symbols, Icons, System glyphs)
	for p in FALLBACK_DISCOVERY_PATHS {
		if fc.fallback_count >= MAX_FALLBACKS do break
		if p == fc.active_path do continue
		if os.is_file(p) {
			err: helper.Font_Error
			if helper.font_rasterizer_init(&fc.fallbacks[fc.fallback_count], p, pixel_size, &err) {
				fc.fallback_paths[fc.fallback_count] = p
				fc.fallback_count += 1
			}
		}
	}

	return true
}

font_context_destroy :: proc(fc: ^Font_Context) {
	if fc == nil do return
	if fc.has_font {
		helper.font_rasterizer_destroy(&fc.rasterizer)
		fc.has_font = false
	}
	for i in 0..<fc.fallback_count {
		helper.font_rasterizer_destroy(&fc.fallbacks[i])
	}
	fc.fallback_count = 0
}

font_has_codepoint :: proc(fc: ^Font_Context, cp: u32) -> bool {
	if fc == nil do return false
	if fc.has_font && helper.font_rasterizer_find_glyph_index(&fc.rasterizer, cp) != 0 {
		return true
	}
	for i in 0..<fc.fallback_count {
		if helper.font_rasterizer_find_glyph_index(&fc.fallbacks[i], cp) != 0 {
			return true
		}
	}
	return false
}

// Optical calibration constants (ported from legacy/src/render/atlas.odin).
// Fallback faces are scaled so their ink height matches the primary face's cap
// height, then bottom-aligned to the primary's baseline, so UI symbols and
// Nerd Font icons share the text face's optical size and baseline instead of
// floating on their own (usually much larger) face metrics.
ATLAS_FALLBACK_MAX_SCALE : f32 : 4.0
ATLAS_FALLBACK_FIT_STEP  : f32 : 0.95
ATLAS_FALLBACK_FIT_STEPS : int : 24

_is_powerline :: proc(cp: u32) -> bool {
	return cp >= 0xE0B0 && cp <= 0xE0B3
}

// is_emoji_codepoint reports whether r is a standard emoji-presentation or
// pictograph codepoint, so the renderer can route it to the color emoji atlas.
// Delegates to the cell package's single source of truth.
is_emoji_codepoint :: proc(r: rune) -> bool {
	return cell.is_emoji_codepoint(r)
}

// _calibrate_reference measures the primary face's cap height and baseline row
// from the rendered ink of a reference glyph ('H', falling back to '0').
_calibrate_reference :: proc(r: ^helper.Font_Rasterizer) -> (cap_px, baseline_px: int) {
	references := [2]u32{'H', '0'}
	for cp in references {
		if helper.font_rasterizer_find_glyph_index(r, cp) == 0 do continue
		_, height, _, bottom, ok := helper.font_measure_glyph_ink_box(r, cp)
		if ok do return height, bottom
	}
	return 0, -1
}

// _blit_centered_bitmap copies a tight glyph bitmap into a slot rect, centering
// it within (box_w x box_h) anchored at (px, py).
_blit_centered_bitmap :: proc(
	bmp: ^helper.Glyph_Bitmap,
	dst_pixels: []u8,
	pitch: int,
	px, py: int,
	slot_w, slot_h: int,
	box_w, box_h: int,
) {
	if bmp == nil || bmp.pixels == nil || bmp.width <= 0 || bmp.height <= 0 do return
	ox := px + (box_w - bmp.width) / 2
	oy := py + (box_h - bmp.height) / 2
	for gy in 0..<bmp.height {
		for gx in 0..<bmp.width {
			dx := ox + gx
			dy := oy + gy
			if dx >= px && dx < px + slot_w && dy >= py && dy < py + slot_h {
				dst_idx := dy * pitch + dx
				src_idx := gy * bmp.width + gx
				if dst_idx >= 0 && dst_idx < len(dst_pixels) && src_idx < len(bmp.pixels) {
					dst_pixels[dst_idx] = bmp.pixels[src_idx]
				}
			}
		}
	}
}

// _rasterize_powerline renders a Powerline caret proportionally fitted and
// centered in its cell. Powerline glyphs are standalone decorative separators
// designed to hang at their own height, so they keep face-local placement.
_rasterize_powerline :: proc(
	r: ^helper.Font_Rasterizer,
	cp: u32,
	dst_pixels: []u8,
	pitch: int,
	px, py: int,
	slot_w, slot_h: int,
	cell_w, cell_h: int,
	is_wide: bool,
) {
	box_w := cell_w * 2 if is_wide else cell_w
	max_w := max(1, box_w - 2)
	max_h := max(1, cell_h - 2)
	bmp := helper.font_rasterize_glyph_fitted(r, cp, max_w, max_h)
	defer if bmp.pixels != nil do delete(bmp.pixels)
	if bmp.width > 0 && bmp.height > 0 && bmp.pixels != nil {
		_blit_centered_bitmap(&bmp, dst_pixels, pitch, px, py, slot_w, slot_h, box_w, cell_h)
		return
	}
	helper.font_rasterize_glyph_into(r, cp, dst_pixels, pitch, px, py, slot_w, slot_h)
}

// _rasterize_fallback_fitted renders a fallback-face glyph scaled so its ink
// height matches the primary's calibrated cap height, then bottom-aligns its
// ink to the primary's baseline. Mirrors legacy/src/render/atlas.odin
// (_atlas_rasterize_fallback_fitted).
_rasterize_fallback_fitted :: proc(
	fc: ^Font_Context,
	r: ^helper.Font_Rasterizer,
	cp: u32,
	dst_pixels: []u8,
	pitch: int,
	px, py: int,
	slot_w, slot_h: int,
	cell_w, cell_h: int,
	center_w: int,
) {
	base_w, base_h, measured := helper.font_measure_glyph_ink(r, cp)
	if fc.primary_cap_px <= 0 || fc.primary_baseline_px < 0 || !measured || base_w <= 0 || base_h <= 0 {
		helper.font_rasterize_glyph_into(r, cp, dst_pixels, pitch, px, py, slot_w, slot_h)
		return
	}

	size := r.metrics.pixel_size * f32(fc.primary_cap_px) / f32(base_h)
	size = min(size, r.metrics.pixel_size * ATLAS_FALLBACK_MAX_SCALE)

	ink_w, ink_h, _ := helper.font_measure_glyph_ink(r, cp, size)
	steps := 0
	for (ink_w > cell_w || ink_h > cell_h) && steps < ATLAS_FALLBACK_FIT_STEPS {
		size *= ATLAS_FALLBACK_FIT_STEP
		ink_w, ink_h, measured = helper.font_measure_glyph_ink(r, cp, size)
		if !measured || ink_h <= 0 do break
		steps += 1
	}

	helper.font_rasterize_glyph_sized_into(
		r, cp, size, dst_pixels, pitch, px, py, slot_w, slot_h,
		fc.primary_baseline_px, center_w,
	)
}

font_rasterize_codepoint :: proc(
	fc: ^Font_Context,
	cp: u32,
	dst_pixels: []u8,
	pitch: int,
	px, py: int,
	slot_w, slot_h: int,
	is_wide: bool = false,
) {
	if fc == nil do return

	cell_w := int(fc.rasterizer.metrics.cell_width) if fc.has_font && fc.rasterizer.metrics.cell_width > 0 else 19
	cell_h := int(fc.rasterizer.metrics.cell_height) if fc.has_font && fc.rasterizer.metrics.cell_height > 0 else 43

	// Powerline carets keep face-local fitted placement regardless of which
	// face supplies the glyph.
	if _is_powerline(cp) {
		if fc.has_font && helper.font_rasterizer_find_glyph_index(&fc.rasterizer, cp) != 0 {
			_rasterize_powerline(&fc.rasterizer, cp, dst_pixels, pitch, px, py, slot_w, slot_h, cell_w, cell_h, is_wide)
			return
		}
		for i in 0..<fc.fallback_count {
			if helper.font_rasterizer_find_glyph_index(&fc.fallbacks[i], cp) != 0 {
				_rasterize_powerline(&fc.fallbacks[i], cp, dst_pixels, pitch, px, py, slot_w, slot_h, cell_w, cell_h, is_wide)
				return
			}
		}
		return
	}

	// 1. Primary face: baseline-anchored using the face's own ascender.
	if fc.has_font && helper.font_rasterizer_find_glyph_index(&fc.rasterizer, cp) != 0 {
		helper.font_rasterize_glyph_into(&fc.rasterizer, cp, dst_pixels, pitch, px, py, slot_w, slot_h)
		return
	}

	// 2. Fallback chain: scale to primary cap height + bottom-align to primary baseline.
	center_w := cell_w * 2 if is_wide else cell_w
	for i in 0..<fc.fallback_count {
		if helper.font_rasterizer_find_glyph_index(&fc.fallbacks[i], cp) != 0 {
			_rasterize_fallback_fitted(fc, &fc.fallbacks[i], cp, dst_pixels, pitch, px, py, slot_w, slot_h, cell_w, cell_h, center_w)
			return
		}
	}
}

// _font_face_for_codepoint returns the first face (primary then fallbacks) that
// covers the codepoint, or nil when none does.
_font_face_for_codepoint :: proc(fc: ^Font_Context, cp: u32) -> ^helper.Font_Rasterizer {
	if fc == nil do return nil
	if fc.has_font && helper.font_rasterizer_find_glyph_index(&fc.rasterizer, cp) != 0 do return &fc.rasterizer
	for i in 0..<fc.fallback_count {
		if helper.font_rasterizer_find_glyph_index(&fc.fallbacks[i], cp) != 0 do return &fc.fallbacks[i]
	}
	return nil
}

// _blit_glyph_max max-blends a tight glyph bitmap into a slot at its baseline
// anchor (bearing_x, ascent + bearing_y), used to overstrike combining marks.
_blit_glyph_max :: proc(
	bmp: ^helper.Glyph_Bitmap,
	dst_pixels: []u8,
	pitch: int,
	px, py: int,
	slot_w, slot_h: int,
	ascent_px: int,
) {
	if bmp == nil || bmp.pixels == nil || bmp.width <= 0 || bmp.height <= 0 do return
	ox := px + int(bmp.bearing_x)
	oy := py + ascent_px + int(bmp.bearing_y)
	for gy in 0..<bmp.height {
		for gx in 0..<bmp.width {
			dx := ox + gx
			dy := oy + gy
			if dx >= px && dx < px + slot_w && dy >= py && dy < py + slot_h {
				dst_idx := dy * pitch + dx
				src_idx := gy * bmp.width + gx
				if dst_idx >= 0 && dst_idx < len(dst_pixels) && src_idx < len(bmp.pixels) {
					if bmp.pixels[src_idx] > dst_pixels[dst_idx] {
						dst_pixels[dst_idx] = bmp.pixels[src_idx]
					}
				}
			}
		}
	}
}

// font_rasterize_cluster_into rasterizes a grapheme cluster (base + combining
// marks) into a slot: the base is baseline-anchored as usual, then each mark is
// overstruck (max-blend) at its own baseline anchor, mirroring legacy
// atlas_dynamic_claim mark compositing.
font_rasterize_cluster_into :: proc(
	fc: ^Font_Context,
	runes: []rune,
	dst_pixels: []u8,
	pitch: int,
	px, py: int,
	slot_w, slot_h: int,
	is_wide: bool,
) {
	if fc == nil || len(runes) == 0 do return
	font_rasterize_codepoint(fc, u32(runes[0]), dst_pixels, pitch, px, py, slot_w, slot_h, is_wide)
	for i in 1..<len(runes) {
		mark_cp := u32(runes[i])
		r := _font_face_for_codepoint(fc, mark_cp)
		if r == nil do continue
		bmp := helper.font_rasterize_glyph(r, mark_cp)
		if bmp.pixels != nil {
			_blit_glyph_max(&bmp, dst_pixels, pitch, px, py, slot_w, slot_h, int(math.round(r.metrics.ascent)))
			delete(bmp.pixels)
		}
	}
}

// is_emoji_cluster reports whether a grapheme cluster should be rendered in
// color via the emoji atlas (direct emoji, ZWJ sequence, keycap, regional
// indicator pair, or VS16 emoji presentation).
is_emoji_cluster :: proc(runes: []rune) -> bool {
	for r in runes {
		if is_emoji_codepoint(r) do return true
		if r == 0x200D || r == 0x20E3 do return true
		if r >= 0x1F1E6 && r <= 0x1F1FF do return true
	}
	return false
}
