package pinnacle_ui

// MSDF (Multi-channel Signed Distance Field) Core Structures
// This defines how the GPU will understand the font textures.

Char_ID :: distinct rune

MSDF_Metrics :: struct {
	advance: f32,
	bearing_x: f32,
	bearing_y: f32,
	width: f32,
	height: f32,
}

MSDF_Glyph_Info :: struct {
	uv_start: [2]f32,
	uv_size: [2]f32,
	metrics: MSDF_Metrics,
}

// MSDF_Port is the inbound interface for requesting font rasterization.
// In the Hexagonal Architecture, the Engine asks this port for MSDF data.
// The actual generation (Stb_truetype, FreeType, or msdfgen) is handled 
// by the adapter bridging this port.
MSDF_Port :: struct {
	adapter_ctx: rawptr,
	
	// Returns the UV bounds of a character on the MSDF GPU Atlas.
	// If the character isn't cached yet, the adapter pauses, generates the MSDF 
	// pixels on the CPU, and signals the GPU Renderer to upload the new patch.
	get_glyph: proc(ctx: rawptr, ch: Char_ID) -> (info: MSDF_Glyph_Info, ok: bool),

	// Triggers a flush of newly generated SDF pixels to the GPU texture
	flush_atlas_to_gpu: proc(ctx: rawptr),
}
