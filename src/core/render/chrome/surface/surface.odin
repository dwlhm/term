package surface

// Strategy 1: Cached Surface for Chrome UI Pillar.
//
// Retains static UI chrome elements (tab bar, status bar, dividers) in a dedicated
// off-screen GPU texture. Cross-frame blits skip re-rasterizing static chrome,
// achieving zero-redraw GPU overhead during steady-state terminal operation.
//
// Invariant: ZERO Horizontal Dependencies.

import contract "../../contract"

Chrome_Surface :: struct {
	texture:  contract.Gpu_Texture,
	view:     contract.Gpu_TextureView,
	width:    u32,
	height:   u32,
	is_dirty: bool,
}

// chrome_surface_init allocates an off-screen texture and view as a render target.
chrome_surface_init :: proc(
	s: ^Chrome_Surface,
	device: contract.Gpu_Device,
	width, height: u32,
	format: contract.Gpu_Format,
) -> bool {
	if s == nil || rawptr(device) == nil do return false

	s.width = max(width, 1)
	s.height = max(height, 1)
	s.is_dirty = true

	usage := contract.Gpu_Texture_Usage.Render_Attach |
	         contract.Gpu_Texture_Usage.Texture_Binding |
	         contract.Gpu_Texture_Usage.Copy_Src |
	         contract.Gpu_Texture_Usage.Copy_Dst

	s.texture = contract.create_texture(device, s.width, s.height, format, usage)
	if rawptr(s.texture) == nil do return false

	s.view = contract.create_texture_view(s.texture)
	if rawptr(s.view) == nil {
		contract.destroy_texture(s.texture)
		s.texture = contract.Gpu_Texture(nil)
		return false
	}

	return true
}

// chrome_surface_destroy releases GPU resources.
chrome_surface_destroy :: proc(s: ^Chrome_Surface) {
	if s == nil do return
	if rawptr(s.view) != nil {
		contract.destroy_texture_view(s.view)
		s.view = contract.Gpu_TextureView(nil)
	}
	if rawptr(s.texture) != nil {
		contract.destroy_texture(s.texture)
		s.texture = contract.Gpu_Texture(nil)
	}
	s.width = 0
	s.height = 0
	s.is_dirty = false
}

// chrome_surface_resize reallocates the texture if dimensions changed.
chrome_surface_resize :: proc(
	s: ^Chrome_Surface,
	device: contract.Gpu_Device,
	width, height: u32,
	format: contract.Gpu_Format,
) -> bool {
	if s == nil do return false
	if s.width == width && s.height == height && rawptr(s.texture) != nil do return true

	chrome_surface_destroy(s)
	return chrome_surface_init(s, device, width, height, format)
}

// chrome_surface_mark_dirty flags that the cached surface requires redraw.
chrome_surface_mark_dirty :: proc(s: ^Chrome_Surface, dirty: bool = true) {
	if s != nil {
		s.is_dirty = dirty
	}
}

// chrome_surface_is_dirty checks if the surface needs re-rendering.
chrome_surface_is_dirty :: proc(s: ^Chrome_Surface) -> bool {
	return s != nil && s.is_dirty
}
