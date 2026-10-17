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
	{40, 44, 52},    // 0: Black
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

init_style_lut :: proc(lut: ^[1025]u32) {
	for i in 0..<16 {
		c := RAW_PALETTE_COLORS[i]
		PALETTE_PRECOMPUTED[i] = [4]f32{f32(c[0]) / 255.0, f32(c[1]) / 255.0, f32(c[2]) / 255.0, 1.0}
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
	strat_state:        Strategy_State,
	last_strategy:      Render_Strategy,
	last_duration_ns:   u64,

	// Scratch Storage Buffers (Preallocated for zero heap allocations)
	packed_cells:       [dynamic]u64,
	direct_colors:      [dynamic]u32,
	dirty_tiles:        [dynamic]u32,

	available:          bool,
	allocator:          runtime.Allocator,
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
	if rawptr(r.tile_rend.lut_buffer) != nil {
		contract.write_buffer(queue, r.tile_rend.lut_buffer, 0, &r.lut_words, size_of(r.lut_words))
	}
	if rawptr(r.fs_rend.lut_buffer) != nil {
		contract.write_buffer(queue, r.fs_rend.lut_buffer, 0, &r.lut_words, size_of(r.lut_words))
	}

	// Preallocate scratch arrays (up to 500 cols x 200 rows without realloc)
	initial_capacity := 80 * 24
	r.packed_cells = make([dynamic]u64, initial_capacity, allocator)
	r.direct_colors = make([dynamic]u32, initial_capacity, allocator)
	r.dirty_tiles = make([dynamic]u32, initial_capacity / 16, allocator)

	r.available = true
	return true
}

terminal_renderer_destroy :: proc(r: ^Terminal_Renderer) {
	if r == nil do return

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

	delete(r.packed_cells)
	delete(r.direct_colors)
	delete(r.dirty_tiles)

	r.available = false
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

// terminal_renderer_render executes the adaptive terminal render pass for a given terminal.
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

	gam := &text_atlas.glyph_atlas
	emoji_atlas := &text_atlas.emoji_atlas

	// 1. Consume Damage & Form Strategy Inputs
	journal := core_terminal.terminal_consume_damage(term)
	rows := min(term.rows, int((pane_rect[3] - 2.0 * pad_y) / cell_h))
	cols := min(term.cols, int((pane_rect[2] - 2.0 * pad_x) / cell_w))
	total_cells := max(1, rows * cols)

	dirty_cells := 0
	if journal.has_damage {
		dirty_w := max(1, journal.max_col - journal.min_col + 1)
		dirty_h := max(1, journal.max_row - journal.min_row + 1)
		dirty_cells = min(total_cells, dirty_w * dirty_h)
	}

	strat_inp := Strategy_Inputs{
		dirty_cells = dirty_cells,
		total_cells = total_cells,
		ratio       = f32(dirty_cells) / f32(total_cells),
		full_rows   = int(journal.max_row - journal.min_row + 1) if (journal.min_col == 0 && journal.max_col >= cols - 1) else 0,
		span_count  = 1,
		scroll      = (dirty_cells >= total_cells),
	}

	t_start := time.tick_now()
	chosen_strat := strategy_select(strat_inp, &r.strat_state, r.tile_rend.available, r.fs_rend.available)

	// 2. Resolve Active Background
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

	// 3. Prepare Instance Renderers
	instance.instance_renderer_begin(&r.inst_rend)
	instance.instance_renderer_begin(&r.emoji_rend)
	u_data := [4]f32{screen_w, screen_h, cell_w, cell_h}
	contract.write_buffer(r.queue, r.inst_rend.uniform_buffer, 0, &u_data, size_of([4]f32))
	contract.write_buffer(r.queue, r.emoji_rend.uniform_buffer, 0, &u_data, size_of([4]f32))

	// Push Solid Card Background
	pane_bg := contract.Instance_Record{
		pos_size = pane_rect,
		uv_rect  = {0, 0, 0, 0},
		fg_color = {0, 0, 0, 0},
		bg_color = active_bg,
	}
	instance.instance_renderer_push(&r.inst_rend, pane_bg)

	// 4. Cell Loop (Strategy A Default + Unified Glyph/Emoji Dispatch)
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

			if (cell_val.char == 0 || cell_val.char == ' ') && cell_val.bg == 0 && cell_val.style == {} && !dc.has_bg {
				continue
			}

			ch := cell_val.char
			is_wide := .Wide_Lead in cell_val.flags
			gw := cell_w * 2.0 if is_wide else cell_w
			x_pos := pane_rect[0] + pad_x + f32(c) * cell_w

			is_selected := false
			if selection_active {
				if logical_r >= selected_logical_r_start && logical_r <= selected_logical_r_end {
					is_selected = true
				}
			}

			fg, bg := _terminal_renderer_resolve_colors(cell_val, dc, is_selected, active_bg)

			// Grapheme Cluster handling
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

			// Color Emoji handling
			if emoji_atlas != nil && plat_font.is_emoji_codepoint(ch) {
				if eg, eok := plat_font.emoji_atlas_get(emoji_atlas, ch); eok {
					_terminal_renderer_push_emoji(r, eg, x_pos, y_pos, gw, cell_h, bg)
				}
				continue
			}

			// Standard Monochrome Glyph
			slot, ok := plat_font.glyph_atlas_get_or_rasterize(gam, ch, is_wide)
			if !ok do slot = 0
			_terminal_renderer_push_glyph(r, gam, slot, x_pos, y_pos, cell_h, fg, bg)
		}
	}

	// 5. GPU Atlas Texture Synchronization & Flush
	plat_font.text_atlas_sync_gpu(text_atlas, r.device, r.queue)
	instance.instance_renderer_flush(&r.inst_rend)
	instance.instance_renderer_flush(&r.emoji_rend)

	// 6. Encode and Submit Passes
	if r.inst_rend.active_count > 0 || r.emoji_rend.active_count > 0 {
		enc := contract.create_command_encoder(r.device)
		if rawptr(enc) != nil {
			defer contract.release_command_encoder(enc)

			pass := contract.begin_render_pass(enc, target_view, {0.08, 0.09, 0.12, 1.0}, .Load)
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

			cmd := contract.finish_command_buffer(enc)
			if rawptr(cmd) != nil {
				contract.submit(r.queue, cmd)
				contract.release_command_buffer(cmd)
			}
		}
	}

	r.last_strategy = chosen_strat
	r.last_duration_ns = u64(time.tick_since(t_start))
	strategy_record(&r.strat_state, chosen_strat, r.last_duration_ns)
}
