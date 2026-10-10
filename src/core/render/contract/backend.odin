package contract

// GPU Backend Contract & Hardware VTable Specification.
// Part of core_render: Tier 1 Autonomous Core Primitives.
//
// Invariant: ZERO Horizontal Dependencies.
// This package depends ONLY on `base:runtime`. It never imports sibling cores
// or feature slices.

import "base:runtime"

// ============================================================================
// GPU Opaque Handle Types
// ============================================================================

// Gpu_Device wraps an abstract hardware GPU device handle.
Gpu_Device :: distinct rawptr

// Gpu_Queue wraps an abstract hardware GPU command queue handle.
Gpu_Queue :: distinct rawptr

// Gpu_Buffer wraps an abstract hardware GPU memory buffer handle.
Gpu_Buffer :: distinct rawptr

// Gpu_Texture wraps an abstract hardware GPU texture resource.
Gpu_Texture :: distinct rawptr

// Gpu_TextureView wraps an abstract view into a GPU texture resource.
Gpu_TextureView :: distinct rawptr

// Gpu_ShaderModule wraps an abstract compiled shader module (MSL library or WGSL module).
Gpu_ShaderModule :: distinct rawptr

// Gpu_RenderPipeline wraps an abstract rasterization graphics pipeline state.
Gpu_RenderPipeline :: distinct rawptr

// Gpu_BindGroup wraps an abstract set of bound GPU resources (buffers, textures, samplers).
Gpu_BindGroup :: distinct rawptr

// Gpu_BindGroupLayout wraps an abstract schema layout for a bind group.
Gpu_BindGroupLayout :: distinct rawptr

// Gpu_CommandEncoder wraps an abstract recording interface for GPU commands.
Gpu_CommandEncoder :: distinct rawptr

// Gpu_RenderPassEncoder wraps an active render pass command recorder.
Gpu_RenderPassEncoder :: distinct rawptr

// Gpu_Surface wraps a window presentation attachment point (e.g., CAMetalLayer).
Gpu_Surface :: distinct rawptr

// Gpu_Sampler wraps an abstract texture sampler state.
Gpu_Sampler :: distinct rawptr

// Gpu_ComputePipeline wraps an abstract compute pipeline state.
Gpu_ComputePipeline :: distinct rawptr

// Gpu_ComputePassEncoder wraps an active compute pass command recorder.
Gpu_ComputePassEncoder :: distinct rawptr

// ============================================================================
// Enums & Descriptors
// ============================================================================

// Gpu_Format represents texture and render target pixel formats.
Gpu_Format :: enum int {
	Undefined,
	BGRA8_Unorm,
	RGBA8_Unorm,
	R8_Unorm,
	Depth24Plus,
	Depth32_Float,
}

// Gpu_Buffer_Usage defines bitfield flags for buffer allocation intents.
Gpu_Buffer_Usage :: enum u32 {
	None        = 0,
	Map_Read    = 1 << 0,
	Map_Write   = 1 << 1,
	Copy_Src    = 1 << 2,
	Copy_Dst    = 1 << 3,
	Index       = 1 << 4,
	Vertex      = 1 << 5,
	Uniform     = 1 << 6,
	Storage     = 1 << 7,
	Indirect    = 1 << 8,
}

// Gpu_Texture_Usage defines bitfield flags for texture resource binding intents.
Gpu_Texture_Usage :: enum u32 {
	None             = 0,
	Copy_Src         = 1 << 0,
	Copy_Dst         = 1 << 1,
	Texture_Binding  = 1 << 2,
	Storage_Binding  = 1 << 3,
	Render_Attach    = 1 << 4,
}

// Gpu_Load_Op specifies how render target pixels are treated at pass begin.
Gpu_Load_Op :: enum int {
	Undefined,
	Load,
	Clear,
}

// Gpu_Store_Op specifies how render target pixels are treated at pass end.
Gpu_Store_Op :: enum int {
	Undefined,
	Store,
	Discard,
}

// Gpu_Primitive_Topology specifies geometry primitive assembly.
Gpu_Primitive_Topology :: enum int {
	Point_List,
	Line_List,
	Line_Strip,
	Triangle_List,
	Triangle_Strip,
}

// Gpu_Blend_Mode specifies alpha blending behavior on color attachments.
Gpu_Blend_Mode :: enum int {
	Opaque,
	Alpha_Blend,
}

// Gpu_Shader_Language defines the target shader language.
Gpu_Shader_Language :: enum {
	MSL,
	WGSL,
}

// Gpu_Vertex_Format specifies vertex attribute component types.
Gpu_Vertex_Format :: enum int {
	Float32,
	Float32x2,
	Float32x3,
	Float32x4,
	Uint8x4,
	Uint32,
	Uint32x2,
}

// Gpu_Step_Mode specifies per-vertex or per-instance stepping.
Gpu_Step_Mode :: enum int {
	Vertex,
	Instance,
}

// Gpu_Binding_Type specifies resource classification in layout bindings.
Gpu_Binding_Type :: enum int {
	Uniform_Buffer,
	Storage_Buffer,
	Sampler,
	Sampled_Texture,
	Storage_Texture,
}

// Gpu_Bind_Entry_Type discriminates which resource union member is active.
Gpu_Bind_Entry_Type :: enum int {
	Buffer,
	Texture_View,
	Sampler,
}

// Descriptor structs
Gpu_Buffer_Desc :: struct {
	size:               u64,
	usage:              Gpu_Buffer_Usage,
	mapped_at_creation: bool,
}

Gpu_Texture_Desc :: struct {
	width:  u32,
	height: u32,
	format: Gpu_Format,
	usage:  Gpu_Texture_Usage,
}

Gpu_Render_Pass_Desc :: struct {
	color_view:  Gpu_TextureView,
	clear_color: [4]f64,
	load_op:     Gpu_Load_Op,
	store_op:    Gpu_Store_Op,
}

Gpu_Vertex_Attribute :: struct {
	format:          Gpu_Vertex_Format,
	offset:          u64,
	shader_location: u32,
}

Gpu_Vertex_Layout :: struct {
	array_stride: u64,
	step_mode:    Gpu_Step_Mode,
	attributes:   []Gpu_Vertex_Attribute,
}

Gpu_Bind_Layout_Entry :: struct {
	binding:      u32,
	visibility:   u32, // bitmask: 1=vertex, 2=fragment, 4=compute
	binding_type: Gpu_Binding_Type,
}

Gpu_Bind_Entry :: struct {
	binding:    u32,
	buffer:     Gpu_Buffer,
	view:       Gpu_TextureView,
	sampler:    Gpu_Sampler,
	offset:     u64,
	size:       u64,
	entry_type: Gpu_Bind_Entry_Type,
}

// ============================================================================
// Uniform Records & Instance Geometry
// ============================================================================

// Terminal_Uniforms: Canonical 64-byte aligned uniform record matching MSL/WGSL.
Terminal_Uniforms :: struct {
	screen_w:     f32,
	screen_h:     f32,
	cell_w:       f32,
	cell_h:       f32,
	cols:         u32,
	rows:         u32,
	pad_x:        f32,
	pad_y:        f32,
	atlas_w:      u32,
	atlas_h:      u32,
	bg_opacity:   f32,
	cell_opacity: f32,
	time:         f32,
	frame_index:  u32,
	_reserved:    [2]u32,
}
#assert(size_of(Terminal_Uniforms) == 64)

// Instance_Record: Canonical 64-byte quad instance record for Terminal Strategy A.
// Eliminates CPU formatting overhead, directly uploadable to MTLBuffer / GPU storage buffer.
Instance_Record :: struct {
	pos_size: [4]f32, // [x, y, cell_w, cell_h] in target coordinates
	uv_rect:  [4]f32, // [u0, v0, u1, v1] normalized atlas UV coordinates
	fg_color: [4]f32, // [r, g, b, a] foreground color (sRGB floats 0..1)
	bg_color: [4]f32, // [r, g, b, a] background color (sRGB floats 0..1)
}
#assert(size_of(Instance_Record) == 64)

// ============================================================================
// VTable & Completion Callback Contract
// ============================================================================

// Asynchronous GPU timing callback (nanoseconds execution duration).
Gpu_Frame_Complete_Proc :: proc(gpu_ns: u64, valid: bool)

// Gpu_Backend_VTable: Pure hardware interface.
// Concrete drivers (Metal, WGPU) implement this table in core_platform/gpu/.
Gpu_Backend_VTable :: struct {
	// Lifecycle
	create_instance:          proc() -> rawptr,
	destroy_instance:         proc(instance: rawptr),
	request_device:           proc(instance: rawptr, surface: rawptr) -> (device: Gpu_Device, queue: Gpu_Queue),
	destroy_device:           proc(device: Gpu_Device),
	poll_device:              proc(device: Gpu_Device, wait: bool) -> bool,

	// Surface & Presentation
	configure_surface:        proc(surface: rawptr, device: Gpu_Device, format: Gpu_Format, width, height: u32),
	get_surface_texture:      proc(surface: rawptr) -> (texture: Gpu_Texture, view: Gpu_TextureView, format: Gpu_Format),
	present_surface:          proc(surface: rawptr) -> bool,
	get_preferred_format:     proc(surface: rawptr, device: Gpu_Device) -> Gpu_Format,

	// Buffer Allocation & Transfers
	create_buffer:            proc(device: Gpu_Device, size: u64, usage: Gpu_Buffer_Usage, mapped_at_creation: bool) -> Gpu_Buffer,
	destroy_buffer:           proc(buffer: Gpu_Buffer),
	write_buffer:             proc(queue: Gpu_Queue, buffer: Gpu_Buffer, offset: u64, data: rawptr, size: u64),
	get_buffer_mapped_range:  proc(buffer: Gpu_Buffer, offset: u64, size: u64) -> []u8,
	unmap_buffer:             proc(buffer: Gpu_Buffer),

	// Textures & Views
	create_texture:           proc(device: Gpu_Device, width, height: u32, format: Gpu_Format, usage: Gpu_Texture_Usage) -> Gpu_Texture,
	destroy_texture:          proc(texture: Gpu_Texture),
	create_texture_view:      proc(texture: Gpu_Texture) -> Gpu_TextureView,
	destroy_texture_view:     proc(view: Gpu_TextureView),
	write_texture:            proc(queue: Gpu_Queue, texture: Gpu_Texture, data: []u8, width, height: u32),

	// Shaders
	shader_language:          Gpu_Shader_Language,
	create_shader_module:     proc(device: Gpu_Device, source: string) -> Gpu_ShaderModule,
	destroy_shader_module:    proc(module: Gpu_ShaderModule),

	// Render Pipelines
	create_render_pipeline:   proc(
		device: Gpu_Device,
		vertex_shader: Gpu_ShaderModule,
		vertex_entry: string,
		fragment_shader: Gpu_ShaderModule,
		fragment_entry: string,
		vertex_layouts: []Gpu_Vertex_Layout,
		format: Gpu_Format,
		blend: Gpu_Blend_Mode,
		topology: Gpu_Primitive_Topology,
	) -> Gpu_RenderPipeline,
	create_render_pipeline_with_depth: proc(
		device: Gpu_Device,
		vertex_shader: Gpu_ShaderModule,
		vertex_entry: string,
		fragment_shader: Gpu_ShaderModule,
		fragment_entry: string,
		vertex_layouts: []Gpu_Vertex_Layout,
		format: Gpu_Format,
		depth_format: Gpu_Format,
		blend: Gpu_Blend_Mode,
		topology: Gpu_Primitive_Topology,
	) -> Gpu_RenderPipeline,
	destroy_render_pipeline:  proc(pipeline: Gpu_RenderPipeline),

	// Resource Binding
	create_bind_group_layout: proc(device: Gpu_Device, entries: []Gpu_Bind_Layout_Entry) -> Gpu_BindGroupLayout,
	destroy_bind_group_layout: proc(layout: Gpu_BindGroupLayout),
	create_bind_group:        proc(device: Gpu_Device, layout: Gpu_BindGroupLayout, entries: []Gpu_Bind_Entry) -> Gpu_BindGroup,
	destroy_bind_group:       proc(group: Gpu_BindGroup),

	// Samplers
	create_sampler:           proc(device: Gpu_Device) -> Gpu_Sampler,
	destroy_sampler:          proc(sampler: Gpu_Sampler),

	// Command Encoding & Submission
	create_command_encoder:   proc(device: Gpu_Device) -> Gpu_CommandEncoder,
	release_command_encoder:  proc(encoder: Gpu_CommandEncoder),
	begin_render_pass:        proc(encoder: Gpu_CommandEncoder, color_view: Gpu_TextureView, clear_color: [4]f64, load_op: Gpu_Load_Op) -> Gpu_RenderPassEncoder,
	begin_render_pass_with_depth: proc(
		encoder: Gpu_CommandEncoder,
		color_view: Gpu_TextureView,
		clear_color: [4]f64,
		load_op: Gpu_Load_Op,
		depth_view: Gpu_TextureView,
		depth_clear: f32,
		depth_load_op: Gpu_Load_Op,
	) -> Gpu_RenderPassEncoder,
	end_render_pass:          proc(pass: Gpu_RenderPassEncoder),
	finish_command_buffer:    proc(encoder: Gpu_CommandEncoder) -> rawptr,
	release_command_buffer:   proc(command_buffer: rawptr),
	submit:                   proc(queue: Gpu_Queue, command_buffer: rawptr) -> bool,
	wait_for_idle:            proc(device: Gpu_Device) -> bool,
	gpu_frame_complete:       Gpu_Frame_Complete_Proc,

	// Render Pass Encoding Commands
	render_set_pipeline:      proc(pass: Gpu_RenderPassEncoder, pipeline: Gpu_RenderPipeline),
	render_set_bind_group:    proc(pass: Gpu_RenderPassEncoder, index: u32, group: Gpu_BindGroup),
	render_set_vertex_buffer: proc(pass: Gpu_RenderPassEncoder, slot: u32, buffer: Gpu_Buffer, offset: u64),
	render_set_index_buffer:  proc(pass: Gpu_RenderPassEncoder, buffer: Gpu_Buffer, offset: u64, size: u64),
	render_set_viewport:      proc(pass: Gpu_RenderPassEncoder, x, y, width, height, min_depth, max_depth: f32),
	render_draw:              proc(pass: Gpu_RenderPassEncoder, vertex_count: u32, instance_count: u32),
	render_draw_indexed:      proc(pass: Gpu_RenderPassEncoder, index_count: u32, instance_count: u32),

	// Surface Attachment Release
	release_surface_texture:  proc(texture: Gpu_Texture, view: Gpu_TextureView),
	pipeline_get_bind_group_layout: proc(pipeline: Gpu_RenderPipeline, index: u32) -> Gpu_BindGroupLayout,

	// Compute Pipelines
	create_compute_pipeline:  proc(device: Gpu_Device, shader: Gpu_ShaderModule, entry: string) -> Gpu_ComputePipeline,
	destroy_compute_pipeline: proc(pipeline: Gpu_ComputePipeline),
	begin_compute_pass:       proc(encoder: Gpu_CommandEncoder) -> Gpu_ComputePassEncoder,
	end_compute_pass:         proc(pass: Gpu_ComputePassEncoder),
	compute_set_pipeline:     proc(pass: Gpu_ComputePassEncoder, pipeline: Gpu_ComputePipeline),
	compute_set_bind_group:   proc(pass: Gpu_ComputePassEncoder, index: u32, group: Gpu_BindGroup),
	compute_dispatch:         proc(pass: Gpu_ComputePassEncoder, x: u32, y: u32, z: u32),
	compute_get_bind_group_layout: proc(pipeline: Gpu_ComputePipeline, index: u32) -> Gpu_BindGroupLayout,
}
