package metal_backend

import "base:intrinsics"
import "core:fmt"
import "core:mem"
import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"
import CA "vendor:darwin/QuartzCore"
import gpu "../"

// Handle wrapper structs per specification
Metal_Device :: struct {
	handle: ^MTL.Device,
}

Metal_Queue :: struct {
	handle: ^MTL.CommandQueue,
}

Metal_Buffer :: struct {
	handle: ^MTL.Buffer,
	size:   u64,
	usage:  gpu.Gpu_Buffer_Usage,
}

Metal_Texture :: struct {
	handle: ^MTL.Texture,
	width:  u32,
	height: u32,
	format: gpu.Gpu_Format,
}

Metal_TextureView :: struct {
	texture: ^MTL.Texture,
	format:  gpu.Gpu_Format,
}

Metal_ShaderModule :: struct {
	library: ^MTL.Library,
}

Metal_RenderPipeline :: struct {
	state:    ^MTL.RenderPipelineState,
	topology: MTL.PrimitiveType,
}

Metal_ComputePipeline :: struct {
	state: ^MTL.ComputePipelineState,
}

Metal_BindGroupLayout :: struct {
	entries: []gpu.Gpu_Bind_Layout_Entry,
}

Metal_BindGroup :: struct {
	entries: []gpu.Gpu_Bind_Entry,
}

Metal_Sampler :: struct {
	handle: ^MTL.SamplerState,
}

Metal_CommandEncoder :: struct {
	cmd_buf: ^MTL.CommandBuffer,
}

Metal_RenderPassEncoder :: struct {
	encoder:  ^MTL.RenderCommandEncoder,
	cmd_buf:  ^MTL.CommandBuffer,
	pipeline: ^Metal_RenderPipeline,
}

Metal_ComputePassEncoder :: struct {
	encoder: ^MTL.ComputeCommandEncoder,
	cmd_buf: ^MTL.CommandBuffer,
}

METAL_VIBRANCY_MIN: f32 : 0.0
METAL_VIBRANCY_MAX: f32 : 1.0

Metal_Surface :: struct {
	layer:          ^CA.MetalLayer,
	cur_drawable:   ^CA.MetalDrawable,
	window_opacity: f32,
	window_blur:    f32,
}

// Global active handles for queue submission and presentation coordination
_active_queue:   ^MTL.CommandQueue
_active_cmd_buf: ^MTL.CommandBuffer
_active_surface: ^Metal_Surface

// Global vtable instance implementing all 52 procedures of gpu.Gpu_Backend_VTable
_metal_vtable: gpu.Gpu_Backend_VTable = gpu.Gpu_Backend_VTable{
	// Lifecycle
	create_instance         = _metal_create_instance,
	destroy_instance        = _metal_destroy_instance,
	request_device          = _metal_request_device,
	destroy_device          = _metal_destroy_device,
	poll_device             = _metal_poll_device,

	// Surface
	configure_surface       = _metal_configure_surface,
	get_surface_texture     = _metal_get_surface_texture,
	present_surface         = _metal_present_surface,
	get_preferred_format    = _metal_get_preferred_format,

	// Buffers
	create_buffer           = _metal_create_buffer,
	destroy_buffer          = _metal_destroy_buffer,
	write_buffer            = _metal_write_buffer,
	get_buffer_mapped_range = _metal_get_buffer_mapped_range,
	unmap_buffer            = _metal_unmap_buffer,

	// Textures
	create_texture          = _metal_create_texture,
	destroy_texture         = _metal_destroy_texture,
	create_texture_view     = _metal_create_texture_view,
	destroy_texture_view    = _metal_destroy_texture_view,
	write_texture           = _metal_write_texture,

	// Shaders
	shader_language         = .MSL,
	create_shader_module    = _metal_create_shader_module,
	destroy_shader_module   = _metal_destroy_shader_module,

	// Pipelines
	create_render_pipeline  = _metal_create_render_pipeline,
	destroy_render_pipeline = _metal_destroy_render_pipeline,

	// Bind groups
	create_bind_group_layout  = _metal_create_bind_group_layout,
	destroy_bind_group_layout = _metal_destroy_bind_group_layout,
	create_bind_group         = _metal_create_bind_group,
	destroy_bind_group        = _metal_destroy_bind_group,

	// Sampler
	create_sampler          = _metal_create_sampler,
	destroy_sampler         = _metal_destroy_sampler,

	// Command encoding
	create_command_encoder  = _metal_create_command_encoder,
	release_command_encoder = _metal_release_command_encoder,
	begin_render_pass       = _metal_begin_render_pass,
	end_render_pass         = _metal_end_render_pass,
	finish_command_buffer   = _metal_finish_command_buffer,
	release_command_buffer  = _metal_release_command_buffer,
	submit                  = _metal_submit,
	wait_for_idle           = _metal_wait_for_idle,

	// Render pass commands
	render_set_pipeline       = _metal_render_set_pipeline,
	render_set_bind_group     = _metal_render_set_bind_group,
	render_set_vertex_buffer  = _metal_render_set_vertex_buffer,
	render_draw               = _metal_render_draw,
	render_draw_indexed       = _metal_render_draw_indexed,

	// Surface texture release
	release_surface_texture   = _metal_release_surface_texture,

	// Pipeline layout query
	pipeline_get_bind_group_layout = _metal_pipeline_get_bind_group_layout,

	// Compute pipelines
	create_compute_pipeline   = _metal_create_compute_pipeline,
	destroy_compute_pipeline  = _metal_destroy_compute_pipeline,

	// Compute command encoding
	begin_compute_pass            = _metal_begin_compute_pass,
	end_compute_pass              = _metal_end_compute_pass,
	compute_set_pipeline          = _metal_compute_set_pipeline,
	compute_set_bind_group        = _metal_compute_set_bind_group,
	compute_dispatch              = _metal_compute_dispatch,
	compute_get_bind_group_layout = _metal_compute_get_bind_group_layout,
}

create_metal_backend :: proc() -> ^gpu.Gpu_Backend_VTable {
	return &_metal_vtable
}

metal_backend_vtable :: proc() -> ^gpu.Gpu_Backend_VTable {
	return &_metal_vtable
}

create_surface :: proc(layer_ptr: rawptr) -> ^Metal_Surface {
	layer := (^CA.MetalLayer)(layer_ptr)
	surf := new(Metal_Surface)
	surf.layer = layer
	surf.window_opacity = METAL_VIBRANCY_MAX
	surf.window_blur = METAL_VIBRANCY_MIN
	if layer != nil {
		top_left := _create_ns_string("topLeft")
		if top_left != nil {
			intrinsics.objc_send(nil, layer, "setContentsGravity:", top_left)
			top_left->release()
		}
	}
	return surf
}

configure_surface_vibrancy :: proc(surf: ^Metal_Surface, opacity: f32, blur: f32) {
	if surf == nil do return
	surf.window_opacity = clamp(opacity, METAL_VIBRANCY_MIN, METAL_VIBRANCY_MAX)
	surf.window_blur = clamp(blur, METAL_VIBRANCY_MIN, METAL_VIBRANCY_MAX)
	if surf.layer != nil {
		opaque := surf.window_opacity == METAL_VIBRANCY_MAX && surf.window_blur == METAL_VIBRANCY_MIN
		surf.layer->setOpaque(NS.BOOL(opaque))
	}
}

destroy_surface :: proc(surf: ^Metal_Surface) {
	if surf != nil {
		free(surf)
	}
}

// Internal helper to create NSString from Odin UTF-8 string
_create_ns_string :: proc(s: string) -> ^NS.String {
	if len(s) == 0 do return nil
	return NS.String.alloc()->initWithOdinString(s)
}

// --- Lifecycle (1-5) ---

_metal_create_instance :: proc() -> rawptr {
	return rawptr(uintptr(1))
}

_metal_destroy_instance :: proc(instance: rawptr) {
	// No-op for native Metal instance sentinel
}

_metal_request_device :: proc(instance: rawptr, surface: rawptr) -> (device: gpu.Gpu_Device, queue: gpu.Gpu_Queue) {
	mtl_dev := MTL.CreateSystemDefaultDevice()
	if mtl_dev == nil {
		return gpu.Gpu_Device(nil), gpu.Gpu_Queue(nil)
	}
	mtl_queue := mtl_dev->newCommandQueue()
	if mtl_queue == nil {
		mtl_dev->release()
		return gpu.Gpu_Device(nil), gpu.Gpu_Queue(nil)
	}
	dev := new(Metal_Device)
	dev.handle = mtl_dev
	q := new(Metal_Queue)
	q.handle = mtl_queue
	_active_queue = mtl_queue
	return gpu.Gpu_Device(dev), gpu.Gpu_Queue(q)
}

_metal_destroy_device :: proc(device: gpu.Gpu_Device) {
	dev := (^Metal_Device)(rawptr(device))
	if dev != nil {
		if dev.handle != nil {
			dev.handle->release()
		}
		free(dev)
	}
	_active_queue = nil
	_active_cmd_buf = nil
}

_metal_poll_device :: proc(device: gpu.Gpu_Device, wait: bool) -> bool {
	return true
}

// --- Surface (6-9) ---

_metal_configure_surface :: proc(surface: rawptr, device: gpu.Gpu_Device, format: gpu.Gpu_Format, width, height: u32) {
	surf := (^Metal_Surface)(surface)
	dev := (^Metal_Device)(rawptr(device))
	if surf == nil || surf.layer == nil || dev == nil || dev.handle == nil do return

	// Changing drawableSize makes CAMetalLayer discard its whole drawable pool.
	// A drawable still referenced here came from the previous pool, can never be
	// presented again, and would otherwise be silently overwritten by the next
	// nextDrawable() while the layer still counted it as in use.
	surf.cur_drawable = nil

	surf.layer->setDevice(dev.handle)
	surf.layer->setPixelFormat(.BGRA8Unorm)
	surf.layer->setDrawableSize(NS.Size{NS.Float(width), NS.Float(height)})

	intrinsics.objc_send(nil, surf.layer, "setMaximumDrawableCount:", NS.UInteger(3))
	intrinsics.objc_send(nil, surf.layer, "setPresentsWithTransaction:", bool(false))

	top_left := _create_ns_string("topLeft")
	if top_left != nil {
		intrinsics.objc_send(nil, surf.layer, "setContentsGravity:", top_left)
		top_left->release()
	}

	opaque := surf.window_opacity == METAL_VIBRANCY_MAX && surf.window_blur == METAL_VIBRANCY_MIN
	surf.layer->setOpaque(NS.BOOL(opaque))

	_active_surface = surf
}

_metal_get_surface_texture :: proc(surface: rawptr) -> (texture: gpu.Gpu_Texture, view: gpu.Gpu_TextureView, format: gpu.Gpu_Format) {
	surf := (^Metal_Surface)(surface)
	if surf == nil || surf.layer == nil {
		return gpu.Gpu_Texture(nil), gpu.Gpu_TextureView(nil), .Undefined
	}
	drawable := surf.layer->nextDrawable()
	if drawable == nil {
		return gpu.Gpu_Texture(nil), gpu.Gpu_TextureView(nil), .Undefined
	}
	surf.cur_drawable = drawable
	_active_surface = surf

	mtl_tex := drawable->texture()
	if mtl_tex == nil {
		return gpu.Gpu_Texture(nil), gpu.Gpu_TextureView(nil), .Undefined
	}

	tex := new(Metal_Texture)
	tex.handle = mtl_tex
	tex.width = u32(mtl_tex->width())
	tex.height = u32(mtl_tex->height())
	tex.format = .BGRA8_Unorm

	tex_view := new(Metal_TextureView)
	tex_view.texture = mtl_tex
	tex_view.format = .BGRA8_Unorm

	return gpu.Gpu_Texture(tex), gpu.Gpu_TextureView(tex_view), .BGRA8_Unorm
}

_metal_present_surface :: proc(surface: rawptr) -> bool {
	surf := (^Metal_Surface)(surface)
	if surf != nil && surf.cur_drawable != nil {
		if _active_cmd_buf != nil {
			_active_cmd_buf->presentDrawable(surf.cur_drawable)
		}
		surf.cur_drawable = nil
	}
	return true
}

_metal_get_preferred_format :: proc(surface: rawptr, device: gpu.Gpu_Device) -> gpu.Gpu_Format {
	return .BGRA8_Unorm
}

// --- Buffers (10-14) ---

_metal_create_buffer :: proc(device: gpu.Gpu_Device, size: u64, usage: gpu.Gpu_Buffer_Usage, mapped_at_creation: bool) -> gpu.Gpu_Buffer {
	dev := (^Metal_Device)(rawptr(device))
	if dev == nil || dev.handle == nil do return gpu.Gpu_Buffer(nil)

	buf_size := size if size > 0 else 4
	mtl_buf := dev.handle->newBufferWithLength(NS.UInteger(buf_size), {})
	if mtl_buf == nil do return gpu.Gpu_Buffer(nil)

	buf := new(Metal_Buffer)
	buf.handle = mtl_buf
	buf.size = size
	buf.usage = usage
	return gpu.Gpu_Buffer(buf)
}

_metal_destroy_buffer :: proc(buffer: gpu.Gpu_Buffer) {
	buf := (^Metal_Buffer)(rawptr(buffer))
	if buf != nil {
		if buf.handle != nil {
			buf.handle->release()
		}
		free(buf)
	}
}

_metal_write_buffer :: proc(queue: gpu.Gpu_Queue, buffer: gpu.Gpu_Buffer, offset: u64, data: rawptr, size: u64) {
	buf := (^Metal_Buffer)(rawptr(buffer))
	if buf == nil || buf.handle == nil || data == nil || size == 0 do return
	raw_contents := buf.handle->contents()
	dst := mem.ptr_offset(raw_data(raw_contents), int(offset))
	mem.copy(dst, data, int(size))
}

_metal_get_buffer_mapped_range :: proc(buffer: gpu.Gpu_Buffer, offset: u64, size: u64) -> []u8 {
	buf := (^Metal_Buffer)(rawptr(buffer))
	if buf == nil || buf.handle == nil do return nil
	raw_contents := buf.handle->contents()
	return raw_contents[offset:offset+size]
}

_metal_unmap_buffer :: proc(buffer: gpu.Gpu_Buffer) {
	// No-op for shared storage mode Metal buffers
}

// --- Textures (15-19) ---

_metal_create_texture :: proc(device: gpu.Gpu_Device, width, height: u32, format: gpu.Gpu_Format, usage: gpu.Gpu_Texture_Usage) -> gpu.Gpu_Texture {
	dev := (^Metal_Device)(rawptr(device))
	if dev == nil || dev.handle == nil do return gpu.Gpu_Texture(nil)

	pixel_format: MTL.PixelFormat = .Invalid
	#partial switch format {
	case .BGRA8_Unorm: pixel_format = .BGRA8Unorm
	case .RGBA8_Unorm: pixel_format = .RGBA8Unorm
	case .R8_Unorm:    pixel_format = .R8Unorm
	case:              pixel_format = .RGBA8Unorm
	}

	w := NS.UInteger(max(width, 1))
	h := NS.UInteger(max(height, 1))
	desc := MTL.TextureDescriptor.texture2DDescriptorWithPixelFormat(pixel_format, w, h, false)
	if desc == nil do return gpu.Gpu_Texture(nil)

	mtl_usage: MTL.TextureUsage = {}
	if u32(usage) & u32(gpu.Gpu_Texture_Usage.Texture_Binding) != 0 {
		mtl_usage |= {.ShaderRead}
	}
	if u32(usage) & u32(gpu.Gpu_Texture_Usage.Storage_Binding) != 0 {
		mtl_usage |= {.ShaderRead, .ShaderWrite}
	}
	if u32(usage) & u32(gpu.Gpu_Texture_Usage.Render_Attach) != 0 {
		mtl_usage |= {.RenderTarget}
	}
	if mtl_usage == {} {
		mtl_usage = {.ShaderRead}
	}
	desc->setUsage(mtl_usage)
	desc->setStorageMode(.Shared)

	mtl_tex := dev.handle->newTextureWithDescriptor(desc)
	if mtl_tex == nil do return gpu.Gpu_Texture(nil)

	tex := new(Metal_Texture)
	tex.handle = mtl_tex
	tex.width = width
	tex.height = height
	tex.format = format
	return gpu.Gpu_Texture(tex)
}

_metal_destroy_texture :: proc(texture: gpu.Gpu_Texture) {
	tex := (^Metal_Texture)(rawptr(texture))
	if tex != nil {
		if tex.handle != nil {
			tex.handle->release()
		}
		free(tex)
	}
}

_metal_create_texture_view :: proc(texture: gpu.Gpu_Texture) -> gpu.Gpu_TextureView {
	tex := (^Metal_Texture)(rawptr(texture))
	if tex == nil || tex.handle == nil do return gpu.Gpu_TextureView(nil)

	view := new(Metal_TextureView)
	view.texture = tex.handle
	view.format = tex.format
	return gpu.Gpu_TextureView(view)
}

_metal_destroy_texture_view :: proc(view: gpu.Gpu_TextureView) {
	v := (^Metal_TextureView)(rawptr(view))
	if v != nil {
		free(v)
	}
}

_metal_write_texture :: proc(queue: gpu.Gpu_Queue, texture: gpu.Gpu_Texture, data: []u8, width, height: u32) {
	tex := (^Metal_Texture)(rawptr(texture))
	if tex == nil || tex.handle == nil || len(data) == 0 do return

	bytes_per_pixel: u32 = 4
	if tex.format == .R8_Unorm {
		bytes_per_pixel = 1
	}
	bytes_per_row := NS.UInteger(width * bytes_per_pixel)

	region := MTL.Region{
		origin = {0, 0, 0},
		size   = {NS.Integer(width), NS.Integer(height), 1},
	}
	tex.handle->replaceRegion(
		region,
		0,
		raw_data(data),
		bytes_per_row,
	)
}

// --- Shaders (20-21) ---

_metal_create_shader_module :: proc(device: gpu.Gpu_Device, source: string) -> gpu.Gpu_ShaderModule {
	dev := (^Metal_Device)(rawptr(device))
	if dev == nil || dev.handle == nil || len(source) == 0 do return gpu.Gpu_ShaderModule(nil)

	ns_source := _create_ns_string(source)
	if ns_source == nil do return gpu.Gpu_ShaderModule(nil)
	defer ns_source->release()

	lib, err := dev.handle->newLibraryWithSource(ns_source, nil)
	if lib == nil {
		if err != nil {
			desc := err->localizedDescription()
			err_str := desc->UTF8String() if desc != nil else cstring("unknown error")
			fmt.eprintf("metal create_shader_module error: %s\n", err_str)
		}
		return gpu.Gpu_ShaderModule(nil)
	}

	mod := new(Metal_ShaderModule)
	mod.library = lib
	return gpu.Gpu_ShaderModule(mod)
}

_metal_destroy_shader_module :: proc(module: gpu.Gpu_ShaderModule) {
	mod := (^Metal_ShaderModule)(rawptr(module))
	if mod != nil {
		if mod.library != nil {
			mod.library->release()
		}
		free(mod)
	}
}

// --- Pipelines (22-23) ---

_metal_create_render_pipeline :: proc(
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
	dev := (^Metal_Device)(rawptr(device))
	if dev == nil || dev.handle == nil do return gpu.Gpu_RenderPipeline(nil)

	v_mod := (^Metal_ShaderModule)(rawptr(vertex_shader))
	f_mod := (^Metal_ShaderModule)(rawptr(fragment_shader))
	if v_mod == nil || v_mod.library == nil do return gpu.Gpu_RenderPipeline(nil)

	desc := MTL.RenderPipelineDescriptor.alloc()->init()
	if desc == nil do return gpu.Gpu_RenderPipeline(nil)
	defer desc->release()

	ns_v_entry := _create_ns_string(vertex_entry)
	if ns_v_entry != nil {
		defer ns_v_entry->release()
		v_fn := v_mod.library->newFunctionWithName(ns_v_entry)
		if v_fn != nil {
			desc->setVertexFunction(v_fn)
		}
	}

	if f_mod != nil && f_mod.library != nil && len(fragment_entry) > 0 {
		ns_f_entry := _create_ns_string(fragment_entry)
		if ns_f_entry != nil {
			defer ns_f_entry->release()
			f_fn := f_mod.library->newFunctionWithName(ns_f_entry)
			if f_fn != nil {
				desc->setFragmentFunction(f_fn)
			}
		}
	}

	mtl_format: MTL.PixelFormat = .Invalid
	#partial switch format {
	case .BGRA8_Unorm: mtl_format = .BGRA8Unorm
	case .RGBA8_Unorm: mtl_format = .RGBA8Unorm
	case .R8_Unorm:    mtl_format = .R8Unorm
	case:              mtl_format = .BGRA8Unorm
	}
	attachments := desc->colorAttachments()
	if attachments != nil {
		color_attach := attachments->object(0)
		if color_attach != nil {
			color_attach->setPixelFormat(mtl_format)
			switch blend {
			case .Alpha_Blend:
				color_attach->setBlendingEnabled(true)
				color_attach->setRgbBlendOperation(.Add)
				color_attach->setAlphaBlendOperation(.Add)
				color_attach->setSourceRGBBlendFactor(.SourceAlpha)
				color_attach->setDestinationRGBBlendFactor(.OneMinusSourceAlpha)
				color_attach->setSourceAlphaBlendFactor(.One)
				color_attach->setDestinationAlphaBlendFactor(.OneMinusSourceAlpha)
			case .Opaque:
				color_attach->setBlendingEnabled(false)
			}
		}
	}

	if len(vertex_layouts) > 0 {
		v_desc := MTL.VertexDescriptor.vertexDescriptor()
		if v_desc != nil {
			layouts := v_desc->layouts()
			attributes := v_desc->attributes()
			for layout, buffer_idx in vertex_layouts {
				if layouts != nil {
					layout_desc := layouts->object(NS.UInteger(buffer_idx))
					if layout_desc != nil {
						layout_desc->setStride(NS.UInteger(layout.array_stride))
						switch layout.step_mode {
						case .Vertex:   layout_desc->setStepFunction(.PerVertex)
						case .Instance: layout_desc->setStepFunction(.PerInstance)
						}
					}
				}
				if attributes != nil {
					for attr in layout.attributes {
						at := attributes->object(NS.UInteger(attr.shader_location))
						if at != nil {
							at->setBufferIndex(NS.UInteger(buffer_idx))
							at->setOffset(NS.UInteger(attr.offset))
							#partial switch attr.format {
							case .Float32:   at->setFormat(.Float)
							case .Float32x2: at->setFormat(.Float2)
							case .Float32x3: at->setFormat(.Float3)
							case .Float32x4: at->setFormat(.Float4)
							case .Uint8x4:   at->setFormat(.UChar4Normalized)
							case .Uint32:    at->setFormat(.UInt)
							case .Uint32x2:  at->setFormat(.UInt2)
							}
						}
					}
				}
			}
			desc->setVertexDescriptor(v_desc)
		}
	}

	pipeline_state, err := dev.handle->newRenderPipelineStateWithDescriptor(desc)
	if pipeline_state == nil {
		if err != nil {
			fmt.eprintf("metal newRenderPipelineStateWithDescriptor error\n")
		}
		return gpu.Gpu_RenderPipeline(nil)
	}

	mtl_topology: MTL.PrimitiveType = .Triangle
	#partial switch topology {
	case .Point_List:     mtl_topology = .Point
	case .Line_List:      mtl_topology = .Line
	case .Line_Strip:     mtl_topology = .LineStrip
	case .Triangle_List:  mtl_topology = .Triangle
	case .Triangle_Strip: mtl_topology = .TriangleStrip
	}

	pipeline := new(Metal_RenderPipeline)
	pipeline.state = pipeline_state
	pipeline.topology = mtl_topology
	return gpu.Gpu_RenderPipeline(pipeline)
}

_metal_destroy_render_pipeline :: proc(pipeline: gpu.Gpu_RenderPipeline) {
	p := (^Metal_RenderPipeline)(rawptr(pipeline))
	if p != nil {
		if p.state != nil {
			p.state->release()
		}
		free(p)
	}
}

// --- Bind Groups (24-27) ---

_metal_create_bind_group_layout :: proc(device: gpu.Gpu_Device, entries: []gpu.Gpu_Bind_Layout_Entry) -> gpu.Gpu_BindGroupLayout {
	layout := new(Metal_BindGroupLayout)
	if len(entries) > 0 {
		layout.entries = make([]gpu.Gpu_Bind_Layout_Entry, len(entries))
		copy(layout.entries, entries)
	}
	return gpu.Gpu_BindGroupLayout(layout)
}

_metal_destroy_bind_group_layout :: proc(layout: gpu.Gpu_BindGroupLayout) {
	l := (^Metal_BindGroupLayout)(rawptr(layout))
	if l != nil {
		if len(l.entries) > 0 {
			delete(l.entries)
		}
		free(l)
	}
}

_metal_create_bind_group :: proc(device: gpu.Gpu_Device, layout: gpu.Gpu_BindGroupLayout, entries: []gpu.Gpu_Bind_Entry) -> gpu.Gpu_BindGroup {
	bg := new(Metal_BindGroup)
	if len(entries) > 0 {
		bg.entries = make([]gpu.Gpu_Bind_Entry, len(entries))
		copy(bg.entries, entries)
	}
	return gpu.Gpu_BindGroup(bg)
}

_metal_destroy_bind_group :: proc(group: gpu.Gpu_BindGroup) {
	bg := (^Metal_BindGroup)(rawptr(group))
	if bg != nil {
		if len(bg.entries) > 0 {
			delete(bg.entries)
		}
		free(bg)
	}
}

// --- Sampler (28-29) ---

_metal_create_sampler :: proc(device: gpu.Gpu_Device) -> gpu.Gpu_Sampler {
	dev := (^Metal_Device)(rawptr(device))
	if dev == nil || dev.handle == nil do return gpu.Gpu_Sampler(nil)

	desc := MTL.SamplerDescriptor.alloc()->init()
	if desc == nil do return gpu.Gpu_Sampler(nil)
	defer desc->release()

	desc->setMinFilter(.Linear)
	desc->setMagFilter(.Linear)
	desc->setMipFilter(.NotMipmapped)
	desc->setSAddressMode(.ClampToEdge)
	desc->setTAddressMode(.ClampToEdge)
	desc->setRAddressMode(.ClampToEdge)

	sampler_state := dev.handle->newSamplerState(desc)
	if sampler_state == nil do return gpu.Gpu_Sampler(nil)

	sampler := new(Metal_Sampler)
	sampler.handle = sampler_state
	return gpu.Gpu_Sampler(sampler)
}

_metal_destroy_sampler :: proc(sampler: gpu.Gpu_Sampler) {
	s := (^Metal_Sampler)(rawptr(sampler))
	if s != nil {
		if s.handle != nil {
			s.handle->release()
		}
		free(s)
	}
}

// --- Command Encoding (30-37) ---

_metal_create_command_encoder :: proc(device: gpu.Gpu_Device) -> gpu.Gpu_CommandEncoder {
	if _active_queue == nil do return gpu.Gpu_CommandEncoder(nil)

	cmd_buf := _active_queue->commandBuffer()
	if cmd_buf == nil do return gpu.Gpu_CommandEncoder(nil)

	enc := new(Metal_CommandEncoder)
	enc.cmd_buf = cmd_buf
	_active_cmd_buf = cmd_buf
	return gpu.Gpu_CommandEncoder(enc)
}

_metal_release_command_encoder :: proc(encoder: gpu.Gpu_CommandEncoder) {
	enc := (^Metal_CommandEncoder)(rawptr(encoder))
	if enc != nil {
		free(enc)
	}
}

_metal_begin_render_pass :: proc(
	encoder: gpu.Gpu_CommandEncoder,
	color_view: gpu.Gpu_TextureView,
	clear_color: [4]f64,
	load_op: gpu.Gpu_Load_Op,
) -> gpu.Gpu_RenderPassEncoder {
	enc := (^Metal_CommandEncoder)(rawptr(encoder))
	view := (^Metal_TextureView)(rawptr(color_view))
	if enc == nil || enc.cmd_buf == nil || view == nil || view.texture == nil {
		return gpu.Gpu_RenderPassEncoder(nil)
	}

	pass_desc := MTL.RenderPassDescriptor.renderPassDescriptor()
	if pass_desc == nil do return gpu.Gpu_RenderPassEncoder(nil)

	attachments := pass_desc->colorAttachments()
	if attachments != nil {
		color_attach := attachments->object(0)
		if color_attach != nil {
			color_attach->setTexture(view.texture)
			switch load_op {
			case .Clear:
				color_attach->setLoadAction(MTL.LoadAction.Clear)
				// The clear alpha is already theme_alpha * background_opacity
				// (see _renderer_theme_clear_color). Multiplying by the surface
				// opacity here would square it, so it is deliberately not applied.
				color_attach->setClearColor(MTL.ClearColor{clear_color[0], clear_color[1], clear_color[2], clear_color[3]})
			case .Load:
				color_attach->setLoadAction(MTL.LoadAction.Load)
			case .Undefined:
				color_attach->setLoadAction(MTL.LoadAction.DontCare)
			}
			color_attach->setStoreAction(MTL.StoreAction.Store)
		}
	}

	r_enc := enc.cmd_buf->renderCommandEncoderWithDescriptor(pass_desc)
	if r_enc == nil do return gpu.Gpu_RenderPassEncoder(nil)

	pass := new(Metal_RenderPassEncoder)
	pass.encoder = r_enc
	pass.cmd_buf = enc.cmd_buf
	return gpu.Gpu_RenderPassEncoder(pass)
}

_metal_end_render_pass :: proc(pass: gpu.Gpu_RenderPassEncoder) {
	p := (^Metal_RenderPassEncoder)(rawptr(pass))
	if p != nil {
		if p.encoder != nil {
			p.encoder->endEncoding()
		}
		free(p)
	}
}

_metal_finish_command_buffer :: proc(encoder: gpu.Gpu_CommandEncoder) -> rawptr {
	enc := (^Metal_CommandEncoder)(rawptr(encoder))
	if enc == nil do return nil
	return rawptr(enc.cmd_buf)
}

_metal_release_command_buffer :: proc(command_buffer: rawptr) {
	// Command buffers are managed by Metal queue
}

// Objective-C block ABI for a `void (^)(id<MTLCommandBuffer>)` handler.
// The runtime owns the layout, not this binding: isa, flags and descriptor are
// read by _Block_copy when the handler is handed to Metal.
@(private)
Metal_Block_Descriptor :: struct {
	reserved: uint,
	size:     uint,
}

// Metal_Command_Buffer_Handler_Block is the capture-free block literal for the
// GPU timing handler. It has no captures because the finished command buffer
// arrives as the handler's argument, so the literal can live in static storage
// as a global block.
@(private)
Metal_Command_Buffer_Handler_Block :: struct {
	isa:        ^intrinsics.objc_class,
	flags:      u32,
	reserved:   u32,
	invoke:     proc "c" (block: ^Metal_Command_Buffer_Handler_Block, command_buffer: ^MTL.CommandBuffer),
	descriptor: ^Metal_Block_Descriptor,
}

foreign import libSystem "system:System"
foreign libSystem {
	_NSConcreteGlobalBlock: intrinsics.objc_class
}

@(private)
_metal_handler_block_descriptor: Metal_Block_Descriptor = Metal_Block_Descriptor{
	reserved = 0,
	size     = size_of(Metal_Command_Buffer_Handler_Block),
}

// BLOCK_IS_GLOBAL from the Objective-C block ABI. A capture-free block literal
// is emitted as a global block, and _Block_copy on one returns the same pointer
// instead of mallocing a copy, so registering the handler adds no allocation to
// the frame path.
METAL_BLOCK_IS_GLOBAL :: 1 << 28

@(private)
_metal_gpu_timing_handler: Metal_Command_Buffer_Handler_Block = Metal_Command_Buffer_Handler_Block{
	isa        = &_NSConcreteGlobalBlock,
	flags      = u32(METAL_BLOCK_IS_GLOBAL),
	invoke     = _metal_gpu_completion,
	descriptor = &_metal_handler_block_descriptor,
}

// _metal_gpu_completion reports one command buffer's GPU execution time.
//
// It runs on a Metal-internal thread after the buffer has finished. It
// allocates nothing, takes no lock beyond whatever the consumer's callback
// takes, and reads nothing but the command buffer it is handed, so it is safe
// to invoke from a driver thread.
@(private)
_metal_gpu_completion :: proc "c" (block: ^Metal_Command_Buffer_Handler_Block, command_buffer: ^MTL.CommandBuffer) {
	_ = block
	if _metal_vtable.gpu_frame_complete == nil || command_buffer == nil do return

	gpu_ns: u64 = 0
	valid := true
	// An errored buffer did not execute the work, so its timestamps describe
	// nothing that reached the screen.
	if command_buffer->status() == .Error {
		valid = false
	} else {
		start := command_buffer->GPUStartTime()
		end := command_buffer->GPUEndTime()
		if end > start {
			gpu_ns = u64((end - start) * 1_000_000_000.0)
		} else {
			// Timestamps are unavailable: some devices never populate them, and
			// dropped work leaves both at zero. Reporting 0 as valid would read
			// as "the GPU took no time", which is a different and wrong claim.
			valid = false
		}
	}
	// The vtable slot is an ordinary Odin proc, while this handler is entered
	// through a C block trampoline, so the call goes through rawptr to drop the
	// context-calling convention rather than smuggling a context into Metal.
	((proc "c" (gpu_ns: u64, valid: bool))(rawptr(_metal_vtable.gpu_frame_complete)))(gpu_ns, valid)
}

// _metal_install_gpu_timing attaches the GPU timing handler to a command buffer
// that is about to be committed.
//
// Asynchronous by design. Commit 34b2daa set setMaximumDrawableCount:3 on the
// CAMetalLayer precisely so CPU command encoding runs ahead of GPU execution.
// Blocking on the command buffer here to read the timestamps would serialise
// encoding against execution and delete that, turning a triple-buffered
// pipelined renderer into a stalling one. The handler runs later, on a
// Metal-internal thread, and reads the timestamps once the buffer has genuinely
// completed.
_metal_install_gpu_timing :: proc(cmd_buf: ^MTL.CommandBuffer) {
	if cmd_buf == nil do return
	cmd_buf->addCompletedHandler(MTL.CommandBufferHandler(rawptr(&_metal_gpu_timing_handler)))
}

_metal_submit :: proc(queue: gpu.Gpu_Queue, command_buffer: rawptr) -> bool {
	if command_buffer == nil do return false
	cmd_buf := (^MTL.CommandBuffer)(command_buffer)
	if _active_surface != nil && _active_surface.cur_drawable != nil {
		cmd_buf->presentDrawable(_active_surface.cur_drawable)
		_active_surface.cur_drawable = nil
	}
	_metal_install_gpu_timing(cmd_buf)
	cmd_buf->commit()
	return true
}

_metal_wait_for_idle :: proc(device: gpu.Gpu_Device) -> bool {
	if _active_queue == nil do return true
	cmd_buf := _active_queue->commandBuffer()
	if cmd_buf == nil do return true
	cmd_buf->commit()
	cmd_buf->waitUntilCompleted()
	return true
}

// --- Render Pass Commands (38-42) ---

_metal_render_set_pipeline :: proc(pass: gpu.Gpu_RenderPassEncoder, pipeline: gpu.Gpu_RenderPipeline) {
	p := (^Metal_RenderPassEncoder)(rawptr(pass))
	pipe := (^Metal_RenderPipeline)(rawptr(pipeline))
	if p == nil || p.encoder == nil || pipe == nil || pipe.state == nil do return
	p.encoder->setRenderPipelineState(pipe.state)
	p.pipeline = pipe
}

_metal_render_set_bind_group :: proc(pass: gpu.Gpu_RenderPassEncoder, index: u32, group: gpu.Gpu_BindGroup) {
	p := (^Metal_RenderPassEncoder)(rawptr(pass))
	bg := (^Metal_BindGroup)(rawptr(group))
	if p == nil || p.encoder == nil || bg == nil do return

	for entry in bg.entries {
		idx := NS.UInteger(entry.binding)
		#partial switch entry.entry_type {
		case .Buffer:
			buf := (^Metal_Buffer)(rawptr(entry.buffer))
			if buf != nil && buf.handle != nil {
				// Uniform bytes are copied into this encoder, not shared with later frames.
				MAX_INLINE_UNIFORM_BYTES :: 4096
				uniform_only := (buf.usage & .Uniform) != .None && (buf.usage & .Storage) == .None
				valid_range := entry.offset <= buf.size && entry.size <= buf.size - entry.offset
				if uniform_only && valid_range && entry.size > 0 && entry.size <= MAX_INLINE_UNIFORM_BYTES {
					contents := buf.handle->contents()
					bytes := contents[int(entry.offset):int(entry.offset + entry.size)]
					p.encoder->setVertexBytes(bytes, idx + 1)
					p.encoder->setFragmentBytes(bytes, idx + 1)
				} else {
					p.encoder->setVertexBuffer(buf.handle, NS.UInteger(entry.offset), idx + 1)
					p.encoder->setFragmentBuffer(buf.handle, NS.UInteger(entry.offset), idx + 1)
				}
			}
		case .Texture_View:
			tv := (^Metal_TextureView)(rawptr(entry.view))
			if tv != nil && tv.texture != nil {
				p.encoder->setFragmentTexture(tv.texture, idx)
			}
		case .Sampler:
			s := (^Metal_Sampler)(rawptr(entry.sampler))
			if s != nil && s.handle != nil {
				p.encoder->setFragmentSamplerState(s.handle, idx)
			}
		}
	}
}

_metal_render_set_vertex_buffer :: proc(pass: gpu.Gpu_RenderPassEncoder, slot: u32, buffer: gpu.Gpu_Buffer, offset: u64) {
	p := (^Metal_RenderPassEncoder)(rawptr(pass))
	buf := (^Metal_Buffer)(rawptr(buffer))
	if p == nil || p.encoder == nil || buf == nil || buf.handle == nil do return
	p.encoder->setVertexBuffer(buf.handle, NS.UInteger(offset), NS.UInteger(slot))
}

_metal_render_draw :: proc(pass: gpu.Gpu_RenderPassEncoder, vertex_count: u32, instance_count: u32) {
	p := (^Metal_RenderPassEncoder)(rawptr(pass))
	if p == nil || p.encoder == nil do return
	topology: MTL.PrimitiveType = .Triangle
	if p.pipeline != nil {
		topology = p.pipeline.topology
	}
	p.encoder->drawPrimitivesWithInstanceCount(
		topology,
		0,
		NS.UInteger(vertex_count),
		NS.UInteger(instance_count),
	)
}

_metal_render_draw_indexed :: proc(pass: gpu.Gpu_RenderPassEncoder, index_count: u32, instance_count: u32) {
	p := (^Metal_RenderPassEncoder)(rawptr(pass))
	if p == nil || p.encoder == nil do return
	// Gpu_Backend_VTable does not expose set_index_buffer; renderer uses instanced draw.
}

// --- Surface Texture Release (43) ---

_metal_release_surface_texture :: proc(texture: gpu.Gpu_Texture, view: gpu.Gpu_TextureView) {
	tex := (^Metal_Texture)(rawptr(texture))
	if tex != nil {
		free(tex)
	}
	tv := (^Metal_TextureView)(rawptr(view))
	if tv != nil {
		free(tv)
	}
}

// --- Pipeline Layout Query (44) ---

_metal_pipeline_get_bind_group_layout :: proc(pipeline: gpu.Gpu_RenderPipeline, index: u32) -> gpu.Gpu_BindGroupLayout {
	layout := new(Metal_BindGroupLayout)
	return gpu.Gpu_BindGroupLayout(layout)
}

// --- Compute Pipelines (45-46) ---

_metal_create_compute_pipeline :: proc(device: gpu.Gpu_Device, shader: gpu.Gpu_ShaderModule, entry: string) -> gpu.Gpu_ComputePipeline {
	pipe := new(Metal_ComputePipeline)
	return gpu.Gpu_ComputePipeline(pipe)
}

_metal_destroy_compute_pipeline :: proc(pipeline: gpu.Gpu_ComputePipeline) {
	p := (^Metal_ComputePipeline)(rawptr(pipeline))
	if p != nil {
		if p.state != nil {
			p.state->release()
		}
		free(p)
	}
}

// --- Compute Command Encoding (47-51) ---

_metal_begin_compute_pass :: proc(encoder: gpu.Gpu_CommandEncoder) -> gpu.Gpu_ComputePassEncoder {
	enc := (^Metal_CommandEncoder)(rawptr(encoder))
	if enc == nil || enc.cmd_buf == nil do return gpu.Gpu_ComputePassEncoder(nil)

	c_enc := enc.cmd_buf->computeCommandEncoder()
	if c_enc == nil do return gpu.Gpu_ComputePassEncoder(nil)

	pass := new(Metal_ComputePassEncoder)
	pass.encoder = c_enc
	pass.cmd_buf = enc.cmd_buf
	return gpu.Gpu_ComputePassEncoder(pass)
}

_metal_end_compute_pass :: proc(pass: gpu.Gpu_ComputePassEncoder) {
	p := (^Metal_ComputePassEncoder)(rawptr(pass))
	if p != nil {
		if p.encoder != nil {
			p.encoder->endEncoding()
		}
		free(p)
	}
}

_metal_compute_set_pipeline :: proc(pass: gpu.Gpu_ComputePassEncoder, pipeline: gpu.Gpu_ComputePipeline) {
	p := (^Metal_ComputePassEncoder)(rawptr(pass))
	pipe := (^Metal_ComputePipeline)(rawptr(pipeline))
	if p == nil || p.encoder == nil || pipe == nil || pipe.state == nil do return
	p.encoder->setComputePipelineState(pipe.state)
}

_metal_compute_set_bind_group :: proc(pass: gpu.Gpu_ComputePassEncoder, index: u32, group: gpu.Gpu_BindGroup) {
	p := (^Metal_ComputePassEncoder)(rawptr(pass))
	bg := (^Metal_BindGroup)(rawptr(group))
	if p == nil || p.encoder == nil || bg == nil do return

	for entry in bg.entries {
		idx := NS.UInteger(entry.binding)
		#partial switch entry.entry_type {
		case .Buffer:
			buf := (^Metal_Buffer)(rawptr(entry.buffer))
			if buf != nil && buf.handle != nil {
				p.encoder->setBuffer(buf.handle, NS.UInteger(entry.offset), idx)
			}
		case .Texture_View:
			tv := (^Metal_TextureView)(rawptr(entry.view))
			if tv != nil && tv.texture != nil {
				p.encoder->setTexture(tv.texture, idx)
			}
		case .Sampler:
			s := (^Metal_Sampler)(rawptr(entry.sampler))
			if s != nil && s.handle != nil {
				p.encoder->setSamplerState(s.handle, idx)
			}
		}
	}
}

_metal_compute_dispatch :: proc(pass: gpu.Gpu_ComputePassEncoder, x: u32, y: u32, z: u32) {
	// Stub for compute pass dispatch
}

// --- Compute Pipeline Layout Query (52) ---

_metal_compute_get_bind_group_layout :: proc(pipeline: gpu.Gpu_ComputePipeline, index: u32) -> gpu.Gpu_BindGroupLayout {
	layout := new(Metal_BindGroupLayout)
	return gpu.Gpu_BindGroupLayout(layout)
}

main :: proc() {}
