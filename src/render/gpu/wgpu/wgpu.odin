package wgpu_backend

// WGPU implementation of the GPU backend abstraction.
// This file bridges the gpu.Gpu_Backend_VTable interface to the vendor:wgpu bindings.

import "base:runtime"
import "core:c"
import "vendor:wgpu"
import "vendor:sdl3"
import wgpu_sdl3_glue "vendor:wgpu/sdl3glue"
import gpu "../"

// Wgpu_Context holds the concrete WGPU handles.
Wgpu_Context :: struct {
	instance: wgpu.Instance,
	adapter:  wgpu.Adapter,
	device:   wgpu.Device,
	queue:    wgpu.Queue,
	surface:  wgpu.Surface,
	format:   wgpu.TextureFormat,
}

// _wgpu_vtable is the WGPU implementation of the GPU backend vtable.
_wgpu_vtable: gpu.Gpu_Backend_VTable = gpu.Gpu_Backend_VTable{
	create_instance     = _wgpu_create_instance,
	destroy_instance    = _wgpu_destroy_instance,
	request_device      = _wgpu_request_device,
	destroy_device      = _wgpu_destroy_device,
	configure_surface   = _wgpu_configure_surface,
	get_surface_texture = _wgpu_get_surface_texture,
	present_surface     = _wgpu_present_surface,
	get_preferred_format = _wgpu_get_preferred_format,
	create_buffer       = _wgpu_create_buffer,
	destroy_buffer      = _wgpu_destroy_buffer,
	write_buffer        = _wgpu_write_buffer,
	get_buffer_mapped_range = _wgpu_get_buffer_mapped_range,
	unmap_buffer        = _wgpu_unmap_buffer,
	create_texture      = _wgpu_create_texture,
	destroy_texture     = _wgpu_destroy_texture,
	create_texture_view = _wgpu_create_texture_view,
	destroy_texture_view = _wgpu_destroy_texture_view,
	write_texture       = _wgpu_write_texture,
	create_shader_module = _wgpu_create_shader_module,
	destroy_shader_module = _wgpu_destroy_shader_module,
	create_render_pipeline = _wgpu_create_render_pipeline,
	destroy_render_pipeline = _wgpu_destroy_render_pipeline,
	create_bind_group_layout = _wgpu_create_bind_group_layout,
	destroy_bind_group_layout = _wgpu_destroy_bind_group_layout,
	create_bind_group   = _wgpu_create_bind_group,
	destroy_bind_group  = _wgpu_destroy_bind_group,
	create_sampler      = _wgpu_create_sampler,
	destroy_sampler     = _wgpu_destroy_sampler,
	create_command_encoder = _wgpu_create_command_encoder,
	release_command_encoder = _wgpu_release_command_encoder,
	begin_render_pass   = _wgpu_begin_render_pass,
	end_render_pass     = _wgpu_end_render_pass,
	finish_command_buffer = _wgpu_finish_command_buffer,
	release_command_buffer = _wgpu_release_command_buffer,
	submit              = _wgpu_submit,
	wait_for_idle       = _wgpu_wait_for_idle,
	render_set_pipeline = _wgpu_render_set_pipeline,
	render_set_bind_group = _wgpu_render_set_bind_group,
	render_set_vertex_buffer = _wgpu_render_set_vertex_buffer,
	render_draw         = _wgpu_render_draw,
	render_draw_indexed = _wgpu_render_draw_indexed,
	release_surface_texture = _wgpu_release_surface_texture,
	pipeline_get_bind_group_layout = _wgpu_pipeline_get_bind_group_layout,
	create_compute_pipeline = _wgpu_create_compute_pipeline,
	destroy_compute_pipeline = _wgpu_destroy_compute_pipeline,
	begin_compute_pass = _wgpu_begin_compute_pass,
	end_compute_pass = _wgpu_end_compute_pass,
	compute_set_pipeline = _wgpu_compute_set_pipeline,
	compute_set_bind_group = _wgpu_compute_set_bind_group,
	compute_dispatch = _wgpu_compute_dispatch,
	compute_get_bind_group_layout = _wgpu_compute_get_bind_group_layout,
}

// --- Lifecycle ---

_wgpu_create_instance :: proc() -> rawptr {
	instance := wgpu.CreateInstance(nil)
	return rawptr(instance)
}

_wgpu_destroy_instance :: proc(instance: rawptr) {
	if instance != nil {
		wgpu.InstanceRelease(wgpu.Instance(instance))
	}
}

_wgpu_request_device :: proc(instance: rawptr, surface: rawptr) -> (device: gpu.Gpu_Device, queue: gpu.Gpu_Queue) {
	if instance == nil {
		return gpu.Gpu_Device(nil), gpu.Gpu_Queue(nil)
	}
	inst := wgpu.Instance(instance)
	surf := wgpu.Surface(surface)

	// Request adapter with compatible surface + HighPerformance.
	pending := _Wgpu_Pending_Request{}
	opts := wgpu.RequestAdapterOptions{
		compatibleSurface = surf,
		powerPreference   = .HighPerformance,
	}
	adapter_cb := wgpu.RequestAdapterCallbackInfo{
		mode      = .AllowProcessEvents,
		callback  = _wgpu_on_adapter,
		userdata1 = &pending,
	}
	_ = wgpu.InstanceRequestAdapter(inst, &opts, adapter_cb)
	for i in 0..<10_000_000 {
		wgpu.InstanceProcessEvents(inst)
		if pending.status != 0 {
			break
		}
	}
	if pending.status != i32(wgpu.RequestAdapterStatus.Success) {
		return gpu.Gpu_Device(nil), gpu.Gpu_Queue(nil)
	}
	if rawptr(pending.adapter) == nil {
		return gpu.Gpu_Device(nil), gpu.Gpu_Queue(nil)
	}

	// Request device.
	pending.status = 0
	pending.device = wgpu.Device(nil)
	device_cb := wgpu.RequestDeviceCallbackInfo{
		mode      = .AllowProcessEvents,
		callback  = _wgpu_on_device,
		userdata1 = &pending,
	}
	_ = wgpu.AdapterRequestDevice(pending.adapter, nil, device_cb)
	for i in 0..<10_000_000 {
		wgpu.InstanceProcessEvents(inst)
		if pending.status != 0 {
			break
		}
	}
	adapter := pending.adapter
	dev := pending.device
	if pending.status != i32(wgpu.RequestDeviceStatus.Success) {
		if rawptr(adapter) != nil {
			wgpu.AdapterRelease(adapter)
		}
		return gpu.Gpu_Device(nil), gpu.Gpu_Queue(nil)
	}
	if rawptr(dev) == nil {
		wgpu.AdapterRelease(adapter)
		return gpu.Gpu_Device(nil), gpu.Gpu_Queue(nil)
	}
	q := wgpu.DeviceGetQueue(dev)
	wgpu.AdapterRelease(adapter)
	if rawptr(q) == nil {
		wgpu.DeviceRelease(dev)
		return gpu.Gpu_Device(nil), gpu.Gpu_Queue(nil)
	}
	return gpu.Gpu_Device(rawptr(dev)), gpu.Gpu_Queue(rawptr(q))
}

// _Wgpu_Pending_Request carries async request results through userdata1.
_Wgpu_Pending_Request :: struct {
	status:  i32,
	adapter: wgpu.Adapter,
	device:  wgpu.Device,
}

// _wgpu_on_adapter writes the adapter result through userdata1.
_wgpu_on_adapter :: proc "c" (status: wgpu.RequestAdapterStatus, adapter: wgpu.Adapter, message: wgpu.StringView, userdata1: rawptr, userdata2: rawptr) {
	if userdata1 != nil {
		pending := (^_Wgpu_Pending_Request)(userdata1)
		pending.status = i32(status)
		pending.adapter = adapter
	}
}

// _wgpu_on_device writes the device result through userdata1.
_wgpu_on_device :: proc "c" (status: wgpu.RequestDeviceStatus, device: wgpu.Device, message: wgpu.StringView, userdata1: rawptr, userdata2: rawptr) {
	if userdata1 != nil {
		pending := (^_Wgpu_Pending_Request)(userdata1)
		pending.status = i32(status)
		pending.device = device
	}
}

// wgpu_backend_vtable returns the WGPU backend vtable.
wgpu_backend_vtable :: proc() -> ^gpu.Gpu_Backend_VTable {
	return &_wgpu_vtable
}

// _wgpu_release_surface_texture releases a surface texture and its view.
_wgpu_release_surface_texture :: proc(texture: gpu.Gpu_Texture, view: gpu.Gpu_TextureView) {
	if rawptr(view) != nil {
		wgpu.TextureViewRelease(wgpu.TextureView(view))
	}
	if rawptr(texture) != nil {
		wgpu.TextureRelease(wgpu.Texture(texture))
	}
}

// _wgpu_pipeline_get_bind_group_layout returns the auto layout for a pipeline slot.
_wgpu_pipeline_get_bind_group_layout :: proc(pipeline: gpu.Gpu_RenderPipeline, index: u32) -> gpu.Gpu_BindGroupLayout {
	layout := wgpu.RenderPipelineGetBindGroupLayout(wgpu.RenderPipeline(pipeline), index)
	return gpu.Gpu_BindGroupLayout(rawptr(layout))
}

_wgpu_destroy_device :: proc(device: gpu.Gpu_Device) {
	if rawptr(device) != nil {
		wgpu.DeviceRelease(wgpu.Device(device))
	}
}

// --- Surface ---

_wgpu_configure_surface :: proc(surface: rawptr, device: gpu.Gpu_Device, format: gpu.Gpu_Format, width, height: u32) {
	surf := wgpu.Surface(surface)
	dev := wgpu.Device(device)
	wgpu_format := _gpu_to_wgpu_format(format)

	wgpu.SurfaceConfigure(surf, &wgpu.SurfaceConfiguration{
		device      = dev,
		format      = wgpu_format,
		usage       = wgpu.TextureUsageFlags{.RenderAttachment},
		width       = width,
		height      = height,
		alphaMode   = .Auto,
		presentMode = .Fifo,
	})
}

_wgpu_get_surface_texture :: proc(surface: rawptr) -> (texture: gpu.Gpu_Texture, view: gpu.Gpu_TextureView, format: gpu.Gpu_Format) {
	surf := wgpu.Surface(surface)
	st := wgpu.SurfaceGetCurrentTexture(surf)
	format = .BGRA8_Unorm
	if st.status != .SuccessOptimal && st.status != .SuccessSuboptimal {
		if rawptr(st.texture) != nil {
			wgpu.TextureRelease(st.texture)
		}
		return gpu.Gpu_Texture(nil), gpu.Gpu_TextureView(nil), format
	}
	texture = gpu.Gpu_Texture(rawptr(st.texture))
	if rawptr(st.texture) != nil {
		tv := wgpu.TextureCreateView(st.texture, nil)
		view = gpu.Gpu_TextureView(rawptr(tv))
	}
	return
}

_wgpu_present_surface :: proc(surface: rawptr) -> bool {
	if surface == nil {
		return false
	}
	surf := wgpu.Surface(surface)
	return wgpu.SurfacePresent(surf) == .Success
}

_wgpu_get_preferred_format :: proc(surface: rawptr, device: gpu.Gpu_Device) -> gpu.Gpu_Format {
	return .BGRA8_Unorm
}

// --- Buffers ---

_wgpu_create_buffer :: proc(device: gpu.Gpu_Device, size: u64, usage: gpu.Gpu_Buffer_Usage, mapped_at_creation: bool) -> gpu.Gpu_Buffer {
	dev := wgpu.Device(device)
	wgpu_usage := _gpu_to_wgpu_buffer_usage(usage)

	buf := wgpu.DeviceCreateBuffer(dev, &wgpu.BufferDescriptor{
		usage            = wgpu_usage,
		size             = size,
		mappedAtCreation = b32(mapped_at_creation),
	})
	return gpu.Gpu_Buffer(rawptr(buf))
}

_wgpu_destroy_buffer :: proc(buffer: gpu.Gpu_Buffer) {
	if rawptr(buffer) != nil {
		wgpu.BufferDestroy(wgpu.Buffer(buffer))
	}
}

_wgpu_write_buffer :: proc(queue: gpu.Gpu_Queue, buffer: gpu.Gpu_Buffer, offset: u64, data: rawptr, size: u64) {
	q := wgpu.Queue(queue)
	buf := wgpu.Buffer(buffer)
	wgpu.QueueWriteBuffer(q, buf, offset, data, uint(size))
}

_wgpu_get_buffer_mapped_range :: proc(buffer: gpu.Gpu_Buffer, offset: u64, size: u64) -> []u8 {
	buf := wgpu.Buffer(buffer)
	return wgpu.BufferGetMappedRange(buf, uint(offset), uint(size))
}

_wgpu_unmap_buffer :: proc(buffer: gpu.Gpu_Buffer) {
	buf := wgpu.Buffer(buffer)
	wgpu.BufferUnmap(buf)
}

// --- Textures ---

_wgpu_create_texture :: proc(device: gpu.Gpu_Device, width, height: u32, format: gpu.Gpu_Format, usage: gpu.Gpu_Texture_Usage) -> gpu.Gpu_Texture {
	dev := wgpu.Device(device)
	wgpu_format := _gpu_to_wgpu_format(format)
	wgpu_usage := _gpu_to_wgpu_texture_usage(usage)

	tex := wgpu.DeviceCreateTexture(dev, &wgpu.TextureDescriptor{
		usage         = wgpu_usage,
		dimension     = ._2D,
		size          = wgpu.Extent3D{width = width, height = height, depthOrArrayLayers = 1},
		format        = wgpu_format,
		mipLevelCount = 1,
		sampleCount   = 1,
	})
	return gpu.Gpu_Texture(rawptr(tex))
}

_wgpu_destroy_texture :: proc(texture: gpu.Gpu_Texture) {
	if rawptr(texture) != nil {
		wgpu.TextureDestroy(wgpu.Texture(texture))
	}
}

_wgpu_create_texture_view :: proc(texture: gpu.Gpu_Texture) -> gpu.Gpu_TextureView {
	tex := wgpu.Texture(texture)
	view := wgpu.TextureCreateView(tex, nil)
	return gpu.Gpu_TextureView(rawptr(view))
}

_wgpu_destroy_texture_view :: proc(view: gpu.Gpu_TextureView) {
	if rawptr(view) != nil {
		wgpu.TextureViewRelease(wgpu.TextureView(view))
	}
}

_wgpu_write_texture :: proc(queue: gpu.Gpu_Queue, texture: gpu.Gpu_Texture, data: []u8, width, height: u32) {
	q := wgpu.Queue(queue)
	tex := wgpu.Texture(texture)

	bytes_per_row := width
	if height > 0 && len(data) > 0 {
		bytes_per_row = u32(len(data)) / height
	}

	data_layout := wgpu.TexelCopyBufferLayout{
		offset       = 0,
		bytesPerRow  = bytes_per_row,
		rowsPerImage = height,
	}
	dest := wgpu.TexelCopyTextureInfo{
		texture = tex,
		origin  = wgpu.Origin3D{},
		aspect  = .All,
	}
	write_size := wgpu.Extent3D{width = width, height = height, depthOrArrayLayers = 1}

	wgpu.QueueWriteTexture(
		q,
		&dest,
		raw_data(data),
		uint(len(data)),
		&data_layout,
		&write_size,
	)
}

// --- Shaders ---

_wgpu_create_shader_module :: proc(device: gpu.Gpu_Device, wgsl_source: string) -> gpu.Gpu_ShaderModule {
	dev := wgpu.Device(device)
	mod := wgpu.DeviceCreateShaderModule(dev, &wgpu.ShaderModuleDescriptor{
		nextInChain = &wgpu.ShaderSourceWGSL{
			chain = wgpu.ChainedStruct{
				sType = .ShaderSourceWGSL,
			},
			code = wgsl_source,
		},
	})
	return gpu.Gpu_ShaderModule(rawptr(mod))
}

_wgpu_destroy_shader_module :: proc(module: gpu.Gpu_ShaderModule) {
	if rawptr(module) != nil {
		wgpu.ShaderModuleRelease(wgpu.ShaderModule(module))
	}
}

// --- Pipelines ---

_wgpu_create_render_pipeline :: proc(
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
	dev := wgpu.Device(device)
	wgpu_format := _gpu_to_wgpu_format(format)

	// Build vertex buffer layouts.
	// NOTE: attribute arrays must outlive DeviceCreateRenderPipeline, so they
	// are owned by attr_store and freed explicitly after pipeline creation
	// (never defer-freed inside the loop).
	wgpu_vertex_layouts := make([dynamic]wgpu.VertexBufferLayout, len(vertex_layouts))
	defer delete(wgpu_vertex_layouts)
	attr_store := make([dynamic][dynamic]wgpu.VertexAttribute, len(vertex_layouts))
	defer delete(attr_store)

	for i in 0..<len(vertex_layouts) {
		vl := vertex_layouts[i]

		attr_store[i] = make([dynamic]wgpu.VertexAttribute, len(vl.attributes))

		for j in 0..<len(vl.attributes) {
			attr := vl.attributes[j]
			attr_store[i][j] = wgpu.VertexAttribute{
				format         = _gpu_to_wgpu_vertex_format(attr.format),
				offset         = attr.offset,
				shaderLocation = attr.shader_location,
			}
		}

		step_mode: wgpu.VertexStepMode
		if vl.step_mode == .Vertex {
			step_mode = .Vertex
		} else {
			step_mode = .Instance
		}

		wgpu_vertex_layouts[i] = wgpu.VertexBufferLayout{
			arrayStride    = vl.array_stride,
			stepMode       = step_mode,
			attributeCount = uint(len(attr_store[i])),
			attributes     = raw_data(attr_store[i]),
		}
	}

	// Build color target state with blend
	blend_state: wgpu.BlendState
	switch blend {
	case .Opaque:
		blend_state = wgpu.BlendState{
			color = wgpu.BlendComponent{
				operation = .Add,
				srcFactor = .One,
				dstFactor = .Zero,
			},
			alpha = wgpu.BlendComponent{
				operation = .Add,
				srcFactor = .One,
				dstFactor = .Zero,
			},
		}
	case .Alpha_Blend:
		blend_state = wgpu.BlendState{
			color = wgpu.BlendComponent{
				operation = .Add,
				srcFactor = .SrcAlpha,
				dstFactor = .OneMinusSrcAlpha,
			},
			alpha = wgpu.BlendComponent{
				operation = .Add,
				srcFactor = .One,
				dstFactor = .OneMinusSrcAlpha,
			},
		}
	}

	color_target := wgpu.ColorTargetState{
		format    = wgpu_format,
		blend     = &blend_state,
		writeMask = wgpu.ColorWriteMaskFlags_All,
	}

	fragment_state := wgpu.FragmentState{
		module      = wgpu.ShaderModule(fragment_shader),
		entryPoint  = fragment_entry,
		targetCount = 1,
		targets     = &color_target,
	}

	pipeline := wgpu.DeviceCreateRenderPipeline(dev, &wgpu.RenderPipelineDescriptor{
		vertex = wgpu.VertexState{
			module      = wgpu.ShaderModule(vertex_shader),
			entryPoint  = vertex_entry,
			bufferCount = uint(len(wgpu_vertex_layouts)),
			buffers     = raw_data(wgpu_vertex_layouts),
		},
		primitive = wgpu.PrimitiveState{
			topology = _gpu_to_wgpu_topology(topology),
		},
		multisample = wgpu.MultisampleState{
			count = 1,
			mask  = 0xFFFFFFFF,
		},
		fragment = &fragment_state,
	})

	for i in 0..<len(attr_store) {
		delete(attr_store[i])
	}

	return gpu.Gpu_RenderPipeline(rawptr(pipeline))
}

_wgpu_destroy_render_pipeline :: proc(pipeline: gpu.Gpu_RenderPipeline) {
	if rawptr(pipeline) != nil {
		wgpu.RenderPipelineRelease(wgpu.RenderPipeline(pipeline))
	}
}

// --- Bind Groups ---

_wgpu_create_bind_group_layout :: proc(device: gpu.Gpu_Device, entries: []gpu.Gpu_Bind_Layout_Entry) -> gpu.Gpu_BindGroupLayout {
	dev := wgpu.Device(device)

	wgpu_entries := make([dynamic]wgpu.BindGroupLayoutEntry, len(entries))
	defer delete(wgpu_entries)

	for i in 0..<len(entries) {
		e := entries[i]
		entry: wgpu.BindGroupLayoutEntry
		entry.binding = e.binding
		entry.visibility = wgpu.ShaderStageFlags{}
		if e.visibility & 1 != 0 {
			entry.visibility |= wgpu.ShaderStageFlags{.Vertex}
		}
		if e.visibility & 2 != 0 {
			entry.visibility |= wgpu.ShaderStageFlags{.Fragment}
		}
		if e.visibility & 4 != 0 {
			entry.visibility |= wgpu.ShaderStageFlags{.Compute}
		}

		switch e.binding_type {
		case .Uniform_Buffer:
			entry.buffer = wgpu.BufferBindingLayout{
				type = .Uniform,
			}
		case .Storage_Buffer:
			entry.buffer = wgpu.BufferBindingLayout{
				type = .ReadOnlyStorage,
			}
		case .Sampler:
			entry.sampler = wgpu.SamplerBindingLayout{
				type = .Filtering,
			}
		case .Sampled_Texture:
			entry.texture = wgpu.TextureBindingLayout{
				sampleType    = .Float,
				viewDimension = ._2D,
			}
		case .Storage_Texture:
			entry.storageTexture = wgpu.StorageTextureBindingLayout{
				access        = .WriteOnly,
				format        = .RGBA8Unorm,
				viewDimension = ._2D,
			}
		}

		wgpu_entries[i] = entry
	}

	layout := wgpu.DeviceCreateBindGroupLayout(dev, &wgpu.BindGroupLayoutDescriptor{
		entryCount = uint(len(wgpu_entries)),
		entries    = raw_data(wgpu_entries),
	})
	return gpu.Gpu_BindGroupLayout(rawptr(layout))
}

_wgpu_destroy_bind_group_layout :: proc(layout: gpu.Gpu_BindGroupLayout) {
	if rawptr(layout) != nil {
		wgpu.BindGroupLayoutRelease(wgpu.BindGroupLayout(layout))
	}
}

_wgpu_create_bind_group :: proc(device: gpu.Gpu_Device, layout: gpu.Gpu_BindGroupLayout, entries: []gpu.Gpu_Bind_Entry) -> gpu.Gpu_BindGroup {
	dev := wgpu.Device(device)

	wgpu_entries := make([dynamic]wgpu.BindGroupEntry, len(entries))
	defer delete(wgpu_entries)

	for i in 0..<len(entries) {
		e := entries[i]
		we: wgpu.BindGroupEntry
		we.binding = e.binding

		switch e.entry_type {
		case .Buffer:
			we.buffer = wgpu.Buffer(e.buffer)
			we.offset = e.offset
			we.size   = e.size
		case .Texture_View:
			we.textureView = wgpu.TextureView(e.view)
		case .Sampler:
			we.sampler = wgpu.Sampler(e.sampler)
		}

		wgpu_entries[i] = we
	}

	group := wgpu.DeviceCreateBindGroup(dev, &wgpu.BindGroupDescriptor{
		layout     = wgpu.BindGroupLayout(layout),
		entryCount = uint(len(wgpu_entries)),
		entries    = raw_data(wgpu_entries),
	})
	return gpu.Gpu_BindGroup(rawptr(group))
}

_wgpu_destroy_bind_group :: proc(group: gpu.Gpu_BindGroup) {
	if rawptr(group) != nil {
		wgpu.BindGroupRelease(wgpu.BindGroup(group))
	}
}

// --- Sampler ---

_wgpu_create_sampler :: proc(device: gpu.Gpu_Device) -> gpu.Gpu_Sampler {
	dev := wgpu.Device(device)
	sampler := wgpu.DeviceCreateSampler(dev, &wgpu.SamplerDescriptor{
		addressModeU = .ClampToEdge,
		addressModeV = .ClampToEdge,
		addressModeW = .ClampToEdge,
		magFilter    = .Nearest,
		minFilter    = .Nearest,
		mipmapFilter = .Nearest,
		lodMinClamp  = 0,
		lodMaxClamp  = 1,
		maxAnisotropy = 1,
	})
	return gpu.Gpu_Sampler(rawptr(sampler))
}

_wgpu_destroy_sampler :: proc(sampler: gpu.Gpu_Sampler) {
	if rawptr(sampler) != nil {
		wgpu.SamplerRelease(wgpu.Sampler(sampler))
	}
}

// --- Command Encoding ---

_wgpu_create_command_encoder :: proc(device: gpu.Gpu_Device) -> gpu.Gpu_CommandEncoder {
	dev := wgpu.Device(device)
	enc := wgpu.DeviceCreateCommandEncoder(dev, nil)
	return gpu.Gpu_CommandEncoder(rawptr(enc))
}

// _wgpu_release_command_encoder releases an encoder abandoned before finish.
_wgpu_release_command_encoder :: proc(encoder: gpu.Gpu_CommandEncoder) {
	if rawptr(encoder) != nil {
		wgpu.CommandEncoderRelease(wgpu.CommandEncoder(encoder))
	}
}

_wgpu_begin_render_pass :: proc(encoder: gpu.Gpu_CommandEncoder, color_view: gpu.Gpu_TextureView, clear_color: [4]f64, load_op: gpu.Gpu_Load_Op) -> gpu.Gpu_RenderPassEncoder {
	enc := wgpu.CommandEncoder(encoder)

	wgpu_load_op: wgpu.LoadOp
	#partial switch load_op {
	case .Clear:
		wgpu_load_op = .Clear
	case:
		wgpu_load_op = .Load
	}

	attachment := wgpu.RenderPassColorAttachment{
		view       = wgpu.TextureView(color_view),
		depthSlice = max(u32),
		loadOp     = wgpu_load_op,
		storeOp    = .Store,
		clearValue = wgpu.Color(clear_color),
	}

	pass := wgpu.CommandEncoderBeginRenderPass(enc, &wgpu.RenderPassDescriptor{
		colorAttachmentCount = 1,
		colorAttachments     = &attachment,
	})
	return gpu.Gpu_RenderPassEncoder(rawptr(pass))
}

_wgpu_end_render_pass :: proc(pass: gpu.Gpu_RenderPassEncoder) {
	wgpu.RenderPassEncoderEnd(wgpu.RenderPassEncoder(pass))
	wgpu.RenderPassEncoderRelease(wgpu.RenderPassEncoder(pass))
}

_wgpu_finish_command_buffer :: proc(encoder: gpu.Gpu_CommandEncoder) -> rawptr {
	enc := wgpu.CommandEncoder(encoder)
	cmd := wgpu.CommandEncoderFinish(enc, nil)
	return rawptr(cmd)
}

// _wgpu_release_command_buffer releases the application reference after submit.
_wgpu_release_command_buffer :: proc(command_buffer: rawptr) {
	if command_buffer != nil {
		wgpu.CommandBufferRelease(wgpu.CommandBuffer(command_buffer))
	}
}

_wgpu_submit :: proc(queue: gpu.Gpu_Queue, command_buffer: rawptr) -> bool {
	if rawptr(queue) == nil || command_buffer == nil {
		return false
	}
	q := wgpu.Queue(queue)
	cmd := wgpu.CommandBuffer(command_buffer)
	cmds := [1]wgpu.CommandBuffer{cmd}
	wgpu.QueueSubmit(q, cmds[:])
	return true
}

// _wgpu_wait_for_idle uses the installed native WGPU completion primitive.
// DevicePoll(wait=true) does not return until the device queue is idle.
_wgpu_wait_for_idle :: proc(device: gpu.Gpu_Device) -> bool {
	if rawptr(device) == nil {
		return false
	}
	return wgpu.DevicePoll(wgpu.Device(device), true, nil) != false
}

// --- Render Pass Commands ---

_wgpu_render_set_pipeline :: proc(pass: gpu.Gpu_RenderPassEncoder, pipeline: gpu.Gpu_RenderPipeline) {
	wgpu.RenderPassEncoderSetPipeline(
		wgpu.RenderPassEncoder(pass),
		wgpu.RenderPipeline(pipeline),
	)
}

_wgpu_render_set_bind_group :: proc(pass: gpu.Gpu_RenderPassEncoder, index: u32, group: gpu.Gpu_BindGroup) {
	wgpu.RenderPassEncoderSetBindGroup(
		wgpu.RenderPassEncoder(pass),
		index,
		wgpu.BindGroup(group),
	)
}

_wgpu_render_set_vertex_buffer :: proc(pass: gpu.Gpu_RenderPassEncoder, slot: u32, buffer: gpu.Gpu_Buffer, offset: u64) {
	wgpu.RenderPassEncoderSetVertexBuffer(
		wgpu.RenderPassEncoder(pass),
		slot,
		wgpu.Buffer(buffer),
		offset,
		wgpu.WHOLE_SIZE,
	)
}

_wgpu_render_draw :: proc(pass: gpu.Gpu_RenderPassEncoder, vertex_count: u32, instance_count: u32) {
	wgpu.RenderPassEncoderDraw(
		wgpu.RenderPassEncoder(pass),
		vertex_count,
		instance_count,
		0,
		0,
	)
}

_wgpu_render_draw_indexed :: proc(pass: gpu.Gpu_RenderPassEncoder, index_count: u32, instance_count: u32) {
	wgpu.RenderPassEncoderDrawIndexed(
		wgpu.RenderPassEncoder(pass),
		index_count,
		instance_count,
		0,
		0,
		0,
	)
}

// --- Compute Pipelines ---

_wgpu_create_compute_pipeline :: proc(device: gpu.Gpu_Device, shader: gpu.Gpu_ShaderModule, entry: string) -> gpu.Gpu_ComputePipeline {
	dev := wgpu.Device(device)
	pipeline := wgpu.DeviceCreateComputePipeline(dev, &wgpu.ComputePipelineDescriptor{
		compute = wgpu.ComputeState{
			module     = wgpu.ShaderModule(shader),
			entryPoint = entry,
		},
	})
	return gpu.Gpu_ComputePipeline(rawptr(pipeline))
}

_wgpu_destroy_compute_pipeline :: proc(pipeline: gpu.Gpu_ComputePipeline) {
	if rawptr(pipeline) != nil {
		wgpu.ComputePipelineRelease(wgpu.ComputePipeline(pipeline))
	}
}

_wgpu_compute_get_bind_group_layout :: proc(pipeline: gpu.Gpu_ComputePipeline, index: u32) -> gpu.Gpu_BindGroupLayout {
	layout := wgpu.ComputePipelineGetBindGroupLayout(wgpu.ComputePipeline(pipeline), index)
	return gpu.Gpu_BindGroupLayout(rawptr(layout))
}

// --- Compute Pass Commands ---

_wgpu_begin_compute_pass :: proc(encoder: gpu.Gpu_CommandEncoder) -> gpu.Gpu_ComputePassEncoder {
	enc := wgpu.CommandEncoder(encoder)
	pass := wgpu.CommandEncoderBeginComputePass(enc, nil)
	return gpu.Gpu_ComputePassEncoder(rawptr(pass))
}

_wgpu_end_compute_pass :: proc(pass: gpu.Gpu_ComputePassEncoder) {
	wgpu.ComputePassEncoderEnd(wgpu.ComputePassEncoder(pass))
	wgpu.ComputePassEncoderRelease(wgpu.ComputePassEncoder(pass))
}

_wgpu_compute_set_pipeline :: proc(pass: gpu.Gpu_ComputePassEncoder, pipeline: gpu.Gpu_ComputePipeline) {
	wgpu.ComputePassEncoderSetPipeline(
		wgpu.ComputePassEncoder(pass),
		wgpu.ComputePipeline(pipeline),
	)
}

_wgpu_compute_set_bind_group :: proc(pass: gpu.Gpu_ComputePassEncoder, index: u32, group: gpu.Gpu_BindGroup) {
	wgpu.ComputePassEncoderSetBindGroup(
		wgpu.ComputePassEncoder(pass),
		index,
		wgpu.BindGroup(group),
	)
}

_wgpu_compute_dispatch :: proc(pass: gpu.Gpu_ComputePassEncoder, x: u32, y: u32, z: u32) {
	wgpu.ComputePassEncoderDispatchWorkgroups(
		wgpu.ComputePassEncoder(pass),
		x,
		y,
		z,
	)
}

// --- Format Conversion Helpers ---

_gpu_to_wgpu_format :: proc(format: gpu.Gpu_Format) -> wgpu.TextureFormat {
	#partial switch format {
	case .BGRA8_Unorm:
		return .BGRA8Unorm
	case .RGBA8_Unorm:
		return .RGBA8Unorm
	case .R8_Unorm:
		return .R8Unorm
	case:
		return .Undefined
	}
}

_gpu_to_wgpu_buffer_usage :: proc(usage: gpu.Gpu_Buffer_Usage) -> wgpu.BufferUsageFlags {
	flags: wgpu.BufferUsageFlags
	u := u32(usage)
	if u & u32(gpu.Gpu_Buffer_Usage.Map_Read) != 0 { flags |= wgpu.BufferUsageFlags{.MapRead} }
	if u & u32(gpu.Gpu_Buffer_Usage.Map_Write) != 0 { flags |= wgpu.BufferUsageFlags{.MapWrite} }
	if u & u32(gpu.Gpu_Buffer_Usage.Copy_Src) != 0 { flags |= wgpu.BufferUsageFlags{.CopySrc} }
	if u & u32(gpu.Gpu_Buffer_Usage.Copy_Dst) != 0 { flags |= wgpu.BufferUsageFlags{.CopyDst} }
	if u & u32(gpu.Gpu_Buffer_Usage.Index) != 0 { flags |= wgpu.BufferUsageFlags{.Index} }
	if u & u32(gpu.Gpu_Buffer_Usage.Vertex) != 0 { flags |= wgpu.BufferUsageFlags{.Vertex} }
	if u & u32(gpu.Gpu_Buffer_Usage.Uniform) != 0 { flags |= wgpu.BufferUsageFlags{.Uniform} }
	if u & u32(gpu.Gpu_Buffer_Usage.Storage) != 0 { flags |= wgpu.BufferUsageFlags{.Storage} }
	if u & u32(gpu.Gpu_Buffer_Usage.Indirect) != 0 { flags |= wgpu.BufferUsageFlags{.Indirect} }
	return flags
}

_gpu_to_wgpu_texture_usage :: proc(usage: gpu.Gpu_Texture_Usage) -> wgpu.TextureUsageFlags {
	flags: wgpu.TextureUsageFlags
	u := u32(usage)
	if u & u32(gpu.Gpu_Texture_Usage.Copy_Src) != 0 { flags |= wgpu.TextureUsageFlags{.CopySrc} }
	if u & u32(gpu.Gpu_Texture_Usage.Copy_Dst) != 0 { flags |= wgpu.TextureUsageFlags{.CopyDst} }
	if u & u32(gpu.Gpu_Texture_Usage.Texture_Binding) != 0 { flags |= wgpu.TextureUsageFlags{.TextureBinding} }
	if u & u32(gpu.Gpu_Texture_Usage.Storage_Binding) != 0 { flags |= wgpu.TextureUsageFlags{.StorageBinding} }
	if u & u32(gpu.Gpu_Texture_Usage.Render_Attach) != 0 { flags |= wgpu.TextureUsageFlags{.RenderAttachment} }
	return flags
}

_gpu_to_wgpu_vertex_format :: proc(format: gpu.Gpu_Vertex_Format) -> wgpu.VertexFormat {
	#partial switch format {
	case .Float32:   return .Float32
	case .Float32x2: return .Float32x2
	case .Float32x3: return .Float32x3
	case .Float32x4: return .Float32x4
	case .Uint8x4:   return .Uint8x4
	case .Uint32:    return .Uint32
	case .Uint32x2:  return .Uint32x2
	case:            return .Float32
	}
}

_gpu_to_wgpu_topology :: proc(topology: gpu.Gpu_Primitive_Topology) -> wgpu.PrimitiveTopology {
	#partial switch topology {
	case .Point_List:     return .PointList
	case .Line_List:      return .LineList
	case .Line_Strip:     return .LineStrip
	case .Triangle_List:  return .TriangleList
	case .Triangle_Strip: return .TriangleStrip
	case:                  return .TriangleList
	}
}
