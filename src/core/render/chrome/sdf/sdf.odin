package sdf

// Strategy 3: SDF Vector Shader for Chrome UI Pillar.
//
// Evaluates Signed Distance Fields on the GPU to produce sub-pixel anti-aliased
// rounded corners, precise borders, and crisp vector dialog elements.
//
// Math: d = length(max(abs(p) - b + r, 0.0)) - r with smoothstep anti-aliasing.
// Invariant: ZERO Horizontal Dependencies across cores.

import contract "../../contract"

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

MAX_SDF_INSTANCES :: 4096

Chrome_Sdf_Pipeline :: struct {
	device:         contract.Gpu_Device,
	queue:          contract.Gpu_Queue,
	pipeline:       contract.Gpu_RenderPipeline,
	bind_layout:    contract.Gpu_BindGroupLayout,
	shader_module:  contract.Gpu_ShaderModule,
	instance_buf:   contract.Gpu_Buffer,
	bind_group:     contract.Gpu_BindGroup,
	instances:      [MAX_SDF_INSTANCES]Sdf_Params,
	instance_count: int,
	available:      bool,
}

chrome_sdf_pipeline_init :: proc(
	p: ^Chrome_Sdf_Pipeline,
	device: contract.Gpu_Device,
	queue: contract.Gpu_Queue,
	format: contract.Gpu_Format,
) -> bool {
	if p == nil || rawptr(device) == nil || rawptr(queue) == nil do return false

	p^ = {}
	p.device = device
	p.queue = queue

	// Create shader module
	source := string(CHROME_SDF_WGSL)
	p.shader_module = contract.create_shader_module(device, source)
	if rawptr(p.shader_module) == nil {
		chrome_sdf_pipeline_destroy(p)
		return false
	}

	// Create graphics pipeline
	p.pipeline = contract.create_render_pipeline(
		device,
		p.shader_module,
		"vs_main",
		p.shader_module,
		"fs_main",
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
	if contract.pipeline_get_bind_group_layout != nil {
		p.bind_layout = contract.pipeline_get_bind_group_layout(p.pipeline, 0)
	}
	if rawptr(p.bind_layout) == nil {
		layout_entries := []contract.Gpu_Bind_Layout_Entry{
			{
				binding      = 0,
				visibility   = 1 | 2, // Vertex | Fragment
				binding_type = .Storage_Buffer,
			},
		}
		p.bind_layout = contract.create_bind_group_layout(device, layout_entries)
	}
	if rawptr(p.bind_layout) == nil {
		chrome_sdf_pipeline_destroy(p)
		return false
	}

	// Preallocate storage buffer and bind group for instanced batching
	buf_size := u64(MAX_SDF_INSTANCES * size_of(Sdf_Params))
	usage := contract.Gpu_Buffer_Usage.Storage | contract.Gpu_Buffer_Usage.Copy_Dst
	p.instance_buf = contract.create_buffer(device, buf_size, usage, false)
	if rawptr(p.instance_buf) == nil {
		chrome_sdf_pipeline_destroy(p)
		return false
	}

	bind_entries := []contract.Gpu_Bind_Entry{
		{
			binding    = 0,
			buffer     = p.instance_buf,
			size       = buf_size,
			entry_type = .Buffer,
		},
	}
	p.bind_group = contract.create_bind_group(device, p.bind_layout, bind_entries)
	if rawptr(p.bind_group) == nil {
		chrome_sdf_pipeline_destroy(p)
		return false
	}

	p.instance_count = 0
	p.available = true
	return true
}

chrome_sdf_pipeline_destroy :: proc(p: ^Chrome_Sdf_Pipeline) {
	if p == nil do return

	if rawptr(p.bind_group) != nil {
		contract.destroy_bind_group(p.bind_group)
		p.bind_group = contract.Gpu_BindGroup(nil)
	}
	if rawptr(p.instance_buf) != nil {
		contract.destroy_buffer(p.instance_buf)
		p.instance_buf = contract.Gpu_Buffer(nil)
	}

	if rawptr(p.pipeline) != nil {
		contract.destroy_render_pipeline(p.pipeline)
		p.pipeline = contract.Gpu_RenderPipeline(nil)
	}
	if rawptr(p.bind_layout) != nil {
		contract.destroy_bind_group_layout(p.bind_layout)
		p.bind_layout = contract.Gpu_BindGroupLayout(nil)
	}
	if rawptr(p.shader_module) != nil {
		contract.destroy_shader_module(p.shader_module)
		p.shader_module = contract.Gpu_ShaderModule(nil)
	}

	p.available = false
	p^ = {}
}

chrome_sdf_pipeline_reset :: proc(p: ^Chrome_Sdf_Pipeline) {
	if p != nil do p.instance_count = 0
}

chrome_sdf_push :: proc(p: ^Chrome_Sdf_Pipeline, params: ^Sdf_Params) -> bool {
	if p == nil || params == nil do return false
	if p.instance_count >= MAX_SDF_INSTANCES do return false

	p.instances[p.instance_count] = params^
	p.instance_count += 1
	return true
}

chrome_sdf_draw_with_pass :: proc(
	p: ^Chrome_Sdf_Pipeline,
	pass: contract.Gpu_RenderPassEncoder,
	params: ^Sdf_Params,
) {
	_ = pass
	chrome_sdf_push(p, params)
}

chrome_sdf_draw_no_pass :: proc(
	p: ^Chrome_Sdf_Pipeline,
	params: ^Sdf_Params,
) {
	chrome_sdf_push(p, params)
}

chrome_sdf_draw :: proc{chrome_sdf_draw_with_pass, chrome_sdf_draw_no_pass}

chrome_sdf_flush_and_draw :: proc(
	p: ^Chrome_Sdf_Pipeline,
	pass: contract.Gpu_RenderPassEncoder,
) {
	if p == nil || !p.available || rawptr(pass) == nil do return
	if p.instance_count <= 0 do return

	contract.write_buffer(
		p.queue,
		p.instance_buf,
		0,
		raw_data(p.instances[:]),
		u64(p.instance_count * size_of(Sdf_Params)),
	)
	contract.render_set_pipeline(pass, p.pipeline)
	contract.render_set_bind_group(pass, 0, p.bind_group)
	contract.render_draw(pass, 6, u32(p.instance_count))
	p.instance_count = 0
}
