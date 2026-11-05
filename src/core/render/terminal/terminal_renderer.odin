package render_terminal

// Terminal Content Pillar - Unified Instanced GPU Renderer.
// Part of Tier 1 Autonomous Core Render Engine (src/core/render/terminal/*).
//
// Invariant: ZERO OS/Platform dependencies, ZERO heap allocations during per-frame render loop.

import "base:runtime"
import contract "../contract"
import "instance"
import kitty "kitty"
import plat_font "../../../platform/font"

GLYPH_WGSL :: #load("../shaders/glyph.wgsl", string)
BG_WGSL    :: #load("../shaders/bg.wgsl", string)
EMOJI_WGSL :: #load("../shaders/emoji.wgsl", string)

Terminal_Pipelines :: struct {
	glyph_pipeline: contract.Gpu_RenderPipeline,
	glyph_layout:   contract.Gpu_BindGroupLayout,
	bg_pipeline:    contract.Gpu_RenderPipeline,
	bg_layout:      contract.Gpu_BindGroupLayout,
	emoji_pipeline: contract.Gpu_RenderPipeline,
	emoji_layout:   contract.Gpu_BindGroupLayout,
	available:      bool,
}

terminal_pipelines_init :: proc(p: ^Terminal_Pipelines, device: contract.Gpu_Device, format: contract.Gpu_Format) -> bool {
	if p == nil || rawptr(device) == nil do return false

	glyph_attrs := []contract.Gpu_Vertex_Attribute{
		{format = .Float32x2, offset = 0, shader_location = 0},
		{format = .Float32x2, offset = 8, shader_location = 1},
		{format = .Float32x4, offset = 16, shader_location = 2},
		{format = .Float32x4, offset = 32, shader_location = 3},
	}
	glyph_ok: bool
	p.glyph_pipeline, p.glyph_layout, glyph_ok = _create_instance_pipeline(device, GLYPH_WGSL, glyph_attrs, format)
	if !glyph_ok do return false

	bg_attrs := []contract.Gpu_Vertex_Attribute{
		{format = .Float32x2, offset = 0, shader_location = 0},
		{format = .Float32x2, offset = 8, shader_location = 1},
		{format = .Float32x4, offset = 16, shader_location = 2},
		{format = .Float32x4, offset = 48, shader_location = 3},
	}
	bg_ok: bool
	p.bg_pipeline, p.bg_layout, bg_ok = _create_instance_pipeline(device, BG_WGSL, bg_attrs, format)
	if !bg_ok do return false

	emoji_ok: bool
	p.emoji_pipeline, p.emoji_layout, emoji_ok = _create_instance_pipeline(device, EMOJI_WGSL, glyph_attrs, format)
	if !emoji_ok do return false

	p.available = true
	return true
}

terminal_pipelines_destroy :: proc(p: ^Terminal_Pipelines) {
	if p == nil do return
	if rawptr(p.glyph_pipeline) != nil do contract.destroy_render_pipeline(p.glyph_pipeline)
	if rawptr(p.bg_pipeline) != nil do contract.destroy_render_pipeline(p.bg_pipeline)
	if rawptr(p.emoji_pipeline) != nil do contract.destroy_render_pipeline(p.emoji_pipeline)

	if rawptr(p.glyph_layout) != nil && contract.destroy_bind_group_layout != nil do contract.destroy_bind_group_layout(p.glyph_layout)
	if rawptr(p.bg_layout) != nil && contract.destroy_bind_group_layout != nil do contract.destroy_bind_group_layout(p.bg_layout)
	if rawptr(p.emoji_layout) != nil && contract.destroy_bind_group_layout != nil do contract.destroy_bind_group_layout(p.emoji_layout)
	p.available = false
}

Terminal_Renderer :: struct {
	device:           contract.Gpu_Device,
	queue:            contract.Gpu_Queue,
	format:           contract.Gpu_Format,

	pipelines:        ^Terminal_Pipelines,
	owns_pipelines:   bool,

	inst_rend:        instance.Instance_Renderer,
	glyph_pipeline:   contract.Gpu_RenderPipeline,
	glyph_layout:     contract.Gpu_BindGroupLayout,
	bg_pipeline:      contract.Gpu_RenderPipeline,
	bg_layout:        contract.Gpu_BindGroupLayout,

	emoji_rend:       instance.Instance_Renderer,
	emoji_pipeline:   contract.Gpu_RenderPipeline,
	emoji_layout:     contract.Gpu_BindGroupLayout,

	kitty_rend:       kitty.Kitty_Renderer,

	last_duration_ns: u64,
	last_dirty_cells: int,

	bound_atlas_view: contract.Gpu_TextureView,
	bound_emoji_view: contract.Gpu_TextureView,
	ligature_cache:   plat_font.Ligature_Cache,

	available:        bool,
	allocator:        runtime.Allocator,
}

_create_instance_pipeline :: proc(
	device: contract.Gpu_Device,
	wgsl_src: string,
	attrs: []contract.Gpu_Vertex_Attribute,
	format: contract.Gpu_Format,
) -> (pipeline: contract.Gpu_RenderPipeline, layout: contract.Gpu_BindGroupLayout, ok: bool) {
	module := contract.create_shader_module(device, wgsl_src)
	if rawptr(module) == nil do return {}, {}, false
	defer contract.destroy_shader_module(module)

	layouts := []contract.Gpu_Vertex_Layout{
		{array_stride = size_of(contract.Instance_Record), step_mode = .Instance, attributes = attrs},
	}
	pipeline = contract.create_render_pipeline(
		device, module, "vs_main", module, "fs_main", layouts, format, .Alpha_Blend, .Triangle_List,
	)
	if rawptr(pipeline) == nil do return {}, {}, false
	layout = contract.pipeline_get_bind_group_layout(pipeline, 0)
	return pipeline, layout, true
}

terminal_renderer_init_with_pipelines :: proc(
	r: ^Terminal_Renderer,
	device: contract.Gpu_Device,
	queue: contract.Gpu_Queue,
	format: contract.Gpu_Format,
	atlas_view: contract.Gpu_TextureView,
	emoji_view: contract.Gpu_TextureView,
	pipes: ^Terminal_Pipelines,
	allocator: runtime.Allocator = context.allocator,
) -> bool {
	if r == nil || rawptr(device) == nil || rawptr(queue) == nil || pipes == nil || !pipes.available do return false
	r.device, r.queue, r.format, r.allocator = device, queue, format, allocator
	r.pipelines, r.owns_pipelines = pipes, false
	r.glyph_pipeline, r.glyph_layout = pipes.glyph_pipeline, pipes.glyph_layout
	r.bg_pipeline, r.bg_layout = pipes.bg_pipeline, pipes.bg_layout
	r.emoji_pipeline, r.emoji_layout = pipes.emoji_pipeline, pipes.emoji_layout

	init_palette_colors()

	if !instance.instance_renderer_init(&r.inst_rend, device, queue, 16384, atlas_view, format, allocator) do return false
	_bind_glyph_resources(r, atlas_view)

	bg_entries := []contract.Gpu_Bind_Entry{
		{binding = 0, buffer = r.inst_rend.uniform_buffer, offset = 0, size = 0, entry_type = .Buffer},
	}
	r.inst_rend.bg_bind_group = contract.create_bind_group(device, r.bg_layout, bg_entries)
	r.inst_rend.pipeline = r.glyph_pipeline

	if !instance.instance_renderer_init(&r.emoji_rend, device, queue, 4096, emoji_view, format, allocator) do return false
	_bind_emoji_resources(r, emoji_view)
	r.emoji_rend.pipeline = r.emoji_pipeline

	_ = kitty.kitty_renderer_init(&r.kitty_rend, device, queue, r.emoji_pipeline, r.emoji_layout, r.inst_rend.sampler, r.emoji_rend.uniform_buffer, allocator)
	plat_font.ligature_cache_init(&r.ligature_cache)

	r.bound_atlas_view, r.bound_emoji_view = atlas_view, emoji_view
	r.available = true
	return true
}

terminal_renderer_init :: proc(
	r: ^Terminal_Renderer,
	device: contract.Gpu_Device,
	queue: contract.Gpu_Queue,
	format: contract.Gpu_Format,
	atlas_view: contract.Gpu_TextureView,
	emoji_view: contract.Gpu_TextureView,
	allocator: runtime.Allocator = context.allocator,
) -> bool {
	pipes := new(Terminal_Pipelines, allocator)
	if !terminal_pipelines_init(pipes, device, format) {
		free(pipes, allocator)
		return false
	}
	if !terminal_renderer_init_with_pipelines(r, device, queue, format, atlas_view, emoji_view, pipes, allocator) {
		terminal_pipelines_destroy(pipes)
		free(pipes, allocator)
		return false
	}
	r.owns_pipelines = true
	return true
}

terminal_renderer_destroy :: proc(r: ^Terminal_Renderer) {
	if r == nil do return

	r.inst_rend.pipeline, r.inst_rend.layout = nil, nil
	r.emoji_rend.pipeline, r.emoji_rend.layout = nil, nil

	instance.instance_renderer_destroy(&r.inst_rend)
	instance.instance_renderer_destroy(&r.emoji_rend)
	kitty.kitty_renderer_destroy(&r.kitty_rend)

	if r.owns_pipelines && r.pipelines != nil {
		terminal_pipelines_destroy(r.pipelines)
		free(r.pipelines, r.allocator)
	}
	r^ = {}
}

@(private = "file")
_bind_glyph_resources :: proc(r: ^Terminal_Renderer, atlas_view: contract.Gpu_TextureView) {
	if rawptr(r.glyph_layout) == nil || rawptr(atlas_view) == nil do return
	if rawptr(r.inst_rend.bind_group) != nil do contract.destroy_bind_group(r.inst_rend.bind_group)
	entries := []contract.Gpu_Bind_Entry{
		{binding = 0, buffer = r.inst_rend.uniform_buffer, offset = 0, size = 0, entry_type = .Buffer},
		{binding = 1, view = atlas_view, entry_type = .Texture_View},
		{binding = 2, sampler = r.inst_rend.sampler, entry_type = .Sampler},
	}
	r.inst_rend.bind_group = contract.create_bind_group(r.device, r.glyph_layout, entries)
	r.inst_rend.atlas_view = atlas_view
}

@(private = "file")
_bind_emoji_resources :: proc(r: ^Terminal_Renderer, emoji_view: contract.Gpu_TextureView) {
	if rawptr(r.emoji_layout) == nil || rawptr(emoji_view) == nil do return
	if rawptr(r.emoji_rend.bind_group) != nil do contract.destroy_bind_group(r.emoji_rend.bind_group)
	entries := []contract.Gpu_Bind_Entry{
		{binding = 0, buffer = r.emoji_rend.uniform_buffer, offset = 0, size = 0, entry_type = .Buffer},
		{binding = 1, view = emoji_view, entry_type = .Texture_View},
		{binding = 2, sampler = r.emoji_rend.sampler, entry_type = .Sampler},
	}
	r.emoji_rend.bind_group = contract.create_bind_group(r.device, r.emoji_layout, entries)
	r.emoji_rend.atlas_view = emoji_view
}

_terminal_renderer_ensure_resources :: proc(
	r: ^Terminal_Renderer,
	cols, rows: u32,
	atlas_view: contract.Gpu_TextureView,
	emoji_view: contract.Gpu_TextureView,
) {
	if r == nil || cols == 0 || rows == 0 do return
	cells := cols * rows
	instance.instance_renderer_ensure_capacity(&r.inst_rend, max(16384, cells * 8))
	instance.instance_renderer_ensure_capacity(&r.emoji_rend, max(4096, cells))

	if rawptr(atlas_view) != nil && atlas_view != r.bound_atlas_view {
		_bind_glyph_resources(r, atlas_view)
		r.bound_atlas_view = atlas_view
	}
	if rawptr(emoji_view) != nil && emoji_view != r.bound_emoji_view {
		_bind_emoji_resources(r, emoji_view)
		r.bound_emoji_view = emoji_view
	}
}
