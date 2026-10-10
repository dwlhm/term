package three_d

import "base:runtime"
import "core:math"
import "vendor:wgpu"

COMPONENT_3D_WGSL :: #load("../shaders/component_3d.wgsl")

// Vertex3D: 48-byte interleaved vertex format.
Vertex3D :: struct {
	position: [3]f32,
	normal:   [3]f32,
	uv:       [2]f32,
	color:    [4]f32,
}
#assert(size_of(Vertex3D) == 48)

// Component3D_Uniforms: 272-byte uniform block matching WGSL @group(0) @binding(0).
Component3D_Uniforms :: struct #align(16) {
	mvp:           matrix[4, 4]f32,
	model:         matrix[4, 4]f32,
	normal_mat:    matrix[4, 4]f32,
	light_pos:     [4]f32,
	view_pos:      [4]f32,
	ambient_color: [4]f32,
	light_color:   [4]f32,
	time:          f32,
	metallic:      f32,
	roughness:     f32,
	wireframe:     f32,
}
#assert(size_of(Component3D_Uniforms) == 272)

// create_cube_mesh builds a 3D unit cube (24 vertices, 36 indices) with CCW winding.
create_cube_mesh :: proc(allocator: runtime.Allocator = context.allocator) -> (vertices: []Vertex3D, indices: []u32) {
	verts := make([]Vertex3D, 24, allocator)
	inds := make([]u32, 36, allocator)

	c_front  := [4]f32{0.15, 0.70, 0.95, 1.0} // Cyan
	c_back   := [4]f32{0.10, 0.45, 0.85, 1.0} // Deep blue
	c_top    := [4]f32{0.30, 0.85, 1.00, 1.0} // Light cyan
	c_bottom := [4]f32{0.08, 0.30, 0.65, 1.0} // Darker blue
	c_right  := [4]f32{0.20, 0.75, 0.90, 1.0} // Teal
	c_left   := [4]f32{0.12, 0.55, 0.80, 1.0} // Slate blue

	// Front face (+Z)
	verts[0]  = Vertex3D{ {-1, -1,  1}, {0, 0,  1}, {0, 0}, c_front }
	verts[1]  = Vertex3D{ { 1, -1,  1}, {0, 0,  1}, {1, 0}, c_front }
	verts[2]  = Vertex3D{ { 1,  1,  1}, {0, 0,  1}, {1, 1}, c_front }
	verts[3]  = Vertex3D{ {-1,  1,  1}, {0, 0,  1}, {0, 1}, c_front }

	// Back face (-Z)
	verts[4]  = Vertex3D{ { 1, -1, -1}, {0, 0, -1}, {0, 0}, c_back }
	verts[5]  = Vertex3D{ {-1, -1, -1}, {0, 0, -1}, {1, 0}, c_back }
	verts[6]  = Vertex3D{ {-1,  1, -1}, {0, 0, -1}, {1, 1}, c_back }
	verts[7]  = Vertex3D{ { 1,  1, -1}, {0, 0, -1}, {0, 1}, c_back }

	// Top face (+Y)
	verts[8]  = Vertex3D{ {-1,  1,  1}, {0, 1,  0}, {0, 0}, c_top }
	verts[9]  = Vertex3D{ { 1,  1,  1}, {0, 1,  0}, {1, 0}, c_top }
	verts[10] = Vertex3D{ { 1,  1, -1}, {0, 1,  0}, {1, 1}, c_top }
	verts[11] = Vertex3D{ {-1,  1, -1}, {0, 1,  0}, {0, 1}, c_top }

	// Bottom face (-Y)
	verts[12] = Vertex3D{ {-1, -1, -1}, {0, -1, 0}, {0, 0}, c_bottom }
	verts[13] = Vertex3D{ { 1, -1, -1}, {0, -1, 0}, {1, 0}, c_bottom }
	verts[14] = Vertex3D{ { 1, -1,  1}, {0, -1, 0}, {1, 1}, c_bottom }
	verts[15] = Vertex3D{ {-1, -1,  1}, {0, -1, 0}, {0, 1}, c_bottom }

	// Right face (+X)
	verts[16] = Vertex3D{ { 1, -1,  1}, {1, 0,  0}, {0, 0}, c_right }
	verts[17] = Vertex3D{ { 1, -1, -1}, {1, 0,  0}, {1, 0}, c_right }
	verts[18] = Vertex3D{ { 1,  1, -1}, {1, 0,  0}, {1, 1}, c_right }
	verts[19] = Vertex3D{ { 1,  1,  1}, {1, 0,  0}, {0, 1}, c_right }

	// Left face (-X)
	verts[20] = Vertex3D{ {-1, -1, -1}, {-1, 0, 0}, {0, 0}, c_left }
	verts[21] = Vertex3D{ {-1, -1,  1}, {-1, 0, 0}, {1, 0}, c_left }
	verts[22] = Vertex3D{ {-1,  1,  1}, {-1, 0, 0}, {1, 1}, c_left }
	verts[23] = Vertex3D{ {-1,  1, -1}, {-1, 0, 0}, {0, 1}, c_left }

	// Indices (6 quads * 2 triangles = 12 triangles = 36 indices)
	for i in 0..<6 {
		base := u32(i * 4)
		out := i * 6
		inds[out + 0] = base + 0
		inds[out + 1] = base + 1
		inds[out + 2] = base + 2
		inds[out + 3] = base + 0
		inds[out + 4] = base + 2
		inds[out + 5] = base + 3
	}

	return verts, inds
}

// create_prism_mesh builds a 3D HUD hexagonal prism / badge.
create_prism_mesh :: proc(allocator: runtime.Allocator = context.allocator) -> (vertices: []Vertex3D, indices: []u32) {
	// 7 vertices for top cap + 7 vertices for bottom cap + 24 vertices for 6 side quads = 38 vertices
	verts := make([]Vertex3D, 38, allocator)
	inds := make([]u32, 72, allocator)

	c_top_center := [4]f32{0.40, 0.90, 1.00, 1.0}
	c_top_rim    := [4]f32{0.15, 0.75, 0.95, 1.0}
	c_bot_center := [4]f32{0.10, 0.35, 0.70, 1.0}
	c_bot_rim    := [4]f32{0.08, 0.30, 0.60, 1.0}
	c_side_a     := [4]f32{0.20, 0.80, 0.95, 1.0}
	c_side_b     := [4]f32{0.12, 0.50, 0.80, 1.0}

	radius: f32 = 1.2
	half_h: f32 = 0.4

	// Top cap: center is at index 0
	verts[0] = Vertex3D{ {0, half_h, 0}, {0, 1, 0}, {0.5, 0.5}, c_top_center }
	for i in 0..<6 {
		angle := f32(i) * (2.0 * math.PI / 6.0)
		x := radius * math.cos(angle)
		z := radius * math.sin(angle)
		u := 0.5 + 0.5 * math.cos(angle)
		v := 0.5 + 0.5 * math.sin(angle)
		verts[1 + i] = Vertex3D{ {x, half_h, z}, {0, 1, 0}, {u, v}, c_top_rim }

		next_i := (i + 1) % 6
		inds[i * 3 + 0] = 0
		inds[i * 3 + 1] = u32(1 + next_i)
		inds[i * 3 + 2] = u32(1 + i)
	}

	// Bottom cap: center is at index 7
	verts[7] = Vertex3D{ {0, -half_h, 0}, {0, -1, 0}, {0.5, 0.5}, c_bot_center }
	for i in 0..<6 {
		angle := f32(i) * (2.0 * math.PI / 6.0)
		x := radius * math.cos(angle)
		z := radius * math.sin(angle)
		u := 0.5 + 0.5 * math.cos(angle)
		v := 0.5 + 0.5 * math.sin(angle)
		verts[8 + i] = Vertex3D{ {x, -half_h, z}, {0, -1, 0}, {u, v}, c_bot_rim }

		next_i := (i + 1) % 6
		inds[18 + i * 3 + 0] = 7
		inds[18 + i * 3 + 1] = u32(8 + i)
		inds[18 + i * 3 + 2] = u32(8 + next_i)
	}

	// Side quads: 6 faces * 4 vertices = 24 vertices (indices 14..37)
	side_v_start := 14
	side_i_start := 36
	for i in 0..<6 {
		a0 := f32(i) * (2.0 * math.PI / 6.0)
		a1 := f32((i + 1) % 6) * (2.0 * math.PI / 6.0)
		amid := (a0 + a1) * 0.5

		nx := math.cos(amid)
		nz := math.sin(amid)
		norm := [3]f32{nx, 0, nz}

		x0 := radius * math.cos(a0)
		z0 := radius * math.sin(a0)
		x1 := radius * math.cos(a1)
		z1 := radius * math.sin(a1)

		base_v := u32(side_v_start + i * 4)
		verts[base_v + 0] = Vertex3D{ {x0, -half_h, z0}, norm, {0, 0}, c_side_b }
		verts[base_v + 1] = Vertex3D{ {x1, -half_h, z1}, norm, {1, 0}, c_side_b }
		verts[base_v + 2] = Vertex3D{ {x1,  half_h, z1}, norm, {1, 1}, c_side_a }
		verts[base_v + 3] = Vertex3D{ {x0,  half_h, z0}, norm, {0, 1}, c_side_a }

		out := side_i_start + i * 6
		inds[out + 0] = base_v + 0
		inds[out + 1] = base_v + 1
		inds[out + 2] = base_v + 2
		inds[out + 3] = base_v + 0
		inds[out + 4] = base_v + 2
		inds[out + 5] = base_v + 3
	}

	return verts, inds
}

Three_D_Renderer :: struct {
	device:         wgpu.Device,
	queue:          wgpu.Queue,
	pipeline:       wgpu.RenderPipeline,
	uniform_buffer: wgpu.Buffer,
	vertex_buffer:  wgpu.Buffer,
	index_buffer:   wgpu.Buffer,
	depth_texture:  wgpu.Texture,
	depth_view:     wgpu.TextureView,
	bind_layout:    wgpu.BindGroupLayout,
	bind_group:     wgpu.BindGroup,
	shader_module:  wgpu.ShaderModule,
	vertex_count:   u32,
	index_count:    u32,
	width:          u32,
	height:         u32,
	color_format:   wgpu.TextureFormat,
	depth_format:   wgpu.TextureFormat,
	active_mesh:    int, // 0 = Cube, 1 = Prism
	initialized:    bool,
}

three_d_init :: proc(
	r: ^Three_D_Renderer,
	device: wgpu.Device,
	queue: wgpu.Queue,
	color_format: wgpu.TextureFormat,
	width, height: u32,
	allocator: runtime.Allocator = context.allocator,
) -> bool {
	if r == nil || device == nil || queue == nil do return false

	r.device = device
	r.queue = queue
	r.width = max(u32(1), width)
	r.height = max(u32(1), height)
	r.color_format = color_format
	if r.color_format == wgpu.TextureFormat(1) {
		r.color_format = .BGRA8Unorm
	} else if r.color_format == wgpu.TextureFormat(2) {
		r.color_format = .RGBA8Unorm
	}
	if r.color_format == .Undefined {
		when ODIN_OS == .Darwin {
			r.color_format = .BGRA8Unorm
		} else {
			r.color_format = .RGBA8Unorm
		}
	}
	r.depth_format = .Depth24Plus
	r.active_mesh = 0

	// Create depth texture and view
	depth_desc := wgpu.TextureDescriptor{
		usage         = { .RenderAttachment },
		dimension     = ._2D,
		size          = wgpu.Extent3D{ width = r.width, height = r.height, depthOrArrayLayers = 1 },
		format        = r.depth_format,
		mipLevelCount = 1,
		sampleCount   = 1,
	}
	r.depth_texture = wgpu.DeviceCreateTexture(device, &depth_desc)
	if r.depth_texture == nil do return false

	r.depth_view = wgpu.TextureCreateView(r.depth_texture, nil)
	if r.depth_view == nil {
		three_d_destroy(r)
		return false
	}

	// Create uniform buffer (272 bytes)
	u_desc := wgpu.BufferDescriptor{
		usage = { .Uniform, .CopyDst },
		size  = u64(size_of(Component3D_Uniforms)),
	}
	r.uniform_buffer = wgpu.DeviceCreateBuffer(device, &u_desc)
	if r.uniform_buffer == nil {
		three_d_destroy(r)
		return false
	}

	// Create initial mesh geometry (Cube)
	verts, inds := create_cube_mesh(allocator)
	defer delete(verts, allocator)
	defer delete(inds, allocator)

	v_desc := wgpu.BufferDescriptor{
		usage = { .Vertex, .CopyDst },
		size  = u64(len(verts) * size_of(Vertex3D)),
	}
	r.vertex_buffer = wgpu.DeviceCreateBuffer(device, &v_desc)
	if r.vertex_buffer == nil {
		three_d_destroy(r)
		return false
	}
	wgpu.QueueWriteBuffer(queue, r.vertex_buffer, 0, raw_data(verts), uint(len(verts) * size_of(Vertex3D)))

	i_desc := wgpu.BufferDescriptor{
		usage = { .Index, .CopyDst },
		size  = u64(len(inds) * size_of(u32)),
	}
	r.index_buffer = wgpu.DeviceCreateBuffer(device, &i_desc)
	if r.index_buffer == nil {
		three_d_destroy(r)
		return false
	}
	wgpu.QueueWriteBuffer(queue, r.index_buffer, 0, raw_data(inds), uint(len(inds) * size_of(u32)))
	r.vertex_count = u32(len(verts))
	r.index_count = u32(len(inds))

	// Create shader module
	wgsl_source := wgpu.ShaderSourceWGSL{
		chain = wgpu.ChainedStruct{
			sType = .ShaderSourceWGSL,
		},
		code = string(COMPONENT_3D_WGSL),
	}
	sm_desc := wgpu.ShaderModuleDescriptor{
		nextInChain = (^wgpu.ChainedStruct)(&wgsl_source),
	}
	r.shader_module = wgpu.DeviceCreateShaderModule(device, &sm_desc)
	if r.shader_module == nil {
		three_d_destroy(r)
		return false
	}

	// Create render pipeline with depth testing
	attributes := [4]wgpu.VertexAttribute{
		{ format = .Float32x3, offset = u64(offset_of(Vertex3D, position)), shaderLocation = 0 },
		{ format = .Float32x3, offset = u64(offset_of(Vertex3D, normal)),   shaderLocation = 1 },
		{ format = .Float32x2, offset = u64(offset_of(Vertex3D, uv)),       shaderLocation = 2 },
		{ format = .Float32x4, offset = u64(offset_of(Vertex3D, color)),    shaderLocation = 3 },
	}
	vertex_layout := wgpu.VertexBufferLayout{
		stepMode       = .Vertex,
		arrayStride    = u64(size_of(Vertex3D)),
		attributeCount = uint(len(attributes)),
		attributes     = raw_data(&attributes),
	}
	vertex_state := wgpu.VertexState{
		module      = r.shader_module,
		entryPoint  = "vs_main",
		bufferCount = 1,
		buffers     = &vertex_layout,
	}
	blend_state := wgpu.BlendState{
		color = {
			operation = .Add,
			srcFactor = .SrcAlpha,
			dstFactor = .OneMinusSrcAlpha,
		},
		alpha = {
			operation = .Add,
			srcFactor = .One,
			dstFactor = .OneMinusSrcAlpha,
		},
	}
	target := wgpu.ColorTargetState{
		format    = r.color_format,
		blend     = &blend_state,
		writeMask = { .Red, .Green, .Blue, .Alpha },
	}
	fragment_state := wgpu.FragmentState{
		module      = r.shader_module,
		entryPoint  = "fs_main",
		targetCount = 1,
		targets     = &target,
	}
	depth_stencil_state := wgpu.DepthStencilState{
		format            = r.depth_format,
		depthWriteEnabled = .True,
		depthCompare      = .Less,
	}
	pipe_desc := wgpu.RenderPipelineDescriptor{
		vertex       = vertex_state,
		primitive    = wgpu.PrimitiveState{
			topology  = .TriangleList,
			frontFace = .CCW,
			cullMode  = .None,
		},
		depthStencil = &depth_stencil_state,
		multisample  = wgpu.MultisampleState{
			count                  = 1,
			mask                   = ~u32(0),
			alphaToCoverageEnabled = false,
		},
		fragment     = &fragment_state,
	}
	r.pipeline = wgpu.DeviceCreateRenderPipeline(device, &pipe_desc)
	if r.pipeline == nil {
		three_d_destroy(r)
		return false
	}

	// Create bind group layout from pipeline
	r.bind_layout = wgpu.RenderPipelineGetBindGroupLayout(r.pipeline, 0)
	if r.bind_layout == nil {
		layout_entry := wgpu.BindGroupLayoutEntry{
			binding    = 0,
			visibility = { .Vertex, .Fragment },
			buffer     = {
				type = .Uniform,
			},
		}
		layout_desc := wgpu.BindGroupLayoutDescriptor{
			entryCount = 1,
			entries    = &layout_entry,
		}
		r.bind_layout = wgpu.DeviceCreateBindGroupLayout(device, &layout_desc)
	}
	if r.bind_layout == nil {
		three_d_destroy(r)
		return false
	}

	// Create bind group
	bind_entry := wgpu.BindGroupEntry{
		binding = 0,
		buffer  = r.uniform_buffer,
		offset  = 0,
		size    = u64(size_of(Component3D_Uniforms)),
	}
	bg_desc := wgpu.BindGroupDescriptor{
		layout     = r.bind_layout,
		entryCount = 1,
		entries    = &bind_entry,
	}
	r.bind_group = wgpu.DeviceCreateBindGroup(device, &bg_desc)
	if r.bind_group == nil {
		three_d_destroy(r)
		return false
	}

	r.initialized = true
	return true
}

three_d_destroy :: proc(r: ^Three_D_Renderer) {
	if r == nil do return

	if r.pipeline != nil {
		wgpu.RenderPipelineRelease(r.pipeline)
		r.pipeline = nil
	}
	if r.bind_group != nil {
		wgpu.BindGroupRelease(r.bind_group)
		r.bind_group = nil
	}
	if r.bind_layout != nil {
		wgpu.BindGroupLayoutRelease(r.bind_layout)
		r.bind_layout = nil
	}
	if r.shader_module != nil {
		wgpu.ShaderModuleRelease(r.shader_module)
		r.shader_module = nil
	}
	if r.depth_view != nil {
		wgpu.TextureViewRelease(r.depth_view)
		r.depth_view = nil
	}
	if r.depth_texture != nil {
		wgpu.TextureDestroy(r.depth_texture)
		wgpu.TextureRelease(r.depth_texture)
		r.depth_texture = nil
	}
	if r.index_buffer != nil {
		wgpu.BufferDestroy(r.index_buffer)
		wgpu.BufferRelease(r.index_buffer)
		r.index_buffer = nil
	}
	if r.vertex_buffer != nil {
		wgpu.BufferDestroy(r.vertex_buffer)
		wgpu.BufferRelease(r.vertex_buffer)
		r.vertex_buffer = nil
	}
	if r.uniform_buffer != nil {
		wgpu.BufferDestroy(r.uniform_buffer)
		wgpu.BufferRelease(r.uniform_buffer)
		r.uniform_buffer = nil
	}
	r.initialized = false
}

three_d_resize :: proc(r: ^Three_D_Renderer, width, height: u32) -> bool {
	if r == nil || r.device == nil do return false
	if width == r.width && height == r.height && r.depth_texture != nil do return true

	if r.depth_view != nil {
		wgpu.TextureViewRelease(r.depth_view)
		r.depth_view = nil
	}
	if r.depth_texture != nil {
		wgpu.TextureDestroy(r.depth_texture)
		wgpu.TextureRelease(r.depth_texture)
		r.depth_texture = nil
	}

	r.width = max(u32(1), width)
	r.height = max(u32(1), height)

	desc := wgpu.TextureDescriptor{
		usage         = { .RenderAttachment },
		dimension     = ._2D,
		size          = wgpu.Extent3D{ width = r.width, height = r.height, depthOrArrayLayers = 1 },
		format        = r.depth_format,
		mipLevelCount = 1,
		sampleCount   = 1,
	}
	r.depth_texture = wgpu.DeviceCreateTexture(r.device, &desc)
	if r.depth_texture == nil do return false

	r.depth_view = wgpu.TextureCreateView(r.depth_texture, nil)
	if r.depth_view == nil do return false

	return true
}

three_d_draw :: proc(r: ^Three_D_Renderer, pass: wgpu.RenderPassEncoder, uniforms: ^Component3D_Uniforms) {
	if r == nil || !r.initialized || pass == nil || uniforms == nil do return

	// Upload uniforms
	wgpu.QueueWriteBuffer(r.queue, r.uniform_buffer, 0, uniforms, uint(size_of(Component3D_Uniforms)))

	// Record pipeline state, bind group, vertex buffer, index buffer, and draw call
	wgpu.RenderPassEncoderSetPipeline(pass, r.pipeline)
	wgpu.RenderPassEncoderSetBindGroup(pass, 0, r.bind_group)
	wgpu.RenderPassEncoderSetVertexBuffer(pass, 0, r.vertex_buffer, 0, u64(r.vertex_count * size_of(Vertex3D)))
	wgpu.RenderPassEncoderSetIndexBuffer(pass, r.index_buffer, .Uint32, 0, u64(r.index_count * size_of(u32)))
	wgpu.RenderPassEncoderDrawIndexed(pass, r.index_count, 1, 0, 0, 0)
}

three_d_set_mesh :: proc(r: ^Three_D_Renderer, mesh_type: int, allocator: runtime.Allocator = context.allocator) -> bool {
	if r == nil || !r.initialized do return false

	verts: []Vertex3D
	inds: []u32
	if mesh_type == 1 {
		verts, inds = create_prism_mesh(allocator)
		r.active_mesh = 1
	} else {
		verts, inds = create_cube_mesh(allocator)
		r.active_mesh = 0
	}
	defer delete(verts, allocator)
	defer delete(inds, allocator)

	// Recreate vertex and index buffers
	if r.vertex_buffer != nil {
		wgpu.BufferDestroy(r.vertex_buffer)
		wgpu.BufferRelease(r.vertex_buffer)
		r.vertex_buffer = nil
	}
	if r.index_buffer != nil {
		wgpu.BufferDestroy(r.index_buffer)
		wgpu.BufferRelease(r.index_buffer)
		r.index_buffer = nil
	}

	v_desc := wgpu.BufferDescriptor{
		usage = { .Vertex, .CopyDst },
		size  = u64(len(verts) * size_of(Vertex3D)),
	}
	r.vertex_buffer = wgpu.DeviceCreateBuffer(r.device, &v_desc)
	if r.vertex_buffer == nil do return false
	wgpu.QueueWriteBuffer(r.queue, r.vertex_buffer, 0, raw_data(verts), uint(len(verts) * size_of(Vertex3D)))

	i_desc := wgpu.BufferDescriptor{
		usage = { .Index, .CopyDst },
		size  = u64(len(inds) * size_of(u32)),
	}
	r.index_buffer = wgpu.DeviceCreateBuffer(r.device, &i_desc)
	if r.index_buffer == nil do return false
	wgpu.QueueWriteBuffer(r.queue, r.index_buffer, 0, raw_data(inds), uint(len(inds) * size_of(u32)))

	r.vertex_count = u32(len(verts))
	r.index_count = u32(len(inds))
	return true
}
