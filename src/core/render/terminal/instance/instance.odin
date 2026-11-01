package instance

// Terminal Render Pillar - Strategy A: Quad Instance Batching.
//
// Designed for localized / sparse screen modifications (< 3% dirty cells).
// Emits canonical 64-byte Instance_Record primitives directly into a GPU buffer.
// Vertex shader expands each instance into a 2-triangle quad (6 vertices).
//
// Invariant: ZERO Horizontal Dependencies (only base:runtime, core:mem, and contract).

import "base:runtime"
import "core:mem"
import contract "../../contract"

// INSTANCE_STRIDE is the exact size of one instance record (64 bytes).
INSTANCE_STRIDE :: size_of(contract.Instance_Record)
#assert(INSTANCE_STRIDE == 64)

// QUAD_VERTEX_COUNT is 6 vertices per quad (non-indexed triangle list).
QUAD_VERTEX_COUNT: u32 : 6

// Instance_Renderer manages instanced cell rasterization.
Instance_Renderer :: struct {
	device:          contract.Gpu_Device,
	queue:           contract.Gpu_Queue,
	pipeline:        contract.Gpu_RenderPipeline,
	instance_buffer: contract.Gpu_Buffer,
	uniform_buffer:  contract.Gpu_Buffer,
	bind_group:      contract.Gpu_BindGroup,
	bg_bind_group:   contract.Gpu_BindGroup,
	layout:          contract.Gpu_BindGroupLayout,
	atlas_view:      contract.Gpu_TextureView,
	sampler:         contract.Gpu_Sampler,
	records:         []contract.Instance_Record,
	max_instances:   u32,
	active_count:    u32,
	// Overlay records (text decorations) stage in the tail of the same record
	// buffer and are appended behind the regular records by flush(), so one
	// upload carries both and the glyph pass stays a prefix of the batch.
	deferred_count:  u32,
	overlay_start:   u32,
	overlay_count:   u32,
	last_uniforms:   [4]f32,
	has_uniforms:    bool,
	available:       bool,
	allocator:       runtime.Allocator,
}

// instance_renderer_init creates the instance batch pipeline and GPU buffers.
instance_renderer_init :: proc(
	r: ^Instance_Renderer,
	device: contract.Gpu_Device,
	queue: contract.Gpu_Queue,
	max_instances: u32,
	atlas_view: contract.Gpu_TextureView,
	format: contract.Gpu_Format,
	allocator: runtime.Allocator = context.allocator,
) -> bool {
	if r == nil || rawptr(device) == nil || rawptr(queue) == nil do return false
	r.device = device
	r.queue = queue
	r.max_instances = max(max_instances, 1024)
	r.atlas_view = atlas_view
	r.allocator = allocator

	// CPU staging buffer
	r.records = make([]contract.Instance_Record, int(r.max_instances), allocator)
	if r.records == nil do return false

	// GPU instance buffer (Storage / Vertex / Copy_Dst)
	buffer_bytes := u64(r.max_instances) * u64(INSTANCE_STRIDE)
	usage := contract.Gpu_Buffer_Usage.Vertex | contract.Gpu_Buffer_Usage.Copy_Dst | contract.Gpu_Buffer_Usage.Storage
	r.instance_buffer = contract.create_buffer(device, buffer_bytes, usage, false)
	if rawptr(r.instance_buffer) == nil {
		instance_renderer_destroy(r)
		return false
	}

	// Uniform buffer (at least 1024 bytes for bg.wgsl Uniforms)
	u_usage := contract.Gpu_Buffer_Usage.Uniform | contract.Gpu_Buffer_Usage.Copy_Dst
	u_size: u64 = max(u64(size_of(contract.Terminal_Uniforms)), u64(1024))
	r.uniform_buffer = contract.create_buffer(device, u_size, u_usage, false)
	if rawptr(r.uniform_buffer) == nil {
		instance_renderer_destroy(r)
		return false
	}

	// Texture Sampler
	r.sampler = contract.create_sampler(device)

	r.available = true
	return true
}

// instance_renderer_destroy tears down all resources.
instance_renderer_destroy :: proc(r: ^Instance_Renderer) {
	if r == nil do return

	if contract.destroy_buffer != nil {
		if rawptr(r.instance_buffer) != nil {
			contract.destroy_buffer(r.instance_buffer)
			r.instance_buffer = contract.Gpu_Buffer(nil)
		}
		if rawptr(r.uniform_buffer) != nil {
			contract.destroy_buffer(r.uniform_buffer)
			r.uniform_buffer = contract.Gpu_Buffer(nil)
		}
	}
	if contract.destroy_sampler != nil && rawptr(r.sampler) != nil {
		contract.destroy_sampler(r.sampler)
		r.sampler = contract.Gpu_Sampler(nil)
	}
	if contract.destroy_bind_group != nil {
		if rawptr(r.bind_group) != nil {
			contract.destroy_bind_group(r.bind_group)
			r.bind_group = contract.Gpu_BindGroup(nil)
		}
		if rawptr(r.bg_bind_group) != nil {
			contract.destroy_bind_group(r.bg_bind_group)
			r.bg_bind_group = contract.Gpu_BindGroup(nil)
		}
	}
	if contract.destroy_bind_group_layout != nil && rawptr(r.layout) != nil {
		contract.destroy_bind_group_layout(r.layout)
		r.layout = contract.Gpu_BindGroupLayout(nil)
	}
	if contract.destroy_render_pipeline != nil && rawptr(r.pipeline) != nil {
		contract.destroy_render_pipeline(r.pipeline)
		r.pipeline = contract.Gpu_RenderPipeline(nil)
	}

	if len(r.records) > 0 {
		delete(r.records, r.allocator)
		r.records = nil
	}
	r.available = false
}

// instance_renderer_begin clears the batch.
instance_renderer_begin :: proc(r: ^Instance_Renderer) {
	if r == nil do return
	r.active_count = 0
	r.deferred_count = 0
	r.overlay_start = 0
	r.overlay_count = 0
}

// instance_renderer_push adds a single 64-byte instance record. Regular and
// deferred records share the same capacity, so the bound accounts for both.
instance_renderer_push :: #force_inline proc(r: ^Instance_Renderer, rec: contract.Instance_Record) -> bool {
	if r == nil || r.active_count + r.deferred_count >= r.max_instances do return false
	r.records[r.active_count] = rec
	r.active_count += 1
	return true
}

// instance_renderer_push_overlay stages a record that must paint after the
// glyph pass (text decorations). It is stored from the tail of the same record
// buffer; flush() moves it behind the regular records before uploading, so the
// whole batch stays one contiguous upload and one buffer.
instance_renderer_push_overlay :: #force_inline proc(r: ^Instance_Renderer, rec: contract.Instance_Record) -> bool {
	if r == nil || r.active_count + r.deferred_count >= r.max_instances do return false
	r.deferred_count += 1
	r.records[r.max_instances - r.deferred_count] = rec
	return true
}

// instance_renderer_front_count is the number of regular records that draw in
// the background and glyph passes (everything before the overlay tail).
instance_renderer_front_count :: #force_inline proc(r: ^Instance_Renderer) -> u32 {
	if r == nil do return 0
	if r.overlay_count > 0 do return r.overlay_start
	return r.active_count
}

// instance_renderer_flush appends staged overlays behind the regular records
// and uploads the whole batch to GPU memory.
instance_renderer_flush :: proc(r: ^Instance_Renderer) -> bool {
	if r == nil || !r.available do return false
	r.overlay_start = r.active_count
	r.overlay_count = r.deferred_count
	if r.deferred_count > 0 {
		src := r.max_instances - r.deferred_count
		for i in 0 ..< r.deferred_count {
			r.records[r.active_count + i] = r.records[src + i]
		}
		r.active_count += r.deferred_count
		r.deferred_count = 0
	}
	if r.active_count == 0 do return false
	upload_bytes := u64(r.active_count) * u64(INSTANCE_STRIDE)
	contract.write_buffer(r.queue, r.instance_buffer, 0, raw_data(r.records), upload_bytes)
	return true
}

// instance_renderer_draw encodes the glyph/regular instanced draw call. The
// overlay tail is excluded so it can be drawn after glyphs.
instance_renderer_draw :: proc(r: ^Instance_Renderer, pass: contract.Gpu_RenderPassEncoder) {
	if r == nil || !r.available || rawptr(pass) == nil do return
	count := instance_renderer_front_count(r)
	if count == 0 do return
	if rawptr(r.pipeline) != nil {
		contract.render_set_pipeline(pass, r.pipeline)
	}
	if rawptr(r.bind_group) != nil {
		contract.render_set_bind_group(pass, 0, r.bind_group)
	}
	contract.render_set_vertex_buffer(pass, 0, r.instance_buffer, 0)
	contract.render_draw(pass, QUAD_VERTEX_COUNT, count)
}

// instance_renderer_draw_overlays encodes the staged overlay tail (text
// decorations) at its buffer offset. The caller sets the pipeline and bind
// group: the overlays use the same solid-fill background pipeline as the cell
// backgrounds, but must be encoded after the glyph pass.
instance_renderer_draw_overlays :: proc(r: ^Instance_Renderer, pass: contract.Gpu_RenderPassEncoder) {
	if r == nil || !r.available || r.overlay_count == 0 || rawptr(pass) == nil do return
	offset := u64(r.overlay_start) * u64(INSTANCE_STRIDE)
	contract.render_set_vertex_buffer(pass, 0, r.instance_buffer, offset)
	contract.render_draw(pass, QUAD_VERTEX_COUNT, r.overlay_count)
}
