package platform_font

// System Font Discovery & FreeType Fallback Loader
// Platform Font Subsystem (src/platform/font/*).

import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import uw "../../core/unicode_width"

FONT_DISCOVERY_PATHS := []string{
	"assets/fonts/GeistMonoNerdFont-Regular.otf",
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

UI_FONT_DISCOVERY_PATHS := []string{
	"assets/fonts/Geist-Regular.ttf",
	"/System/Library/Fonts/SFNS.ttf",
	"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
}

MAX_FALLBACKS :: 32

FALLBACK_DISCOVERY_PATHS := []string{
	"assets/fonts/SymbolsNerdFontMono-Regular.ttf",
	"/System/Library/Fonts/SFNSMono.ttf",
	"/System/Library/Fonts/Apple Symbols.ttf",
	"/System/Library/Fonts/Menlo.ttc",
	"/System/Library/Fonts/Monaco.ttf",
	"/Library/Fonts/Arial Unicode.ttf",
}

UI_FALLBACK_DISCOVERY_PATHS := []string{
	"assets/fonts/SymbolsNerdFontMono-Regular.ttf",
	"/System/Library/Fonts/SFNS.ttf",
	"/System/Library/Fonts/Apple Symbols.ttf",
	"/Library/Fonts/Arial Unicode.ttf",
}

Font_Context :: struct {
	rasterizer:          Font_Rasterizer,
	has_font:            bool,
	style_class:         Font_Style_Class,
	fallbacks:           [MAX_FALLBACKS]Font_Rasterizer,
	fallback_paths:      [MAX_FALLBACKS]string,
	fallback_count:      int,
	pixel_size:          f32,
	active_path:         string,
	primary_cap_px:      int,
	primary_baseline_px: int,
	miss_cache:          [FONT_MISS_CACHE_SIZE]u32,
	font_mutex:          sync.Mutex,
}

// resolve_font_path locates font assets across bundle resources, portable directories, or system paths.
resolve_font_path :: proc(path: string, allocator := context.temp_allocator) -> (resolved: string, ok: bool) {
	if os.is_file(path) {
		return path, true
	}

	prefix :: "assets/fonts/"
	if strings.has_prefix(path, prefix) {
		filename := path[len(prefix):]
		exec_path, err := os.get_executable_path(allocator)
		if err == nil && len(exec_path) > 0 {
			exec_dir := filepath.dir(exec_path)

			// 1. macOS Application Bundle: Term.app/Contents/MacOS/../Resources/fonts/<file>
			bundle_res, _ := filepath.join({exec_dir, "../Resources/fonts", filename}, allocator)
			if os.is_file(bundle_res) {
				return bundle_res, true
			}

			// 2. Relative to executable parent (portable folder or bin/../assets/fonts/<file>)
			portable_res, _ := filepath.join({exec_dir, "../assets/fonts", filename}, allocator)
			if os.is_file(portable_res) {
				return portable_res, true
			}

			// 3. Adjacent fonts folder: <exec_dir>/fonts/<file>
			adjacent_res, _ := filepath.join({exec_dir, "fonts", filename}, allocator)
			if os.is_file(adjacent_res) {
				return adjacent_res, true
			}

			// 4. Linux FHS prefix: <exec_dir>/../share/term/fonts/<file>
			fhs_res, _ := filepath.join({exec_dir, "../share/term/fonts", filename}, allocator)
			if os.is_file(fhs_res) {
				return fhs_res, true
			}
		}
	}

	return "", false
}

font_context_init :: proc(fc: ^Font_Context, pixel_size: f32 = 32.0, style_class: Font_Style_Class = .Mono) -> bool {
	if fc == nil do return false
	fc.pixel_size = pixel_size
	fc.style_class = style_class
	fc.has_font = false
	fc.active_path = ""
	fc.fallback_count = 0
	fc.miss_cache = {}

	// 1. Discover Primary Font (Priority A: Bundled / User configured font)
	primary_paths := UI_FONT_DISCOVERY_PATHS if style_class == .Sans else FONT_DISCOVERY_PATHS
	for p in primary_paths {
		if path, ok := resolve_font_path(p, context.temp_allocator); ok {
			err: Font_Error
			if font_rasterizer_init(&fc.rasterizer, path, pixel_size, &err) {
				fc.has_font = true
				fc.active_path = strings.clone(path)
				break
			}
		}
	}

	// Priority B: OS default font (.Mono fixed-pitch or .Sans system UI)
	if !fc.has_font {
		if os_font, ok := platform_query_os_default_font(style_class, context.temp_allocator); ok {
			err: Font_Error
			if font_rasterizer_init(&fc.rasterizer, os_font, pixel_size, &err) {
				fc.has_font = true
				fc.active_path = strings.clone(os_font)
			}
		}
	}

	if !fc.has_font do return false

	// Calibrate reference cap-height and baseline
	fc.primary_cap_px, fc.primary_baseline_px = _calibrate_reference(&fc.rasterizer)

	// 2. Discover Fallback Fonts (Priority A: Bundled symbol / nerd font & OS defaults)
	fallback_paths := UI_FALLBACK_DISCOVERY_PATHS if style_class == .Sans else FALLBACK_DISCOVERY_PATHS
	for p in fallback_paths {
		if path, ok := resolve_font_path(p, context.temp_allocator); ok {
			_try_append_fallback(fc, path, pixel_size)
		}
	}
	if os_fallback, ok := platform_query_os_default_font(style_class, context.temp_allocator); ok {
		_try_append_fallback(fc, os_fallback, pixel_size)
	}

	// Priority B: Dynamic Operating System cascade list (Arabic, CJK, etc.)
	needed := FALLBACK_INIT_LIMIT - fc.fallback_count
	if needed > 0 {
		cascades := platform_query_os_cascade_fonts(needed, context.temp_allocator, style_class)
		for path in cascades {
			_try_append_fallback(fc, path, pixel_size)
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
	if len(fc.active_path) > 0 {
		delete(fc.active_path)
		fc.active_path = ""
	}
	for i in 0..<fc.fallback_count {
		font_rasterizer_destroy(&fc.fallbacks[i])
		if len(fc.fallback_paths[i]) > 0 {
			delete(fc.fallback_paths[i])
			fc.fallback_paths[i] = ""
		}
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
	sync.mutex_lock(&fc.font_mutex)
	defer sync.mutex_unlock(&fc.font_mutex)
	return _font_face_for_codepoint(fc, cp) != nil
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

	// Scale so ink height matches cap-height in .Sans UI, or ~90% cell height in .Mono terminal
	target_h := f32(fc.primary_cap_px) if fc.style_class == .Sans else max(f32(fc.primary_cap_px) * 1.25, f32(cell_h) * 0.90)
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
	sync.mutex_lock(&fc.font_mutex)
	defer sync.mutex_unlock(&fc.font_mutex)
	return _rasterize_codepoint_locked(fc, cp, dst_pixels, pitch, px, py, slot_w, slot_h, is_wide)
}

@(private = "file")
_rasterize_codepoint_locked :: proc(
	fc: ^Font_Context,
	cp: u32,
	dst_pixels: []u8,
	pitch: int,
	px, py: int,
	slot_w, slot_h: int,
	is_wide: bool,
) -> (draw_w: f32, offset_x: f32) {
	cell_w := int(fc.rasterizer.metrics.cell_width) if fc.has_font && fc.rasterizer.metrics.cell_width > 0 else 19
	cell_h := int(fc.rasterizer.metrics.cell_height) if fc.has_font && fc.rasterizer.metrics.cell_height > 0 else 43
	target_w := cell_w * 2 if is_wide else cell_w
	gw := f32(target_w)

	face := _font_face_for_codepoint(fc, cp)
	if face == nil do return gw, 0.0

	// 1. Box drawing and block elements
	if _is_box_or_block(cp) {
		font_rasterize_glyph_into(face, cp, dst_pixels, pitch, px, py, slot_w, slot_h)
		return gw, 0.0
	}

	// 2. Primary face
	if face == &fc.rasterizer {
		slot := fc.rasterizer.face.glyph
		gid := font_rasterizer_find_glyph_index(&fc.rasterizer, cp)
		if FT_Load_Glyph(fc.rasterizer.face, gid, FT_LOAD_RENDER | FT_LOAD_TARGET_NORMAL) == 0 {
			w := int(slot.bitmap.width)
			h := int(slot.bitmap.rows)
			max_fit_w := slot_w - 2 if fc.style_class == .Sans else target_w
			if w > max_fit_w || h > cell_h {
				return _rasterize_symbol_fitted(&fc.rasterizer, cp, dst_pixels, pitch, px, py, slot_w, slot_h, cell_w, cell_h, is_wide)
			}
			if fc.style_class == .Sans && !is_symbol_or_pua(cp) {
				adv := max(math.ceil(f32(slot.advance.x) / 64.0), f32(max(0, int(slot.bitmap_left)) + w))
				if adv <= 0 do adv = gw
				font_rasterize_glyph_into(&fc.rasterizer, cp, dst_pixels, pitch, px, py, slot_w, slot_h)
				return adv, 0.0
			}
		}
		font_rasterize_glyph_into(&fc.rasterizer, cp, dst_pixels, pitch, px, py, slot_w, slot_h)
		return gw, 0.0
	}

	// 3. Fallback face
	return _rasterize_fallback_fitted(fc, face, cp, dst_pixels, pitch, px, py, slot_w, slot_h, cell_w, cell_h, target_w)
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
	sync.mutex_lock(&fc.font_mutex)
	defer sync.mutex_unlock(&fc.font_mutex)

	// 1. If cluster contains complex scripts (e.g. Arabic) or ligatures, shape via HarfBuzz
	r := _font_face_for_codepoint(fc, u32(runes[0]))
	if r != nil && len(runes) > 1 {
		if shaped, ok := font_shape_cluster(r, runes); ok && shaped.glyph_count > 0 {
			for i in 0..<int(shaped.glyph_count) {
				g := shaped.glyphs[i]
				font_rasterize_glyph_index_into(r, g.glyph_id, dst_pixels, pitch, px + int(g.x_offset), py + int(g.y_offset), slot_w, slot_h)
			}
			return f32(slot_w), 0.0
		}
	}

	// 2. Fallback base codepoint + stacked mark blitting
	draw_w, offset_x = _rasterize_codepoint_locked(fc, u32(runes[0]), dst_pixels, pitch, px, py, slot_w, slot_h, is_wide)
	for i in 1..<len(runes) {
		mark_cp := u32(runes[i])
		mr := _font_face_for_codepoint(fc, mark_cp)
		if mr == nil do continue
		bmp := font_rasterize_glyph(mr, mark_cp)
		if bmp.pixels != nil {
			_blit_glyph_max(&bmp, dst_pixels, pitch, px, py, slot_w, slot_h, int(math.round(mr.metrics.ascent)))
			delete(bmp.pixels)
		}
	}
	return draw_w, offset_x
}

// is_emoji_cluster reports emoji presentation: an Emoji_Presentation rune, VS16,
// ZWJ sequence or keycap, unless VS15 (U+FE0E) explicitly requests text.
is_emoji_cluster :: proc(runes: []rune) -> bool {
	for r in runes do if r == 0xFE0E do return false
	for r in runes {
		if uw.is_emoji_presentation(r) do return true
		if r == 0x200D || r == 0x20E3 || r == 0xFE0F do return true
	}
	return false
}
