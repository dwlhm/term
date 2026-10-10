package batch

// Strategy 2: Dynamic Primitive Batch for Chrome UI Pillar.
//
// Rapidly batches transient, interactive geometry (hover glows, active divider drag
// guides, dynamic rectangles) into a temporary frame scratch buffer for immediate
// rasterization.
//
// Invariant: ZERO Horizontal Dependencies across cores.

import "base:runtime"
import contract "../../contract"

// Chrome_Vertex: 32-byte quad vertex record.
Chrome_Vertex :: struct {
	pos:   [2]f32,
	uv:    [2]f32,
	color: [4]f32,
}
#assert(size_of(Chrome_Vertex) == 32)

CHROME_BATCH_DEFAULT_CAPACITY :: 2048

Chrome_Batch :: struct {
	backend:       ^contract.Gpu_Backend_VTable,
	device:        contract.Gpu_Device,
	queue:         contract.Gpu_Queue,
	vertex_buffer: contract.Gpu_Buffer,
	pipeline:      contract.Gpu_RenderPipeline,
	vertices:      [dynamic]Chrome_Vertex,
	max_vertices:  u32,
	active_count:  u32,
	allocator:     runtime.Allocator,
	available:     bool,
}

chrome_batch_init :: proc(
	b: ^Chrome_Batch,
	backend: ^contract.Gpu_Backend_VTable,
	device: contract.Gpu_Device,
	queue: contract.Gpu_Queue,
	capacity: u32 = CHROME_BATCH_DEFAULT_CAPACITY,
	allocator := context.allocator,
) -> bool {
	if b == nil || backend == nil || rawptr(device) == nil || rawptr(queue) == nil do return false

	b.backend = backend
	b.device = device
	b.queue = queue
	b.allocator = allocator
	b.max_vertices = max(capacity, 256)
	b.vertices = make([dynamic]Chrome_Vertex, allocator)

	buf_size := u64(b.max_vertices) * size_of(Chrome_Vertex)
	usage := contract.Gpu_Buffer_Usage.Vertex | contract.Gpu_Buffer_Usage.Copy_Dst
	b.vertex_buffer = backend.create_buffer(device, buf_size, usage, false)
	if rawptr(b.vertex_buffer) == nil {
		chrome_batch_destroy(b)
		return false
	}

	b.available = true
	return true
}

chrome_batch_destroy :: proc(b: ^Chrome_Batch) {
	if b == nil || b.backend == nil do return

	if rawptr(b.vertex_buffer) != nil {
		b.backend.destroy_buffer(b.vertex_buffer)
		b.vertex_buffer = contract.Gpu_Buffer(nil)
	}
	if rawptr(b.pipeline) != nil {
		b.backend.destroy_render_pipeline(b.pipeline)
		b.pipeline = contract.Gpu_RenderPipeline(nil)
	}
	delete(b.vertices)
	b.vertices = nil
	b.active_count = 0
	b.available = false
}

chrome_batch_clear :: proc(b: ^Chrome_Batch) {
	if b == nil do return
	clear(&b.vertices)
	b.active_count = 0
}

chrome_batch_push_quad :: proc(b: ^Chrome_Batch, rect: [4]f32, color: [4]f32) -> bool {
	if b == nil || !b.available do return false
	if u32(len(b.vertices) + 6) > b.max_vertices do return false

	x0 := rect[0]
	y0 := rect[1]
	x1 := rect[0] + rect[2]
	y1 := rect[1] + rect[3]

	// 2 triangles = 6 vertices
	v0 := Chrome_Vertex{pos = {x0, y0}, uv = {0, 0}, color = color}
	v1 := Chrome_Vertex{pos = {x1, y0}, uv = {1, 0}, color = color}
	v2 := Chrome_Vertex{pos = {x0, y1}, uv = {0, 1}, color = color}
	v3 := Chrome_Vertex{pos = {x0, y1}, uv = {0, 1}, color = color}
	v4 := Chrome_Vertex{pos = {x1, y0}, uv = {1, 0}, color = color}
	v5 := Chrome_Vertex{pos = {x1, y1}, uv = {1, 1}, color = color}

	append(&b.vertices, v0, v1, v2, v3, v4, v5)
	b.active_count = u32(len(b.vertices))
	return true
}

chrome_batch_flush :: proc(b: ^Chrome_Batch) -> bool {
	if b == nil || !b.available || len(b.vertices) == 0 do return false
	bytes := u64(len(b.vertices)) * size_of(Chrome_Vertex)
	b.backend.write_buffer(b.queue, b.vertex_buffer, 0, raw_data(b.vertices), bytes)
	return true
}

chrome_batch_draw :: proc(b: ^Chrome_Batch, pass: contract.Gpu_RenderPassEncoder) {
	if b == nil || !b.available || len(b.vertices) == 0 || rawptr(pass) == nil do return
	if rawptr(b.pipeline) != nil {
		b.backend.render_set_pipeline(pass, b.pipeline)
	}
	b.backend.render_set_vertex_buffer(pass, 0, b.vertex_buffer, 0)
	b.backend.render_draw(pass, u32(len(b.vertices)), 1)
}
