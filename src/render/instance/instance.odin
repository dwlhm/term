package instance

// Instanced glyph renderer: renders terminal cells using 2-pass instanced drawing.
//
// Pass 1: Backgrounds - render cell backgrounds as colored quads
// Pass 2: Glyphs - render cell foregrounds using atlas-textured quads
//
// Each cell is a single instance; the vertex shader expands it into a quad
// (6 vertices via vertex_index). This means 1 draw call per pass regardless
// of the number of visible cells.

import "base:runtime"
import gpu "../gpu"

// INSTANCE_STRIDE is the byte size of a single instance's vertex data.
// position(2xf32) + cell_size(2xf32) + uv_rect(4xf32) + color(4xf32) = 12 floats = 48 bytes
INSTANCE_STRIDE :: 48

// QUAD_VERTEX_COUNT is the number of vertices per instanced quad (non-indexed triangle list).
QUAD_VERTEX_COUNT :: 6

// Instance_Data holds the per-instance data for one cell.
Instance_Data :: struct {
	x: f32, y: f32,         // position (pixel coordinates)
	cw: f32, ch: f32,       // cell size (pixels)
	u0: f32, v0: f32,       // atlas UV top-left
	u1: f32, v1: f32,       // atlas UV bottom-right
	r: f32, g: f32,         // color (RGBA, but packed as 4 floats)
	b: f32, a: f32,
}

// Instance_Renderer manages the instanced rendering state.
Instance_Renderer :: struct {
	// GPU resources
	bg_pipeline:      gpu.Gpu_RenderPipeline,
	glyph_pipeline:   gpu.Gpu_RenderPipeline,
	instance_buffer:  gpu.Gpu_Buffer,
	uniform_buffer:   gpu.Gpu_Buffer,
	bind_group_layout_bg: gpu.Gpu_BindGroupLayout,
	bind_group_layout_glyph: gpu.Gpu_BindGroupLayout,
	bind_group_bg:    gpu.Gpu_BindGroup,
	bind_group_glyph: gpu.Gpu_BindGroup,
	atlas_texture:    gpu.Gpu_Texture,
	atlas_view:       gpu.Gpu_TextureView,
	sampler:          gpu.Gpu_Sampler,

	// State
	max_instances: u32,
	instance_data: []Instance_Data, // CPU staging buffer
	device:        gpu.Gpu_Device,
	queue:         gpu.Gpu_Queue,
	backend:       ^gpu.Gpu_Backend_VTable,
}

// Uniform_Data is the uniform buffer layout shared by both shaders.
Uniform_Data :: struct {
	screen_w: f32, screen_h: f32,
	cell_w:   f32, cell_h:   f32,
}

// instance_renderer_init creates the instance renderer with GPU resources.
instance_renderer_init :: proc(
	r: ^Instance_Renderer,
	backend: ^gpu.Gpu_Backend_VTable,
	device: gpu.Gpu_Device,
	queue: gpu.Gpu_Queue,
	max_instances: u32,
	atlas_texture: gpu.Gpu_Texture,
	atlas_view: gpu.Gpu_TextureView,
	format: gpu.Gpu_Format,
	bg_wgsl: string,
	glyph_wgsl: string,
	screen_w: f32,
	screen_h: f32,
	allocator: runtime.Allocator = context.allocator,
) -> bool {
	if backend == nil || rawptr(device) == nil || rawptr(queue) == nil {
		return false
	}
	r.backend = backend
	r.device = device
	r.queue = queue
	r.max_instances = max_instances
	r.atlas_texture = atlas_texture
	r.atlas_view = atlas_view

	// Allocate CPU staging buffer for instance data
	r.instance_data = make([]Instance_Data, max_instances, allocator)

	// Create instance buffer (vertex buffer, updated per frame)
	r.instance_buffer = backend.create_buffer(
		device,
		u64(max_instances) * INSTANCE_STRIDE,
		gpu.Gpu_Buffer_Usage.Vertex | gpu.Gpu_Buffer_Usage.Copy_Dst,
		false,
	)

	// Create uniform buffer
	r.uniform_buffer = backend.create_buffer(
		device,
		size_of(Uniform_Data),
		gpu.Gpu_Buffer_Usage.Uniform | gpu.Gpu_Buffer_Usage.Copy_Dst,
		false,
	)

	// Write initial uniforms
	ud := Uniform_Data{screen_w = screen_w, screen_h = screen_h}
	backend.write_buffer(queue, r.uniform_buffer, 0, &ud, size_of(Uniform_Data))

	// Create sampler (nearest filtering for pixel-perfect glyphs)
	r.sampler = backend.create_sampler(device)

	// Shared vertex layout: stride 48, step Instance.
	attrs := []gpu.Gpu_Vertex_Attribute{
		{format = .Float32x2, offset = 0, shader_location = 0},
		{format = .Float32x2, offset = 8, shader_location = 1},
		{format = .Float32x4, offset = 16, shader_location = 2},
		{format = .Float32x4, offset = 32, shader_location = 3},
	}
	layouts := []gpu.Gpu_Vertex_Layout{
		{array_stride = INSTANCE_STRIDE, step_mode = .Instance, attributes = attrs},
	}

	// Pipelines with auto layout (nil layout in backend).
	bg_module := backend.create_shader_module(device, bg_wgsl)
	glyph_module := backend.create_shader_module(device, glyph_wgsl)
	r.bg_pipeline = backend.create_render_pipeline(
		device, bg_module, "vs_main", bg_module, "fs_main",
		layouts, format, .Opaque, .Triangle_List,
	)
	r.glyph_pipeline = backend.create_render_pipeline(
		device, glyph_module, "vs_main", glyph_module, "fs_main",
		layouts, format, .Alpha_Blend, .Triangle_List,
	)
	backend.destroy_shader_module(bg_module)
	backend.destroy_shader_module(glyph_module)

	if rawptr(r.bg_pipeline) == nil || rawptr(r.glyph_pipeline) == nil {
		return false
	}

	// Fetch auto bind-group layouts from the pipelines so bind groups are
	// created against the exact layouts the pipelines expect.
	r.bind_group_layout_bg = backend.pipeline_get_bind_group_layout(r.bg_pipeline, 0)
	r.bind_group_layout_glyph = backend.pipeline_get_bind_group_layout(r.glyph_pipeline, 0)

	// Bind groups
	bg_entries := []gpu.Gpu_Bind_Entry{
		{binding = 0, buffer = r.uniform_buffer, offset = 0, size = size_of(Uniform_Data), entry_type = .Buffer},
	}
	r.bind_group_bg = backend.create_bind_group(device, r.bind_group_layout_bg, bg_entries)

	glyph_entries := []gpu.Gpu_Bind_Entry{
		{binding = 0, buffer = r.uniform_buffer, offset = 0, size = size_of(Uniform_Data), entry_type = .Buffer},
		{binding = 1, view = atlas_view, entry_type = .Texture_View},
		{binding = 2, sampler = r.sampler, entry_type = .Sampler},
	}
	r.bind_group_glyph = backend.create_bind_group(device, r.bind_group_layout_glyph, glyph_entries)
	return true
}

// instance_renderer_destroy frees all GPU resources.
instance_renderer_destroy :: proc(r: ^Instance_Renderer, allocator: runtime.Allocator = context.allocator) {
	if r.backend != nil {
		if rawptr(r.bg_pipeline) != nil {
			r.backend.destroy_render_pipeline(r.bg_pipeline)
			r.bg_pipeline = gpu.Gpu_RenderPipeline(nil)
		}
		if rawptr(r.glyph_pipeline) != nil {
			r.backend.destroy_render_pipeline(r.glyph_pipeline)
			r.glyph_pipeline = gpu.Gpu_RenderPipeline(nil)
		}
		if rawptr(r.bind_group_bg) != nil {
			r.backend.destroy_bind_group(r.bind_group_bg)
			r.bind_group_bg = gpu.Gpu_BindGroup(nil)
		}
		if rawptr(r.bind_group_glyph) != nil {
			r.backend.destroy_bind_group(r.bind_group_glyph)
			r.bind_group_glyph = gpu.Gpu_BindGroup(nil)
		}
		if rawptr(r.bind_group_layout_bg) != nil {
			r.backend.destroy_bind_group_layout(r.bind_group_layout_bg)
			r.bind_group_layout_bg = gpu.Gpu_BindGroupLayout(nil)
		}
		if rawptr(r.bind_group_layout_glyph) != nil {
			r.backend.destroy_bind_group_layout(r.bind_group_layout_glyph)
			r.bind_group_layout_glyph = gpu.Gpu_BindGroupLayout(nil)
		}
		if rawptr(r.sampler) != nil {
			r.backend.destroy_sampler(r.sampler)
			r.sampler = gpu.Gpu_Sampler(nil)
		}
		if rawptr(r.uniform_buffer) != nil {
			r.backend.destroy_buffer(r.uniform_buffer)
			r.uniform_buffer = gpu.Gpu_Buffer(nil)
		}
		if rawptr(r.instance_buffer) != nil {
			r.backend.destroy_buffer(r.instance_buffer)
			r.instance_buffer = gpu.Gpu_Buffer(nil)
		}
	}
	if r.instance_data != nil {
		delete(r.instance_data)
		r.instance_data = nil
	}
}

// instance_renderer_set_screen_size rewrites the uniform buffer with a new screen size.
instance_renderer_set_screen_size :: proc(r: ^Instance_Renderer, backend: ^gpu.Gpu_Backend_VTable, screen_w: f32, screen_h: f32) {
	if backend == nil || rawptr(r.uniform_buffer) == nil || rawptr(r.queue) == nil {
		return
	}
	ud := Uniform_Data{screen_w = screen_w, screen_h = screen_h}
	backend.write_buffer(r.queue, r.uniform_buffer, 0, &ud, size_of(Uniform_Data))
}

// instance_renderer_fill_bg fills a background instance into the staging buffer.
instance_renderer_fill_bg :: proc(
	r: ^Instance_Renderer,
	index: u32,
	x, y, cell_w, cell_h: f32,
	r_color, g_color, b_color: f32,
) {
	if index >= r.max_instances {
		return
	}
	r.instance_data[index] = Instance_Data{
		x = x, y = y,
		cw = cell_w, ch = cell_h,
		u0 = 0, v0 = 0, u1 = 0, v1 = 0,
		r = r_color, g = g_color, b = b_color, a = 1.0,
	}
}

// instance_renderer_fill_glyph fills a glyph instance into the staging buffer.
instance_renderer_fill_glyph :: proc(
	r: ^Instance_Renderer,
	index: u32,
	x, y, cell_w, cell_h: f32,
	u0, v0, u1, v1: f32,
	r_color, g_color, b_color: f32,
) {
	if index >= r.max_instances {
		return
	}
	r.instance_data[index] = Instance_Data{
		x = x, y = y,
		cw = cell_w, ch = cell_h,
		u0 = u0, v0 = v0,
		u1 = u1, v1 = v1,
		r = r_color, g = g_color, b = b_color, a = 1.0,
	}
}

// unpack_r5g6b5 unpacks a 16-bit R5G6B5 color to f32 RGB components [0, 1].
unpack_r5g6b5 :: proc(packed: u16) -> (r, g, b: f32) {
	r5 := f32((packed >> 11) & 0x1F) / 31.0
	g6 := f32((packed >> 5) & 0x3F) / 63.0
	b5 := f32(packed & 0x1F) / 31.0
	return r5, g6, b5
}
