package render

// Font rasterizer: wraps stb_truetype to load TrueType/OpenType fonts and rasterize glyphs.
// Provides a clean interface for the atlas to consume bitmap data.

import "base:runtime"
import "core:c"
import "core:math"
import "core:os"
import "core:strings"
import "vendor:stb/truetype"

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
	info:       truetype.fontinfo,
	font_data:  []u8,          // raw font file data (must stay alive)
	scale:      f32,           // pixels per em
	metrics:    Font_Metrics,
	allocator:  runtime.Allocator,
}

// font_rasterizer_init loads a font file and initializes the rasterizer.
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

	// Read font file
	actual_path := font_path
	if strings.has_prefix(font_path, "~/") {
		if home, ok := os.lookup_env("HOME", context.temp_allocator); ok {
			actual_path = strings.concatenate({home, font_path[1:]}, context.temp_allocator)
		}
	}

	font_data, err := os.read_entire_file(actual_path, allocator)
	if err != nil {
		if out_error != nil {
			out_error^ = Font_Error.File_Not_Found
		}
		return false
	}

	// Initialize stb_truetype
	r.font_data = font_data
	r.allocator = allocator

	font_data_ptr := &font_data[0]
	
	// For .ttc files, get the offset for the first font
	font_offset := truetype.GetFontOffsetForIndex(font_data_ptr, 0)
	
	if !truetype.InitFont(&r.info, font_data_ptr, font_offset) {
		if out_error != nil {
			out_error^ = Font_Error.Invalid_Font
		}
		delete(font_data)
		r.font_data = nil
		return false
	}

	// Calculate scale
	r.scale = truetype.ScaleForPixelHeight(&r.info, pixel_size)

	// Extract metrics
	ascent, descent, line_gap: c.int
	truetype.GetFontVMetrics(&r.info, &ascent, &descent, &line_gap)
	r.metrics.pixel_size = pixel_size
	r.metrics.ascent = f32(ascent) * r.scale
	r.metrics.descent = f32(descent) * r.scale
	r.metrics.line_gap = f32(line_gap) * r.scale
	r.metrics.cell_height = math.ceil(r.metrics.ascent - r.metrics.descent + r.metrics.line_gap)

	// For monospace fonts, all glyphs have the same advance width.
	// Probe common glyphs in case 'M' is not in a symbol-only font.
	advance_width, lsb: c.int
	sample_runes := []rune{'M', 'W', 'm', '0', 'A', ' ', 0x2500, 0xE0B0, 0xF179, 0xF07B}
	for sr in sample_runes {
		if truetype.FindGlyphIndex(&r.info, sr) != 0 {
			truetype.GetCodepointHMetrics(&r.info, sr, &advance_width, &lsb)
			if advance_width > 0 {
				break
			}
		}
	}
	if advance_width > 0 {
		r.metrics.cell_width = math.ceil(f32(advance_width) * r.scale)
	} else {
		r.metrics.cell_width = math.ceil(pixel_size * 0.6)
	}

	return true
}

// font_rasterizer_destroy frees all font resources.
font_rasterizer_destroy :: proc(r: ^Font_Rasterizer) {
	if r == nil {
		return
	}
	if r.font_data != nil {
		delete(r.font_data)
		r.font_data = nil
	}
}

// is_symbol_or_pua returns true for PUA, Nerd Font icons, Powerline, and symbol ranges
// that should be centered inside their cell rather than baseline-anchored.
is_symbol_or_pua :: proc(cp: u32) -> bool {
	return (cp >= 0xE000 && cp <= 0xF8FF) ||
	       (cp >= 0xF0000 && cp <= 0x10FFFD) ||
	       (cp >= 0x2500 && cp <= 0x27BF) ||
	       (cp >= 0x2B00 && cp <= 0x2BFF)
}

// font_rasterize_glyph_fitted rasterizes a glyph proportionally scaled to fit within max_w and max_h.
// When max_w and max_h are 0, it rasterizes at the font's unconstrained scale.
// If the glyph bounding box exceeds max_w or max_h, it scales the glyph down proportionally
// and centers it horizontally, preventing out-of-bounds clipping.
font_rasterize_glyph_fitted :: proc(
	r: ^Font_Rasterizer,
	codepoint: u32,
	max_w: int = 0,
	max_h: int = 0,
	allocator: runtime.Allocator = context.allocator,
) -> Glyph_Bitmap {
	result: Glyph_Bitmap

	glyph_index := truetype.FindGlyphIndex(&r.info, rune(codepoint))
	if glyph_index == 0 {
		return result
	}

	scale := r.scale
	x0, y0, x1, y1: c.int
	truetype.GetCodepointBitmapBox(&r.info, rune(codepoint), scale, scale, &x0, &y0, &x1, &y1)
	width := int(x1 - x0)
	height := int(y1 - y0)

	if width <= 0 || height <= 0 {
		result.advance = r.metrics.cell_width
		return result
	}

	if max_w > 0 && max_h > 0 && (width > max_w || height > max_h) {
		fit_factor := min(f32(max_w) / f32(width), f32(max_h) / f32(height))
		scale = r.scale * fit_factor
		truetype.GetCodepointBitmapBox(&r.info, rune(codepoint), scale, scale, &x0, &y0, &x1, &y1)
		width = int(x1 - x0)
		height = int(y1 - y0)
		for (width > max_w || height > max_h) && scale > 0.0001 {
			scale *= 0.95
			truetype.GetCodepointBitmapBox(&r.info, rune(codepoint), scale, scale, &x0, &y0, &x1, &y1)
			width = int(x1 - x0)
			height = int(y1 - y0)
		}
	}

	if width <= 0 || height <= 0 {
		result.advance = r.metrics.cell_width
		return result
	}

	result.width = width
	result.height = height
	result.pixels = make([]u8, width * height, allocator)

	truetype.MakeCodepointBitmap(&r.info, &result.pixels[0], c.int(width), c.int(height), c.int(width), scale, scale, rune(codepoint))

	advance_width, lsb: c.int
	truetype.GetCodepointHMetrics(&r.info, rune(codepoint), &advance_width, &lsb)
	result.advance = f32(advance_width) * scale

	if max_w > 0 && max_h > 0 {
		if is_symbol_or_pua(codepoint) {
			// Symbols and Nerd Font icons: optically center both horizontally and vertically
			ascent_int := int(math.round(r.metrics.ascent))
			result.bearing_x = f32(max_w - width) * 0.5
			result.bearing_y = f32((max_h - height) / 2 - ascent_int)
		} else {
			// Text glyphs: keep baseline anchoring
			result.bearing_y = f32(y0)
			if int(x0) >= 0 && int(x0) + width <= max_w {
				result.bearing_x = f32(x0)
			} else {
				result.bearing_x = f32(max_w - width) * 0.5
			}
		}
	} else {
		// Unconstrained scale
		result.bearing_x = f32(x0)
		result.bearing_y = f32(y0)
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
// This avoids an intermediate allocation for atlas filling.
font_rasterize_glyph_into :: proc(
	r: ^Font_Rasterizer,
	codepoint: u32,
	dst: []u8,
	dst_stride: int,
	dst_x, dst_y: int,
	slot_w, slot_h: int,
) {
	// Check if glyph exists in font
	glyph_index := truetype.FindGlyphIndex(&r.info, rune(codepoint))
	if glyph_index == 0 {
		// Glyph doesn't exist - leave destination unchanged
		return
	}

	// Get glyph bounding box
	x0, y0, x1, y1: c.int
	truetype.GetCodepointBitmapBox(&r.info, rune(codepoint), r.scale, r.scale, &x0, &y0, &x1, &y1)
	width := int(x1 - x0)
	height := int(y1 - y0)

	if width <= 0 || height <= 0 {
		// Empty glyph (e.g., space) - leave destination unchanged
		return
	}

	// Allocate temporary bitmap
	temp_pixels := make([]u8, width * height)
	defer delete(temp_pixels)

	// Rasterize glyph
	truetype.MakeCodepointBitmap(&r.info, &temp_pixels[0], c.int(width), c.int(height), c.int(width), r.scale, r.scale, rune(codepoint))

	// Copy into destination with offset
	// Baseline-anchored typography
	ascent_px := int(math.round(r.metrics.ascent))
	offset_x := dst_x + int(x0)
	offset_y := dst_y + ascent_px + int(y0)

	for gy in 0..<height {
		for gx in 0..<width {
			src_idx := gy * width + gx
			dst_px := offset_x + gx
			dst_py := offset_y + gy

			// Slot-relative clamp: dst_px/dst_py are absolute buffer
			// coordinates, so compare against the slot rect origin
			// plus size (comparing against slot_w/slot_h alone
			// clips every slot past row 0 to nothing).
			if dst_px >= dst_x && dst_px < dst_x + slot_w &&
			   dst_py >= dst_y && dst_py < dst_y + slot_h {
				dst_idx := dst_py * dst_stride + dst_px
				if dst_idx >= 0 && dst_idx < len(dst) {
					dst[dst_idx] = temp_pixels[src_idx]
				}
			}
		}
	}
}
