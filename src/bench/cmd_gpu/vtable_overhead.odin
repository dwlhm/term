package gpu_bench

// Phase 17 vtable-overhead probe: VtableCall -> NullBackend -> CycleCounter.
//
// bench_null_vtable answers "what does the ~15-calls/frame vtable shape cost
// with zero driver work" (§54 first). bench_measure_vtable_overhead times that
// shape and returns mean ns/frame, or max(u64) when timer elision is detected
// (zero elapsed despite a live sink).
//
// Isolation: every slot is a no-op against a private sink counter. No GPU,
// no window, no app state. The sink is the elision gate required by
// verification, not a side effect on any shared subsystem.

import gpu "../../render/gpu"
import instance "../../render/instance"
import platform "../../platform"

// BENCH_NULL_INSTANCES is the per-draw instance count used by the probe.
BENCH_NULL_INSTANCES :: u32(BENCH_TRACE_COLS * BENCH_TRACE_ROWS)

// _null_sink keeps every null slot live: each slot touches it, and the
// measurer rejects the run (max(u64)) when it did not advance.
_null_sink: u64 = 0

// _NULL_TEX / _NULL_VIEW are non-nil sentinels so the probe exercises the
// full acquire -> encode -> submit -> present -> release shape without a
// surface. They are never dereferenced.
_NULL_TEX  := rawptr(uintptr(0x17beef01))
_NULL_VIEW := rawptr(uintptr(0x17beef02))
_NULL_SURFACE := rawptr(uintptr(0x17beef03))

// bench_null_vtable returns the no-op vtable with the production
// ~15-calls/frame shape. The same pointer is returned on every call.
bench_null_vtable :: proc() -> ^gpu.Gpu_Backend_VTable {
	return &_null_vtable
}

// bench_measure_vtable_overhead times the full frame-call shape against the
// null backend and returns mean ns/frame. Returns max(u64) when elision is
// detected (sink did not advance or zero ticks elapsed).
bench_measure_vtable_overhead :: proc(frames: u64) -> u64 {
	if frames == 0 {
		return 0
	}
	vt := bench_null_vtable()
	sink_start := _null_sink
	start := platform.platform_now()
	for _ in 0..<frames {
		tex, view, _ := vt.get_surface_texture(_NULL_SURFACE)
		enc := vt.create_command_encoder(gpu.Gpu_Device(nil))
		pass := vt.begin_render_pass(enc, view, {0, 0, 0, 1}, .Clear)
		vt.render_set_pipeline(pass, gpu.Gpu_RenderPipeline(nil))
		vt.render_set_bind_group(pass, 0, gpu.Gpu_BindGroup(nil))
		vt.render_set_vertex_buffer(pass, 0, gpu.Gpu_Buffer(nil), 0)
		vt.render_draw(pass, instance.QUAD_VERTEX_COUNT, BENCH_NULL_INSTANCES)
		vt.render_set_pipeline(pass, gpu.Gpu_RenderPipeline(nil))
		vt.render_set_bind_group(pass, 0, gpu.Gpu_BindGroup(nil))
		vt.render_set_vertex_buffer(pass, 0, gpu.Gpu_Buffer(nil), 0)
		vt.render_draw(pass, instance.QUAD_VERTEX_COUNT, BENCH_NULL_INSTANCES)
		vt.end_render_pass(pass)
		cmd := vt.finish_command_buffer(enc)
		_ = vt.submit(gpu.Gpu_Queue(nil), cmd)
		_ = vt.present_surface(_NULL_SURFACE)
		vt.release_surface_texture(tex, view)
	}
	end := platform.platform_now()
	if _null_sink == sink_start {
		return max(u64)
	}
	delta := platform.platform_ticks_to_ns(end - start)
	if delta <= 0 {
		return max(u64)
	}
	return u64(delta) / frames
}

_null_vtable: gpu.Gpu_Backend_VTable = gpu.Gpu_Backend_VTable{
	create_instance              = _null_create_instance,
	destroy_instance             = _null_destroy_instance,
	request_device               = _null_request_device,
	destroy_device               = _null_destroy_device,
	configure_surface            = _null_configure_surface,
	get_surface_texture          = _null_get_surface_texture,
	present_surface              = _null_present_surface,
	get_preferred_format         = _null_get_preferred_format,
	create_buffer                = _null_create_buffer,
	destroy_buffer               = _null_destroy_buffer,
	write_buffer                 = _null_write_buffer,
	get_buffer_mapped_range      = _null_get_buffer_mapped_range,
	unmap_buffer                 = _null_unmap_buffer,
	create_texture               = _null_create_texture,
	destroy_texture              = _null_destroy_texture,
	create_texture_view          = _null_create_texture_view,
	destroy_texture_view         = _null_destroy_texture_view,
	write_texture                = _null_write_texture,
	create_shader_module         = _null_create_shader_module,
	destroy_shader_module        = _null_destroy_shader_module,
	create_render_pipeline       = _null_create_render_pipeline,
	destroy_render_pipeline      = _null_destroy_render_pipeline,
	create_bind_group_layout     = _null_create_bind_group_layout,
	destroy_bind_group_layout    = _null_destroy_bind_group_layout,
	create_bind_group            = _null_create_bind_group,
	destroy_bind_group           = _null_destroy_bind_group,
	create_sampler               = _null_create_sampler,
	destroy_sampler              = _null_destroy_sampler,
	create_command_encoder       = _null_create_command_encoder,
	begin_render_pass            = _null_begin_render_pass,
	end_render_pass              = _null_end_render_pass,
	finish_command_buffer        = _null_finish_command_buffer,
	submit                       = _null_submit,
	render_set_pipeline          = _null_render_set_pipeline,
	render_set_bind_group        = _null_render_set_bind_group,
	render_set_vertex_buffer     = _null_render_set_vertex_buffer,
	render_draw                  = _null_render_draw,
	render_draw_indexed          = _null_render_draw_indexed,
	release_surface_texture      = _null_release_surface_texture,
	pipeline_get_bind_group_layout = _null_pipeline_get_bind_group_layout,
	create_compute_pipeline      = _null_create_compute_pipeline,
	destroy_compute_pipeline     = _null_destroy_compute_pipeline,
	begin_compute_pass           = _null_begin_compute_pass,
	end_compute_pass             = _null_end_compute_pass,
	compute_set_pipeline         = _null_compute_set_pipeline,
	compute_set_bind_group       = _null_compute_set_bind_group,
	compute_dispatch             = _null_compute_dispatch,
	compute_get_bind_group_layout = _null_compute_get_bind_group_layout,
}

_null_create_instance :: proc() -> rawptr {
	_null_sink += 1
	return nil
}

_null_destroy_instance :: proc(instance: rawptr) {
	_null_sink += 1
}

_null_request_device :: proc(instance: rawptr, surface: rawptr) -> (device: gpu.Gpu_Device, queue: gpu.Gpu_Queue) {
	_null_sink += 1
	return gpu.Gpu_Device(nil), gpu.Gpu_Queue(nil)
}

_null_destroy_device :: proc(device: gpu.Gpu_Device) {
	_null_sink += 1
}

_null_configure_surface :: proc(surface: rawptr, device: gpu.Gpu_Device, format: gpu.Gpu_Format, width, height: u32) {
	_null_sink += 1
}

_null_get_surface_texture :: proc(surface: rawptr) -> (texture: gpu.Gpu_Texture, view: gpu.Gpu_TextureView, format: gpu.Gpu_Format) {
	_null_sink += 1
	return gpu.Gpu_Texture(_NULL_TEX), gpu.Gpu_TextureView(_NULL_VIEW), .BGRA8_Unorm
}

_null_present_surface :: proc(surface: rawptr) -> bool {
	_null_sink += 1
	return true
}

_null_get_preferred_format :: proc(surface: rawptr, device: gpu.Gpu_Device) -> gpu.Gpu_Format {
	_null_sink += 1
	return .BGRA8_Unorm
}

_null_create_buffer :: proc(device: gpu.Gpu_Device, size: u64, usage: gpu.Gpu_Buffer_Usage, mapped_at_creation: bool) -> gpu.Gpu_Buffer {
	_null_sink += 1
	return gpu.Gpu_Buffer(nil)
}

_null_destroy_buffer :: proc(buffer: gpu.Gpu_Buffer) {
	_null_sink += 1
}

_null_write_buffer :: proc(queue: gpu.Gpu_Queue, buffer: gpu.Gpu_Buffer, offset: u64, data: rawptr, size: u64) {
	_null_sink += 1
}

_null_get_buffer_mapped_range :: proc(buffer: gpu.Gpu_Buffer, offset: u64, size: u64) -> []u8 {
	_null_sink += 1
	return nil
}

_null_unmap_buffer :: proc(buffer: gpu.Gpu_Buffer) {
	_null_sink += 1
}

_null_create_texture :: proc(device: gpu.Gpu_Device, width, height: u32, format: gpu.Gpu_Format, usage: gpu.Gpu_Texture_Usage) -> gpu.Gpu_Texture {
	_null_sink += 1
	return gpu.Gpu_Texture(nil)
}

_null_destroy_texture :: proc(texture: gpu.Gpu_Texture) {
	_null_sink += 1
}

_null_create_texture_view :: proc(texture: gpu.Gpu_Texture) -> gpu.Gpu_TextureView {
	_null_sink += 1
	return gpu.Gpu_TextureView(nil)
}

_null_destroy_texture_view :: proc(view: gpu.Gpu_TextureView) {
	_null_sink += 1
}

_null_write_texture :: proc(queue: gpu.Gpu_Queue, texture: gpu.Gpu_Texture, data: []u8, width, height: u32) {
	_null_sink += 1
}

_null_create_shader_module :: proc(device: gpu.Gpu_Device, wgsl_source: string) -> gpu.Gpu_ShaderModule {
	_null_sink += 1
	return gpu.Gpu_ShaderModule(nil)
}

_null_destroy_shader_module :: proc(module: gpu.Gpu_ShaderModule) {
	_null_sink += 1
}

_null_create_render_pipeline :: proc(
	device: gpu.Gpu_Device,
	vertex_shader: gpu.Gpu_ShaderModule,
	vertex_entry: string,
	fragment_shader: gpu.Gpu_ShaderModule,
	fragment_entry: string,
	vertex_layouts: []gpu.Gpu_Vertex_Layout,
	format: gpu.Gpu_Format,
	blend: gpu.Gpu_Blend_Mode,
	topology: gpu.Gpu_Primitive_Topology,
) -> gpu.Gpu_RenderPipeline {
	_null_sink += 1
	return gpu.Gpu_RenderPipeline(nil)
}

_null_destroy_render_pipeline :: proc(pipeline: gpu.Gpu_RenderPipeline) {
	_null_sink += 1
}

_null_create_bind_group_layout :: proc(device: gpu.Gpu_Device, entries: []gpu.Gpu_Bind_Layout_Entry) -> gpu.Gpu_BindGroupLayout {
	_null_sink += 1
	return gpu.Gpu_BindGroupLayout(nil)
}

_null_destroy_bind_group_layout :: proc(layout: gpu.Gpu_BindGroupLayout) {
	_null_sink += 1
}

_null_create_bind_group :: proc(device: gpu.Gpu_Device, layout: gpu.Gpu_BindGroupLayout, entries: []gpu.Gpu_Bind_Entry) -> gpu.Gpu_BindGroup {
	_null_sink += 1
	return gpu.Gpu_BindGroup(nil)
}

_null_destroy_bind_group :: proc(group: gpu.Gpu_BindGroup) {
	_null_sink += 1
}

_null_create_sampler :: proc(device: gpu.Gpu_Device) -> gpu.Gpu_Sampler {
	_null_sink += 1
	return gpu.Gpu_Sampler(nil)
}

_null_destroy_sampler :: proc(sampler: gpu.Gpu_Sampler) {
	_null_sink += 1
}

_null_create_command_encoder :: proc(device: gpu.Gpu_Device) -> gpu.Gpu_CommandEncoder {
	_null_sink += 1
	return gpu.Gpu_CommandEncoder(nil)
}

_null_begin_render_pass :: proc(encoder: gpu.Gpu_CommandEncoder, color_view: gpu.Gpu_TextureView, clear_color: [4]f64, load_op: gpu.Gpu_Load_Op) -> gpu.Gpu_RenderPassEncoder {
	_null_sink += 1
	return gpu.Gpu_RenderPassEncoder(nil)
}

_null_end_render_pass :: proc(pass: gpu.Gpu_RenderPassEncoder) {
	_null_sink += 1
}

_null_finish_command_buffer :: proc(encoder: gpu.Gpu_CommandEncoder) -> rawptr {
	_null_sink += 1
	return nil
}

_null_submit :: proc(queue: gpu.Gpu_Queue, command_buffer: rawptr) -> bool {
	_null_sink += 1
	return true
}

_null_render_set_pipeline :: proc(pass: gpu.Gpu_RenderPassEncoder, pipeline: gpu.Gpu_RenderPipeline) {
	_null_sink += 1
}

_null_render_set_bind_group :: proc(pass: gpu.Gpu_RenderPassEncoder, index: u32, group: gpu.Gpu_BindGroup) {
	_null_sink += 1
}

_null_render_set_vertex_buffer :: proc(pass: gpu.Gpu_RenderPassEncoder, slot: u32, buffer: gpu.Gpu_Buffer, offset: u64) {
	_null_sink += 1
}

_null_render_draw :: proc(pass: gpu.Gpu_RenderPassEncoder, vertex_count: u32, instance_count: u32) {
	_null_sink += u64(instance_count)
}

_null_render_draw_indexed :: proc(pass: gpu.Gpu_RenderPassEncoder, index_count: u32, instance_count: u32) {
	_null_sink += u64(instance_count)
}

_null_release_surface_texture :: proc(texture: gpu.Gpu_Texture, view: gpu.Gpu_TextureView) {
	_null_sink += 1
}

_null_pipeline_get_bind_group_layout :: proc(pipeline: gpu.Gpu_RenderPipeline, index: u32) -> gpu.Gpu_BindGroupLayout {
	_null_sink += 1
	return gpu.Gpu_BindGroupLayout(nil)
}

_null_create_compute_pipeline :: proc(device: gpu.Gpu_Device, shader: gpu.Gpu_ShaderModule, entry: string) -> gpu.Gpu_ComputePipeline {
	_null_sink += 1
	return gpu.Gpu_ComputePipeline(nil)
}

_null_destroy_compute_pipeline :: proc(pipeline: gpu.Gpu_ComputePipeline) {
	_null_sink += 1
}

_null_begin_compute_pass :: proc(encoder: gpu.Gpu_CommandEncoder) -> gpu.Gpu_ComputePassEncoder {
	_null_sink += 1
	return gpu.Gpu_ComputePassEncoder(nil)
}

_null_end_compute_pass :: proc(pass: gpu.Gpu_ComputePassEncoder) {
	_null_sink += 1
}

_null_compute_set_pipeline :: proc(pass: gpu.Gpu_ComputePassEncoder, pipeline: gpu.Gpu_ComputePipeline) {
	_null_sink += 1
}

_null_compute_set_bind_group :: proc(pass: gpu.Gpu_ComputePassEncoder, index: u32, group: gpu.Gpu_BindGroup) {
	_null_sink += 1
}

_null_compute_dispatch :: proc(pass: gpu.Gpu_ComputePassEncoder, x: u32, y: u32, z: u32) {
	_null_sink += u64(x) + u64(y) + u64(z)
}

_null_compute_get_bind_group_layout :: proc(pipeline: gpu.Gpu_ComputePipeline, index: u32) -> gpu.Gpu_BindGroupLayout {
	_null_sink += 1
	return gpu.Gpu_BindGroupLayout(nil)
}
