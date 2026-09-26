package pinnacle_app_adapter

import pure_ui "../"
import "core:fmt"
import "core:mem"
import "core:os"
import stbtt "vendor:stb/truetype"

MSDF_Adapter :: struct {
	font_info:    stbtt.fontinfo,
	font_data:    []byte, // Keep memory alive
	pixel_range:  f32, 
	
	glyph_cache:  map[pure_ui.Char_ID]pure_ui.MSDF_Glyph_Info,
	gpu_port:     ^pure_ui.Renderer_Port,
	
	atlas_width:  i32,
	atlas_height: i32,
	atlas_x:      i32,
	atlas_y:      i32,
	atlas_y_max:  i32,
	
	cpu_atlas_pixels: []u8, // 1-byte per pixel SDF (Distance)
	dirty_pixels:     bool,
}

init_msdf_adapter :: proc(adapter: ^MSDF_Adapter, render_port: ^pure_ui.Renderer_Port, font_path: string) -> pure_ui.MSDF_Port {
	adapter.gpu_port = render_port
	adapter.pixel_range = 4.0   
	adapter.atlas_width = 1024
	adapter.atlas_height = 1024
	adapter.cpu_atlas_pixels = make([]u8, adapter.atlas_width * adapter.atlas_height)
	adapter.glyph_cache = make(map[pure_ui.Char_ID]pure_ui.MSDF_Glyph_Info)
	adapter.atlas_x = 0
	adapter.atlas_y = 0
	adapter.atlas_y_max = 0

	// 1. Read Font Data natively
	data, err := os.read_entire_file(font_path, context.allocator)
	if err == nil && len(data) > 0 {
		adapter.font_data = data
		stbtt.InitFont(&adapter.font_info, raw_data(adapter.font_data), 0)
	} else {
		fmt.eprintf("Failed to load TrueType font for SDF parsing.\n")
	}

	return pure_ui.MSDF_Port{
		adapter_ctx = adapter,
		get_glyph = _msdf_get_glyph,
		flush_atlas_to_gpu = _msdf_flush_atlas,
	}
}

_msdf_get_glyph :: proc(ctx: rawptr, ch: pure_ui.Char_ID) -> (info: pure_ui.MSDF_Glyph_Info, ok: bool) {
	a := cast(^MSDF_Adapter)ctx
	if cached, exists := a.glyph_cache[ch]; exists {
		return cached, true
	}

	if len(a.font_data) == 0 do return {}, false

	// Generate SDF dynamically via STB Truetype! No C++ needed!
	scale := stbtt.ScaleForPixelHeight(&a.font_info, 48.0) // Render SDF at base 48px
	
	width, height, xoff, yoff: i32
	padding :: 8 // Padding around character to allow distance falloff
	onedge_val : u8 = 127
	pixel_dist_scale : f32 = 48.0 / 4.0 // roughly distance spread
	
	// Create SDF buffer
	sdf_pixels := stbtt.GetCodepointSDF(
		&a.font_info, scale, i32(ch), padding,
		onedge_val, pixel_dist_scale,
		&width, &height, &xoff, &yoff,
	)
	
	if sdf_pixels == nil {
		// Fallback empty spacer
		new_info := pure_ui.MSDF_Glyph_Info{}
		a.glyph_cache[ch] = new_info
		return new_info, true
	}
	defer stbtt.FreeSDF(sdf_pixels, nil)

	// Simple Atlas packing logic
	if a.atlas_x + width + 1 > a.atlas_width {
		a.atlas_x = 0
		a.atlas_y += a.atlas_y_max + 1
		a.atlas_y_max = 0
	}
	if a.atlas_y + height > a.atlas_height {
		// Atlas full! In a real engine, we allocate a new texture array level.
		return {}, false 
	}
    
	if height > a.atlas_y_max do a.atlas_y_max = height

	// Copy pixels to our CPU canvas
	for row in 0..<height {
		dest_idx := (a.atlas_y + row) * a.atlas_width + a.atlas_x
		src_idx := row * width
		mem.copy(&a.cpu_atlas_pixels[dest_idx], mem.ptr_offset(sdf_pixels, src_idx), int(width))
	}
	a.dirty_pixels = true

	// Build exact UV map mappings for the Shader
	uv_start_x := f32(a.atlas_x) / f32(a.atlas_width)
	uv_start_y := f32(a.atlas_y) / f32(a.atlas_height)
	uv_size_w  := f32(width) / f32(a.atlas_width)
	uv_size_h  := f32(height) / f32(a.atlas_height)
	
	adv, lsb: i32
	stbtt.GetCodepointHMetrics(&a.font_info, rune(ch), &adv, &lsb)

	new_info := pure_ui.MSDF_Glyph_Info{
		uv_start = {uv_start_x, uv_start_y},
		uv_size  = {uv_size_w, uv_size_h},
		metrics  = pure_ui.MSDF_Metrics{ 
			advance = f32(adv) * scale, 
			bearing_x = f32(xoff), // offset handles bearing with SDF padding
			bearing_y = f32(yoff),
			width = f32(width), 
			height = f32(height), 
		},
	}

	a.atlas_x += width + 1
	a.glyph_cache[ch] = new_info
	return new_info, true
}

_msdf_flush_atlas :: proc(ctx: rawptr) {
	a := cast(^MSDF_Adapter)ctx
	if a.dirty_pixels {
		// Mock dispatching to WGPU Port here later
		a.dirty_pixels = false
	}
}

destroy_msdf_adapter :: proc(adapter: ^MSDF_Adapter) {
	if adapter.font_data != nil do delete(adapter.font_data)
	delete(adapter.cpu_atlas_pixels)
	delete(adapter.glyph_cache)
}