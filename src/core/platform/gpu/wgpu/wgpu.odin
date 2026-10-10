package wgpu_backend

import "base:runtime"
import "core:fmt"
import "vendor:sdl3"
import "vendor:wgpu"
import wgpu_sdl3_glue "vendor:wgpu/sdl3glue"
import contract "../../../render/contract"

// Wgpu_Surface wraps the native WGPU surface handle and state.
Wgpu_Surface :: struct {
	handle:     wgpu.Surface,
	adapter:    wgpu.Adapter,
	format:     wgpu.TextureFormat,
	width:      u32,
	height:     u32,
	configured: bool,
}

// Global vtable instance implementing all procedures of contract.Gpu_Backend_VTable
_wgpu_vtable: contract.Gpu_Backend_VTable = contract.Gpu_Backend_VTable{
	// Lifecycle
	create_instance         = _wgpu_create_instance,
	destroy_instance        = _wgpu_destroy_instance,
	request_device          = _wgpu_request_device,
	destroy_device          = _wgpu_destroy_device,
	poll_device             = _wgpu_poll_device,

	// Surface
	configure_surface       = _wgpu_configure_surface,
	get_surface_texture     = _wgpu_get_surface_texture,
	present_surface         = _wgpu_present_surface,
	get_preferred_format    = _wgpu_get_preferred_format,

	// Buffers
	create_buffer           = _wgpu_create_buffer,
	destroy_buffer          = _wgpu_destroy_buffer,
	write_buffer            = _wgpu_write_buffer,
	get_buffer_mapped_range = _wgpu_get_buffer_mapped_range,
	unmap_buffer            = _wgpu_unmap_buffer,

	// Textures
	create_texture          = _wgpu_create_texture,
	destroy_texture         = _wgpu_destroy_texture,
	create_texture_view     = _wgpu_create_texture_view,
	destroy_texture_view    = _wgpu_destroy_texture_view,
	write_texture           = _wgpu_write_texture,

	// Shaders
	shader_language         = .WGSL,
	create_shader_module    = _wgpu_create_shader_module,
	destroy_shader_module   = _wgpu_destroy_shader_module,

	// Pipelines
	create_render_pipeline            = _wgpu_create_render_pipeline,
	create_render_pipeline_with_depth = _wgpu_create_render_pipeline_with_depth,
	destroy_render_pipeline           = _wgpu_destroy_render_pipeline,

	// Bind groups
	create_bind_group_layout  = _wgpu_create_bind_group_layout,
	destroy_bind_group_layout = _wgpu_destroy_bind_group_layout,
	create_bind_group         = _wgpu_create_bind_group,
	destroy_bind_group        = _wgpu_destroy_bind_group,

	// Sampler
	create_sampler          = _wgpu_create_sampler,
	destroy_sampler         = _wgpu_destroy_sampler,

	// Command encoding
	create_command_encoder       = _wgpu_create_command_encoder,
	release_command_encoder      = _wgpu_release_command_encoder,
	begin_render_pass            = _wgpu_begin_render_pass,
	begin_render_pass_with_depth = _wgpu_begin_render_pass_with_depth,
	end_render_pass              = _wgpu_end_render_pass,
	finish_command_buffer   = _wgpu_finish_command_buffer,
	release_command_buffer  = _wgpu_release_command_buffer,
	submit                  = _wgpu_submit,
	wait_for_idle           = _wgpu_wait_for_idle,

	// Render pass commands
	render_set_pipeline       = _wgpu_render_set_pipeline,
	render_set_bind_group     = _wgpu_render_set_bind_group,
	render_set_vertex_buffer  = _wgpu_render_set_vertex_buffer,
	render_set_index_buffer   = _wgpu_render_set_index_buffer,
	render_set_viewport       = _wgpu_render_set_viewport,
	render_draw               = _wgpu_render_draw,
	render_draw_indexed       = _wgpu_render_draw_indexed,

	// Surface texture release
	release_surface_texture   = _wgpu_release_surface_texture,

	// Pipeline layout query
	pipeline_get_bind_group_layout = _wgpu_pipeline_get_bind_group_layout,

	// Compute pipelines
	create_compute_pipeline   = _wgpu_create_compute_pipeline,
	destroy_compute_pipeline  = _wgpu_destroy_compute_pipeline,

	// Compute command encoding
	begin_compute_pass            = _wgpu_begin_compute_pass,
	end_compute_pass              = _wgpu_end_compute_pass,
	compute_set_pipeline          = _wgpu_compute_set_pipeline,
	compute_set_bind_group        = _wgpu_compute_set_bind_group,
	compute_dispatch              = _wgpu_compute_dispatch,
	compute_get_bind_group_layout = _wgpu_compute_get_bind_group_layout,
}

create_wgpu_backend :: proc() -> ^contract.Gpu_Backend_VTable {
	return &_wgpu_vtable
}

wgpu_backend_vtable :: proc() -> ^contract.Gpu_Backend_VTable {
	return &_wgpu_vtable
}

create_surface :: proc(instance: rawptr, window: ^sdl3.Window) -> rawptr {
	inst := wgpu.Instance(instance)
	if inst == nil || window == nil do return nil

	handle := wgpu_sdl3_glue.GetSurface(inst, window)
	if handle == nil do return nil

	surf := new(Wgpu_Surface)
	surf.handle = handle
	return rawptr(surf)
}

destroy_surface :: proc(surf: rawptr) {
	if surf == nil do return
	s := (^Wgpu_Surface)(surf)
	if s.handle != nil {
		if s.configured {
			wgpu.SurfaceUnconfigure(s.handle)
		}
		wgpu.SurfaceRelease(s.handle)
		s.handle = nil
	}
	if s.adapter != nil {
		wgpu.AdapterRelease(s.adapter)
		s.adapter = nil
	}
	free(s)
}

// --- Lifecycle (1-5) ---

_wgpu_create_instance :: proc() -> rawptr {
	inst := wgpu.CreateInstance(nil)
	return rawptr(inst)
}

_wgpu_destroy_instance :: proc(instance: rawptr) {
	if instance != nil {
		wgpu.InstanceRelease(wgpu.Instance(instance))
	}
}

_Adapter_Result :: struct {
	adapter: wgpu.Adapter,
	status:  wgpu.RequestAdapterStatus,
	done:    bool,
}

_on_adapter :: proc "c" (
	status: wgpu.RequestAdapterStatus,
	adapter: wgpu.Adapter,
	message: wgpu.StringView,
	userdata1: rawptr,
	userdata2: rawptr,
) {
	res := (^ _Adapter_Result)(userdata1)
	if res != nil {
		res.adapter = adapter
		res.status = status
		res.done = true
	}
}

_Device_Result :: struct {
	device: wgpu.Device,
	status: wgpu.RequestDeviceStatus,
	done:   bool,
}

_on_device :: proc "c" (
	status: wgpu.RequestDeviceStatus,
	device: wgpu.Device,
	message: wgpu.StringView,
	userdata1: rawptr,
	userdata2: rawptr,
) {
	res := (^ _Device_Result)(userdata1)
	if res != nil {
		res.device = device
		res.status = status
		res.done = true
	}
}

_on_uncaptured_error :: proc "c" (
	device: ^wgpu.Device,
	type: wgpu.ErrorType,
	message: wgpu.StringView,
	userdata1: rawptr,
	userdata2: rawptr,
) {
	context = runtime.default_context()
	fmt.eprintfln("[wgpu] uncaptured error (%v): %s", type, message)
}

_on_device_lost :: proc "c" (
	device: ^wgpu.Device,
	reason: wgpu.DeviceLostReason,
	message: wgpu.StringView,
	userdata1: rawptr,
	userdata2: rawptr,
) {
	context = runtime.default_context()
	fmt.eprintfln("[wgpu] device lost (%v): %s", reason, message)
}

_wgpu_request_device :: proc(instance: rawptr, surface: rawptr) -> (device: contract.Gpu_Device, queue: contract.Gpu_Queue) {
	inst := wgpu.Instance(instance)
	if inst == nil {
		return contract.Gpu_Device(nil), contract.Gpu_Queue(nil)
	}

	surf_handle: wgpu.Surface
	if surface != nil {
		surf_handle = ((^Wgpu_Surface)(surface)).handle
	}

	options := wgpu.RequestAdapterOptions{
		powerPreference   = .HighPerformance,
		compatibleSurface = surf_handle,
	}

	adapter_res: _Adapter_Result
	_ = wgpu.InstanceRequestAdapter(
		inst,
		&options,
		wgpu.RequestAdapterCallbackInfo{
			mode      = .AllowProcessEvents,
			callback  = _on_adapter,
			userdata1 = &adapter_res,
		},
	)
	wgpu.InstanceProcessEvents(inst)

	if adapter_res.status != .Success || adapter_res.adapter == nil {
		return contract.Gpu_Device(nil), contract.Gpu_Queue(nil)
	}
	adapter := adapter_res.adapter
	defer wgpu.AdapterRelease(adapter)

	dev_desc := wgpu.DeviceDescriptor{
		uncapturedErrorCallbackInfo = {
			callback = _on_uncaptured_error,
		},
		deviceLostCallbackInfo = {
			mode     = .WaitAnyOnly,
			callback = _on_device_lost,
		},
	}

	device_res: _Device_Result
	_ = wgpu.AdapterRequestDevice(
		adapter,
		&dev_desc,
		wgpu.RequestDeviceCallbackInfo{
			mode      = .AllowProcessEvents,
			callback  = _on_device,
			userdata1 = &device_res,
		},
	)
	wgpu.InstanceProcessEvents(inst)

	if device_res.status != .Success || device_res.device == nil {
		return contract.Gpu_Device(nil), contract.Gpu_Queue(nil)
	}

	if surface != nil {
		surf := (^Wgpu_Surface)(surface)
		if surf.adapter != nil {
			wgpu.AdapterRelease(surf.adapter)
		}
		wgpu.AdapterAddRef(adapter)
		surf.adapter = adapter
	}

	dev := device_res.device
	q := wgpu.DeviceGetQueue(dev)

	return contract.Gpu_Device(dev), contract.Gpu_Queue(q)
}

_wgpu_destroy_device :: proc(device: contract.Gpu_Device) {
	dev := wgpu.Device(rawptr(device))
	if dev != nil {
		wgpu.DeviceDestroy(dev)
		wgpu.DeviceRelease(dev)
	}
}

_wgpu_poll_device :: proc(device: contract.Gpu_Device, wait: bool) -> bool {
	dev := wgpu.Device(rawptr(device))
	if dev == nil do return false
	return bool(wgpu.DevicePoll(dev, b32(wait), nil))
}

// --- Surface (6-9) ---

_wgpu_configure_surface :: proc(surface: rawptr, device: contract.Gpu_Device, format: contract.Gpu_Format, width, height: u32) {
	surf := (^Wgpu_Surface)(surface)
	if surf == nil || surf.handle == nil do return
	dev := wgpu.Device(rawptr(device))
	if dev == nil do return

	wgpu_fmt := _contract_to_wgpu_format(format)
	if surf.adapter != nil {
		caps, status := wgpu.SurfaceGetCapabilities(surf.handle, surf.adapter)
		if status == .Success {
			defer wgpu.SurfaceCapabilitiesFreeMembers(caps)
			preferred_target := wgpu.TextureFormat.BGRA8Unorm when ODIN_OS == .Darwin else wgpu.TextureFormat.RGBA8Unorm
			formats := caps.formats[:caps.formatCount]
			found_req := false
			if wgpu_fmt != .Undefined {
				for f in formats {
					if f == wgpu_fmt {
						found_req = true
						break
					}
				}
			}
			if !found_req {
				wgpu_fmt = .Undefined
				for f in formats {
					if f == preferred_target {
						wgpu_fmt = f
						break
					}
				}
				if wgpu_fmt == .Undefined && len(formats) > 0 {
					wgpu_fmt = formats[0]
				}
			}
		}
	}

	if wgpu_fmt == .Undefined {
		when ODIN_OS == .Darwin {
			wgpu_fmt = .BGRA8Unorm
		} else {
			wgpu_fmt = .RGBA8Unorm
		}
	}

	w := max(u32(1), width)
	h := max(u32(1), height)

	config := wgpu.SurfaceConfiguration{
		device      = dev,
		format      = wgpu_fmt,
		usage       = { .RenderAttachment },
		width       = w,
		height      = h,
		alphaMode   = .Opaque,
		presentMode = .Fifo,
	}
	wgpu.SurfaceConfigure(surf.handle, &config)
	surf.format = wgpu_fmt
	surf.width = w
	surf.height = h
	surf.configured = true
}

_wgpu_get_surface_texture :: proc(surface: rawptr) -> (texture: contract.Gpu_Texture, view: contract.Gpu_TextureView, format: contract.Gpu_Format) {
	surf := (^Wgpu_Surface)(surface)
	if surf == nil || surf.handle == nil do return contract.Gpu_Texture(nil), contract.Gpu_TextureView(nil), .Undefined

	st := wgpu.SurfaceGetCurrentTexture(surf.handle)
	if st.status != .SuccessOptimal && st.status != .SuccessSuboptimal {
		return contract.Gpu_Texture(nil), contract.Gpu_TextureView(nil), .Undefined
	}

	tex := st.texture
	if tex == nil {
		return contract.Gpu_Texture(nil), contract.Gpu_TextureView(nil), .Undefined
	}

	tv := wgpu.TextureCreateView(tex, nil)
	if tv == nil {
		wgpu.TextureRelease(tex)
		return contract.Gpu_Texture(nil), contract.Gpu_TextureView(nil), .Undefined
	}

	return contract.Gpu_Texture(tex), contract.Gpu_TextureView(tv), _wgpu_to_contract_format(surf.format)
}

_wgpu_present_surface :: proc(surface: rawptr) -> bool {
	surf := (^Wgpu_Surface)(surface)
	if surf == nil || surf.handle == nil do return false
	status := wgpu.SurfacePresent(surf.handle)
	return status == .Success
}

_wgpu_get_preferred_format :: proc(surface: rawptr, device: contract.Gpu_Device) -> contract.Gpu_Format {
	surf := (^Wgpu_Surface)(surface)
	if surf != nil && surf.handle != nil && surf.adapter != nil {
		caps, status := wgpu.SurfaceGetCapabilities(surf.handle, surf.adapter)
		if status == .Success {
			defer wgpu.SurfaceCapabilitiesFreeMembers(caps)
			preferred_target := wgpu.TextureFormat.BGRA8Unorm when ODIN_OS == .Darwin else wgpu.TextureFormat.RGBA8Unorm
			formats := caps.formats[:caps.formatCount]
			for f in formats {
				if f == preferred_target {
					return _wgpu_to_contract_format(f)
				}
			}
			if len(formats) > 0 {
				return _wgpu_to_contract_format(formats[0])
			}
		}
	}
	when ODIN_OS == .Darwin {
		return .BGRA8_Unorm
	} else {
		return .RGBA8_Unorm
	}
}

// --- Buffers (10-14) ---

_wgpu_create_buffer :: proc(device: contract.Gpu_Device, size: u64, usage: contract.Gpu_Buffer_Usage, mapped_at_creation: bool) -> contract.Gpu_Buffer {
	dev := wgpu.Device(rawptr(device))
	if dev == nil do return contract.Gpu_Buffer(nil)

	buf_size := max(u64(4), (size + 3) & ~u64(3))
	desc := wgpu.BufferDescriptor{
		usage            = _contract_to_wgpu_buffer_usage(usage),
		size             = buf_size,
		mappedAtCreation = b32(mapped_at_creation),
	}
	buf := wgpu.DeviceCreateBuffer(dev, &desc)
	return contract.Gpu_Buffer(buf)
}

_wgpu_destroy_buffer :: proc(buffer: contract.Gpu_Buffer) {
	buf := wgpu.Buffer(rawptr(buffer))
	if buf != nil {
		wgpu.BufferDestroy(buf)
		wgpu.BufferRelease(buf)
	}
}

_wgpu_write_buffer :: proc(queue: contract.Gpu_Queue, buffer: contract.Gpu_Buffer, offset: u64, data: rawptr, size: u64) {
	q := wgpu.Queue(rawptr(queue))
	b := wgpu.Buffer(rawptr(buffer))
	if q != nil && b != nil && data != nil && size > 0 {
		wgpu.QueueWriteBuffer(q, b, offset, data, uint(size))
	}
}

_wgpu_get_buffer_mapped_range :: proc(buffer: contract.Gpu_Buffer, offset: u64, size: u64) -> []u8 {
	b := wgpu.Buffer(rawptr(buffer))
	if b == nil do return nil
	ptr := wgpu.RawBufferGetMappedRange(b, uint(offset), uint(size))
	if ptr == nil do return nil
	return ([^]u8)(ptr)[:size]
}

_wgpu_unmap_buffer :: proc(buffer: contract.Gpu_Buffer) {
	b := wgpu.Buffer(rawptr(buffer))
	if b != nil {
		wgpu.BufferUnmap(b)
	}
}

// --- Textures (15-19) ---

_wgpu_create_texture :: proc(device: contract.Gpu_Device, width, height: u32, format: contract.Gpu_Format, usage: contract.Gpu_Texture_Usage) -> contract.Gpu_Texture {
	dev := wgpu.Device(rawptr(device))
	if dev == nil do return contract.Gpu_Texture(nil)

	w := max(u32(1), width)
	h := max(u32(1), height)

	desc := wgpu.TextureDescriptor{
		usage         = _contract_to_wgpu_texture_usage(usage),
		dimension     = ._2D,
		size          = wgpu.Extent3D{ width = w, height = h, depthOrArrayLayers = 1 },
		format        = _contract_to_wgpu_format(format),
		mipLevelCount = 1,
		sampleCount   = 1,
	}
	tex := wgpu.DeviceCreateTexture(dev, &desc)
	return contract.Gpu_Texture(tex)
}

_wgpu_destroy_texture :: proc(texture: contract.Gpu_Texture) {
	tex := wgpu.Texture(rawptr(texture))
	if tex != nil {
		wgpu.TextureDestroy(tex)
		wgpu.TextureRelease(tex)
	}
}

_wgpu_create_texture_view :: proc(texture: contract.Gpu_Texture) -> contract.Gpu_TextureView {
	tex := wgpu.Texture(rawptr(texture))
	if tex == nil do return contract.Gpu_TextureView(nil)
	view := wgpu.TextureCreateView(tex, nil)
	return contract.Gpu_TextureView(view)
}

_wgpu_destroy_texture_view :: proc(view: contract.Gpu_TextureView) {
	tv := wgpu.TextureView(rawptr(view))
	if tv != nil {
		wgpu.TextureViewRelease(tv)
	}
}

_wgpu_write_texture :: proc(queue: contract.Gpu_Queue, texture: contract.Gpu_Texture, data: []u8, width, height: u32) {
	q := wgpu.Queue(rawptr(queue))
	tex := wgpu.Texture(rawptr(texture))
	if q == nil || tex == nil || len(data) == 0 do return

	w := max(u32(1), width)
	h := max(u32(1), height)

	bytes_per_row := w * 4
	if h > 0 && u32(len(data)) >= h {
		bytes_per_row = u32(len(data)) / h
	}

	dst := wgpu.TexelCopyTextureInfo{
		texture  = tex,
		mipLevel = 0,
		origin   = { x = 0, y = 0, z = 0 },
		aspect   = .All,
	}
	data_layout := wgpu.TexelCopyBufferLayout{
		offset       = 0,
		bytesPerRow  = bytes_per_row,
		rowsPerImage = h,
	}
	write_size := wgpu.Extent3D{
		width              = w,
		height             = h,
		depthOrArrayLayers = 1,
	}
	wgpu.QueueWriteTexture(q, &dst, raw_data(data), uint(len(data)), &data_layout, &write_size)
}

// --- Shaders (20-21) ---

_wgpu_create_shader_module :: proc(device: contract.Gpu_Device, source: string) -> contract.Gpu_ShaderModule {
	dev := wgpu.Device(rawptr(device))
	if dev == nil do return contract.Gpu_ShaderModule(nil)

	wgsl_source := wgpu.ShaderSourceWGSL{
		chain = wgpu.ChainedStruct{
			sType = .ShaderSourceWGSL,
		},
		code = source,
	}
	desc := wgpu.ShaderModuleDescriptor{
		nextInChain = (^wgpu.ChainedStruct)(&wgsl_source),
	}
	module := wgpu.DeviceCreateShaderModule(dev, &desc)
	return contract.Gpu_ShaderModule(module)
}

_wgpu_destroy_shader_module :: proc(module: contract.Gpu_ShaderModule) {
	mod := wgpu.ShaderModule(rawptr(module))
	if mod != nil {
		wgpu.ShaderModuleRelease(mod)
	}
}

// --- Pipelines (22-23) ---

_wgpu_create_render_pipeline :: proc(
	device: contract.Gpu_Device,
	vertex_shader: contract.Gpu_ShaderModule,
	vertex_entry: string,
	fragment_shader: contract.Gpu_ShaderModule,
	fragment_entry: string,
	vertex_layouts: []contract.Gpu_Vertex_Layout,
	format: contract.Gpu_Format,
	blend: contract.Gpu_Blend_Mode,
	topology: contract.Gpu_Primitive_Topology,
) -> contract.Gpu_RenderPipeline {
	dev := wgpu.Device(rawptr(device))
	if dev == nil do return contract.Gpu_RenderPipeline(nil)

	wgpu_layouts := make([]wgpu.VertexBufferLayout, len(vertex_layouts), context.temp_allocator)
	for vl, i in vertex_layouts {
		attrs := make([]wgpu.VertexAttribute, len(vl.attributes), context.temp_allocator)
		for a, j in vl.attributes {
			attrs[j] = wgpu.VertexAttribute{
				format         = _contract_to_wgpu_vertex_format(a.format),
				offset         = a.offset,
				shaderLocation = a.shader_location,
			}
		}
		wgpu_layouts[i] = wgpu.VertexBufferLayout{
			stepMode       = _contract_to_wgpu_step_mode(vl.step_mode),
			arrayStride    = vl.array_stride,
			attributeCount = uint(len(attrs)),
			attributes     = raw_data(attrs),
		}
	}

	vertex_state := wgpu.VertexState{
		module      = wgpu.ShaderModule(rawptr(vertex_shader)),
		entryPoint  = vertex_entry,
		bufferCount = uint(len(wgpu_layouts)),
		buffers     = raw_data(wgpu_layouts),
	}

	target_fmt := _contract_to_wgpu_format(format)
	if target_fmt == .Undefined {
		when ODIN_OS == .Darwin {
			target_fmt = .BGRA8Unorm
		} else {
			target_fmt = .RGBA8Unorm
		}
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
		format    = target_fmt,
		blend     = &blend_state if blend == .Alpha_Blend else nil,
		writeMask = { .Red, .Green, .Blue, .Alpha },
	}

	fragment_state := wgpu.FragmentState{
		module      = wgpu.ShaderModule(rawptr(fragment_shader)),
		entryPoint  = fragment_entry,
		targetCount = 1,
		targets     = &target,
	}

	desc := wgpu.RenderPipelineDescriptor{
		vertex      = vertex_state,
		primitive   = wgpu.PrimitiveState{
			topology  = _contract_to_wgpu_topology(topology),
			frontFace = .CCW,
			cullMode  = .None,
		},
		multisample = wgpu.MultisampleState{
			count                  = 1,
			mask                   = ~u32(0),
			alphaToCoverageEnabled = false,
		},
		fragment    = &fragment_state if fragment_shader != nil else nil,
	}

	pipeline := wgpu.DeviceCreateRenderPipeline(dev, &desc)
	return contract.Gpu_RenderPipeline(pipeline)
}

_wgpu_create_render_pipeline_with_depth :: proc(
	device: contract.Gpu_Device,
	vertex_shader: contract.Gpu_ShaderModule,
	vertex_entry: string,
	fragment_shader: contract.Gpu_ShaderModule,
	fragment_entry: string,
	vertex_layouts: []contract.Gpu_Vertex_Layout,
	format: contract.Gpu_Format,
	depth_format: contract.Gpu_Format,
	blend: contract.Gpu_Blend_Mode,
	topology: contract.Gpu_Primitive_Topology,
) -> contract.Gpu_RenderPipeline {
	dev := wgpu.Device(rawptr(device))
	if dev == nil do return contract.Gpu_RenderPipeline(nil)

	wgpu_layouts := make([]wgpu.VertexBufferLayout, len(vertex_layouts), context.temp_allocator)
	for vl, i in vertex_layouts {
		attrs := make([]wgpu.VertexAttribute, len(vl.attributes), context.temp_allocator)
		for a, j in vl.attributes {
			attrs[j] = wgpu.VertexAttribute{
				format         = _contract_to_wgpu_vertex_format(a.format),
				offset         = a.offset,
				shaderLocation = a.shader_location,
			}
		}
		wgpu_layouts[i] = wgpu.VertexBufferLayout{
			stepMode       = _contract_to_wgpu_step_mode(vl.step_mode),
			arrayStride    = vl.array_stride,
			attributeCount = uint(len(attrs)),
			attributes     = raw_data(attrs),
		}
	}

	vertex_state := wgpu.VertexState{
		module      = wgpu.ShaderModule(rawptr(vertex_shader)),
		entryPoint  = vertex_entry,
		bufferCount = uint(len(wgpu_layouts)),
		buffers     = raw_data(wgpu_layouts),
	}

	target_fmt := _contract_to_wgpu_format(format)
	if target_fmt == .Undefined {
		when ODIN_OS == .Darwin {
			target_fmt = .BGRA8Unorm
		} else {
			target_fmt = .RGBA8Unorm
		}
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
		format    = target_fmt,
		blend     = &blend_state if blend == .Alpha_Blend else nil,
		writeMask = { .Red, .Green, .Blue, .Alpha },
	}

	fragment_state := wgpu.FragmentState{
		module      = wgpu.ShaderModule(rawptr(fragment_shader)),
		entryPoint  = fragment_entry,
		targetCount = 1,
		targets     = &target,
	}

	depth_fmt := _contract_to_wgpu_format(depth_format)
	depth_stencil_state: wgpu.DepthStencilState
	depth_stencil_ptr: ^wgpu.DepthStencilState = nil
	if depth_fmt != .Undefined {
		depth_stencil_state = wgpu.DepthStencilState{
			format            = depth_fmt,
			depthWriteEnabled = .True,
			depthCompare      = .Less,
		}
		depth_stencil_ptr = &depth_stencil_state
	}

	desc := wgpu.RenderPipelineDescriptor{
		vertex       = vertex_state,
		primitive    = wgpu.PrimitiveState{
			topology  = _contract_to_wgpu_topology(topology),
			frontFace = .CCW,
			cullMode  = .None,
		},
		depthStencil = depth_stencil_ptr,
		multisample  = wgpu.MultisampleState{
			count                  = 1,
			mask                   = ~u32(0),
			alphaToCoverageEnabled = false,
		},
		fragment     = &fragment_state if fragment_shader != nil else nil,
	}

	pipeline := wgpu.DeviceCreateRenderPipeline(dev, &desc)
	return contract.Gpu_RenderPipeline(pipeline)
}

_wgpu_destroy_render_pipeline :: proc(pipeline: contract.Gpu_RenderPipeline) {
	p := wgpu.RenderPipeline(rawptr(pipeline))
	if p != nil {
		wgpu.RenderPipelineRelease(p)
	}
}

// --- Bind Groups (24-27) ---

_wgpu_create_bind_group_layout :: proc(device: contract.Gpu_Device, entries: []contract.Gpu_Bind_Layout_Entry) -> contract.Gpu_BindGroupLayout {
	dev := wgpu.Device(rawptr(device))
	if dev == nil do return contract.Gpu_BindGroupLayout(nil)

	w_entries := make([]wgpu.BindGroupLayoutEntry, len(entries), context.temp_allocator)
	for e, i in entries {
		vis: wgpu.ShaderStageFlags
		if (e.visibility & 1) != 0 do vis += { .Vertex }
		if (e.visibility & 2) != 0 do vis += { .Fragment }
		if (e.visibility & 4) != 0 do vis += { .Compute }

		w_entries[i] = wgpu.BindGroupLayoutEntry{
			binding    = e.binding,
			visibility = vis,
		}

		switch e.binding_type {
		case .Uniform_Buffer:
			w_entries[i].buffer = wgpu.BufferBindingLayout{
				type             = .Uniform,
				hasDynamicOffset = false,
				minBindingSize   = 0,
			}
		case .Storage_Buffer:
			w_entries[i].buffer = wgpu.BufferBindingLayout{
				type             = .Storage,
				hasDynamicOffset = false,
				minBindingSize   = 0,
			}
		case .Sampler:
			w_entries[i].sampler = wgpu.SamplerBindingLayout{
				type = .Filtering,
			}
		case .Sampled_Texture:
			w_entries[i].texture = wgpu.TextureBindingLayout{
				sampleType    = .Float,
				viewDimension = ._2D,
				multisampled  = false,
			}
		case .Storage_Texture:
			w_entries[i].storageTexture = wgpu.StorageTextureBindingLayout{
				access        = .WriteOnly,
				format        = .RGBA8Unorm,
				viewDimension = ._2D,
			}
		}
	}

	desc := wgpu.BindGroupLayoutDescriptor{
		entryCount = uint(len(w_entries)),
		entries    = raw_data(w_entries),
	}
	layout := wgpu.DeviceCreateBindGroupLayout(dev, &desc)
	return contract.Gpu_BindGroupLayout(layout)
}

_wgpu_destroy_bind_group_layout :: proc(layout: contract.Gpu_BindGroupLayout) {
	l := wgpu.BindGroupLayout(rawptr(layout))
	if l != nil {
		wgpu.BindGroupLayoutRelease(l)
	}
}

_wgpu_create_bind_group :: proc(device: contract.Gpu_Device, layout: contract.Gpu_BindGroupLayout, entries: []contract.Gpu_Bind_Entry) -> contract.Gpu_BindGroup {
	dev := wgpu.Device(rawptr(device))
	l := wgpu.BindGroupLayout(rawptr(layout))
	if dev == nil || l == nil do return contract.Gpu_BindGroup(nil)

	w_entries := make([]wgpu.BindGroupEntry, len(entries), context.temp_allocator)
	for e, i in entries {
		switch e.entry_type {
		case .Buffer:
			w_entries[i] = wgpu.BindGroupEntry{
				binding = e.binding,
				buffer  = wgpu.Buffer(rawptr(e.buffer)),
				offset  = e.offset,
				size    = e.size if e.size > 0 else wgpu.WHOLE_SIZE,
			}
		case .Texture_View:
			w_entries[i] = wgpu.BindGroupEntry{
				binding     = e.binding,
				textureView = wgpu.TextureView(rawptr(e.view)),
			}
		case .Sampler:
			w_entries[i] = wgpu.BindGroupEntry{
				binding = e.binding,
				sampler = wgpu.Sampler(rawptr(e.sampler)),
			}
		}
	}

	desc := wgpu.BindGroupDescriptor{
		layout     = l,
		entryCount = uint(len(w_entries)),
		entries    = raw_data(w_entries),
	}
	bg := wgpu.DeviceCreateBindGroup(dev, &desc)
	return contract.Gpu_BindGroup(bg)
}

_wgpu_destroy_bind_group :: proc(group: contract.Gpu_BindGroup) {
	g := wgpu.BindGroup(rawptr(group))
	if g != nil {
		wgpu.BindGroupRelease(g)
	}
}

// --- Sampler (28-29) ---

_wgpu_create_sampler :: proc(device: contract.Gpu_Device) -> contract.Gpu_Sampler {
	dev := wgpu.Device(rawptr(device))
	if dev == nil do return contract.Gpu_Sampler(nil)

	desc := wgpu.SamplerDescriptor{
		addressModeU  = .ClampToEdge,
		addressModeV  = .ClampToEdge,
		addressModeW  = .ClampToEdge,
		magFilter     = .Linear,
		minFilter     = .Linear,
		mipmapFilter  = .Nearest,
		lodMinClamp   = 0.0,
		lodMaxClamp   = 32.0,
		maxAnisotropy = 1,
	}
	s := wgpu.DeviceCreateSampler(dev, &desc)
	return contract.Gpu_Sampler(s)
}

_wgpu_destroy_sampler :: proc(sampler: contract.Gpu_Sampler) {
	s := wgpu.Sampler(rawptr(sampler))
	if s != nil {
		wgpu.SamplerRelease(s)
	}
}

// --- Command Encoding (30-37) ---

_wgpu_create_command_encoder :: proc(device: contract.Gpu_Device) -> contract.Gpu_CommandEncoder {
	dev := wgpu.Device(rawptr(device))
	if dev == nil do return contract.Gpu_CommandEncoder(nil)
	enc := wgpu.DeviceCreateCommandEncoder(dev, nil)
	return contract.Gpu_CommandEncoder(enc)
}

_wgpu_release_command_encoder :: proc(encoder: contract.Gpu_CommandEncoder) {
	enc := wgpu.CommandEncoder(rawptr(encoder))
	if enc != nil {
		wgpu.CommandEncoderRelease(enc)
	}
}

_wgpu_begin_render_pass :: proc(
	encoder: contract.Gpu_CommandEncoder,
	color_view: contract.Gpu_TextureView,
	clear_color: [4]f64,
	load_op: contract.Gpu_Load_Op,
) -> contract.Gpu_RenderPassEncoder {
	enc := wgpu.CommandEncoder(rawptr(encoder))
	tv := wgpu.TextureView(rawptr(color_view))
	if enc == nil || tv == nil do return contract.Gpu_RenderPassEncoder(nil)

	wgpu_load_op: wgpu.LoadOp = .Clear
	switch load_op {
	case .Load:      wgpu_load_op = .Load
	case .Clear:     wgpu_load_op = .Clear
	case .Undefined: wgpu_load_op = .Clear
	}

	color_attachment := wgpu.RenderPassColorAttachment{
		view       = tv,
		loadOp     = wgpu_load_op,
		storeOp    = .Store,
		clearValue = wgpu.Color{ clear_color[0], clear_color[1], clear_color[2], clear_color[3] },
		depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
	}

	desc := wgpu.RenderPassDescriptor{
		colorAttachmentCount = 1,
		colorAttachments     = &color_attachment,
	}
	pass := wgpu.CommandEncoderBeginRenderPass(enc, &desc)
	return contract.Gpu_RenderPassEncoder(pass)
}

_wgpu_begin_render_pass_with_depth :: proc(
	encoder: contract.Gpu_CommandEncoder,
	color_view: contract.Gpu_TextureView,
	clear_color: [4]f64,
	load_op: contract.Gpu_Load_Op,
	depth_view: contract.Gpu_TextureView,
	depth_clear: f32,
	depth_load_op: contract.Gpu_Load_Op,
) -> contract.Gpu_RenderPassEncoder {
	enc := wgpu.CommandEncoder(rawptr(encoder))
	tv := wgpu.TextureView(rawptr(color_view))
	dv := wgpu.TextureView(rawptr(depth_view))
	if enc == nil || tv == nil do return contract.Gpu_RenderPassEncoder(nil)

	wgpu_load_op: wgpu.LoadOp = .Clear
	switch load_op {
	case .Load:      wgpu_load_op = .Load
	case .Clear:     wgpu_load_op = .Clear
	case .Undefined: wgpu_load_op = .Clear
	}

	color_attachment := wgpu.RenderPassColorAttachment{
		view       = tv,
		loadOp     = wgpu_load_op,
		storeOp    = .Store,
		clearValue = wgpu.Color{ clear_color[0], clear_color[1], clear_color[2], clear_color[3] },
		depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
	}

	wgpu_depth_load_op: wgpu.LoadOp = .Clear
	switch depth_load_op {
	case .Load:      wgpu_depth_load_op = .Load
	case .Clear:     wgpu_depth_load_op = .Clear
	case .Undefined: wgpu_depth_load_op = .Clear
	}

	depth_attachment: wgpu.RenderPassDepthStencilAttachment
	depth_attachment_ptr: ^wgpu.RenderPassDepthStencilAttachment = nil
	if dv != nil {
		depth_attachment = wgpu.RenderPassDepthStencilAttachment{
			view            = dv,
			depthLoadOp     = wgpu_depth_load_op,
			depthStoreOp    = .Store,
			depthClearValue = depth_clear,
			depthReadOnly   = false,
		}
		depth_attachment_ptr = &depth_attachment
	}

	desc := wgpu.RenderPassDescriptor{
		colorAttachmentCount   = 1,
		colorAttachments       = &color_attachment,
		depthStencilAttachment = depth_attachment_ptr,
	}
	pass := wgpu.CommandEncoderBeginRenderPass(enc, &desc)
	return contract.Gpu_RenderPassEncoder(pass)
}

_wgpu_end_render_pass :: proc(pass: contract.Gpu_RenderPassEncoder) {
	p := wgpu.RenderPassEncoder(rawptr(pass))
	if p != nil {
		wgpu.RenderPassEncoderEnd(p)
		wgpu.RenderPassEncoderRelease(p)
	}
}

_wgpu_finish_command_buffer :: proc(encoder: contract.Gpu_CommandEncoder) -> rawptr {
	enc := wgpu.CommandEncoder(rawptr(encoder))
	if enc == nil do return nil
	cb := wgpu.CommandEncoderFinish(enc, nil)
	return rawptr(cb)
}

_wgpu_release_command_buffer :: proc(command_buffer: rawptr) {
	cb := wgpu.CommandBuffer(command_buffer)
	if cb != nil {
		wgpu.CommandBufferRelease(cb)
	}
}

_wgpu_submit :: proc(queue: contract.Gpu_Queue, command_buffer: rawptr) -> bool {
	q := wgpu.Queue(rawptr(queue))
	cb := wgpu.CommandBuffer(command_buffer)
	if q == nil || cb == nil do return false
	wgpu.RawQueueSubmit(q, 1, &cb)
	return true
}

_wgpu_wait_for_idle :: proc(device: contract.Gpu_Device) -> bool {
	dev := wgpu.Device(rawptr(device))
	if dev == nil do return false
	return bool(wgpu.DevicePoll(dev, true, nil))
}

// --- Render Pass Commands (38-42) ---

_wgpu_render_set_pipeline :: proc(pass: contract.Gpu_RenderPassEncoder, pipeline: contract.Gpu_RenderPipeline) {
	p := wgpu.RenderPassEncoder(rawptr(pass))
	pipe := wgpu.RenderPipeline(rawptr(pipeline))
	if p != nil && pipe != nil {
		wgpu.RenderPassEncoderSetPipeline(p, pipe)
	}
}

_wgpu_render_set_bind_group :: proc(pass: contract.Gpu_RenderPassEncoder, index: u32, group: contract.Gpu_BindGroup) {
	p := wgpu.RenderPassEncoder(rawptr(pass))
	bg := wgpu.BindGroup(rawptr(group))
	if p != nil && bg != nil {
		wgpu.RenderPassEncoderSetBindGroup(p, index, bg)
	}
}

_wgpu_render_set_vertex_buffer :: proc(pass: contract.Gpu_RenderPassEncoder, slot: u32, buffer: contract.Gpu_Buffer, offset: u64) {
	p := wgpu.RenderPassEncoder(rawptr(pass))
	b := wgpu.Buffer(rawptr(buffer))
	if p != nil && b != nil {
		size: u64 = wgpu.WHOLE_SIZE
		total := wgpu.BufferGetSize(b)
		if total > offset {
			size = total - offset
		}
		wgpu.RenderPassEncoderSetVertexBuffer(p, slot, b, offset, size)
	}
}

_wgpu_render_set_index_buffer :: proc(pass: contract.Gpu_RenderPassEncoder, buffer: contract.Gpu_Buffer, offset: u64, size: u64) {
	p := wgpu.RenderPassEncoder(rawptr(pass))
	buf := wgpu.Buffer(rawptr(buffer))
	if p != nil && buf != nil {
		sz := size if size > 0 else wgpu.WHOLE_SIZE
		wgpu.RenderPassEncoderSetIndexBuffer(p, buf, .Uint32, offset, sz)
	}
}

_wgpu_render_set_viewport :: proc(pass: contract.Gpu_RenderPassEncoder, x, y, width, height: f32, min_depth, max_depth: f32) {
	p := wgpu.RenderPassEncoder(rawptr(pass))
	if p != nil {
		wgpu.RenderPassEncoderSetViewport(p, x, y, width, height, min_depth, max_depth)
	}
}

_wgpu_render_draw :: proc(pass: contract.Gpu_RenderPassEncoder, vertex_count: u32, instance_count: u32) {
	p := wgpu.RenderPassEncoder(rawptr(pass))
	if p != nil {
		wgpu.RenderPassEncoderDraw(p, vertex_count, instance_count, 0, 0)
	}
}

_wgpu_render_draw_indexed :: proc(pass: contract.Gpu_RenderPassEncoder, index_count: u32, instance_count: u32) {
	p := wgpu.RenderPassEncoder(rawptr(pass))
	if p != nil {
		wgpu.RenderPassEncoderDrawIndexed(p, index_count, instance_count, 0, 0, 0)
	}
}

// --- Surface Texture Release (43) ---

_wgpu_release_surface_texture :: proc(texture: contract.Gpu_Texture, view: contract.Gpu_TextureView) {
	if view != nil {
		wgpu.TextureViewRelease(wgpu.TextureView(rawptr(view)))
	}
	if texture != nil {
		wgpu.TextureRelease(wgpu.Texture(rawptr(texture)))
	}
}

// --- Pipeline Layout Query (44) ---

_wgpu_pipeline_get_bind_group_layout :: proc(pipeline: contract.Gpu_RenderPipeline, index: u32) -> contract.Gpu_BindGroupLayout {
	p := wgpu.RenderPipeline(rawptr(pipeline))
	if p == nil do return contract.Gpu_BindGroupLayout(nil)
	layout := wgpu.RenderPipelineGetBindGroupLayout(p, index)
	return contract.Gpu_BindGroupLayout(layout)
}

// --- Compute Pipelines (45-46) ---

_wgpu_create_compute_pipeline :: proc(device: contract.Gpu_Device, shader: contract.Gpu_ShaderModule, entry: string) -> contract.Gpu_ComputePipeline {
	dev := wgpu.Device(rawptr(device))
	if dev == nil do return contract.Gpu_ComputePipeline(nil)

	desc := wgpu.ComputePipelineDescriptor{
		compute = {
			module     = wgpu.ShaderModule(rawptr(shader)),
			entryPoint = entry,
		},
	}
	pipe := wgpu.DeviceCreateComputePipeline(dev, &desc)
	return contract.Gpu_ComputePipeline(pipe)
}

_wgpu_destroy_compute_pipeline :: proc(pipeline: contract.Gpu_ComputePipeline) {
	p := wgpu.ComputePipeline(rawptr(pipeline))
	if p != nil {
		wgpu.ComputePipelineRelease(p)
	}
}

// --- Compute Command Encoding (47-51) ---

_wgpu_begin_compute_pass :: proc(encoder: contract.Gpu_CommandEncoder) -> contract.Gpu_ComputePassEncoder {
	enc := wgpu.CommandEncoder(rawptr(encoder))
	if enc == nil do return contract.Gpu_ComputePassEncoder(nil)
	pass := wgpu.CommandEncoderBeginComputePass(enc, nil)
	return contract.Gpu_ComputePassEncoder(pass)
}

_wgpu_end_compute_pass :: proc(pass: contract.Gpu_ComputePassEncoder) {
	p := wgpu.ComputePassEncoder(rawptr(pass))
	if p != nil {
		wgpu.ComputePassEncoderEnd(p)
		wgpu.ComputePassEncoderRelease(p)
	}
}

_wgpu_compute_set_pipeline :: proc(pass: contract.Gpu_ComputePassEncoder, pipeline: contract.Gpu_ComputePipeline) {
	p := wgpu.ComputePassEncoder(rawptr(pass))
	pipe := wgpu.ComputePipeline(rawptr(pipeline))
	if p != nil && pipe != nil {
		wgpu.ComputePassEncoderSetPipeline(p, pipe)
	}
}

_wgpu_compute_set_bind_group :: proc(pass: contract.Gpu_ComputePassEncoder, index: u32, group: contract.Gpu_BindGroup) {
	p := wgpu.ComputePassEncoder(rawptr(pass))
	bg := wgpu.BindGroup(rawptr(group))
	if p != nil && bg != nil {
		wgpu.ComputePassEncoderSetBindGroup(p, index, bg)
	}
}

_wgpu_compute_dispatch :: proc(pass: contract.Gpu_ComputePassEncoder, x: u32, y: u32, z: u32) {
	p := wgpu.ComputePassEncoder(rawptr(pass))
	if p != nil {
		wgpu.ComputePassEncoderDispatchWorkgroups(p, x, y, z)
	}
}

// --- Compute Pipeline Layout Query (52) ---

_wgpu_compute_get_bind_group_layout :: proc(pipeline: contract.Gpu_ComputePipeline, index: u32) -> contract.Gpu_BindGroupLayout {
	pipe := wgpu.ComputePipeline(rawptr(pipeline))
	if pipe == nil do return contract.Gpu_BindGroupLayout(nil)
	layout := wgpu.ComputePipelineGetBindGroupLayout(pipe, index)
	return contract.Gpu_BindGroupLayout(layout)
}

// --- Format Conversion Helpers ---

_contract_to_wgpu_format :: proc(fmt: contract.Gpu_Format) -> wgpu.TextureFormat {
	switch fmt {
	case .BGRA8_Unorm:   return .BGRA8Unorm
	case .RGBA8_Unorm:   return .RGBA8Unorm
	case .R8_Unorm:      return .R8Unorm
	case .Depth24Plus:   return .Depth24Plus
	case .Depth32_Float: return .Depth32Float
	case .Undefined:     return .Undefined
	}
	return .Undefined
}

_wgpu_to_contract_format :: proc(fmt: wgpu.TextureFormat) -> contract.Gpu_Format {
	#partial switch fmt {
	case .BGRA8Unorm, .BGRA8UnormSrgb: return .BGRA8_Unorm
	case .RGBA8Unorm, .RGBA8UnormSrgb: return .RGBA8_Unorm
	case .R8Unorm:                     return .R8_Unorm
	case .Depth24Plus:                 return .Depth24Plus
	case .Depth32Float:                return .Depth32_Float
	case:                              return .Undefined
	}
}

_contract_to_wgpu_buffer_usage :: proc(usage: contract.Gpu_Buffer_Usage) -> wgpu.BufferUsageFlags {
	res: wgpu.BufferUsageFlags
	u := u32(usage)
	if (u & u32(contract.Gpu_Buffer_Usage.Map_Read)) != 0 do res += { .MapRead }
	if (u & u32(contract.Gpu_Buffer_Usage.Map_Write)) != 0 do res += { .MapWrite }
	if (u & u32(contract.Gpu_Buffer_Usage.Copy_Src)) != 0 do res += { .CopySrc }
	if (u & u32(contract.Gpu_Buffer_Usage.Copy_Dst)) != 0 do res += { .CopyDst }
	if (u & u32(contract.Gpu_Buffer_Usage.Index)) != 0 do res += { .Index }
	if (u & u32(contract.Gpu_Buffer_Usage.Vertex)) != 0 do res += { .Vertex }
	if (u & u32(contract.Gpu_Buffer_Usage.Uniform)) != 0 do res += { .Uniform }
	if (u & u32(contract.Gpu_Buffer_Usage.Storage)) != 0 do res += { .Storage }
	if (u & u32(contract.Gpu_Buffer_Usage.Indirect)) != 0 do res += { .Indirect }
	return res
}

_contract_to_wgpu_texture_usage :: proc(usage: contract.Gpu_Texture_Usage) -> wgpu.TextureUsageFlags {
	res: wgpu.TextureUsageFlags
	u := u32(usage)
	if (u & u32(contract.Gpu_Texture_Usage.Copy_Src)) != 0 do res += { .CopySrc }
	if (u & u32(contract.Gpu_Texture_Usage.Copy_Dst)) != 0 do res += { .CopyDst }
	if (u & u32(contract.Gpu_Texture_Usage.Texture_Binding)) != 0 do res += { .TextureBinding }
	if (u & u32(contract.Gpu_Texture_Usage.Storage_Binding)) != 0 do res += { .StorageBinding }
	if (u & u32(contract.Gpu_Texture_Usage.Render_Attach)) != 0 do res += { .RenderAttachment }
	return res
}

_contract_to_wgpu_vertex_format :: proc(fmt: contract.Gpu_Vertex_Format) -> wgpu.VertexFormat {
	switch fmt {
	case .Float32:   return .Float32
	case .Float32x2: return .Float32x2
	case .Float32x3: return .Float32x3
	case .Float32x4: return .Float32x4
	case .Uint8x4:   return .Uint8x4
	case .Uint32:    return .Uint32
	case .Uint32x2:  return .Uint32x2
	}
	return .Float32
}

_contract_to_wgpu_step_mode :: proc(mode: contract.Gpu_Step_Mode) -> wgpu.VertexStepMode {
	switch mode {
	case .Vertex:   return .Vertex
	case .Instance: return .Instance
	}
	return .Vertex
}

_contract_to_wgpu_topology :: proc(top: contract.Gpu_Primitive_Topology) -> wgpu.PrimitiveTopology {
	switch top {
	case .Point_List:     return .PointList
	case .Line_List:      return .LineList
	case .Line_Strip:     return .LineStrip
	case .Triangle_List:  return .TriangleList
	case .Triangle_Strip: return .TriangleStrip
	}
	return .TriangleList
}
