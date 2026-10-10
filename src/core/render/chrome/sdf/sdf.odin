package sdf

// Strategy 3: SDF Vector Shader for Chrome UI Pillar.
//
// Evaluates Signed Distance Fields on the GPU to produce sub-pixel anti-aliased
// rounded corners, precise borders, and crisp vector dialog elements.
//
// Math: d = length(max(abs(p) - b + r, 0.0)) - r with smoothstep anti-aliasing.
// Invariant: ZERO Horizontal Dependencies across cores.

import contract "../../contract"

CHROME_SDF_MSL  :: #load("../../shaders/chrome_sdf.msl")
CHROME_SDF_WGSL :: #load("../../shaders/chrome_sdf.wgsl")

// Sdf_Params: 64-byte aligned uniform record matching MSL/WGSL shader.
Sdf_Params :: struct {
	screen_size:  [2]f32,
	rect_pos:     [2]f32,
	rect_size:    [2]f32,
	radius:       f32,
	border_width: f32,
	color:        [4]f32,
	border_color: [4]f32,
}
#assert(size_of(Sdf_Params) == 64)

Chrome_Sdf_Pipeline :: struct {
	backend:        ^contract.Gpu_Backend_VTable,
	device:         contract.Gpu_Device,
	queue:          contract.Gpu_Queue,
	pipeline:       contract.Gpu_RenderPipeline,
	uniform_buffer: contract.Gpu_Buffer,
	bind_group:     contract.Gpu_BindGroup,
	bind_layout:    contract.Gpu_BindGroupLayout,
	shader_module:  contract.Gpu_ShaderModule,
	available:      bool,
}

chrome_sdf_pipeline_init :: proc(
	p: ^Chrome_Sdf_Pipeline,
	backend: ^contract.Gpu_Backend_VTable,
	device: contract.Gpu_Device,
	queue: contract.Gpu_Queue,
	format: contract.Gpu_Format,
) -> bool {
	if p == nil || backend == nil || rawptr(device) == nil || rawptr(queue) == nil do return false

	p.backend = backend
	p.device = device
	p.queue = queue

	// Create uniform buffer (64 bytes)
	usage := contract.Gpu_Buffer_Usage.Uniform | contract.Gpu_Buffer_Usage.Copy_Dst
	p.uniform_buffer = backend.create_buffer(device, size_of(Sdf_Params), usage, false)
	if rawptr(p.uniform_buffer) == nil do return false

	// Create shader module
	source := string(CHROME_SDF_MSL) if backend.shader_language == .MSL else string(CHROME_SDF_WGSL)
	p.shader_module = backend.create_shader_module(device, source)
	if rawptr(p.shader_module) == nil {
		chrome_sdf_pipeline_destroy(p)
		return false
	}

	// Create graphics pipeline
	vs_entry := "chrome_sdf_vs_main" if backend.shader_language == .MSL else "vs_main"
	fs_entry := "chrome_sdf_fs_main" if backend.shader_language == .MSL else "fs_main"

	p.pipeline = backend.create_render_pipeline(
		device,
		p.shader_module,
		vs_entry,
		p.shader_module,
		fs_entry,
		nil, // Procedural vertex generation from vid (no vertex buffer required)
		format,
		.Alpha_Blend,
		.Triangle_List,
	)
	if rawptr(p.pipeline) == nil {
		chrome_sdf_pipeline_destroy(p)
		return false
	}

	// Create bind group layout (from pipeline for WebGPU exclusive layout compatibility)
	if backend.pipeline_get_bind_group_layout != nil {
		p.bind_layout = backend.pipeline_get_bind_group_layout(p.pipeline, 0)
	}
	if rawptr(p.bind_layout) == nil {
		layout_entries := []contract.Gpu_Bind_Layout_Entry{
			{
				binding      = 0,
				visibility   = 1 | 2, // Vertex | Fragment
				binding_type = .Uniform_Buffer,
			},
		}
		p.bind_layout = backend.create_bind_group_layout(device, layout_entries)
	}
	if rawptr(p.bind_layout) == nil {
		chrome_sdf_pipeline_destroy(p)
		return false
	}

	// Create bind group
	bind_entries := []contract.Gpu_Bind_Entry{
		{
			binding    = 0,
			buffer     = p.uniform_buffer,
			size       = size_of(Sdf_Params),
			entry_type = .Buffer,
		},
	}
	p.bind_group = backend.create_bind_group(device, p.bind_layout, bind_entries)
	if rawptr(p.bind_group) == nil {
		chrome_sdf_pipeline_destroy(p)
		return false
	}

	p.available = true
	return true
}

chrome_sdf_pipeline_destroy :: proc(p: ^Chrome_Sdf_Pipeline) {
	if p == nil || p.backend == nil do return

	if rawptr(p.pipeline) != nil {
		p.backend.destroy_render_pipeline(p.pipeline)
		p.pipeline = contract.Gpu_RenderPipeline(nil)
	}
	if rawptr(p.bind_group) != nil {
		p.backend.destroy_bind_group(p.bind_group)
		p.bind_group = contract.Gpu_BindGroup(nil)
	}
	if rawptr(p.bind_layout) != nil {
		p.backend.destroy_bind_group_layout(p.bind_layout)
		p.bind_layout = contract.Gpu_BindGroupLayout(nil)
	}
	if rawptr(p.shader_module) != nil {
		p.backend.destroy_shader_module(p.shader_module)
		p.shader_module = contract.Gpu_ShaderModule(nil)
	}
	if rawptr(p.uniform_buffer) != nil {
		p.backend.destroy_buffer(p.uniform_buffer)
		p.uniform_buffer = contract.Gpu_Buffer(nil)
	}
	p.available = false
}

chrome_sdf_draw :: proc(
	p: ^Chrome_Sdf_Pipeline,
	pass: contract.Gpu_RenderPassEncoder,
	params: ^Sdf_Params,
) {
	if p == nil || !p.available || rawptr(pass) == nil || params == nil do return

	p.backend.write_buffer(p.queue, p.uniform_buffer, 0, params, size_of(Sdf_Params))
	p.backend.render_set_pipeline(pass, p.pipeline)
	p.backend.render_set_bind_group(pass, 0, p.bind_group)
	p.backend.render_draw(pass, 6, 1) // 6 vertices for procedural quad
}
