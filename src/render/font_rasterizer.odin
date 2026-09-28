package render

// Font rasterizer: wraps FreeType2 and HarfBuzz to load TrueType/OpenType fonts,
// shape text clusters, and rasterize glyph bitmaps.
// Provides a clean interface for the atlas to consume bitmap data.

import "base:runtime"
import "core:c"
import "core:math"
import "core:os"
import "core:strings"

// Font_Error represents font loading errors.
Font_Error :: enum {
	None,
	File_Not_Found,
	Invalid_Font,
}

// Font_Metrics holds font measurement data.
Font_Metrics :: struct {
	pixel_size:  f32,   // requested pixel size
	ascent:      f32,   // pixels above baseline
	descent:     f32,   // pixels below baseline (negative)
	line_gap:    f32,   // extra spacing between lines
	cell_width:  f32,   // advance width for monospace (or average)
	cell_height: f32,   // ascent - descent + line_gap
	scale:       f32,   // pixels per em
}

// Glyph_Bitmap holds a rasterized glyph's bitmap and metrics.
Glyph_Bitmap :: struct {
	width:     int,     // bitmap width in pixels
	height:    int,     // bitmap height in pixels
	bearing_x: f32,    // horizontal offset from cursor to left of bitmap
	bearing_y: f32,    // vertical offset from baseline to top of bitmap
	advance:   f32,    // horizontal advance to next cursor position
	pixels:    []u8,   // grayscale bitmap (width * height bytes)
}

// Font_Rasterizer holds the loaded font and rasterization state.
Font_Rasterizer :: struct {
	ft_lib:     FT_Library,
	face:       FT_Face,
	hb_font:    hb_font_t,
	scale:      f32,           // pixels per em
	metrics:    Font_Metrics,
	allocator:  runtime.Allocator,
}

// font_rasterizer_init loads a font file and initializes the FreeType face and HarfBuzz font.
font_rasterizer_init :: proc(
	r: ^Font_Rasterizer,
	font_path: string,
	pixel_size: f32,
	out_error: ^Font_Error = nil,
	allocator: runtime.Allocator = context.allocator,
) -> bool {
	if out_error != nil {
		out_error^ = Font_Error.None
	}

	// Resolve path
	actual_path := font_path
	if strings.has_prefix(font_path, "~/") {
		if home, ok := os.lookup_env("HOME", context.temp_allocator); ok {
			actual_path = strings.concatenate({home, font_path[1:]}, context.temp_allocator)
		}
	}

	// 1. Initialize FreeType library
	ft_err := FT_Init_FreeType(&r.ft_lib)
	if ft_err != 0 {
		if out_error != nil {
			out_error^ = Font_Error.Invalid_Font
		}
		return false
	}

	// 2. Create FreeType face from file path (OS kernel mmap)
	c_path := strings.clone_to_cstring(actual_path, context.temp_allocator)
	ft_err = FT_New_Face(r.ft_lib, c_path, 0, &r.face)
	if ft_err != 0 || r.face == nil {
		if out_error != nil {
			if !os.exists(actual_path) {
				out_error^ = Font_Error.File_Not_Found
			} else {
				out_error^ = Font_Error.Invalid_Font
			}
		}
		FT_Done_FreeType(r.ft_lib)
		r.ft_lib = nil
		return false
	}

	r.allocator = allocator

	// Set pixel sizes
	FT_Set_Pixel_Sizes(r.face, 0, FT_UInt(pixel_size))

	// 3. Create HarfBuzz font referenced to FreeType face
	r.hb_font = hb_ft_font_create_referenced(r.face)

	// Extract metrics
	r.metrics.pixel_size = pixel_size
	if r.face.size != nil {
		sm := &r.face.size.metrics
		r.metrics.ascent = f32(sm.ascender) / 64.0
		r.metrics.descent = f32(sm.descender) / 64.0
		line_height := f32(sm.height) / 64.0
		r.metrics.line_gap = max(0, line_height - (r.metrics.ascent - r.metrics.descent))
		if r.face.units_per_EM > 0 {
			r.scale = pixel_size / f32(r.face.units_per_EM)
		} else {
			r.scale = f32(sm.y_scale) / 65536.0
		}
	} else {
		if r.face.units_per_EM > 0 {
			r.scale = pixel_size / f32(r.face.units_per_EM)
		} else {
			r.scale = 1.0
		}
		r.metrics.ascent = f32(r.face.ascender) * r.scale
		r.metrics.descent = f32(r.face.descender) * r.scale
		r.metrics.line_gap = max(0, f32(r.face.height) * r.scale - (r.metrics.ascent - r.metrics.descent))
	}
	r.metrics.scale = r.scale
	r.metrics.cell_height = math.ceil(r.metrics.ascent - r.metrics.descent + r.metrics.line_gap)

	// Monospace cell width probe
	advance_px: f32 = 0
	sample_runes := []rune{'M', 'W', 'm', '0', 'A', ' ', 0x2500, 0xE0B0, 0xF179, 0xF07B}
	for sr in sample_runes {
		g_idx := FT_Get_Char_Index(r.face, FT_ULong(sr))
		if g_idx != 0 {
			if FT_Load_Glyph(r.face, g_idx, FT_LOAD_DEFAULT) == 0 {
				adv := f32(r.face.glyph.advance.x) / 64.0
				if adv > 0 {
					advance_px = adv
					break
				}
			}
		}
	}
	if advance_px > 0 {
		r.metrics.cell_width = math.ceil(advance_px)
	} else {
		r.metrics.cell_width = math.ceil(pixel_size * 0.6)
	}

	return true
}

// font_rasterizer_destroy frees all font resources in reverse order of initialization.
font_rasterizer_destroy :: proc(r: ^Font_Rasterizer) {
	if r == nil {
		return
	}
	// Teardown sequence: hb_font -> face -> ft_lib
	if r.hb_font != nil {
		hb_font_destroy(r.hb_font)
		r.hb_font = nil
	}
	if r.face != nil {
		FT_Done_Face(r.face)
		r.face = nil
	}
	if r.ft_lib != nil {
		FT_Done_FreeType(r.ft_lib)
		r.ft_lib = nil
	}
}

// font_rasterizer_find_glyph_index returns the glyph index for a codepoint, or 0 if missing.
font_rasterizer_find_glyph_index :: proc(r: ^Font_Rasterizer, codepoint: u32) -> u32 {
	if r == nil || r.face == nil {
		return 0
	}
	return u32(FT_Get_Char_Index(r.face, FT_ULong(codepoint)))
}

// font_rasterizer_has_glyph checks if the font contains a glyph for the codepoint.
font_rasterizer_has_glyph :: proc(r: ^Font_Rasterizer, codepoint: u32) -> bool {
	return font_rasterizer_find_glyph_index(r, codepoint) != 0
}

// font_shape_cluster shapes a cluster of runes using HarfBuzz into glyph IDs and advances.
font_shape_cluster :: proc(
	r: ^Font_Rasterizer,
	runes: []rune,
) -> (cluster: Shaped_Cluster, ok: bool) {
	if r == nil || r.hb_font == nil || len(runes) == 0 {
		return {}, false
	}
	buf := hb_buffer_create()
	defer hb_buffer_destroy(buf)

	cps := make([]u32, len(runes), context.temp_allocator)
	for r_val, i in runes {
		cps[i] = u32(r_val)
	}

	hb_buffer_add_codepoints(buf, raw_data(cps), c.int(len(cps)), 0, c.int(len(cps)))
	hb_buffer_guess_segment_properties(buf)
	hb_shape(r.hb_font, buf, nil, 0)

	glyph_count: c.uint
	infos := hb_buffer_get_glyph_infos(buf, &glyph_count)
	positions := hb_buffer_get_glyph_positions(buf, &glyph_count)

	if glyph_count == 0 {
		return {}, false
	}

	count := min(int(glyph_count), MAX_CLUSTER_GLYPHS)
	cluster.glyph_count = u8(count)
	for i in 0..<count {
		cluster.glyphs[i] = Cluster_Glyph{
			glyph_id  = infos[i].codepoint,
			x_advance = f32(positions[i].x_advance) / 64.0,
			x_offset  = f32(positions[i].x_offset) / 64.0,
			y_offset  = f32(positions[i].y_offset) / 64.0,
		}
	}
	return cluster, true
}

// is_symbol_or_pua returns true for PUA, Nerd Font icons, Powerline, and symbol ranges
// that should be centered inside their cell rather than baseline-anchored.
is_symbol_or_pua :: proc(cp: u32) -> bool {
	return (cp >= 0xE000 && cp <= 0xF8FF) ||
	       (cp >= 0xF0000 && cp <= 0x10FFFD) ||
	       (cp >= 0x2190 && cp <= 0x21FF) || // Arrows
	       (cp >= 0x2500 && cp <= 0x27BF) || // Box, blocks, geometric shapes, misc symbols
	       (cp >= 0x2800 && cp <= 0x28FF) || // Braille patterns
	       (cp >= 0x2B00 && cp <= 0x2BFF)    // Misc symbols and arrows
}

// font_rasterize_glyph_fitted rasterizes a glyph proportionally scaled to fit within max_w and max_h.
// When max_w and max_h are 0, it rasterizes at the font's unconstrained scale.
font_rasterize_glyph_fitted :: proc(
	r: ^Font_Rasterizer,
	codepoint: u32,
	max_w: int = 0,
	max_h: int = 0,
	allocator: runtime.Allocator = context.allocator,
) -> Glyph_Bitmap {
	result: Glyph_Bitmap
	if r == nil || r.face == nil {
		return result
	}

	glyph_index := FT_Get_Char_Index(r.face, FT_ULong(codepoint))
	if glyph_index == 0 {
		return result
	}

	if FT_Load_Glyph(r.face, glyph_index, FT_LOAD_RENDER | FT_LOAD_TARGET_NORMAL) != 0 {
		return result
	}

	slot := r.face.glyph
	width := int(slot.bitmap.width)
	height := int(slot.bitmap.rows)

	if width <= 0 || height <= 0 {
		result.advance = f32(slot.advance.x) / 64.0
		if result.advance <= 0 {
			result.advance = r.metrics.cell_width
		}
		return result
	}

	current_size := r.metrics.pixel_size
	if max_w > 0 && max_h > 0 && (width > max_w || height > max_h) {
		fit_factor := min(f32(max_w) / f32(width), f32(max_h) / f32(height))
		scaled_size := max(1, current_size * fit_factor)
		FT_Set_Pixel_Sizes(r.face, 0, FT_UInt(scaled_size))
		if FT_Load_Glyph(r.face, glyph_index, FT_LOAD_RENDER | FT_LOAD_TARGET_NORMAL) == 0 {
			slot = r.face.glyph
			width = int(slot.bitmap.width)
			height = int(slot.bitmap.rows)
			for (width > max_w || height > max_h) && scaled_size > 2 {
				scaled_size *= 0.95
				FT_Set_Pixel_Sizes(r.face, 0, FT_UInt(scaled_size))
				if FT_Load_Glyph(r.face, glyph_index, FT_LOAD_RENDER | FT_LOAD_TARGET_NORMAL) != 0 {
					break
				}
				slot = r.face.glyph
				width = int(slot.bitmap.width)
				height = int(slot.bitmap.rows)
			}
		}
		FT_Set_Pixel_Sizes(r.face, 0, FT_UInt(current_size))
		if r.hb_font != nil {
			hb_ft_font_changed(r.hb_font)
		}
	}

	if width <= 0 || height <= 0 {
		result.advance = r.metrics.cell_width
		return result
	}

	result.width = width
	result.height = height
	result.pixels = make([]u8, width * height, allocator)

	pitch := int(slot.bitmap.pitch)
	src_buf := slot.bitmap.buffer
	mode := slot.bitmap.pixel_mode

	if mode == u8(FT_Pixel_Mode.GRAY) {
		for y in 0..<height {
			src_row := y * pitch
			dst_row := y * width
			for x in 0..<width {
				result.pixels[dst_row + x] = src_buf[src_row + x]
			}
		}
	} else if mode == u8(FT_Pixel_Mode.MONO) {
		for y in 0..<height {
			src_row := y * pitch
			dst_row := y * width
			for x in 0..<width {
				byte_val := src_buf[src_row + (x >> 3)]
				bit_val := (byte_val >> uint(7 - (x & 7))) & 1
				result.pixels[dst_row + x] = bit_val != 0 ? 255 : 0
			}
		}
	} else if mode == u8(FT_Pixel_Mode.BGRA) {
		for y in 0..<height {
			src_row := y * pitch
			dst_row := y * width
			for x in 0..<width {
				a := src_buf[src_row + x * 4 + 3]
				result.pixels[dst_row + x] = a
			}
		}
	} else {
		for y in 0..<height {
			src_row := y * pitch
			dst_row := y * width
			for x in 0..<width {
				result.pixels[dst_row + x] = src_buf[src_row + x]
			}
		}
	}

	result.advance = f32(slot.advance.x) / 64.0
	if result.advance <= 0 {
		result.advance = r.metrics.cell_width
	}

	if max_w > 0 && max_h > 0 {
		if is_symbol_or_pua(codepoint) {
			ascent_int := int(math.round(r.metrics.ascent))
			result.bearing_x = f32(max_w - width) * 0.5
			result.bearing_y = f32((max_h - height) / 2 - ascent_int)
		} else {
			result.bearing_y = -f32(slot.bitmap_top)
			if int(slot.bitmap_left) >= 0 && int(slot.bitmap_left) + width <= max_w {
				result.bearing_x = f32(slot.bitmap_left)
			} else {
				result.bearing_x = f32(max_w - width) * 0.5
			}
		}
	} else {
		result.bearing_x = f32(slot.bitmap_left)
		result.bearing_y = -f32(slot.bitmap_top)
	}

	return result
}

// font_rasterize_glyph rasterizes a single glyph and returns its bitmap.
// The caller is responsible for freeing the returned pixels slice.
font_rasterize_glyph :: proc(
	r: ^Font_Rasterizer,
	codepoint: u32,
	allocator: runtime.Allocator = context.allocator,
) -> Glyph_Bitmap {
	return font_rasterize_glyph_fitted(r, codepoint, 0, 0, allocator)
}

// font_rasterize_glyph_into rasterizes a glyph directly into a destination buffer.
font_rasterize_glyph_into :: proc(
	r: ^Font_Rasterizer,
	codepoint: u32,
	dst: []u8,
	dst_stride: int,
	dst_x, dst_y: int,
	slot_w, slot_h: int,
) {
	if r == nil || r.face == nil do return

	glyph_index := FT_Get_Char_Index(r.face, FT_ULong(codepoint))
	if glyph_index == 0 do return

	if FT_Load_Glyph(r.face, glyph_index, FT_LOAD_RENDER | FT_LOAD_TARGET_NORMAL) != 0 do return

	slot := r.face.glyph
	width := int(slot.bitmap.width)
	height := int(slot.bitmap.rows)
	if width <= 0 || height <= 0 do return

	ascent_px := int(math.round(r.metrics.ascent))
	offset_x := dst_x + int(slot.bitmap_left)
	offset_y := dst_y + ascent_px - int(slot.bitmap_top)

	pitch := int(slot.bitmap.pitch)
	src_buf := slot.bitmap.buffer
	mode := slot.bitmap.pixel_mode

	for gy in 0..<height {
		for gx in 0..<width {
			dst_px := offset_x + gx
			dst_py := offset_y + gy

			if dst_px >= dst_x && dst_px < dst_x + slot_w &&
			   dst_py >= dst_y && dst_py < dst_y + slot_h {
				dst_idx := dst_py * dst_stride + dst_px
				if dst_idx >= 0 && dst_idx < len(dst) {
					if mode == u8(FT_Pixel_Mode.GRAY) {
						dst[dst_idx] = src_buf[gy * pitch + gx]
					} else if mode == u8(FT_Pixel_Mode.MONO) {
						b := src_buf[gy * pitch + (gx >> 3)]
						val := (b >> uint(7 - (gx & 7))) & 1
						dst[dst_idx] = val != 0 ? 255 : 0
					} else if mode == u8(FT_Pixel_Mode.BGRA) {
						dst[dst_idx] = src_buf[gy * pitch + gx * 4 + 3]
					} else {
						dst[dst_idx] = src_buf[gy * pitch + gx]
					}
				}
			}
		}
	}
}

// font_rasterize_glyph_index_into rasterizes a glyph directly by glyph index into a destination buffer.
font_rasterize_glyph_index_into :: proc(
	r: ^Font_Rasterizer,
	glyph_index: u32,
	dest_pixels: []u8,
	dest_stride: int,
	dest_x, dest_y: int,
	dest_w, dest_h: int,
) {
	if r == nil || r.face == nil do return
	if glyph_index == 0 do return

	if FT_Load_Glyph(r.face, FT_UInt(glyph_index), FT_LOAD_RENDER | FT_LOAD_TARGET_NORMAL) != 0 do return

	slot := r.face.glyph
	width := int(slot.bitmap.width)
	height := int(slot.bitmap.rows)
	if width <= 0 || height <= 0 do return

	ascent_px := int(math.round(r.metrics.ascent))
	offset_x := dest_x + int(slot.bitmap_left)
	offset_y := dest_y + ascent_px - int(slot.bitmap_top)

	pitch := int(slot.bitmap.pitch)
	src_buf := slot.bitmap.buffer
	mode := slot.bitmap.pixel_mode

	for gy in 0..<height {
		for gx in 0..<width {
			dst_px := offset_x + gx
			dst_py := offset_y + gy

			if dst_px >= dest_x && dst_px < dest_x + dest_w &&
			   dst_py >= dest_y && dst_py < dest_y + dest_h {
				dst_idx := dst_py * dest_stride + dst_px
				if dst_idx >= 0 && dst_idx < len(dest_pixels) {
					if mode == u8(FT_Pixel_Mode.GRAY) {
						dest_pixels[dst_idx] = src_buf[gy * pitch + gx]
					} else if mode == u8(FT_Pixel_Mode.MONO) {
						b := src_buf[gy * pitch + (gx >> 3)]
						val := (b >> uint(7 - (gx & 7))) & 1
						dest_pixels[dst_idx] = val != 0 ? 255 : 0
					} else if mode == u8(FT_Pixel_Mode.BGRA) {
						dest_pixels[dst_idx] = src_buf[gy * pitch + gx * 4 + 3]
					} else {
						dest_pixels[dst_idx] = src_buf[gy * pitch + gx]
					}
				}
			}
		}
	}
}

// font_rasterize_glyph_index_fitted rasterizes a glyph by glyph index proportionally scaled to fit within max_w and max_h.
font_rasterize_glyph_index_fitted :: proc(
	r: ^Font_Rasterizer,
	glyph_index: u32,
	max_w: int = 0,
	max_h: int = 0,
	allocator: runtime.Allocator = context.allocator,
) -> Glyph_Bitmap {
	result: Glyph_Bitmap
	if r == nil || r.face == nil || glyph_index == 0 {
		return result
	}

	if FT_Load_Glyph(r.face, FT_UInt(glyph_index), FT_LOAD_RENDER | FT_LOAD_TARGET_NORMAL) != 0 {
		return result
	}

	slot := r.face.glyph
	width := int(slot.bitmap.width)
	height := int(slot.bitmap.rows)

	if width <= 0 || height <= 0 {
		result.advance = f32(slot.advance.x) / 64.0
		if result.advance <= 0 {
			result.advance = r.metrics.cell_width
		}
		return result
	}

	current_size := r.metrics.pixel_size
	if max_w > 0 && max_h > 0 && (width > max_w || height > max_h) {
		fit_factor := min(f32(max_w) / f32(width), f32(max_h) / f32(height))
		scaled_size := max(1, current_size * fit_factor)
		FT_Set_Pixel_Sizes(r.face, 0, FT_UInt(scaled_size))
		if FT_Load_Glyph(r.face, FT_UInt(glyph_index), FT_LOAD_RENDER | FT_LOAD_TARGET_NORMAL) == 0 {
			slot = r.face.glyph
			width = int(slot.bitmap.width)
			height = int(slot.bitmap.rows)
			for (width > max_w || height > max_h) && scaled_size > 2 {
				scaled_size *= 0.95
				FT_Set_Pixel_Sizes(r.face, 0, FT_UInt(scaled_size))
				if FT_Load_Glyph(r.face, FT_UInt(glyph_index), FT_LOAD_RENDER | FT_LOAD_TARGET_NORMAL) != 0 {
					break
				}
				slot = r.face.glyph
				width = int(slot.bitmap.width)
				height = int(slot.bitmap.rows)
			}
		}
		FT_Set_Pixel_Sizes(r.face, 0, FT_UInt(current_size))
		if r.hb_font != nil {
			hb_ft_font_changed(r.hb_font)
		}
	}

	if width <= 0 || height <= 0 {
		result.advance = r.metrics.cell_width
		return result
	}

	result.width = width
	result.height = height
	result.pixels = make([]u8, width * height, allocator)

	pitch := int(slot.bitmap.pitch)
	src_buf := slot.bitmap.buffer
	mode := slot.bitmap.pixel_mode

	if mode == u8(FT_Pixel_Mode.GRAY) {
		for y in 0..<height {
			src_row := y * pitch
			dst_row := y * width
			for x in 0..<width {
				result.pixels[dst_row + x] = src_buf[src_row + x]
			}
		}
	} else if mode == u8(FT_Pixel_Mode.MONO) {
		for y in 0..<height {
			src_row := y * pitch
			dst_row := y * width
			for x in 0..<width {
				byte_val := src_buf[src_row + (x >> 3)]
				bit_val := (byte_val >> uint(7 - (x & 7))) & 1
				result.pixels[dst_row + x] = bit_val != 0 ? 255 : 0
			}
		}
	} else if mode == u8(FT_Pixel_Mode.BGRA) {
		for y in 0..<height {
			src_row := y * pitch
			dst_row := y * width
			for x in 0..<width {
				a := src_buf[src_row + x * 4 + 3]
				result.pixels[dst_row + x] = a
			}
		}
	} else {
		for y in 0..<height {
			src_row := y * pitch
			dst_row := y * width
			for x in 0..<width {
				result.pixels[dst_row + x] = src_buf[src_row + x]
			}
		}
	}

	result.advance = f32(slot.advance.x) / 64.0
	if result.advance <= 0 {
		result.advance = r.metrics.cell_width
	}

	if max_w > 0 && max_h > 0 {
		result.bearing_y = -f32(slot.bitmap_top)
		if int(slot.bitmap_left) >= 0 && int(slot.bitmap_left) + width <= max_w {
			result.bearing_x = f32(slot.bitmap_left)
		} else {
			result.bearing_x = f32(max_w - width) * 0.5
		}
	} else {
		result.bearing_x = f32(slot.bitmap_left)
		result.bearing_y = -f32(slot.bitmap_top)
	}

	return result
}
