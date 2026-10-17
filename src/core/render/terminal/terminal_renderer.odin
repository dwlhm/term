package render_terminal

// Terminal Content Pillar - Unified Multi-Strategy GPU Renderer Facade.
// Part of Tier 1 Autonomous Core Render Engine (src/core/render/terminal/*).
//
// Unifies:
//   Strategy A: Instanced Quad Batching (`instance/`) — < 3% damage, cursor, emoji overlay.
//   Strategy B: Compute Tile Binning (`tile/`) — 3% - 65% damage, 16x16 tile binning.
//   Strategy C: Fullscreen Direct Quad (`fullscreen/`) — >= 65% damage / flood scroll.
//   Adaptive Online Selector (`selector.odin`) — Selects optimal strategy in ~35.9ns.
//
// Invariant: ZERO OS/Platform dependencies, ZERO heap allocations during per-frame render loop.

import "base:runtime"
import "core:math"
import "core:time"
import contract "../contract"
import atlas "../atlas"
import "instance"
import "tile"
import "fullscreen"
import core_terminal "../../terminal"
import cell "../../terminal/cell"
import damage "../../terminal/damage"
import plat_font "../../../platform/font"

GLYPH_WGSL        :: #load("../shaders/glyph.wgsl", string)
BG_WGSL           :: #load("../shaders/bg.wgsl", string)
EMOJI_WGSL        :: #load("../shaders/emoji.wgsl", string)
TILE_COMPUTE_WGSL :: #load("../shaders/tile_compute.wgsl", string)
TILE_BLIT_WGSL    :: #load("../shaders/tile_blit.wgsl", string)
FULLSCREEN_WGSL   :: #load("../shaders/fullscreen.wgsl", string)

RAW_PALETTE_COLORS: [16][3]u8 = {
	{20, 23, 31},    // 0: Default Dark Background ({0.08, 0.09, 0.12})
	{224, 108, 117}, // 1: Red
	{152, 195, 121}, // 2: Green
	{229, 192, 123}, // 3: Yellow
	{97, 175, 239},  // 4: Blue
	{198, 120, 221}, // 5: Magenta
	{86, 182, 194},  // 6: Cyan
	{171, 178, 191}, // 7: Light Gray
	{92, 99, 112},   // 8: Dark Gray
	{255, 120, 130}, // 9: Bright Red
	{170, 220, 130}, // 10: Bright Green
	{255, 210, 130}, // 11: Bright Yellow
	{110, 190, 255}, // 12: Bright Blue
	{220, 140, 240}, // 13: Bright Magenta
	{100, 200, 220}, // 14: Bright Cyan
	{240, 240, 245}, // 15: Bright White
}

PALETTE_PRECOMPUTED: [16][4]f32

rgb_to_r5g6b5 :: #force_inline proc "contextless" (r, g, b: u8) -> u16 {
	r5 := (u16(r) * 31 + 127) / 255
	g6 := (u16(g) * 63 + 127) / 255
	b5 := (u16(b) * 31 + 127) / 255
	return (r5 << 11) | (g6 << 5) | b5
}

unpack_r5g6b5 :: #force_inline proc "contextless" (packed: u16) -> [4]f32 {
	r := math.round(f32((packed >> 11) & 0x1F) / 31.0 * 255.0) / 255.0
	g := math.round(f32((packed >> 5) & 0x3F) / 63.0 * 255.0) / 255.0
	b := math.round(f32(packed & 0x1F) / 31.0 * 255.0) / 255.0
	return {r, g, b, 1.0}
}

init_style_lut :: proc(lut: ^[1025]u32) {
	for i in 0..<16 {
		c := RAW_PALETTE_COLORS[i]
		PALETTE_PRECOMPUTED[i] = unpack_r5g6b5(rgb_to_r5g6b5(c[0], c[1], c[2]))
	}

	fg_packed: [1024]u16
	bg_packed: [1024]u16

	for s in 0..<1024 {
		fg_idx := s & 15
		bg_idx := (s >> 4) & 15
		if s == 0 {
			fg_idx = 15
			bg_idx = 0
		}
		fg_c := RAW_PALETTE_COLORS[fg_idx]
		bg_c := RAW_PALETTE_COLORS[bg_idx]
		fg_packed[s] = rgb_to_r5g6b5(fg_c[0], fg_c[1], fg_c[2])
		bg_packed[s] = rgb_to_r5g6b5(bg_c[0], bg_c[1], bg_c[2])
	}

	for i in 0..<512 {
		w_fg := u32(fg_packed[i * 2]) | (u32(fg_packed[i * 2 + 1]) << 16)
		lut[i] = w_fg
		w_bg := u32(bg_packed[i * 2]) | (u32(bg_packed[i * 2 + 1]) << 16)
		lut[512 + i] = w_bg
	}

	sel_fg := rgb_to_r5g6b5(255, 255, 255)
	sel_bg := rgb_to_r5g6b5(60, 100, 180)
	lut[1024] = u32(sel_fg) | (u32(sel_bg) << 16)
}

Terminal_Renderer :: struct {
	device:             contract.Gpu_Device,
	queue:              contract.Gpu_Queue,
	format:             contract.Gpu_Format,

	// Strategy A: Instanced Quad Batching
	inst_rend:          instance.Instance_Renderer,
	glyph_pipeline:     contract.Gpu_RenderPipeline,
	glyph_layout:       contract.Gpu_BindGroupLayout,
	bg_pipeline:        contract.Gpu_RenderPipeline,
	bg_layout:          contract.Gpu_BindGroupLayout,

	// Dedicated RGBA8 Color Emoji Batching
	emoji_rend:         instance.Instance_Renderer,
	emoji_pipeline:     contract.Gpu_RenderPipeline,
	emoji_layout:       contract.Gpu_BindGroupLayout,

	// Strategy B: Compute Tile Binning (16x16 pixel tiles)
	tile_rend:          tile.Compute_Tile_Renderer,
	compute_pipeline:   contract.Gpu_ComputePipeline,
	compute_layout:     contract.Gpu_BindGroupLayout,
	blit_pipeline:      contract.Gpu_RenderPipeline,
	blit_layout:        contract.Gpu_BindGroupLayout,

	// Strategy C: Fullscreen Direct Quad
	fs_rend:            fullscreen.Fullscreen_Renderer,
	fs_pipeline:        contract.Gpu_RenderPipeline,
	fs_layout:          contract.Gpu_BindGroupLayout,
	fs_color_buffer:    contract.Gpu_Buffer,

	// Shared LUT & Adaptive Strategy Selector State
	lut_words:          [1025]u32,
	last_default_bg_packed: u16,
	strat_state:        Strategy_State,
	last_strategy:      Render_Strategy,
	last_duration_ns:   u64,
	last_dirty_cells:   int,

	// Resource Binding & Tile Cache Tracking
	bound_atlas_view:   contract.Gpu_TextureView,
	bound_emoji_view:   contract.Gpu_TextureView,
	last_term_ptr:      rawptr,
	last_scroll_offset: int,
	tile_fb_valid:      bool,

	// Scratch Storage Buffers (Preallocated for zero heap allocations)
	packed_cells:       [dynamic]u64,
	direct_colors:      [dynamic]u32,
	dirty_tiles:        [dynamic]u32,

	available:          bool,
	allocator:          runtime.Allocator,
}

_pack_gpu_cell :: #force_inline proc "contextless" (
	content: u32,
	style:   u32,
	width:   u32,
	cflags:  u32,
	slot:    u32,
) -> u64 {
	lo := (content & 0x1FFFFF) | ((style & 0x3FF) << 21) | ((width & 1) << 31)
	hi := ((width >> 1) & 1) | ((cflags & 0x7F) << 1) | ((slot & 0x1FF) << 8)
	return u64(lo) | (u64(hi) << 32)
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

_create_triangle_pipeline :: proc(
	device: contract.Gpu_Device,
	wgsl_src: string,
	vs_entry: string,
	fs_entry: string,
	format: contract.Gpu_Format,
) -> (pipeline: contract.Gpu_RenderPipeline, layout: contract.Gpu_BindGroupLayout, ok: bool) {
	module := contract.create_shader_module(device, wgsl_src)
	if rawptr(module) == nil do return {}, {}, false
	defer contract.destroy_shader_module(module)

	pipeline = contract.create_render_pipeline(
		device, module, vs_entry, module, fs_entry, nil, format, .Alpha_Blend, .Triangle_List,
	)
	if rawptr(pipeline) == nil do return {}, {}, false
	layout = contract.pipeline_get_bind_group_layout(pipeline, 0)
	return pipeline, layout, true
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
	if r == nil || rawptr(device) == nil || rawptr(queue) == nil do return false
	r.device = device
	r.queue = queue
	r.format = format
	r.allocator = allocator
	r.last_strategy = .Instance
	r.last_duration_ns = 0

	init_style_lut(&r.lut_words)

	// 1. Initialize Strategy A (Glyph & BG Instance Batching)
	glyph_attrs := []contract.Gpu_Vertex_Attribute{
		{format = .Float32x2, offset = 0, shader_location = 0},
		{format = .Float32x2, offset = 8, shader_location = 1},
		{format = .Float32x4, offset = 16, shader_location = 2},
		{format = .Float32x4, offset = 32, shader_location = 3},
	}
	var_glyph_ok: bool
	r.glyph_pipeline, r.glyph_layout, var_glyph_ok = _create_instance_pipeline(device, GLYPH_WGSL, glyph_attrs, format)
	if !var_glyph_ok do return false

	bg_attrs := []contract.Gpu_Vertex_Attribute{
		{format = .Float32x2, offset = 0, shader_location = 0},
		{format = .Float32x2, offset = 8, shader_location = 1},
		{format = .Float32x4, offset = 16, shader_location = 2},
		{format = .Float32x4, offset = 48, shader_location = 3},
	}
	var_bg_ok: bool
	r.bg_pipeline, r.bg_layout, var_bg_ok = _create_instance_pipeline(device, BG_WGSL, bg_attrs, format)
	if !var_bg_ok do return false

	if !instance.instance_renderer_init(&r.inst_rend, device, queue, 16384, atlas_view, format) {
		return false
	}

	entries := []contract.Gpu_Bind_Entry{
		{binding = 0, buffer = r.inst_rend.uniform_buffer, offset = 0, size = 0, entry_type = .Buffer},
		{binding = 1, view = atlas_view, entry_type = .Texture_View},
		{binding = 2, sampler = r.inst_rend.sampler, entry_type = .Sampler},
	}
	r.inst_rend.bind_group = contract.create_bind_group(device, r.glyph_layout, entries)

	bg_entries := []contract.Gpu_Bind_Entry{
		{binding = 0, buffer = r.inst_rend.uniform_buffer, offset = 0, size = 0, entry_type = .Buffer},
	}
	r.inst_rend.bg_bind_group = contract.create_bind_group(device, r.bg_layout, bg_entries)
	r.inst_rend.pipeline = r.glyph_pipeline

	// 2. Initialize Dedicated Emoji Instance Batching
	var_emoji_ok: bool
	r.emoji_pipeline, r.emoji_layout, var_emoji_ok = _create_instance_pipeline(device, EMOJI_WGSL, glyph_attrs, format)
	if !var_emoji_ok do return false

	if !instance.instance_renderer_init(&r.emoji_rend, device, queue, 4096, emoji_view, format) {
		return false
	}

	emoji_entries := []contract.Gpu_Bind_Entry{
		{binding = 0, buffer = r.emoji_rend.uniform_buffer, offset = 0, size = 0, entry_type = .Buffer},
		{binding = 1, view = emoji_view, entry_type = .Texture_View},
		{binding = 2, sampler = r.emoji_rend.sampler, entry_type = .Sampler},
	}
	r.emoji_rend.bind_group = contract.create_bind_group(device, r.emoji_layout, emoji_entries)
	r.emoji_rend.pipeline = r.emoji_pipeline

	// 3. Initialize Strategy B (Compute Tile Binning)
	compute_mod := contract.create_shader_module(device, TILE_COMPUTE_WGSL)
	if rawptr(compute_mod) != nil {
		r.compute_pipeline = contract.create_compute_pipeline(device, compute_mod, "cs_main")
		if rawptr(r.compute_pipeline) != nil {
			r.compute_layout = contract.compute_get_bind_group_layout(r.compute_pipeline, 0)
		}
		contract.destroy_shader_module(compute_mod)
	}

	var_blit_ok: bool
	r.blit_pipeline, r.blit_layout, var_blit_ok = _create_triangle_pipeline(device, TILE_BLIT_WGSL, "vs_main", "fs_main", format)
	_ = var_blit_ok

	_ = tile.compute_tile_init(&r.tile_rend, device, queue, 24, 80, 10.0, 20.0, atlas_view, format, allocator)
	r.tile_rend.compute_pipeline = r.compute_pipeline
	r.tile_rend.compute_layout = r.compute_layout
	r.tile_rend.blit_pipeline = r.blit_pipeline
	r.tile_rend.blit_layout = r.blit_layout

	// 4. Initialize Strategy C (Fullscreen Direct Triangle)
	var_fs_ok: bool
	r.fs_pipeline, r.fs_layout, var_fs_ok = _create_triangle_pipeline(device, FULLSCREEN_WGSL, "fullscreen_vs_main", "fullscreen_fs_main", format)
	_ = var_fs_ok

	_ = fullscreen.fullscreen_init(&r.fs_rend, device, queue, 24, 80, 10.0, 20.0, atlas_view, format, allocator)
	r.fs_rend.pipeline = r.fs_pipeline
	r.fs_rend.layout = r.fs_layout

	// Upload initial LUT palette to compute and fullscreen storage buffers
	r.last_default_bg_packed = u16(r.lut_words[512] & 0xFFFF)
	if rawptr(r.tile_rend.lut_buffer) != nil {
		contract.write_buffer(queue, r.tile_rend.lut_buffer, 0, &r.lut_words, size_of(r.lut_words))
	}
	if rawptr(r.fs_rend.lut_buffer) != nil {
		contract.write_buffer(queue, r.fs_rend.lut_buffer, 0, &r.lut_words, size_of(r.lut_words))
	}

	// Preallocate scratch arrays (up to 500 cols x 200 rows without steady-state realloc)
	initial_capacity := 500 * 200
	r.packed_cells = make([dynamic]u64, 80 * 24, initial_capacity, allocator)
	r.direct_colors = make([dynamic]u32, 80 * 24 * 2, initial_capacity * 2, allocator)
	r.dirty_tiles = make([dynamic]u32, 0, initial_capacity / 16, allocator)

	r.bound_atlas_view = atlas_view
	r.bound_emoji_view = emoji_view
	_terminal_renderer_ensure_resources(r, 80, 24, 10.0, 20.0, atlas_view, emoji_view)

	r.available = true
	return true
}

terminal_renderer_destroy :: proc(r: ^Terminal_Renderer) {
	if r == nil do return

	// Prevent double-free of shared pipelines owned by Terminal_Renderer
	r.tile_rend.compute_pipeline = contract.Gpu_ComputePipeline(nil)
	r.tile_rend.blit_pipeline = contract.Gpu_RenderPipeline(nil)
	r.fs_rend.pipeline = contract.Gpu_RenderPipeline(nil)
	r.fs_rend.layout = contract.Gpu_BindGroupLayout(nil)

	instance.instance_renderer_destroy(&r.inst_rend)
	instance.instance_renderer_destroy(&r.emoji_rend)
	tile.compute_tile_destroy(&r.tile_rend)
	fullscreen.fullscreen_destroy(&r.fs_rend)

	if rawptr(r.glyph_pipeline) != nil do contract.destroy_render_pipeline(r.glyph_pipeline)
	if rawptr(r.bg_pipeline) != nil do contract.destroy_render_pipeline(r.bg_pipeline)
	if rawptr(r.emoji_pipeline) != nil do contract.destroy_render_pipeline(r.emoji_pipeline)
	if rawptr(r.blit_pipeline) != nil do contract.destroy_render_pipeline(r.blit_pipeline)
	if rawptr(r.fs_pipeline) != nil do contract.destroy_render_pipeline(r.fs_pipeline)
	if rawptr(r.compute_pipeline) != nil do contract.destroy_compute_pipeline(r.compute_pipeline)
	if rawptr(r.fs_color_buffer) != nil do contract.destroy_buffer(r.fs_color_buffer)

	if rawptr(r.glyph_layout) != nil && contract.destroy_bind_group_layout != nil do contract.destroy_bind_group_layout(r.glyph_layout)
	if rawptr(r.bg_layout) != nil && contract.destroy_bind_group_layout != nil do contract.destroy_bind_group_layout(r.bg_layout)
	if rawptr(r.emoji_layout) != nil && contract.destroy_bind_group_layout != nil do contract.destroy_bind_group_layout(r.emoji_layout)
	if rawptr(r.blit_layout) != nil && contract.destroy_bind_group_layout != nil do contract.destroy_bind_group_layout(r.blit_layout)
	if rawptr(r.fs_layout) != nil && contract.destroy_bind_group_layout != nil do contract.destroy_bind_group_layout(r.fs_layout)
	if rawptr(r.compute_layout) != nil && contract.destroy_bind_group_layout != nil do contract.destroy_bind_group_layout(r.compute_layout)

	delete(r.packed_cells)
	delete(r.direct_colors)
	delete(r.dirty_tiles)

	r.available = false
}

_terminal_renderer_ensure_resources :: proc(
	r: ^Terminal_Renderer,
	cols, rows: u32,
	cell_w, cell_h: f32,
	atlas_view: contract.Gpu_TextureView,
	emoji_view: contract.Gpu_TextureView,
) {
	if r == nil || cols == 0 || rows == 0 do return

	total_cells := int(cols * rows)
	if len(r.packed_cells) < total_cells {
		resize(&r.packed_cells, total_cells)
	}
	if len(r.direct_colors) < total_cells * 2 {
		resize(&r.direct_colors, total_cells * 2)
	}

	atlas_changed := rawptr(atlas_view) != nil && atlas_view != r.bound_atlas_view
	emoji_changed := rawptr(emoji_view) != nil && emoji_view != r.bound_emoji_view

	if atlas_changed && rawptr(r.glyph_layout) != nil {
		if rawptr(r.inst_rend.bind_group) != nil do contract.destroy_bind_group(r.inst_rend.bind_group)
		entries := []contract.Gpu_Bind_Entry{
			{binding = 0, buffer = r.inst_rend.uniform_buffer, offset = 0, size = 0, entry_type = .Buffer},
			{binding = 1, view = atlas_view, entry_type = .Texture_View},
			{binding = 2, sampler = r.inst_rend.sampler, entry_type = .Sampler},
		}
		r.inst_rend.bind_group = contract.create_bind_group(r.device, r.glyph_layout, entries)
		r.inst_rend.atlas_view = atlas_view
	}

	if emoji_changed && rawptr(r.emoji_layout) != nil {
		if rawptr(r.emoji_rend.bind_group) != nil do contract.destroy_bind_group(r.emoji_rend.bind_group)
		emoji_entries := []contract.Gpu_Bind_Entry{
			{binding = 0, buffer = r.emoji_rend.uniform_buffer, offset = 0, size = 0, entry_type = .Buffer},
			{binding = 1, view = emoji_view, entry_type = .Texture_View},
			{binding = 2, sampler = r.emoji_rend.sampler, entry_type = .Sampler},
		}
		r.emoji_rend.bind_group = contract.create_bind_group(r.device, r.emoji_layout, emoji_entries)
		r.emoji_rend.atlas_view = emoji_view
	}

	exact_w := max(u32(f32(cols) * cell_w), 1)
	exact_h := max(u32(f32(rows) * cell_h), 1)

	grid_changed := cols != r.tile_rend.cols || rows != r.tile_rend.rows
	fb_changed := exact_w != r.tile_rend.fb_w_px || exact_h != r.tile_rend.fb_h_px

	// Ensure shared direct_colors GPU buffer & Strategy C (Fullscreen) GPU resources first
	if grid_changed || atlas_changed || rawptr(r.fs_rend.bind_group) == nil || rawptr(r.fs_color_buffer) == nil {
		r.fs_rend.cols = cols
		r.fs_rend.rows = rows
		r.fs_rend.cell_w = cell_w
		r.fs_rend.cell_h = cell_h

		cell_bytes := u64(cols * rows) * fullscreen.FULLSCREEN_CELL_BYTES
		if grid_changed || rawptr(r.fs_rend.cell_buffer) == nil {
			if rawptr(r.fs_rend.cell_buffer) != nil do contract.destroy_buffer(r.fs_rend.cell_buffer)
			r.fs_rend.cell_buffer = contract.create_buffer(r.device, cell_bytes, .Storage | .Copy_Dst, false)
		}
		if grid_changed || rawptr(r.fs_color_buffer) == nil {
			if rawptr(r.fs_color_buffer) != nil do contract.destroy_buffer(r.fs_color_buffer)
			r.fs_color_buffer = contract.create_buffer(r.device, cell_bytes, .Storage | .Copy_Dst, false)
		}

		if rawptr(r.fs_rend.bind_group) != nil do contract.destroy_bind_group(r.fs_rend.bind_group)
		if rawptr(r.fs_layout) != nil && rawptr(atlas_view) != nil && rawptr(r.fs_color_buffer) != nil {
			fs_entries := []contract.Gpu_Bind_Entry{
				{binding = 0, buffer = r.fs_rend.params_buffer, offset = 0, size = 0, entry_type = .Buffer},
				{binding = 1, buffer = r.fs_rend.cell_buffer, offset = 0, size = 0, entry_type = .Buffer},
				{binding = 2, buffer = r.fs_rend.lut_buffer, offset = 0, size = 0, entry_type = .Buffer},
				{binding = 3, view = atlas_view, entry_type = .Texture_View},
				{binding = 4, sampler = r.fs_rend.sampler, entry_type = .Sampler},
				{binding = 5, buffer = r.fs_color_buffer, offset = 0, size = 0, entry_type = .Buffer},
			}
			r.fs_rend.bind_group = contract.create_bind_group(r.device, r.fs_layout, fs_entries)
		}
		r.fs_rend.available = rawptr(r.fs_rend.bind_group) != nil
	}

	// Ensure Strategy B (Compute_Tiles) GPU resources & bind groups (binding 7 shares r.fs_color_buffer)
	if grid_changed || fb_changed || atlas_changed || rawptr(r.tile_rend.compute_bind_group) == nil || rawptr(r.tile_rend.blit_bind_group) == nil {
		r.tile_rend.cols = cols
		r.tile_rend.rows = rows
		r.tile_rend.cell_w = cell_w
		r.tile_rend.cell_h = cell_h
		r.tile_rend.tile_w = tile.TILE_DEFAULT_W
		r.tile_rend.tile_h = tile.TILE_DEFAULT_H
		r.tile_rend.tiles_x = max((cols + r.tile_rend.tile_w - 1) / r.tile_rend.tile_w, 1)
		r.tile_rend.tiles_y = max((rows + r.tile_rend.tile_h - 1) / r.tile_rend.tile_h, 1)
		r.tile_rend.tile_count = r.tile_rend.tiles_x * r.tile_rend.tiles_y

		if rawptr(r.tile_rend.framebuffer) == nil || fb_changed {
			if rawptr(r.tile_rend.fb_view) != nil do contract.destroy_texture_view(r.tile_rend.fb_view)
			if rawptr(r.tile_rend.framebuffer) != nil do contract.destroy_texture(r.tile_rend.framebuffer)
			r.tile_rend.fb_w_px = exact_w
			r.tile_rend.fb_h_px = exact_h
			usage := contract.Gpu_Texture_Usage.Storage_Binding |
			         contract.Gpu_Texture_Usage.Texture_Binding |
			         contract.Gpu_Texture_Usage.Copy_Src
			r.tile_rend.framebuffer = contract.create_texture(r.device, exact_w, exact_h, .RGBA8_Unorm, usage)
			r.tile_rend.fb_view = contract.create_texture_view(r.tile_rend.framebuffer)
		}

		if grid_changed || rawptr(r.tile_rend.cell_buffer) == nil {
			if rawptr(r.tile_rend.cell_buffer) != nil do contract.destroy_buffer(r.tile_rend.cell_buffer)
			cell_bytes := u64(cols * rows) * tile.TILE_CELL_BYTES
			r.tile_rend.cell_buffer = contract.create_buffer(r.device, cell_bytes, .Storage | .Copy_Dst, false)

			if rawptr(r.tile_rend.tile_list_buffer) != nil do contract.destroy_buffer(r.tile_rend.tile_list_buffer)
			tile_list_bytes := u64(r.tile_rend.tile_count) * size_of(u32)
			r.tile_rend.tile_list_buffer = contract.create_buffer(r.device, tile_list_bytes, .Storage | .Copy_Dst, false)
		}

		if rawptr(r.tile_rend.compute_bind_group) != nil do contract.destroy_bind_group(r.tile_rend.compute_bind_group)
		if rawptr(r.tile_rend.blit_bind_group) != nil do contract.destroy_bind_group(r.tile_rend.blit_bind_group)

		if rawptr(r.compute_layout) != nil && rawptr(atlas_view) != nil && rawptr(r.tile_rend.fb_view) != nil && rawptr(r.fs_color_buffer) != nil {
			c_entries := []contract.Gpu_Bind_Entry{
				{binding = 0, buffer = r.tile_rend.params_buffer, offset = 0, size = 0, entry_type = .Buffer},
				{binding = 1, buffer = r.tile_rend.tile_list_buffer, offset = 0, size = 0, entry_type = .Buffer},
				{binding = 2, buffer = r.tile_rend.cell_buffer, offset = 0, size = 0, entry_type = .Buffer},
				{binding = 3, buffer = r.tile_rend.lut_buffer, offset = 0, size = 0, entry_type = .Buffer},
				{binding = 4, view = atlas_view, entry_type = .Texture_View},
				{binding = 5, sampler = r.tile_rend.sampler, entry_type = .Sampler},
				{binding = 6, view = r.tile_rend.fb_view, entry_type = .Texture_View},
				{binding = 7, buffer = r.fs_color_buffer, offset = 0, size = 0, entry_type = .Buffer},
			}
			r.tile_rend.compute_bind_group = contract.create_bind_group(r.device, r.compute_layout, c_entries)
		}

		if rawptr(r.blit_layout) != nil && rawptr(r.tile_rend.fb_view) != nil {
			b_entries := []contract.Gpu_Bind_Entry{
				{binding = 0, view = r.tile_rend.fb_view, entry_type = .Texture_View},
				{binding = 1, sampler = r.tile_rend.sampler, entry_type = .Sampler},
			}
			r.tile_rend.blit_bind_group = contract.create_bind_group(r.device, r.blit_layout, b_entries)
		}

		r.tile_rend.available = rawptr(r.tile_rend.compute_bind_group) != nil && rawptr(r.tile_rend.blit_bind_group) != nil
		r.tile_fb_valid = false
	}

	if rawptr(atlas_view) != nil do r.bound_atlas_view = atlas_view
	if rawptr(emoji_view) != nil do r.bound_emoji_view = emoji_view
}

_terminal_renderer_resolve_colors :: #force_inline proc(
	cell_val: cell.Semantic_Cell,
	dc: cell.Direct_Color,
	is_selected: bool,
	default_bg: [4]f32,
) -> (fg, bg: [4]f32) {
	has_direct_fg := .Has_Direct_Color in cell_val.flags && dc.has_fg
	has_direct_bg := .Has_Direct_Color in cell_val.flags && dc.has_bg

	fg = {f32(dc.fg[0]) / 255.0, f32(dc.fg[1]) / 255.0, f32(dc.fg[2]) / 255.0, 1.0} if has_direct_fg else PALETTE_PRECOMPUTED[cell_val.fg & 15]
	bg = {f32(dc.bg[0]) / 255.0, f32(dc.bg[1]) / 255.0, f32(dc.bg[2]) / 255.0, 1.0} if has_direct_bg else (PALETTE_PRECOMPUTED[cell_val.bg & 15] if cell_val.bg != 0 else default_bg)

	if .Bold in cell_val.style && cell_val.fg < 8 && !has_direct_fg {
		fg = PALETTE_PRECOMPUTED[(cell_val.fg + 8) & 15]
	}
	if .Dim in cell_val.style {
		fg[0] *= 0.6; fg[1] *= 0.6; fg[2] *= 0.6
	}
	if .Invert in cell_val.style {
		fg, bg = bg, fg
	}
	if is_selected {
		fg = {1.0, 1.0, 1.0, 1.0}
		bg = {0.23, 0.39, 0.70, 0.60} // Selection blue
	}
	return fg, bg
}

_terminal_renderer_push_emoji_quad_only :: #force_inline proc(
	r: ^Terminal_Renderer,
	eg: plat_font.Emoji_Glyph,
	x_pos, y_pos, gw, cell_h: f32,
) {
	base_h := cell_h * 0.95
	scale := base_h / max(1.0, eg.height)
	draw_w := eg.width * scale
	draw_h := eg.height * scale
	offset_x := (gw - draw_w) * 0.5
	offset_y := (cell_h - draw_h) * 0.5

	emoji_rec := contract.Instance_Record{
		pos_size = {x_pos + offset_x, y_pos + offset_y, draw_w, draw_h},
		uv_rect  = {eg.u0, eg.v0, eg.u1, eg.v1},
		fg_color = {1, 1, 1, 1},
		bg_color = {0, 0, 0, 0},
	}
	instance.instance_renderer_push(&r.emoji_rend, emoji_rec)
}

_terminal_renderer_push_emoji :: #force_inline proc(
	r: ^Terminal_Renderer,
	eg: plat_font.Emoji_Glyph,
	x_pos, y_pos, gw, cell_h: f32,
	bg: [4]f32,
) {
	bg_rec := contract.Instance_Record{
		pos_size = {x_pos, y_pos, gw, cell_h},
		uv_rect  = {0, 0, 0, 0},
		fg_color = {0, 0, 0, 0},
		bg_color = bg,
	}
	instance.instance_renderer_push(&r.inst_rend, bg_rec)
	_terminal_renderer_push_emoji_quad_only(r, eg, x_pos, y_pos, gw, cell_h)
}

_terminal_renderer_push_glyph :: #force_inline proc(
	r: ^Terminal_Renderer,
	gam: ^plat_font.Glyph_Atlas_Manager,
	slot: u32,
	x_pos, y_pos, cell_h: f32,
	fg, bg: [4]f32,
) {
	slot_info := gam.atlas.slots[slot]
	rec := contract.Instance_Record{
		pos_size = {x_pos + slot_info.offset_x, y_pos, slot_info.draw_w, cell_h},
		uv_rect  = {slot_info.u0, slot_info.v0, slot_info.u1, slot_info.v1},
		fg_color = fg,
		bg_color = bg,
	}
	instance.instance_renderer_push(&r.inst_rend, rec)
}

_terminal_renderer_is_cell_selected :: #force_inline proc "contextless" (
	logical_r, c: int,
	selection_active: bool,
	sel_r_start, sel_c_start, sel_r_end, sel_c_end: int,
) -> bool {
	if !selection_active || logical_r < sel_r_start || logical_r > sel_r_end do return false
	if sel_r_start == sel_r_end && sel_c_start >= 0 && sel_c_end >= 0 {
		return c >= min(sel_c_start, sel_c_end) && c <= max(sel_c_start, sel_c_end)
	}
	if logical_r == sel_r_start && sel_c_start >= 0 do return c >= sel_c_start
	if logical_r == sel_r_end && sel_c_end >= 0 do return c <= sel_c_end
	return true
}

_float_to_argb :: #force_inline proc "contextless" (col: [4]f32) -> u32 {
	r := u32(clamp(col[0] * 255.0 + 0.5, 0.0, 255.0))
	g := u32(clamp(col[1] * 255.0 + 0.5, 0.0, 255.0))
	b := u32(clamp(col[2] * 255.0 + 0.5, 0.0, 255.0))
	return 0xFF000000 | (r << 16) | (g << 8) | b
}

_terminal_renderer_pack_grid :: proc(
	r: ^Terminal_Renderer,
	term: ^core_terminal.Terminal,
	gam: ^plat_font.Glyph_Atlas_Manager,
	emoji_atlas: ^plat_font.Emoji_Atlas_Manager,
	rows, cols: int,
	pane_rect: [4]f32,
	cell_w, cell_h: f32,
	pad_x, pad_y: f32,
	scroll_offset: int,
	active_bg: [4]f32,
	selection_active: bool,
	sel_r_start, sel_c_start, sel_r_end, sel_c_end: int,
) {
	blank_packed := _pack_gpu_cell(' ', 0, 1, 0, 0)
	for r_idx in 0..<rows {
		logical_r := r_idx - scroll_offset
		row := core_terminal.terminal_get_row(term, logical_r)
		y_pos := pane_rect[1] + pad_y + f32(r_idx) * cell_h
		row_base := r_idx * cols

		if row == nil {
			for c in 0..<cols {
				ci := row_base + c
				r.packed_cells[ci] = blank_packed
				r.direct_colors[ci * 2] = 0
				r.direct_colors[ci * 2 + 1] = 0
			}
			continue
		}

		for c in 0..<cols {
			ci := row_base + c
			if c >= len(row.cells) {
				r.packed_cells[ci] = blank_packed
				r.direct_colors[ci * 2] = 0
				r.direct_colors[ci * 2 + 1] = 0
				continue
			}

			cell_val := row.cells[c]
			is_selected := _terminal_renderer_is_cell_selected(
				logical_r, c, selection_active, sel_r_start, sel_c_start, sel_r_end, sel_c_end,
			)

			fg_idx := u32(cell_val.fg & 15)
			bg_idx := u32(cell_val.bg & 15)
			if .Bold in cell_val.style && fg_idx < 8 {
				fg_idx = (fg_idx + 8) & 15
			}
			if .Invert in cell_val.style {
				fg_idx, bg_idx = bg_idx, fg_idx
			}
			style_val := fg_idx | (bg_idx << 4)
			if style_val == 0 && (.Invert in cell_val.style || (cell_val.fg == 0 && cell_val.char > ' ')) {
				style_val |= 256
			}

			cflags: u32 = 2 if is_selected else 0
			fg_argb: u32 = 0
			bg_argb: u32 = 0

			dc: cell.Direct_Color
			if .Has_Direct_Color in cell_val.flags && c < len(row.direct_colors) {
				dc = row.direct_colors[c]
			}
			if dc.has_fg || dc.has_bg || .Dim in cell_val.style {
				cflags |= 8
				fg_col, bg_col := _terminal_renderer_resolve_colors(cell_val, dc, false, active_bg)
				if dc.has_fg || .Dim in cell_val.style || .Invert in cell_val.style {
					fg_argb = _float_to_argb(fg_col)
				}
				if dc.has_bg || .Invert in cell_val.style {
					bg_argb = _float_to_argb(bg_col)
				}
			}
			r.direct_colors[ci * 2] = fg_argb
			r.direct_colors[ci * 2 + 1] = bg_argb

			if .Wide_Continuation in cell_val.flags && c > 0 && .Wide_Lead in row.cells[c - 1].flags {
				r.packed_cells[ci] = _pack_gpu_cell(' ', style_val, 0, cflags, 0)
				continue
			}

			ch := cell_val.char
			is_wide := .Wide_Lead in cell_val.flags
			width_val: u32 = 2 if is_wide else 1
			gw := cell_w * 2.0 if is_wide else cell_w
			x_pos := pane_rect[0] + pad_x + f32(c) * cell_w

			if .Has_Egc in cell_val.flags {
				if runes := core_terminal.terminal_get_egc_runes(term, ch); len(runes) > 0 {
					if emoji_atlas != nil && plat_font.is_emoji_cluster(runes) {
						if eg, eok := plat_font.emoji_atlas_get_runes(emoji_atlas, runes); eok {
							_terminal_renderer_push_emoji_quad_only(r, eg, x_pos, y_pos, gw, cell_h)
						}
						r.packed_cells[ci] = _pack_gpu_cell(' ', style_val, 1, cflags, 0)
						continue
					}
					if slot, sok := plat_font.glyph_atlas_get_or_rasterize_cluster(gam, runes, is_wide); sok {
						r.packed_cells[ci] = _pack_gpu_cell(u32(runes[0]), style_val, width_val, cflags, slot)
						continue
					}
					ch = runes[0]
				} else {
					r.packed_cells[ci] = _pack_gpu_cell(' ', style_val, 1, cflags, 0)
					continue
				}
			}

			if emoji_atlas != nil && plat_font.is_emoji_codepoint(ch) {
				if eg, eok := plat_font.emoji_atlas_get(emoji_atlas, ch); eok {
					_terminal_renderer_push_emoji_quad_only(r, eg, x_pos, y_pos, gw, cell_h)
				}
				r.packed_cells[ci] = _pack_gpu_cell(' ', style_val, 1, cflags, 0)
				continue
			}

			if ch <= ' ' {
				r.packed_cells[ci] = _pack_gpu_cell(' ', style_val, width_val, cflags, 0)
				continue
			}

			slot, ok := plat_font.glyph_atlas_get_or_rasterize(gam, ch, is_wide)
			if !ok do slot = 0
			r.packed_cells[ci] = _pack_gpu_cell(u32(ch), style_val, width_val, cflags, slot)
		}
	}
}

// terminal_renderer_encode records the adaptive terminal compute/render passes onto a caller-provided CommandEncoder.
terminal_renderer_encode :: proc(
	r: ^Terminal_Renderer,
	enc: contract.Gpu_CommandEncoder,
	term: ^core_terminal.Terminal,
	target_view: contract.Gpu_TextureView,
	text_atlas: ^plat_font.Text_Atlas,
	pane_rect: [4]f32,
	cell_w, cell_h: f32,
	pad_x, pad_y: f32,
	scroll_offset: int,
	screen_w, screen_h: f32,
	has_custom_bg: bool,
	custom_bg: [4]f32,
	selected_logical_r_start: int = -1,
	selected_c_start: int = -1,
	selected_logical_r_end: int = -1,
	selected_c_end: int = -1,
	selection_active: bool = false,
	load_op: contract.Gpu_Load_Op = .Load,
) {
	if r == nil || rawptr(enc) == nil || term == nil || rawptr(target_view) == nil || text_atlas == nil do return

	gam := &text_atlas.glyph_atlas
	emoji_atlas := &text_atlas.emoji_atlas

	// 1. Consume Damage & Form Strategy Inputs
	journal := core_terminal.terminal_consume_damage(term)
	rows := max(1, min(term.rows, int((pane_rect[3] - 2.0 * pad_y) / cell_h)))
	cols := max(1, min(term.cols, int((pane_rect[2] - 2.0 * pad_x) / cell_w)))
	total_cells := max(1, rows * cols)

	_terminal_renderer_ensure_resources(r, u32(cols), u32(rows), cell_w, cell_h, text_atlas.glyph_view, text_atlas.emoji_view)

	dirty_cells := 0
	span_count := 0
	full_rows := 0
	if journal.has_damage {
		for r_idx in 0..<min(rows, len(journal.dirty_rows)) {
			dr := journal.dirty_rows[r_idx]
			if dr.full {
				full_rows += 1
				span_count += 1
			} else if dr.span_count > 0 {
				span_count += int(dr.span_count)
			}
		}
		dirty_w := max(1, min(journal.max_col, cols) - max(journal.min_col, 0))
		dirty_h := max(1, min(journal.max_row, rows - 1) - max(journal.min_row, 0) + 1)
		dirty_cells = min(total_cells, dirty_w * dirty_h)
	}

	strat_inp := Strategy_Inputs{
		dirty_cells = dirty_cells,
		total_cells = total_cells,
		ratio       = f32(dirty_cells) / f32(total_cells),
		full_rows   = full_rows,
		span_count  = max(1, span_count) if dirty_cells > 0 else 0,
		scroll      = (r.last_scroll_offset != scroll_offset),
	}
	r.last_dirty_cells = dirty_cells

	t_start := time.tick_now()
	chosen_strat := strategy_select(strat_inp, &r.strat_state, r.tile_rend.available, r.fs_rend.available)

	// 2. Resolve Active Background & Sync LUT Default Background across all bg_idx == 0 entries
	active_bg: [4]f32 = {0.08, 0.09, 0.12, 1.0}
	if has_custom_bg {
		active_bg = custom_bg
	} else if dc, pal, ok := core_terminal.terminal_sample_bg(term, scroll_offset); ok {
		if dc.has_bg {
			active_bg = {f32(dc.bg[0]) / 255.0, f32(dc.bg[1]) / 255.0, f32(dc.bg[2]) / 255.0, 1.0}
		} else if pal != 0 {
			active_bg = PALETTE_PRECOMPUTED[pal & 15]
		}
	}

	bg_packed := rgb_to_r5g6b5(
		u8(clamp(active_bg[0] * 255.0 + 0.5, 0.0, 255.0)),
		u8(clamp(active_bg[1] * 255.0 + 0.5, 0.0, 255.0)),
		u8(clamp(active_bg[2] * 255.0 + 0.5, 0.0, 255.0)),
	)
	if bg_packed != r.last_default_bg_packed {
		r.last_default_bg_packed = bg_packed
		for i in 0..<512 {
			s0 := i * 2
			s1 := i * 2 + 1
			w := r.lut_words[512 + i]
			if ((s0 >> 4) & 15) == 0 {
				w = (w & 0xFFFF0000) | u32(bg_packed)
			}
			if ((s1 >> 4) & 15) == 0 {
				w = (w & 0x0000FFFF) | (u32(bg_packed) << 16)
			}
			r.lut_words[512 + i] = w
		}
		if rawptr(r.tile_rend.lut_buffer) != nil {
			contract.write_buffer(r.queue, r.tile_rend.lut_buffer, 512 * size_of(u32), &r.lut_words[512], 512 * size_of(u32))
		}
		if rawptr(r.fs_rend.lut_buffer) != nil {
			contract.write_buffer(r.queue, r.fs_rend.lut_buffer, 512 * size_of(u32), &r.lut_words[512], 512 * size_of(u32))
		}
		r.tile_fb_valid = false
	}

	// 3. Prepare Instance & Emoji Uniforms + Pane Background Quad
	instance.instance_renderer_begin(&r.inst_rend)
	instance.instance_renderer_begin(&r.emoji_rend)
	u_data := [4]f32{screen_w, screen_h, cell_w, cell_h}
	contract.write_buffer(r.queue, r.inst_rend.uniform_buffer, 0, &u_data, size_of([4]f32))
	contract.write_buffer(r.queue, r.emoji_rend.uniform_buffer, 0, &u_data, size_of([4]f32))

	pane_bg := contract.Instance_Record{
		pos_size = pane_rect,
		uv_rect  = {0, 0, 0, 0},
		fg_color = {0, 0, 0, 0},
		bg_color = active_bg,
	}
	instance.instance_renderer_push(&r.inst_rend, pane_bg)

	clear_col := [4]f64{f64(active_bg[0]), f64(active_bg[1]), f64(active_bg[2]), 1.0}

	// 4. Execute Strategy-Specific Cell Preparation & Encoding
	switch chosen_strat {
	case .Instance:
		r.tile_fb_valid = false
		for r_idx in 0..<rows {
			logical_r := r_idx - scroll_offset
			row := core_terminal.terminal_get_row(term, logical_r)
			if row == nil do continue

			y_pos := pane_rect[1] + pad_y + f32(r_idx) * cell_h

			for c in 0..<cols {
				if c >= len(row.cells) do break
				cell_val := row.cells[c]

				if .Wide_Continuation in cell_val.flags {
					if c > 0 && .Wide_Lead in row.cells[c - 1].flags do continue
				}

				dc: cell.Direct_Color
				if .Has_Direct_Color in cell_val.flags && c < len(row.direct_colors) {
					dc = row.direct_colors[c]
				}

				is_selected := _terminal_renderer_is_cell_selected(
					logical_r, c, selection_active,
					selected_logical_r_start, selected_c_start, selected_logical_r_end, selected_c_end,
				)

				if !is_selected && (cell_val.char == 0 || cell_val.char == ' ') && cell_val.bg == 0 && cell_val.style == {} && !dc.has_bg {
					continue
				}

				ch := cell_val.char
				is_wide := .Wide_Lead in cell_val.flags
				gw := cell_w * 2.0 if is_wide else cell_w
				x_pos := pane_rect[0] + pad_x + f32(c) * cell_w

				fg, bg := _terminal_renderer_resolve_colors(cell_val, dc, is_selected, active_bg)

				if .Has_Egc in cell_val.flags {
					if runes := core_terminal.terminal_get_egc_runes(term, ch); len(runes) > 0 {
						handled := false
						if emoji_atlas != nil && plat_font.is_emoji_cluster(runes) {
							if eg, eok := plat_font.emoji_atlas_get_runes(emoji_atlas, runes); eok {
								_terminal_renderer_push_emoji(r, eg, x_pos, y_pos, gw, cell_h, bg)
								handled = true
							}
						}
						if !handled {
							if slot, sok := plat_font.glyph_atlas_get_or_rasterize_cluster(gam, runes, is_wide); sok {
								_terminal_renderer_push_glyph(r, gam, slot, x_pos, y_pos, cell_h, fg, bg)
								handled = true
							}
						}
						if handled do continue
						ch = runes[0]
					} else {
						continue
					}
				}

				if emoji_atlas != nil && plat_font.is_emoji_codepoint(ch) {
					if eg, eok := plat_font.emoji_atlas_get(emoji_atlas, ch); eok {
						_terminal_renderer_push_emoji(r, eg, x_pos, y_pos, gw, cell_h, bg)
					}
					continue
				}

				slot, ok := plat_font.glyph_atlas_get_or_rasterize(gam, ch, is_wide)
				if !ok do slot = 0
				_terminal_renderer_push_glyph(r, gam, slot, x_pos, y_pos, cell_h, fg, bg)
			}
		}

		if plat_font.text_atlas_sync_gpu(text_atlas, r.device, r.queue) {
			_terminal_renderer_ensure_resources(r, u32(cols), u32(rows), cell_w, cell_h, text_atlas.glyph_view, text_atlas.emoji_view)
		}
		instance.instance_renderer_flush(&r.inst_rend)
		instance.instance_renderer_flush(&r.emoji_rend)

		if r.inst_rend.active_count > 0 || r.emoji_rend.active_count > 0 || load_op == .Clear {
			pass := contract.begin_render_pass(enc, target_view, clear_col, load_op)
			if rawptr(pass) != nil {
				if r.inst_rend.active_count > 0 {
					contract.render_set_pipeline(pass, r.bg_pipeline)
					contract.render_set_bind_group(pass, 0, r.inst_rend.bg_bind_group)
					contract.render_set_vertex_buffer(pass, 0, r.inst_rend.instance_buffer, 0)
					contract.render_draw(pass, 6, r.inst_rend.active_count)

					instance.instance_renderer_draw(&r.inst_rend, pass)
				}
				if r.emoji_rend.active_count > 0 {
					instance.instance_renderer_draw(&r.emoji_rend, pass)
				}
				contract.end_render_pass(pass)
			}
		}

	case .Compute_Tiles:
		_terminal_renderer_pack_grid(
			r, term, gam, emoji_atlas, rows, cols, pane_rect, cell_w, cell_h, pad_x, pad_y,
			scroll_offset, active_bg, selection_active,
			selected_logical_r_start, selected_c_start, selected_logical_r_end, selected_c_end,
		)
		if plat_font.text_atlas_sync_gpu(text_atlas, r.device, r.queue) {
			_terminal_renderer_ensure_resources(r, u32(cols), u32(rows), cell_w, cell_h, text_atlas.glyph_view, text_atlas.emoji_view)
		}
		instance.instance_renderer_flush(&r.inst_rend)
		instance.instance_renderer_flush(&r.emoji_rend)

		contract.write_buffer(r.queue, r.tile_rend.cell_buffer, 0, raw_data(r.packed_cells[:]), u64(total_cells * size_of(u64)))
		contract.write_buffer(r.queue, r.fs_color_buffer, 0, raw_data(r.direct_colors[:]), u64(total_cells * 2 * size_of(u32)))

		clear(&r.dirty_tiles)
		full_tile_sync := !r.tile_fb_valid ||
		                  r.last_strategy != .Compute_Tiles ||
		                  r.last_term_ptr != rawptr(term) ||
		                  r.last_scroll_offset != scroll_offset ||
		                  !journal.has_damage ||
		                  journal.full_damage ||
		                  selection_active

		if full_tile_sync {
			for tid in 0..<r.tile_rend.tile_count {
				append(&r.dirty_tiles, tid)
			}
		} else {
			c0 := u32(clamp(journal.min_col, 0, cols - 1))
			c1 := u32(clamp(journal.max_col, int(c0), cols - 1))
			r0 := u32(clamp(journal.min_row, 0, rows - 1))
			r1 := u32(clamp(journal.max_row, int(r0), rows - 1))
			tx_s := c0 / r.tile_rend.tile_w
			ty_s := r0 / r.tile_rend.tile_h
			tx_e := min((c1 + r.tile_rend.tile_w) / r.tile_rend.tile_w, r.tile_rend.tiles_x)
			ty_e := min((r1 + r.tile_rend.tile_h) / r.tile_rend.tile_h, r.tile_rend.tiles_y)
			for ty in ty_s..<ty_e {
				for tx in tx_s..<tx_e {
					append(&r.dirty_tiles, ty * r.tile_rend.tiles_x + tx)
				}
			}
		}

		if len(r.dirty_tiles) > 0 {
			t_params := tile.Tile_Params{
				screen_w     = f32(r.tile_rend.fb_w_px),
				screen_h     = f32(r.tile_rend.fb_h_px),
				cols         = u32(cols),
				rows         = u32(rows),
				cell_w       = cell_w,
				cell_h       = cell_h,
				pad_x        = 0.0,
				pad_y        = 0.0,
				tile_w       = r.tile_rend.tile_w,
				tile_h       = r.tile_rend.tile_h,
				tiles_x      = r.tile_rend.tiles_x,
				tiles_y      = r.tile_rend.tiles_y,
				atlas_w      = atlas.ATLAS_WIDTH,
				atlas_h      = atlas.ATLAS_HEIGHT,
				bg_opacity   = 1.0,
				cell_opacity = 1.0,
			}
			contract.write_buffer(r.queue, r.tile_rend.params_buffer, 0, &t_params, size_of(tile.Tile_Params))
			contract.write_buffer(r.queue, r.tile_rend.tile_list_buffer, 0, raw_data(r.dirty_tiles[:]), u64(len(r.dirty_tiles) * size_of(u32)))
			tile.compute_tile_dispatch(&r.tile_rend, enc, u32(len(r.dirty_tiles)))
			r.tile_fb_valid = true
		}

		pass := contract.begin_render_pass(enc, target_view, clear_col, load_op)
		if rawptr(pass) != nil {
			// 1. Draw solid card background (covers pane padding border)
			if r.inst_rend.active_count > 0 {
				contract.render_set_pipeline(pass, r.bg_pipeline)
				contract.render_set_bind_group(pass, 0, r.inst_rend.bg_bind_group)
				contract.render_set_vertex_buffer(pass, 0, r.inst_rend.instance_buffer, 0)
				contract.render_draw(pass, 6, r.inst_rend.active_count)
			}

			// 2. Blit compute tile framebuffer into cell grid viewport
			vp_x := clamp(pane_rect[0] + pad_x, 0.0, screen_w)
			vp_y := clamp(pane_rect[1] + pad_y, 0.0, screen_h)
			vp_w := clamp(f32(r.tile_rend.fb_w_px), 1.0, max(1.0, screen_w - vp_x))
			vp_h := clamp(f32(r.tile_rend.fb_h_px), 1.0, max(1.0, screen_h - vp_y))
			if contract.render_set_viewport != nil {
				contract.render_set_viewport(pass, vp_x, vp_y, vp_w, vp_h, 0.0, 1.0)
			}
			if contract.render_set_scissor_rect != nil {
				contract.render_set_scissor_rect(pass, u32(vp_x), u32(vp_y), u32(vp_w), u32(vp_h))
			}
			contract.render_set_pipeline(pass, r.tile_rend.blit_pipeline)
			contract.render_set_bind_group(pass, 0, r.tile_rend.blit_bind_group)
			contract.render_draw(pass, 3, 1)

			// 3. Restore full-screen viewport & scissor and overlay emojis if present
			if contract.render_set_viewport != nil {
				contract.render_set_viewport(pass, 0.0, 0.0, screen_w, screen_h, 0.0, 1.0)
			}
			if contract.render_set_scissor_rect != nil {
				contract.render_set_scissor_rect(pass, 0, 0, max(1, u32(screen_w)), max(1, u32(screen_h)))
			}
			if r.emoji_rend.active_count > 0 {
				instance.instance_renderer_draw(&r.emoji_rend, pass)
			}
			contract.end_render_pass(pass)
		}

	case .Fullscreen:
		r.tile_fb_valid = false
		_terminal_renderer_pack_grid(
			r, term, gam, emoji_atlas, rows, cols, pane_rect, cell_w, cell_h, pad_x, pad_y,
			scroll_offset, active_bg, selection_active,
			selected_logical_r_start, selected_c_start, selected_logical_r_end, selected_c_end,
		)
		if plat_font.text_atlas_sync_gpu(text_atlas, r.device, r.queue) {
			_terminal_renderer_ensure_resources(r, u32(cols), u32(rows), cell_w, cell_h, text_atlas.glyph_view, text_atlas.emoji_view)
		}
		instance.instance_renderer_flush(&r.emoji_rend)

		contract.write_buffer(r.queue, r.fs_rend.cell_buffer, 0, raw_data(r.packed_cells[:]), u64(total_cells * size_of(u64)))
		contract.write_buffer(r.queue, r.fs_color_buffer, 0, raw_data(r.direct_colors[:]), u64(total_cells * 2 * size_of(u32)))

		fs_params := fullscreen.Fullscreen_Params{
			screen_w     = screen_w,
			screen_h     = screen_h,
			cols         = u32(cols),
			rows         = u32(rows),
			cell_w       = cell_w,
			cell_h       = cell_h,
			pad_x        = pane_rect[0] + pad_x,
			pad_y        = pane_rect[1] + pad_y,
			atlas_w      = atlas.ATLAS_WIDTH,
			atlas_h      = atlas.ATLAS_HEIGHT,
			bg_opacity   = 1.0,
			cell_opacity = 1.0,
		}
		contract.write_buffer(r.queue, r.fs_rend.params_buffer, 0, &fs_params, size_of(fullscreen.Fullscreen_Params))

		pass := contract.begin_render_pass(enc, target_view, clear_col, load_op)
		if rawptr(pass) != nil {
			sc_x := u32(clamp(pane_rect[0], 0.0, screen_w))
			sc_y := u32(clamp(pane_rect[1], 0.0, screen_h))
			sc_w := max(1, u32(clamp(pane_rect[2], 1.0, max(1.0, screen_w - f32(sc_x)))))
			sc_h := max(1, u32(clamp(pane_rect[3], 1.0, max(1.0, screen_h - f32(sc_y)))))
			if contract.render_set_scissor_rect != nil {
				contract.render_set_scissor_rect(pass, sc_x, sc_y, sc_w, sc_h)
			}
			fullscreen.fullscreen_draw(&r.fs_rend, pass)

			if contract.render_set_scissor_rect != nil {
				contract.render_set_scissor_rect(pass, 0, 0, max(1, u32(screen_w)), max(1, u32(screen_h)))
			}
			if r.emoji_rend.active_count > 0 {
				instance.instance_renderer_draw(&r.emoji_rend, pass)
			}
			contract.end_render_pass(pass)
		}
	}

	r.last_term_ptr = rawptr(term)
	r.last_scroll_offset = scroll_offset
	r.last_strategy = chosen_strat
	r.last_duration_ns = u64(time.tick_since(t_start))
	strategy_record(&r.strat_state, chosen_strat, r.last_duration_ns)
}

// terminal_renderer_render executes the adaptive terminal render pass using a standalone CommandEncoder.
terminal_renderer_render :: proc(
	r: ^Terminal_Renderer,
	term: ^core_terminal.Terminal,
	target_view: contract.Gpu_TextureView,
	text_atlas: ^plat_font.Text_Atlas,
	pane_rect: [4]f32,
	cell_w, cell_h: f32,
	pad_x, pad_y: f32,
	scroll_offset: int,
	screen_w, screen_h: f32,
	has_custom_bg: bool,
	custom_bg: [4]f32,
	selected_logical_r_start: int = -1,
	selected_c_start: int = -1,
	selected_logical_r_end: int = -1,
	selected_c_end: int = -1,
	selection_active: bool = false,
) {
	if r == nil || term == nil || rawptr(target_view) == nil || text_atlas == nil do return
	enc := contract.create_command_encoder(r.device)
	if rawptr(enc) == nil do return
	defer contract.release_command_encoder(enc)

	terminal_renderer_encode(
		r, enc, term, target_view, text_atlas, pane_rect, cell_w, cell_h, pad_x, pad_y,
		scroll_offset, screen_w, screen_h, has_custom_bg, custom_bg,
		selected_logical_r_start, selected_c_start, selected_logical_r_end, selected_c_end,
		selection_active, .Load,
	)

	cmd := contract.finish_command_buffer(enc)
	if rawptr(cmd) != nil {
		contract.submit(r.queue, cmd)
		contract.release_command_buffer(cmd)
	}
}
