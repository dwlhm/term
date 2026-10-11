package blit

// Hardware quad blit pipeline for OS-Style Layer Compositor Architecture.
// Composites offscreen layer backing textures onto the window surface / render pass.
//
// Features:
// 1. Procedural quad vertices generated from vertex ID (zero vertex buffer overhead).
// 2. Per-layer scissor clipping boundary check (discard fragments outside clip_rect).
// 3. Corner rounding via Box SDF smoothstep (for floating/rounded panes).
// 4. Opacity alpha blending (opacity * sampled.a).
// 5. Zero heap allocation during steady-state.
//
// Invariants:
// - ZERO Horizontal Dependencies: Imports ONLY base:runtime, contract, composer, and layer.
// - Strict adherence to Odin -strict-style.

import "base:runtime"
import contract "../../render/contract"
import composer "../"
import layer "../layer"

COMPOSER_BLIT_WGSL :: #load("../../render/shaders/composer_blit.wgsl", string)

// Blit_Uniforms: 48-byte aligned uniform record matching MSL/WGSL shader.
Blit_Uniforms :: struct #align(16) {
	screen_size:   [2]f32,
	dest_rect:     [4]f32,
	clip_rect:     [4]f32,
	opacity:       f32,
	corner_radius: f32,
}
#assert(size_of(Blit_Uniforms) == 48)

Blit_Slot :: struct {
	uniform_buffer: contract.Gpu_Buffer,
	bind_group:     contract.Gpu_BindGroup,
	bound_view:     contract.Gpu_TextureView,
	bound_version:  u32,
	last_uniforms:  Blit_Uniforms,
	has_uniforms:   bool,
}

Blit_Pipeline :: struct {
	device:        contract.Gpu_Device,
	queue:         contract.Gpu_Queue,
	pipeline:      contract.Gpu_RenderPipeline,
	bind_layout:   contract.Gpu_BindGroupLayout,
	shader_module: contract.Gpu_ShaderModule,
	sampler:       contract.Gpu_Sampler,
	slots:         [layer.MAX_COMPOSER_LAYERS]Blit_Slot,
	format:        contract.Gpu_Format,
	available:     bool,
}

// blit_pipeline_init compiles shader modules, builds graphics pipeline, allocates uniform buffers,
// and prepares slot states for multi-pane layer compositing.
blit_pipeline_init :: proc(
	p: ^Blit_Pipeline,
	device: contract.Gpu_Device,
	queue: contract.Gpu_Queue,
	format: contract.Gpu_Format,
) -> bool {
	if p == nil || rawptr(device) == nil || rawptr(queue) == nil do return false

	p^ = {}
	p.device = device
	p.queue = queue
	p.format = format

	// Allocate sampler for layer texture sampling
	p.sampler = contract.create_sampler(device)
	if rawptr(p.sampler) == nil {
		blit_pipeline_destroy(p)
		return false
	}

	// Preallocate per-slot uniform buffers (steady-state zero heap allocation)
	u_usage := contract.Gpu_Buffer_Usage.Uniform | contract.Gpu_Buffer_Usage.Copy_Dst
	for i in 0..<layer.MAX_COMPOSER_LAYERS {
		p.slots[i].uniform_buffer = contract.create_buffer(device, size_of(Blit_Uniforms), u_usage, false)
		if rawptr(p.slots[i].uniform_buffer) == nil {
			blit_pipeline_destroy(p)
			return false
		}
	}

	// Create shader module matching active GPU backend language
	p.shader_module = contract.create_shader_module(device, COMPOSER_BLIT_WGSL)
	if rawptr(p.shader_module) == nil {
		blit_pipeline_destroy(p)
		return false
	}

	// Create render pipeline with procedural quad vertex generation
	p.pipeline = contract.create_render_pipeline(
		device,
		p.shader_module,
		"vs_main",
		p.shader_module,
		"fs_main",
		nil, // Procedural vertex generation from vid (zero vertex buffer overhead)
		format,
		.Alpha_Blend,
		.Triangle_List,
	)
	if rawptr(p.pipeline) == nil {
		blit_pipeline_destroy(p)
		return false
	}

	// Derive or create bind group layout:
	// binding(0): Uniform_Buffer (Vertex | Fragment)
	// binding(1): Sampled_Texture (Fragment)
	// binding(2): Sampler (Fragment)
	if contract.pipeline_get_bind_group_layout != nil {
		p.bind_layout = contract.pipeline_get_bind_group_layout(p.pipeline, 0)
	}
	if rawptr(p.bind_layout) == nil {
		layout_entries := []contract.Gpu_Bind_Layout_Entry{
			{binding = 0, visibility = 1 | 2, binding_type = .Uniform_Buffer},
			{binding = 1, visibility = 2,     binding_type = .Sampled_Texture},
			{binding = 2, visibility = 2,     binding_type = .Sampler},
		}
		p.bind_layout = contract.create_bind_group_layout(device, layout_entries)
	}
	if rawptr(p.bind_layout) == nil {
		blit_pipeline_destroy(p)
		return false
	}

	p.available = true
	return true
}

// blit_pipeline_destroy releases all GPU resources across all slots.
blit_pipeline_destroy :: proc(p: ^Blit_Pipeline) {
	if p == nil do return

	for i in 0..<layer.MAX_COMPOSER_LAYERS {
		if rawptr(p.slots[i].bind_group) != nil {
			contract.destroy_bind_group(p.slots[i].bind_group)
			p.slots[i].bind_group = contract.Gpu_BindGroup(nil)
		}
		if rawptr(p.slots[i].uniform_buffer) != nil {
			contract.destroy_buffer(p.slots[i].uniform_buffer)
			p.slots[i].uniform_buffer = contract.Gpu_Buffer(nil)
		}
		p.slots[i].bound_view = contract.Gpu_TextureView(nil)
		p.slots[i].bound_version = 0
		p.slots[i].has_uniforms = false
		p.slots[i].last_uniforms = {}
	}

	if rawptr(p.sampler) != nil {
		contract.destroy_sampler(p.sampler)
		p.sampler = contract.Gpu_Sampler(nil)
	}
	if rawptr(p.bind_layout) != nil {
		contract.destroy_bind_group_layout(p.bind_layout)
		p.bind_layout = contract.Gpu_BindGroupLayout(nil)
	}
	if rawptr(p.pipeline) != nil {
		contract.destroy_render_pipeline(p.pipeline)
		p.pipeline = contract.Gpu_RenderPipeline(nil)
	}
	if rawptr(p.shader_module) != nil {
		contract.destroy_shader_module(p.shader_module)
		p.shader_module = contract.Gpu_ShaderModule(nil)
	}

	p.available = false
	p^ = {}
}

// blit_pipeline_bind_layer binds a layer's texture view into the specified slot's bind group.
// Caches existing bind group if texture view hasn't changed.
blit_pipeline_bind_layer :: proc(p: ^Blit_Pipeline, slot_idx: int, view: contract.Gpu_TextureView, version: u32 = 0) -> bool {
	if p == nil || !p.available || rawptr(p.device) == nil do return false
	if slot_idx < 0 || slot_idx >= layer.MAX_COMPOSER_LAYERS || rawptr(view) == nil do return false

	slot := &p.slots[slot_idx]
	if slot.bound_view == view && slot.bound_version == version && rawptr(slot.bind_group) != nil {
		return true
	}

	if rawptr(slot.bind_group) != nil {
		contract.destroy_bind_group(slot.bind_group)
		slot.bind_group = contract.Gpu_BindGroup(nil)
		slot.bound_view = contract.Gpu_TextureView(nil)
		slot.bound_version = 0
	}

	entries := []contract.Gpu_Bind_Entry{
		{
			binding    = 0,
			buffer     = slot.uniform_buffer,
			size       = size_of(Blit_Uniforms),
			entry_type = .Buffer,
		},
		{
			binding    = 1,
			view       = view,
			entry_type = .Texture_View,
		},
		{
			binding    = 2,
			sampler    = p.sampler,
			entry_type = .Sampler,
		},
	}
	slot.bind_group = contract.create_bind_group(p.device, p.bind_layout, entries)
	if rawptr(slot.bind_group) == nil do return false

	slot.bound_view = view
	slot.bound_version = version
	return true
}

// blit_layer encodes a single layer quad blit into the render pass.
// Dispatches 6 procedural vertices with scissor clipping and SDF corner rounding.
blit_layer :: proc(
	p: ^Blit_Pipeline,
	pass: contract.Gpu_RenderPassEncoder,
	slot_idx: int,
	layer_ptr: ^composer.Composer_Layer,
	screen_w, screen_h: f32,
) -> bool {
	if p == nil || !p.available || rawptr(pass) == nil || layer_ptr == nil do return false
	if slot_idx < 0 || slot_idx >= layer.MAX_COMPOSER_LAYERS do return false
	if screen_w <= 0.0 || screen_h <= 0.0 do return false
	if layer_ptr.dest_rect.w <= 0.0 || layer_ptr.dest_rect.h <= 0.0 do return false
	if rawptr(layer_ptr.view) == nil do return false

	slot := &p.slots[slot_idx]
	if slot.bound_view != layer_ptr.view || slot.bound_version != layer_ptr.version || rawptr(slot.bind_group) == nil {
		if !blit_pipeline_bind_layer(p, slot_idx, layer_ptr.view, layer_ptr.version) do return false
	}

	scissor := layer_ptr.scissor_rect
	if scissor.w <= 0.0 || scissor.h <= 0.0 {
		scissor = layer_ptr.dest_rect
	}

	scissor.x = clamp(scissor.x, 0.0, screen_w)
	scissor.y = clamp(scissor.y, 0.0, screen_h)
	scissor.w = clamp(scissor.w, 0.0, screen_w)
	scissor.h = clamp(scissor.h, 0.0, screen_h)

	uniforms := Blit_Uniforms{
		screen_size   = {screen_w, screen_h},
		dest_rect     = {layer_ptr.dest_rect.x, layer_ptr.dest_rect.y, layer_ptr.dest_rect.w, layer_ptr.dest_rect.h},
		clip_rect     = {scissor.x, scissor.y, scissor.w, scissor.h},
		opacity       = layer_ptr.opacity,
		corner_radius = layer_ptr.corner_radius,
	}

	if !slot.has_uniforms || slot.last_uniforms != uniforms {
		contract.write_buffer(p.queue, slot.uniform_buffer, 0, &uniforms, size_of(Blit_Uniforms))
		slot.last_uniforms = uniforms
		slot.has_uniforms = true
	}

	contract.render_set_bind_group(pass, 0, slot.bind_group)
	contract.render_draw(pass, 6, 1)
	return true
}
