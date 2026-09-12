package gpu

// GPU backend abstraction layer.
// Defines the interface that any GPU backend (WGPU, Vulkan, etc.) must implement.
// The render package depends only on this abstraction, not on concrete backends.

import "base:runtime"

// Gpu_Device wraps a GPU device handle. The concrete type depends on the backend.
Gpu_Device :: distinct rawptr

// Gpu_Queue wraps a GPU command queue handle.
Gpu_Queue :: distinct rawptr

// Gpu_Buffer wraps a GPU buffer handle.
Gpu_Buffer :: distinct rawptr

// Gpu_Texture wraps a GPU texture handle.
Gpu_Texture :: distinct rawptr

// Gpu_TextureView wraps a GPU texture view handle.
Gpu_TextureView :: distinct rawptr

// Gpu_ShaderModule wraps a GPU shader module handle.
Gpu_ShaderModule :: distinct rawptr

// Gpu_RenderPipeline wraps a GPU render pipeline handle.
Gpu_RenderPipeline :: distinct rawptr

// Gpu_BindGroup wraps a GPU bind group handle.
Gpu_BindGroup :: distinct rawptr

// Gpu_BindGroupLayout wraps a GPU bind group layout handle.
Gpu_BindGroupLayout :: distinct rawptr

// Gpu_CommandEncoder wraps a GPU command encoder handle.
Gpu_CommandEncoder :: distinct rawptr

// Gpu_RenderPassEncoder wraps a GPU render pass encoder handle.
Gpu_RenderPassEncoder :: distinct rawptr

// Gpu_Surface wraps a GPU surface handle (window attachment point).
Gpu_Surface :: distinct rawptr

// Gpu_Sampler wraps a GPU sampler handle.
Gpu_Sampler :: distinct rawptr

// Gpu_ComputePipeline wraps a GPU compute pipeline handle.
Gpu_ComputePipeline :: distinct rawptr

// Gpu_ComputePassEncoder wraps a GPU compute pass encoder handle.
Gpu_ComputePassEncoder :: distinct rawptr

// Gpu_Format represents a texture/surface format.
Gpu_Format :: enum int {
	Undefined,
	BGRA8_Unorm,
	RGBA8_Unorm,
	R8_Unorm,
}

// Gpu_Buffer_Usage is a bitfield for buffer usage flags.
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

// Gpu_Texture_Usage is a bitfield for texture usage flags.
Gpu_Texture_Usage :: enum u32 {
	None             = 0,
	Copy_Src         = 1 << 0,
	Copy_Dst         = 1 << 1,
	Texture_Binding  = 1 << 2,
	Storage_Binding  = 1 << 3,
	Render_Attach    = 1 << 4,
}

// Gpu_Load_Op specifies what to do with a render attachment at the start of a pass.
Gpu_Load_Op :: enum int {
	Undefined,
	Load,
	Clear,
}

// Gpu_Store_Op specifies what to do with a render attachment at the end of a pass.
Gpu_Store_Op :: enum int {
	Undefined,
	Store,
	Discard,
}

// Gpu_Primitive_Topology specifies the primitive type for rendering.
Gpu_Primitive_Topology :: enum int {
	Point_List,
	Line_List,
	Line_Strip,
	Triangle_List,
	Triangle_Strip,
}

// Gpu_Blend_Mode specifies a blend mode for color attachments.
Gpu_Blend_Mode :: enum int {
	Opaque,       // no blending: src
	Alpha_Blend,  // standard alpha blending: src * srcAlpha + dst * (1 - srcAlpha)
}

// Gpu_Backend_VTable is the virtual function table for a GPU backend.
// Each backend (WGPU, etc.) provides an implementation of these functions.
Gpu_Backend_VTable :: struct {
	// Lifecycle
	create_instance:    proc() -> rawptr,
	destroy_instance:   proc(instance: rawptr),
	request_device:     proc(instance: rawptr, surface: rawptr) -> (device: Gpu_Device, queue: Gpu_Queue),
	destroy_device:     proc(device: Gpu_Device),

	// Surface
	configure_surface:  proc(surface: rawptr, device: Gpu_Device, format: Gpu_Format, width, height: u32),
	get_surface_texture: proc(surface: rawptr) -> (texture: Gpu_Texture, view: Gpu_TextureView, format: Gpu_Format),
	// Returns false when the surface cannot be presented.
	present_surface:    proc(surface: rawptr) -> bool,
	get_preferred_format: proc(surface: rawptr, device: Gpu_Device) -> Gpu_Format,

	// Buffers
	create_buffer:      proc(device: Gpu_Device, size: u64, usage: Gpu_Buffer_Usage, mapped_at_creation: bool) -> Gpu_Buffer,
	destroy_buffer:     proc(buffer: Gpu_Buffer),
	write_buffer:       proc(queue: Gpu_Queue, buffer: Gpu_Buffer, offset: u64, data: rawptr, size: u64),
	get_buffer_mapped_range: proc(buffer: Gpu_Buffer, offset: u64, size: u64) -> []u8,
	unmap_buffer:       proc(buffer: Gpu_Buffer),

	// Textures
	create_texture:     proc(device: Gpu_Device, width, height: u32, format: Gpu_Format, usage: Gpu_Texture_Usage) -> Gpu_Texture,
	destroy_texture:    proc(texture: Gpu_Texture),
	create_texture_view: proc(texture: Gpu_Texture) -> Gpu_TextureView,
	destroy_texture_view: proc(view: Gpu_TextureView),
	write_texture:      proc(queue: Gpu_Queue, texture: Gpu_Texture, data: []u8, width, height: u32),

	// Shaders
	create_shader_module: proc(device: Gpu_Device, wgsl_source: string) -> Gpu_ShaderModule,
	destroy_shader_module: proc(module: Gpu_ShaderModule),

	// Pipelines
	create_render_pipeline: proc(
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
	destroy_render_pipeline: proc(pipeline: Gpu_RenderPipeline),

	// Bind groups
	create_bind_group_layout: proc(device: Gpu_Device, entries: []Gpu_Bind_Layout_Entry) -> Gpu_BindGroupLayout,
	destroy_bind_group_layout: proc(layout: Gpu_BindGroupLayout),
	create_bind_group: proc(device: Gpu_Device, layout: Gpu_BindGroupLayout, entries: []Gpu_Bind_Entry) -> Gpu_BindGroup,
	destroy_bind_group: proc(group: Gpu_BindGroup),

	// Sampler
	create_sampler: proc(device: Gpu_Device) -> Gpu_Sampler,
	destroy_sampler: proc(sampler: Gpu_Sampler),

	// Command encoding
	create_command_encoder: proc(device: Gpu_Device) -> Gpu_CommandEncoder,
	// Releases an encoder that has not been consumed by finish.
	release_command_encoder: proc(encoder: Gpu_CommandEncoder),
	begin_render_pass: proc(encoder: Gpu_CommandEncoder, color_view: Gpu_TextureView, clear_color: [4]f64, load_op: Gpu_Load_Op) -> Gpu_RenderPassEncoder,
	end_render_pass: proc(pass: Gpu_RenderPassEncoder),
	finish_command_buffer: proc(encoder: Gpu_CommandEncoder) -> rawptr,
	// Releases a finished command buffer after queue submission or rejection.
	release_command_buffer: proc(command_buffer: rawptr),
	// Returns false when queue or command_buffer is invalid or submission fails.
	submit: proc(queue: Gpu_Queue, command_buffer: rawptr) -> bool,
	// Blocks until all work submitted to the device queue has completed.
	// Implementations must return false when completion cannot be verified.
	wait_for_idle: proc(device: Gpu_Device) -> bool,

	// Render pass commands
	render_set_pipeline: proc(pass: Gpu_RenderPassEncoder, pipeline: Gpu_RenderPipeline),
	render_set_bind_group: proc(pass: Gpu_RenderPassEncoder, index: u32, group: Gpu_BindGroup),
	render_set_vertex_buffer: proc(pass: Gpu_RenderPassEncoder, slot: u32, buffer: Gpu_Buffer, offset: u64),
	render_draw: proc(pass: Gpu_RenderPassEncoder, vertex_count: u32, instance_count: u32),
	render_draw_indexed: proc(pass: Gpu_RenderPassEncoder, index_count: u32, instance_count: u32),

	// Surface texture release (release texture+view acquired from get_surface_texture)
	release_surface_texture: proc(texture: Gpu_Texture, view: Gpu_TextureView),

	// Pipeline layout query (returns auto layout for a pipeline's bind group slot)
	pipeline_get_bind_group_layout: proc(pipeline: Gpu_RenderPipeline, index: u32) -> Gpu_BindGroupLayout,

	// Compute pipelines
	create_compute_pipeline: proc(device: Gpu_Device, shader: Gpu_ShaderModule, entry: string) -> Gpu_ComputePipeline,
	destroy_compute_pipeline: proc(pipeline: Gpu_ComputePipeline),

	// Compute command encoding
	begin_compute_pass: proc(encoder: Gpu_CommandEncoder) -> Gpu_ComputePassEncoder,
	end_compute_pass: proc(pass: Gpu_ComputePassEncoder),
	compute_set_pipeline: proc(pass: Gpu_ComputePassEncoder, pipeline: Gpu_ComputePipeline),
	compute_set_bind_group: proc(pass: Gpu_ComputePassEncoder, index: u32, group: Gpu_BindGroup),
	compute_dispatch: proc(pass: Gpu_ComputePassEncoder, x: u32, y: u32, z: u32),

	// Compute pipeline layout query (returns auto layout for a pipeline's bind group slot)
	compute_get_bind_group_layout: proc(pipeline: Gpu_ComputePipeline, index: u32) -> Gpu_BindGroupLayout,
}

// Gpu_Vertex_Attribute describes a single vertex attribute.
Gpu_Vertex_Attribute :: struct {
	format:       Gpu_Vertex_Format,
	offset:       u64,
	shader_location: u32,
}

// Gpu_Vertex_Layout describes the layout of a vertex buffer.
Gpu_Vertex_Layout :: struct {
	array_stride: u64,
	step_mode:    Gpu_Step_Mode,
	attributes:   []Gpu_Vertex_Attribute,
}

// Gpu_Vertex_Format specifies the format of a vertex attribute.
Gpu_Vertex_Format :: enum int {
	Float32,
	Float32x2,
	Float32x3,
	Float32x4,
	Uint8x4,
	Uint32,
	Uint32x2,
}

// Gpu_Step_Mode specifies whether vertex data is per-vertex or per-instance.
Gpu_Step_Mode :: enum int {
	Vertex,
	Instance,
}

// Gpu_Bind_Layout_Entry describes a single bind group layout entry.
Gpu_Bind_Layout_Entry :: struct {
	binding:       u32,
	visibility:    u32, // bitmask: 1=vertex, 2=fragment, 4=compute
	binding_type:  Gpu_Binding_Type,
}

// Gpu_Binding_Type specifies the type of a bind group binding.
Gpu_Binding_Type :: enum int {
	Uniform_Buffer,
	Storage_Buffer,
	Sampler,
	Sampled_Texture,
	Storage_Texture,
}

// Gpu_Bind_Entry provides the actual resource for a bind group entry.
Gpu_Bind_Entry :: struct {
	binding:  u32,
	buffer:   Gpu_Buffer,
	view:     Gpu_TextureView,
	sampler:  Gpu_Sampler,
	offset:   u64,
	size:     u64,
	entry_type: Gpu_Bind_Entry_Type,
}

// Gpu_Bind_Entry_Type discriminates which resource is bound.
Gpu_Bind_Entry_Type :: enum int {
	Buffer,
	Texture_View,
	Sampler,
}

// Gpu_Backend holds a reference to a backend's vtable.
Gpu_Backend :: struct {
	vtable: ^Gpu_Backend_VTable,
}
