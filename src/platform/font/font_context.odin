package platform_font

// System Font Discovery & FreeType Fallback Loader
// Platform Font Subsystem (src/platform/font/*).

import "core:math"
import "core:os"
import cell "../../core/terminal/cell"

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
	rasterizer:          Font_Rasterizer,
	has_font:            bool,
	fallbacks:           [MAX_FALLBACKS]Font_Rasterizer,
	fallback_paths:      [MAX_FALLBACKS]string,
	fallback_count:      int,
	pixel_size:          f32,
	active_path:         string,
	primary_cap_px:      int,
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
			err: Font_Error
			if font_rasterizer_init(&fc.rasterizer, p, pixel_size, &err) {
				fc.has_font = true
				fc.active_path = p
				break
			}
		}
	}

	if !fc.has_font do return false

	// Calibrate reference cap-height and baseline
	fc.primary_cap_px, fc.primary_baseline_px = _calibrate_reference(&fc.rasterizer)

	// 2. Discover Fallback Fonts (Symbols, Icons, System glyphs)
	for p in FALLBACK_DISCOVERY_PATHS {
		if fc.fallback_count >= MAX_FALLBACKS do break
		if p == fc.active_path do continue
		if os.is_file(p) {
			err: Font_Error
			if font_rasterizer_init(&fc.fallbacks[fc.fallback_count], p, pixel_size, &err) {
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
		font_rasterizer_destroy(&fc.rasterizer)
		fc.has_font = false
	}
	for i in 0..<fc.fallback_count {
		font_rasterizer_destroy(&fc.fallbacks[i])
	}
	fc.fallback_count = 0
}

font_context_set_pixel_size :: proc(fc: ^Font_Context, pixel_size: f32) -> bool {
	if fc == nil || pixel_size <= 0 do return false
	fc.pixel_size = pixel_size
	if fc.has_font {
		font_rasterizer_set_pixel_size(&fc.rasterizer, pixel_size)
		fc.primary_cap_px, fc.primary_baseline_px = _calibrate_reference(&fc.rasterizer)
	}
	for i in 0..<fc.fallback_count {
		font_rasterizer_set_pixel_size(&fc.fallbacks[i], pixel_size)
	}
	return fc.has_font
}

font_has_codepoint :: proc(fc: ^Font_Context, cp: u32) -> bool {
	if fc == nil do return false
	if fc.has_font && font_rasterizer_find_glyph_index(&fc.rasterizer, cp) != 0 {
		return true
	}
	for i in 0..<fc.fallback_count {
		if font_rasterizer_find_glyph_index(&fc.fallbacks[i], cp) != 0 {
			return true
		}
	}
	return false
}

ATLAS_FALLBACK_MAX_SCALE : f32 : 4.0
ATLAS_FALLBACK_FIT_STEP  : f32 : 0.95
ATLAS_FALLBACK_FIT_STEPS : int : 24

_is_box_or_block :: proc(cp: u32) -> bool {
	return (cp >= 0x2500 && cp <= 0x259F) ||
	       (cp >= 0xE0A0 && cp <= 0xE0A3) ||
	       (cp >= 0xE0B0 && cp <= 0xE0D7) ||
	       (cp >= 0xEE00 && cp <= 0xEE0B)
}

is_emoji_codepoint :: proc(r: rune) -> bool {
	return cell.is_emoji_codepoint(r)
}

_calibrate_reference :: proc(r: ^Font_Rasterizer) -> (cap_px, baseline_px: int) {
	references := [2]u32{'H', '0'}
	for cp in references {
		if font_rasterizer_find_glyph_index(r, cp) == 0 do continue
		_, height, _, bottom, ok := font_measure_glyph_ink_box(r, cp)
		if ok do return height, bottom
	}
	return 0, -1
}

_blit_centered_bitmap :: proc(
	bmp: ^Glyph_Bitmap,
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

_rasterize_symbol_fitted :: proc(
	r: ^Font_Rasterizer,
	cp: u32,
	dst_pixels: []u8,
	pitch: int,
	px, py: int,
	slot_w, slot_h: int,
	cell_w, cell_h: int,
	is_wide: bool,
) -> (draw_w: f32, offset_x: f32) {
	gw := f32(cell_w * 2 if is_wide else cell_w)
	max_h := max(1, int(f32(cell_h) * 0.90))
	max_w := max(1, min(int(gw), slot_w - 2))

	bmp := font_rasterize_glyph_fitted(r, cp, max_w, max_h)
	defer if bmp.pixels != nil do delete(bmp.pixels)

	if bmp.width > 0 && bmp.height > 0 && bmp.pixels != nil {
		_blit_centered_bitmap(&bmp, dst_pixels, pitch, px, py, slot_w, slot_h, int(gw), cell_h)
		return gw, 0.0
	}

	font_rasterize_glyph_into(r, cp, dst_pixels, pitch, px, py, slot_w, slot_h)
	return gw, 0.0
}

_rasterize_fallback_fitted :: proc(
	fc: ^Font_Context,
	r: ^Font_Rasterizer,
	cp: u32,
	dst_pixels: []u8,
	pitch: int,
	px, py: int,
	slot_w, slot_h: int,
	cell_w, cell_h: int,
	center_w: int,
) -> (draw_w: f32, offset_x: f32) {
	gw := f32(center_w)
	base_w, base_h, measured := font_measure_glyph_ink(r, cp)
	if fc.primary_cap_px <= 0 || fc.primary_baseline_px < 0 || !measured || base_w <= 0 || base_h <= 0 {
		font_rasterize_glyph_into(r, cp, dst_pixels, pitch, px, py, slot_w, slot_h)
		return gw, 0.0
	}

	// Scale so ink height matches normal text (~90% cell height)
	target_h := max(f32(fc.primary_cap_px) * 1.25, f32(cell_h) * 0.90)
	size := r.metrics.pixel_size * target_h / f32(base_h)
	size = min(size, r.metrics.pixel_size * ATLAS_FALLBACK_MAX_SCALE)

	max_w := max(1, min(center_w, slot_w - 2))
	ink_w, ink_h, _ := font_measure_glyph_ink(r, cp, size)
	steps := 0
	for (ink_w > max_w || ink_h > cell_h) && steps < ATLAS_FALLBACK_FIT_STEPS {
		size *= ATLAS_FALLBACK_FIT_STEP
		ink_w, ink_h, measured = font_measure_glyph_ink(r, cp, size)
		if !measured || ink_h <= 0 do break
		steps += 1
	}

	font_rasterize_glyph_sized_into(
		r, cp, size, dst_pixels, pitch, px, py, slot_w, slot_h,
		fc.primary_baseline_px, center_w,
	)
	return gw, 0.0
}

font_rasterize_codepoint :: proc(
	fc: ^Font_Context,
	cp: u32,
	dst_pixels: []u8,
	pitch: int,
	px, py: int,
	slot_w, slot_h: int,
	is_wide: bool = false,
) -> (draw_w: f32, offset_x: f32) {
	if fc == nil do return 0, 0

	cell_w := int(fc.rasterizer.metrics.cell_width) if fc.has_font && fc.rasterizer.metrics.cell_width > 0 else 19
	cell_h := int(fc.rasterizer.metrics.cell_height) if fc.has_font && fc.rasterizer.metrics.cell_height > 0 else 43
	target_w := cell_w * 2 if is_wide else cell_w
	gw := f32(target_w)

	// 1. Box drawing and block elements
	if _is_box_or_block(cp) {
		if fc.has_font && font_rasterizer_find_glyph_index(&fc.rasterizer, cp) != 0 {
			font_rasterize_glyph_into(&fc.rasterizer, cp, dst_pixels, pitch, px, py, slot_w, slot_h)
			return gw, 0.0
		}
		for i in 0..<fc.fallback_count {
			if font_rasterizer_find_glyph_index(&fc.fallbacks[i], cp) != 0 {
				font_rasterize_glyph_into(&fc.fallbacks[i], cp, dst_pixels, pitch, px, py, slot_w, slot_h)
				return gw, 0.0
			}
		}
		return gw, 0.0
	}

	// 2. Primary face
	if fc.has_font && font_rasterizer_find_glyph_index(&fc.rasterizer, cp) != 0 {
		slot := fc.rasterizer.face.glyph
		gid := font_rasterizer_find_glyph_index(&fc.rasterizer, cp)
		if FT_Load_Glyph(fc.rasterizer.face, gid, FT_LOAD_RENDER | FT_LOAD_TARGET_NORMAL) == 0 {
			w := int(slot.bitmap.width)
			h := int(slot.bitmap.rows)
			if w > target_w || h > cell_h {
				return _rasterize_symbol_fitted(&fc.rasterizer, cp, dst_pixels, pitch, px, py, slot_w, slot_h, cell_w, cell_h, is_wide)
			}
		}
		font_rasterize_glyph_into(&fc.rasterizer, cp, dst_pixels, pitch, px, py, slot_w, slot_h)
		return gw, 0.0
	}

	// 3. Fallback chain
	center_w := cell_w * 2 if is_wide else cell_w
	for i in 0..<fc.fallback_count {
		if font_rasterizer_find_glyph_index(&fc.fallbacks[i], cp) != 0 {
			return _rasterize_fallback_fitted(fc, &fc.fallbacks[i], cp, dst_pixels, pitch, px, py, slot_w, slot_h, cell_w, cell_h, center_w)
		}
	}

	return gw, 0.0
}

_font_face_for_codepoint :: proc(fc: ^Font_Context, cp: u32) -> ^Font_Rasterizer {
	if fc == nil do return nil
	if fc.has_font && font_rasterizer_find_glyph_index(&fc.rasterizer, cp) != 0 do return &fc.rasterizer
	for i in 0..<fc.fallback_count {
		if font_rasterizer_find_glyph_index(&fc.fallbacks[i], cp) != 0 do return &fc.fallbacks[i]
	}
	return nil
}

_blit_glyph_max :: proc(
	bmp: ^Glyph_Bitmap,
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

font_rasterize_cluster_into :: proc(
	fc: ^Font_Context,
	runes: []rune,
	dst_pixels: []u8,
	pitch: int,
	px, py: int,
	slot_w, slot_h: int,
	is_wide: bool,
) -> (draw_w: f32, offset_x: f32) {
	if fc == nil || len(runes) == 0 do return 0, 0
	draw_w, offset_x = font_rasterize_codepoint(fc, u32(runes[0]), dst_pixels, pitch, px, py, slot_w, slot_h, is_wide)
	for i in 1..<len(runes) {
		mark_cp := u32(runes[i])
		r := _font_face_for_codepoint(fc, mark_cp)
		if r == nil do continue
		bmp := font_rasterize_glyph(r, mark_cp)
		if bmp.pixels != nil {
			_blit_glyph_max(&bmp, dst_pixels, pitch, px, py, slot_w, slot_h, int(math.round(r.metrics.ascent)))
			delete(bmp.pixels)
		}
	}
	return draw_w, offset_x
}

is_emoji_cluster :: proc(runes: []rune) -> bool {
	for r in runes {
		if is_emoji_codepoint(r) do return true
		if r == 0x200D || r == 0x20E3 || r == 0xFE0F do return true
		if r >= 0x1F1E6 && r <= 0x1F1FF do return true
		if cell.is_emoji_vs16_eligible(r) do return true
	}
	return false
}
