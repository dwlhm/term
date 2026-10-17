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

CHROME_BATCH_DEFAULT_CAPACITY :: 8192

CHROME_BATCH_WGSL :: `
struct Uniforms {
	screen_size: vec2<f32>,
	_pad: vec2<f32>,
};

@group(0) @binding(0) var<uniform> uniforms: Uniforms;
@group(0) @binding(1) var atlas_texture: texture_2d<f32>;
@group(0) @binding(2) var atlas_sampler: sampler;

struct VertexOutput {
	@builtin(position) clip_position: vec4<f32>,
	@location(0) uv: vec2<f32>,
	@location(1) color: vec4<f32>,
};

@vertex
fn vs_main(
	@location(0) pos: vec2<f32>,
	@location(1) uv: vec2<f32>,
	@location(2) color: vec4<f32>,
) -> VertexOutput {
	var out: VertexOutput;
	let sw = max(uniforms.screen_size.x, 1.0);
	let sh = max(uniforms.screen_size.y, 1.0);
	let clip_x = (pos.x / sw) * 2.0 - 1.0;
	let clip_y = 1.0 - (pos.y / sh) * 2.0;
	out.clip_position = vec4<f32>(clip_x, clip_y, 0.0, 1.0);
	out.uv = uv;
	out.color = color;
	return out;
}

@fragment
fn fs_main(input: VertexOutput) -> @location(0) vec4<f32> {
	let mask = textureSampleLevel(atlas_texture, atlas_sampler, clamp(input.uv, vec2<f32>(0.0), vec2<f32>(1.0)), 0.0).r;
	if (input.uv.x < 0.0) {
		return input.color;
	}
	if (mask < 0.01) {
		discard;
	}
	return vec4<f32>(input.color.rgb, input.color.a * mask);
}
`

Chrome_Batch :: struct {
	device:         contract.Gpu_Device,
	queue:          contract.Gpu_Queue,
	vertex_buffer:  contract.Gpu_Buffer,
	uniform_buffer: contract.Gpu_Buffer,
	pipeline:       contract.Gpu_RenderPipeline,
	bind_layout:    contract.Gpu_BindGroupLayout,
	bind_group:     contract.Gpu_BindGroup,
	sampler:        contract.Gpu_Sampler,
	fallback_tex:   contract.Gpu_Texture,
	fallback_view:  contract.Gpu_TextureView,
	atlas_view:     contract.Gpu_TextureView,
	screen_size:    [2]f32,
	vertices:       [dynamic]Chrome_Vertex,
	max_vertices:   u32,
	active_count:   u32,
	allocator:      runtime.Allocator,
	available:      bool,
}

_chrome_batch_rebuild_bind_group :: proc(b: ^Chrome_Batch, view: contract.Gpu_TextureView) -> bool {
	if b == nil || rawptr(b.device) == nil || rawptr(b.bind_layout) == nil || rawptr(view) == nil do return false
	if rawptr(b.bind_group) != nil {
		contract.destroy_bind_group(b.bind_group)
		b.bind_group = contract.Gpu_BindGroup(nil)
	}
	entries := []contract.Gpu_Bind_Entry{
		{binding = 0, buffer = b.uniform_buffer, offset = 0, size = 16, entry_type = .Buffer},
		{binding = 1, view = view, entry_type = .Texture_View},
		{binding = 2, sampler = b.sampler, entry_type = .Sampler},
	}
	b.bind_group = contract.create_bind_group(b.device, b.bind_layout, entries)
	b.atlas_view = view
	return rawptr(b.bind_group) != nil
}

chrome_batch_init :: proc(
	b: ^Chrome_Batch,
	device: contract.Gpu_Device,
	queue: contract.Gpu_Queue,
	capacity: u32 = CHROME_BATCH_DEFAULT_CAPACITY,
	allocator := context.allocator,
	format: contract.Gpu_Format = .Undefined,
) -> bool {
	if b == nil || rawptr(device) == nil || rawptr(queue) == nil do return false

	b^ = {}
	b.device = device
	b.queue = queue
	b.allocator = allocator
	b.max_vertices = max(capacity, 256)
	b.vertices = make([dynamic]Chrome_Vertex, 0, int(b.max_vertices), allocator)

	buf_size := u64(b.max_vertices) * size_of(Chrome_Vertex)
	usage := contract.Gpu_Buffer_Usage.Vertex | contract.Gpu_Buffer_Usage.Copy_Dst
	b.vertex_buffer = contract.create_buffer(device, buf_size, usage, false)
	if rawptr(b.vertex_buffer) == nil {
		chrome_batch_destroy(b)
		return false
	}

	u_usage := contract.Gpu_Buffer_Usage.Uniform | contract.Gpu_Buffer_Usage.Copy_Dst
	b.uniform_buffer = contract.create_buffer(device, 16, u_usage, false)
	if rawptr(b.uniform_buffer) == nil {
		chrome_batch_destroy(b)
		return false
	}

	b.sampler = contract.create_sampler(device)
	b.fallback_tex = contract.create_texture(device, 1, 1, .R8_Unorm, .Copy_Dst | .Texture_Binding)
	if rawptr(b.fallback_tex) != nil {
		white := [1]u8{255}
		if contract.write_texture != nil {
			contract.write_texture(queue, b.fallback_tex, white[:], 1, 1)
		}
		b.fallback_view = contract.create_texture_view(b.fallback_tex)
	}

	if contract.create_shader_module != nil && contract.create_render_pipeline != nil {
		mod := contract.create_shader_module(device, CHROME_BATCH_WGSL)
		if rawptr(mod) != nil {
			defer contract.destroy_shader_module(mod)
			attrs := []contract.Gpu_Vertex_Attribute{
				{format = .Float32x2, offset = 0,  shader_location = 0},
				{format = .Float32x2, offset = 8,  shader_location = 1},
				{format = .Float32x4, offset = 16, shader_location = 2},
			}
			layouts := []contract.Gpu_Vertex_Layout{
				{array_stride = size_of(Chrome_Vertex), step_mode = .Vertex, attributes = attrs},
			}
			b.pipeline = contract.create_render_pipeline(
				device, mod, "vs_main", mod, "fs_main", layouts, format, .Alpha_Blend, .Triangle_List,
			)
			if rawptr(b.pipeline) != nil && contract.pipeline_get_bind_group_layout != nil {
				b.bind_layout = contract.pipeline_get_bind_group_layout(b.pipeline, 0)
			}
		}
	}

	if rawptr(b.bind_layout) != nil && rawptr(b.fallback_view) != nil {
		_chrome_batch_rebuild_bind_group(b, b.fallback_view)
	}

	b.available = true
	return true
}

chrome_batch_destroy :: proc(b: ^Chrome_Batch) {
	if b == nil do return

	if rawptr(b.bind_group) != nil && contract.destroy_bind_group != nil {
		contract.destroy_bind_group(b.bind_group)
		b.bind_group = contract.Gpu_BindGroup(nil)
	}
	if rawptr(b.bind_layout) != nil && contract.destroy_bind_group_layout != nil {
		contract.destroy_bind_group_layout(b.bind_layout)
		b.bind_layout = contract.Gpu_BindGroupLayout(nil)
	}
	if rawptr(b.fallback_view) != nil && contract.destroy_texture_view != nil {
		contract.destroy_texture_view(b.fallback_view)
		b.fallback_view = contract.Gpu_TextureView(nil)
	}
	if rawptr(b.fallback_tex) != nil && contract.destroy_texture != nil {
		contract.destroy_texture(b.fallback_tex)
		b.fallback_tex = contract.Gpu_Texture(nil)
	}
	if rawptr(b.sampler) != nil && contract.destroy_sampler != nil {
		contract.destroy_sampler(b.sampler)
		b.sampler = contract.Gpu_Sampler(nil)
	}
	if rawptr(b.uniform_buffer) != nil && contract.destroy_buffer != nil {
		contract.destroy_buffer(b.uniform_buffer)
		b.uniform_buffer = contract.Gpu_Buffer(nil)
	}
	if rawptr(b.vertex_buffer) != nil && contract.destroy_buffer != nil {
		contract.destroy_buffer(b.vertex_buffer)
		b.vertex_buffer = contract.Gpu_Buffer(nil)
	}
	if rawptr(b.pipeline) != nil && contract.destroy_render_pipeline != nil {
		contract.destroy_render_pipeline(b.pipeline)
		b.pipeline = contract.Gpu_RenderPipeline(nil)
	}
	delete(b.vertices)
	b.vertices = nil
	b.active_count = 0
	b.available = false
}

chrome_batch_set_atlas :: proc(b: ^Chrome_Batch, atlas_view: contract.Gpu_TextureView) -> bool {
	if b == nil || !b.available || rawptr(atlas_view) == nil do return false
	if b.atlas_view == atlas_view && rawptr(b.bind_group) != nil do return true
	return _chrome_batch_rebuild_bind_group(b, atlas_view)
}

chrome_batch_set_screen_size :: proc(b: ^Chrome_Batch, width, height: f32) {
	if b == nil || !b.available || rawptr(b.uniform_buffer) == nil do return
	sz := [2]f32{max(width, 1.0), max(height, 1.0)}
	if b.screen_size == sz do return
	b.screen_size = sz
	u_data := [4]f32{sz[0], sz[1], 0.0, 0.0}
	contract.write_buffer(b.queue, b.uniform_buffer, 0, &u_data, size_of([4]f32))
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

	// 2 triangles = 6 vertices; negative UV signals solid fill in fragment shader
	v0 := Chrome_Vertex{pos = {x0, y0}, uv = {-1.0, -1.0}, color = color}
	v1 := Chrome_Vertex{pos = {x1, y0}, uv = {-1.0, -1.0}, color = color}
	v2 := Chrome_Vertex{pos = {x0, y1}, uv = {-1.0, -1.0}, color = color}
	v3 := Chrome_Vertex{pos = {x0, y1}, uv = {-1.0, -1.0}, color = color}
	v4 := Chrome_Vertex{pos = {x1, y0}, uv = {-1.0, -1.0}, color = color}
	v5 := Chrome_Vertex{pos = {x1, y1}, uv = {-1.0, -1.0}, color = color}

	append(&b.vertices, v0, v1, v2, v3, v4, v5)
	b.active_count = u32(len(b.vertices))
	return true
}

chrome_batch_push_uv_quad :: proc(b: ^Chrome_Batch, rect: [4]f32, uv_rect: [4]f32, color: [4]f32) -> bool {
	if b == nil || !b.available do return false
	if u32(len(b.vertices) + 6) > b.max_vertices do return false

	x0 := rect[0]
	y0 := rect[1]
	x1 := rect[0] + rect[2]
	y1 := rect[1] + rect[3]

	u0 := uv_rect[0]
	v0_uv := uv_rect[1]
	u1 := uv_rect[2]
	v1_uv := uv_rect[3]

	v0 := Chrome_Vertex{pos = {x0, y0}, uv = {u0, v0_uv}, color = color}
	v1 := Chrome_Vertex{pos = {x1, y0}, uv = {u1, v0_uv}, color = color}
	v2 := Chrome_Vertex{pos = {x0, y1}, uv = {u0, v1_uv}, color = color}
	v3 := Chrome_Vertex{pos = {x0, y1}, uv = {u0, v1_uv}, color = color}
	v4 := Chrome_Vertex{pos = {x1, y0}, uv = {u1, v0_uv}, color = color}
	v5 := Chrome_Vertex{pos = {x1, y1}, uv = {u1, v1_uv}, color = color}

	append(&b.vertices, v0, v1, v2, v3, v4, v5)
	b.active_count = u32(len(b.vertices))
	return true
}

chrome_batch_flush :: proc(b: ^Chrome_Batch) -> bool {
	if b == nil || !b.available || len(b.vertices) == 0 do return false
	bytes := u64(len(b.vertices)) * size_of(Chrome_Vertex)
	contract.write_buffer(b.queue, b.vertex_buffer, 0, raw_data(b.vertices), bytes)
	return true
}

chrome_batch_draw :: proc(b: ^Chrome_Batch, pass: contract.Gpu_RenderPassEncoder) {
	if b == nil || !b.available || len(b.vertices) == 0 || rawptr(pass) == nil do return
	if rawptr(b.pipeline) != nil {
		contract.render_set_pipeline(pass, b.pipeline)
	}
	if rawptr(b.bind_group) != nil {
		contract.render_set_bind_group(pass, 0, b.bind_group)
	}
	contract.render_set_vertex_buffer(pass, 0, b.vertex_buffer, 0)
	contract.render_draw(pass, u32(len(b.vertices)), 1)
}
