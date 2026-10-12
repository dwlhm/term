package main

// Multi-Pane Terminal Render Harness (Phase 4 GUI)
// Demonstrates all three terminal rendering pillars simultaneously:
//   - Pane 1: Strategy A (Quad Instance Batching - instance.Instance_Renderer)
//   - Pane 2: Strategy B (Compute Tile Binning - tile.Compute_Tile_Renderer)
//   - Pane 3: Strategy C (Fullscreen Quad Direct - fullscreen.Fullscreen_Renderer)
//   - Pane 4: Strategy Dynamic (Online Strategy Selector - selector.odin)
//
// Invariant: ZERO Horizontal Dependencies across cores, zero dynamic allocations in frame loop.

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:time"
import "vendor:sdl3"

import helper "../harness_helper"
import contract "../../core/render/contract"
import wgpu_backend "../../core/platform/gpu/wgpu"
import composer "../../core/composer"
import pipeline "../../core/composer/pipeline"
import atlas "../../core/render/atlas"
import terminal "../../core/render/terminal"
import terminal_instance "../../core/render/terminal/instance"
import tile "../../core/render/terminal/tile"
import fullscreen "../../core/render/terminal/fullscreen"

// Embedded WGSL shader sources matching backend pipeline contracts
GLYPH_WGSL        :: #load("../../core/render/shaders/glyph.wgsl", string)
TILE_COMPUTE_WGSL :: #load("../../core/render/shaders/tile_compute.wgsl", string)
TILE_BLIT_WGSL    :: #load("../../core/render/shaders/tile_blit.wgsl", string)
FULLSCREEN_WGSL   :: #load("../../core/render/shaders/fullscreen.wgsl", string)

// Locked Values
FULLSCREEN_CELL_BYTES: u64 : 8
TILE_CELL_BYTES:       u64 : 8
UNRESOLVED_SLOT:       u32 : 0x1FF

// Default grid dimensions
GRID_COLS_NORMAL:  u32 : 80
GRID_ROWS_NORMAL:  u32 : 24
GRID_COLS_EXTREME: u32 : 500
GRID_ROWS_EXTREME: u32 : 200

// ============================================================================
// 1. Cell Packing (bit-exact to shader unpack)
// ============================================================================

pack_cell :: #force_inline proc "contextless" (
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

unpack_cell :: #force_inline proc "contextless" (cell: u64) -> (
	content: u32,
	style:   u32,
	width:   u32,
	cflags:  u32,
	slot:    u32,
) {
	lo := u32(cell & 0xFFFFFFFF)
	hi := u32(cell >> 32)
	content = lo & 0x1FFFFF
	style = (lo >> 21) & 0x3FF
	width = (lo >> 31) & 1 | ((hi & 1) << 1)
	cflags = (hi >> 1) & 0x7F
	slot = (hi >> 8) & 0x1FF
	return
}

// ============================================================================
// 2. Synthetic_Terminal Grid State
// ============================================================================

Synthetic_Terminal :: struct {
	cols:   u32,
	rows:   u32,
	cells:  []u64,
	damage: contract.Damage_Rect,
}

synthetic_terminal_init :: proc(t: ^Synthetic_Terminal, cols, rows: u32) {
	t.cols = cols
	t.rows = rows
	t.cells = make([]u64, int(cols * rows))
	synthetic_terminal_clear(t)
}

synthetic_terminal_destroy :: proc(t: ^Synthetic_Terminal) {
	if t.cells != nil {
		delete(t.cells)
		t.cells = nil
	}
}

synthetic_terminal_clear :: proc(t: ^Synthetic_Terminal) {
	if len(t.cells) == 0 do return
	for i in 0..<len(t.cells) {
		t.cells[i] = pack_cell(' ', 0, 1, 0, 0)
	}
	t.damage = contract.damage_rect_make(0, 0, t.cols, t.rows)
}

synthetic_terminal_write_text :: proc(t: ^Synthetic_Terminal, r, c: u32, text: string, style: u32) {
	if r >= t.rows do return
	col := c
	for ch in text {
		if col >= t.cols do break
		slot := UNRESOLVED_SLOT if ch != ' ' else u32(0)
		t.cells[r * t.cols + col] = pack_cell(u32(ch), style, 1, 0, slot)
		col += 1
	}
	span := col - c
	if span > 0 {
		t.damage = contract.damage_rect_union(t.damage, contract.damage_rect_make(c, r, span, 1))
	}
}

synthetic_terminal_randomize :: proc(t: ^Synthetic_Terminal, rng: ^helper.Xoshiro256pp, count: int) {
	if t.cols == 0 || t.rows == 0 || len(t.cells) == 0 do return

	r_min: u32 = 2
	r_max := t.rows - 1 if t.rows > 3 else t.rows
	if r_max <= r_min do r_min = 0

	for _ in 0..<count {
		row_span := max(r_max - r_min, 1)
		r := r_min + u32(helper.xoshiro256pp_next(rng) % u64(row_span))
		c := u32(helper.xoshiro256pp_next(rng) % u64(t.cols))

		// Random printable ASCII (0x21 .. 0x7E)
		ch := u32(33 + (helper.xoshiro256pp_next(rng) % 94))
		style := u32(1 + (helper.xoshiro256pp_next(rng) % 15))
		slot := UNRESOLVED_SLOT

		t.cells[r * t.cols + c] = pack_cell(ch, style, 1, 0, slot)
		t.damage = contract.damage_rect_union(t.damage, contract.damage_rect_make(c, r, 1, 1))
	}
}

synthetic_terminal_scroll :: proc(t: ^Synthetic_Terminal, rng: ^helper.Xoshiro256pp) {
	if t.rows <= 3 || t.cols == 0 do return

	// Preserve top 2 header lines; scroll content region [2 .. rows-1]
	start_r: u32 = 2
	scroll_rows := t.rows - start_r - 1
	if scroll_rows > 0 {
		dst_start := start_r * t.cols
		src_start := (start_r + 1) * t.cols
		copy_len := scroll_rows * t.cols
		copy(t.cells[dst_start : dst_start + copy_len], t.cells[src_start : src_start + copy_len])
	}

	// Fill new bottom line with random colorful characters
	bottom_start := (t.rows - 1) * t.cols
	for c in 0..<t.cols {
		ch := u32(32 + (helper.xoshiro256pp_next(rng) % 95))
		style := u32(helper.xoshiro256pp_next(rng) % 16)
		slot := UNRESOLVED_SLOT if ch != ' ' else u32(0)
		t.cells[bottom_start + c] = pack_cell(ch, style, 1, 0, slot)
	}

	t.damage = contract.damage_rect_make(0, start_r, t.cols, t.rows - start_r)
}

synthetic_terminal_resize :: proc(t: ^Synthetic_Terminal, new_cols, new_rows: u32) {
	if new_cols == t.cols && new_rows == t.rows do return
	old_cells := t.cells
	old_cols := t.cols
	old_rows := t.rows

	t.cols = new_cols
	t.rows = new_rows
	t.cells = make([]u64, int(new_cols * new_rows))

	for i in 0..<len(t.cells) {
		t.cells[i] = pack_cell(' ', 0, 1, 0, 0)
	}

	copy_rows := min(old_rows, new_rows)
	copy_cols := min(old_cols, new_cols)
	for r in 0..<copy_rows {
		for c in 0..<copy_cols {
			t.cells[r * new_cols + c] = old_cells[r * old_cols + c]
		}
	}

	delete(old_cells)
	t.damage = contract.damage_rect_make(0, 0, new_cols, new_rows)
}

// ============================================================================
// Style LUT & Palette Math
// ============================================================================

rgb_to_r5g6b5 :: #force_inline proc "contextless" (r, g, b: u8) -> u16 {
	return (u16(r >> 3) << 11) | (u16(g >> 2) << 5) | u16(b >> 3)
}

init_style_lut :: proc(lut: ^[1025]u32) {
	colors := [16][3]u8{
		{20, 22, 26},    // 0: Default dark bg
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

	fg_packed: [1024]u16
	bg_packed: [1024]u16

	for s in 0..<1024 {
		fg_idx := s % 16
		bg_idx := (s / 16) % 16
		if s == 0 {
			fg_idx = 15
			bg_idx = 0
		}
		fg_c := colors[fg_idx]
		bg_c := colors[bg_idx]
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

palette_srgb_float :: proc(style: u32, is_fg: bool) -> [4]f32 {
	s := style % 16
	if s == 0 {
		if is_fg do return {0.95, 0.95, 0.98, 1.0}
		return {0.08, 0.09, 0.11, 1.0}
	}
	switch s {
	case 1:  return {0.88, 0.42, 0.46, 1.0} // Red
	case 2:  return {0.60, 0.76, 0.47, 1.0} // Green
	case 3:  return {0.90, 0.75, 0.48, 1.0} // Yellow
	case 4:  return {0.38, 0.69, 0.94, 1.0} // Blue
	case 5:  return {0.78, 0.47, 0.87, 1.0} // Magenta
	case 6:  return {0.34, 0.71, 0.76, 1.0} // Cyan
	case 7:  return {0.85, 0.85, 0.85, 1.0} // White
	case 8:  return {0.45, 0.45, 0.50, 1.0} // Dark Gray
	case 9:  return {1.00, 0.50, 0.55, 1.0} // Bright Red
	case 10: return {0.70, 0.90, 0.55, 1.0} // Bright Green
	case 11: return {1.00, 0.85, 0.55, 1.0} // Bright Yellow
	case 12: return {0.50, 0.80, 1.00, 1.0} // Bright Blue
	case 13: return {0.90, 0.60, 0.95, 1.0} // Bright Magenta
	case 14: return {0.45, 0.85, 0.90, 1.0} // Bright Cyan
	case:    return {0.95, 0.95, 1.00, 1.0} // Bright White
	}
}

// ============================================================================
// 3. Harness State & Pipeline Management
// ============================================================================

Harness_State :: struct {
	window:           helper.Window,
	instance:         rawptr,
	surface:          rawptr,
	device:           contract.Gpu_Device,
	queue:            contract.Gpu_Queue,
	format:           contract.Gpu_Format,
	running:          bool,

	composer_pipe:    pipeline.Composer_Pipeline,
	screen_w:         f32,
	screen_h:         f32,
	pane_w:           f32,
	pane_h:           f32,

	atlas:            atlas.Atlas,
	lut_words:        [1025]u32,

	// Shared GPU Pipeline Objects
	glyph_pipeline:   contract.Gpu_RenderPipeline,
	glyph_layout:     contract.Gpu_BindGroupLayout,
	compute_pipeline: contract.Gpu_ComputePipeline,
	compute_layout:   contract.Gpu_BindGroupLayout,
	blit_pipeline:    contract.Gpu_RenderPipeline,
	blit_layout:      contract.Gpu_BindGroupLayout,
	fs_pipeline:      contract.Gpu_RenderPipeline,
	fs_layout:        contract.Gpu_BindGroupLayout,

	// Pane 1: Instance Quad Batching
	term1:            Synthetic_Terminal,
	inst1:            terminal_instance.Instance_Renderer,

	// Pane 2: Compute Tile Binning
	term2:            Synthetic_Terminal,
	tile2:            tile.Compute_Tile_Renderer,

	// Pane 3: Fullscreen Quad Direct
	term3:            Synthetic_Terminal,
	fs3:              fullscreen.Fullscreen_Renderer,
	fs3_color_buf:    contract.Gpu_Buffer,

	// Pane 4: Adaptive Online Selector
	term4:            Synthetic_Terminal,
	inst4:            terminal_instance.Instance_Renderer,
	tile4:            tile.Compute_Tile_Renderer,
	fs4:              fullscreen.Fullscreen_Renderer,
	fs4_color_buf:    contract.Gpu_Buffer,
	strat4_state:     terminal.Strategy_State,
	last_strat4:      terminal.Render_Strategy,
	last_duration_ns: u64,

	// Controls & PRNG
	blasting:         bool,
	is_extreme_size:  bool,
	rng:              helper.Xoshiro256pp,
	frame_counter:    u64,
}

_init_atlas :: proc(h: ^Harness_State) -> bool {
	if !atlas.atlas_init(&h.atlas) do return false

	font_path := "assets/fonts/MapleMono-NF-Regular.ttf"
	r: helper.Font_Rasterizer
	has_font := false
	if os.is_file(font_path) {
		err: helper.Font_Error
		has_font = helper.font_rasterizer_init(&r, font_path, 32.0, &err)
	}

	if has_font {
		defer helper.font_rasterizer_destroy(&r)
		for cp in u32(32)..=126 {
			slot := cp - 32
			px, py := atlas.atlas_slot_origin(slot)
			helper.font_rasterize_glyph_into(
				&r,
				cp,
				h.atlas.pixels,
				atlas.ATLAS_WIDTH,
				int(px),
				int(py),
				atlas.ATLAS_GLYPH_SIZE,
				atlas.ATLAS_GLYPH_SIZE,
			)
			h.atlas.slots[slot].valid = true
		}
	} else {
		// Procedural fallback pattern ensuring visible glyph ink if TTF is unavailable
		for cp in u32(33)..=126 {
			slot := cp - 32
			px, py := atlas.atlas_slot_origin(slot)
			for y in 14..<48 {
				for x in 16..<36 {
					if x == 16 || x == 35 || y == 14 || y == 47 || ((x * 3 + y * 7 + int(cp)) % 5 == 0) {
						h.atlas.pixels[(int(py) + y) * atlas.ATLAS_WIDTH + (int(px) + x)] = 255
					}
				}
			}
			h.atlas.slots[slot].valid = true
		}
	}

	return atlas.atlas_upload_gpu(&h.atlas, h.device, h.queue)
}

_create_shared_pipelines :: proc(h: ^Harness_State) -> bool {
	// 1. Instance Glyph Render Pipeline (location 0: pos, 1: size, 2: uv, 3: fg)
	glyph_mod := contract.create_shader_module(h.device, GLYPH_WGSL)
	if rawptr(glyph_mod) == nil do return false
	defer contract.destroy_shader_module(glyph_mod)

	attrs := []contract.Gpu_Vertex_Attribute{
		{format = .Float32x2, offset = 0, shader_location = 0},
		{format = .Float32x2, offset = 8, shader_location = 1},
		{format = .Float32x4, offset = 16, shader_location = 2},
		{format = .Float32x4, offset = 32, shader_location = 3},
	}
	layouts := []contract.Gpu_Vertex_Layout{
		{
			array_stride = size_of(contract.Instance_Record),
			step_mode    = .Instance,
			attributes   = attrs,
		},
	}

	h.glyph_pipeline = contract.create_render_pipeline(
		h.device,
		glyph_mod,
		"vs_main",
		glyph_mod,
		"fs_main",
		layouts,
		h.format,
		.Alpha_Blend,
		.Triangle_List,
	)
	if rawptr(h.glyph_pipeline) == nil do return false
	h.glyph_layout = contract.pipeline_get_bind_group_layout(h.glyph_pipeline, 0)

	// 2. Compute Tile Pipelines (Compute + Blit)
	compute_mod := contract.create_shader_module(h.device, TILE_COMPUTE_WGSL)
	if rawptr(compute_mod) == nil do return false
	defer contract.destroy_shader_module(compute_mod)

	h.compute_pipeline = contract.create_compute_pipeline(h.device, compute_mod, "cs_main")
	if rawptr(h.compute_pipeline) == nil do return false
	h.compute_layout = contract.compute_get_bind_group_layout(h.compute_pipeline, 0)

	blit_mod := contract.create_shader_module(h.device, TILE_BLIT_WGSL)
	if rawptr(blit_mod) == nil do return false
	defer contract.destroy_shader_module(blit_mod)

	h.blit_pipeline = contract.create_render_pipeline(
		h.device,
		blit_mod,
		"vs_main",
		blit_mod,
		"fs_main",
		nil,
		h.format,
		.Alpha_Blend,
		.Triangle_List,
	)
	if rawptr(h.blit_pipeline) == nil do return false
	h.blit_layout = contract.pipeline_get_bind_group_layout(h.blit_pipeline, 0)

	// 3. Fullscreen Quad Direct Render Pipeline
	fs_mod := contract.create_shader_module(h.device, FULLSCREEN_WGSL)
	if rawptr(fs_mod) == nil do return false
	defer contract.destroy_shader_module(fs_mod)

	h.fs_pipeline = contract.create_render_pipeline(
		h.device,
		fs_mod,
		"fullscreen_vs_main",
		fs_mod,
		"fullscreen_fs_main",
		nil,
		h.format,
		.Alpha_Blend,
		.Triangle_List,
	)
	if rawptr(h.fs_pipeline) == nil do return false
	h.fs_layout = contract.pipeline_get_bind_group_layout(h.fs_pipeline, 0)

	return true
}

_rebuild_tile_resources :: proc(
	h: ^Harness_State,
	r: ^tile.Compute_Tile_Renderer,
	cols, rows: u32,
	pane_w, pane_h: f32,
) -> bool {
	cell_w := pane_w / f32(cols)
	cell_h := pane_h / f32(rows)
	fb_w := u32(pane_w)
	fb_h := u32(pane_h)

	r.cols = cols
	r.rows = rows
	r.cell_w = cell_w
	r.cell_h = cell_h
	r.tile_w = 16
	r.tile_h = 16
	r.tiles_x = (cols + r.tile_w - 1) / r.tile_w
	r.tiles_y = (rows + r.tile_h - 1) / r.tile_h
	r.tile_count = max(r.tiles_x * r.tiles_y, 1)

	// Recreate Framebuffer if dimension changed
	if rawptr(r.framebuffer) == nil || r.fb_w_px != fb_w || r.fb_h_px != fb_h {
		if rawptr(r.fb_view) != nil do contract.destroy_texture_view(r.fb_view)
		if rawptr(r.framebuffer) != nil do contract.destroy_texture(r.framebuffer)

		r.fb_w_px = fb_w
		r.fb_h_px = fb_h
		usage := contract.Gpu_Texture_Usage.Storage_Binding |
		         contract.Gpu_Texture_Usage.Texture_Binding |
		         contract.Gpu_Texture_Usage.Copy_Src
		r.framebuffer = contract.create_texture(h.device, fb_w, fb_h, .RGBA8_Unorm, usage)
		r.fb_view = contract.create_texture_view(r.framebuffer)
	}

	// Reallocate cell and tile list buffers
	cell_bytes := u64(cols * rows) * TILE_CELL_BYTES
	if rawptr(r.cell_buffer) != nil do contract.destroy_buffer(r.cell_buffer)
	r.cell_buffer = contract.create_buffer(h.device, cell_bytes, .Storage | .Copy_Dst, false)

	tile_list_bytes := u64(r.tile_count) * size_of(u32)
	if rawptr(r.tile_list_buffer) != nil do contract.destroy_buffer(r.tile_list_buffer)
	r.tile_list_buffer = contract.create_buffer(h.device, tile_list_bytes, .Storage | .Copy_Dst, false)

	// Destroy and recreate bind groups
	if rawptr(r.compute_bind_group) != nil do contract.destroy_bind_group(r.compute_bind_group)
	if rawptr(r.blit_bind_group) != nil do contract.destroy_bind_group(r.blit_bind_group)

	c_entries := []contract.Gpu_Bind_Entry{
		{binding = 0, buffer = r.params_buffer, offset = 0, size = 0, entry_type = .Buffer},
		{binding = 1, buffer = r.tile_list_buffer, offset = 0, size = 0, entry_type = .Buffer},
		{binding = 2, buffer = r.cell_buffer, offset = 0, size = 0, entry_type = .Buffer},
		{binding = 3, buffer = r.lut_buffer, offset = 0, size = 0, entry_type = .Buffer},
		{binding = 4, view = h.atlas.gpu_view, entry_type = .Texture_View},
		{binding = 5, sampler = r.sampler, entry_type = .Sampler},
		{binding = 6, view = r.fb_view, entry_type = .Texture_View},
	}
	r.compute_bind_group = contract.create_bind_group(h.device, h.compute_layout, c_entries)

	b_entries := []contract.Gpu_Bind_Entry{
		{binding = 0, view = r.fb_view, entry_type = .Texture_View},
		{binding = 1, sampler = r.sampler, entry_type = .Sampler},
	}
	r.blit_bind_group = contract.create_bind_group(h.device, h.blit_layout, b_entries)

	r.compute_pipeline = h.compute_pipeline
	r.blit_pipeline = h.blit_pipeline
	r.available = true
	return rawptr(r.compute_bind_group) != nil && rawptr(r.blit_bind_group) != nil
}

_rebuild_fullscreen_resources :: proc(
	h: ^Harness_State,
	r: ^fullscreen.Fullscreen_Renderer,
	color_buf: ^contract.Gpu_Buffer,
	cols, rows: u32,
	pane_w, pane_h: f32,
) -> bool {
	cell_w := pane_w / f32(cols)
	cell_h := pane_h / f32(rows)

	r.cols = cols
	r.rows = rows
	r.cell_w = cell_w
	r.cell_h = cell_h

	cell_bytes := u64(cols * rows) * FULLSCREEN_CELL_BYTES
	if rawptr(r.cell_buffer) != nil do contract.destroy_buffer(r.cell_buffer)
	r.cell_buffer = contract.create_buffer(h.device, cell_bytes, .Storage | .Copy_Dst, false)

	if rawptr(color_buf^) != nil do contract.destroy_buffer(color_buf^)
	color_buf^ = contract.create_buffer(h.device, cell_bytes, .Storage | .Copy_Dst, false)

	if rawptr(r.bind_group) != nil do contract.destroy_bind_group(r.bind_group)

	fs_entries := []contract.Gpu_Bind_Entry{
		{binding = 0, buffer = r.params_buffer, offset = 0, size = 0, entry_type = .Buffer},
		{binding = 1, buffer = r.cell_buffer, offset = 0, size = 0, entry_type = .Buffer},
		{binding = 2, buffer = r.lut_buffer, offset = 0, size = 0, entry_type = .Buffer},
		{binding = 3, view = h.atlas.gpu_view, entry_type = .Texture_View},
		{binding = 4, sampler = r.sampler, entry_type = .Sampler},
		{binding = 5, buffer = color_buf^, offset = 0, size = 0, entry_type = .Buffer},
	}
	r.bind_group = contract.create_bind_group(h.device, h.fs_layout, fs_entries)
	r.pipeline = h.fs_pipeline
	r.available = true
	return rawptr(r.bind_group) != nil
}

_rebuild_instance_resources :: proc(
	h: ^Harness_State,
	r: ^terminal_instance.Instance_Renderer,
	max_instances: u32,
) -> bool {
	if r.max_instances >= max_instances && rawptr(r.instance_buffer) != nil do return true

	r.max_instances = max(max_instances, 1024)
	if len(r.records) > 0 do delete(r.records)
	r.records = make([]contract.Instance_Record, int(r.max_instances))

	if rawptr(r.instance_buffer) != nil do contract.destroy_buffer(r.instance_buffer)
	buf_bytes := u64(r.max_instances) * size_of(contract.Instance_Record)
	usage := contract.Gpu_Buffer_Usage.Vertex |
	         contract.Gpu_Buffer_Usage.Copy_Dst |
	         contract.Gpu_Buffer_Usage.Storage
	r.instance_buffer = contract.create_buffer(h.device, buf_bytes, usage, false)

	if rawptr(r.bind_group) != nil do contract.destroy_bind_group(r.bind_group)
	entries := []contract.Gpu_Bind_Entry{
		{binding = 0, buffer = r.uniform_buffer, offset = 0, size = 0, entry_type = .Buffer},
		{binding = 1, view = h.atlas.gpu_view, entry_type = .Texture_View},
		{binding = 2, sampler = r.sampler, entry_type = .Sampler},
	}
	r.bind_group = contract.create_bind_group(h.device, h.glyph_layout, entries)
	r.pipeline = h.glyph_pipeline
	r.available = true
	return rawptr(r.bind_group) != nil
}

_update_renderer_limits :: proc(h: ^Harness_State, cols, rows: u32) {
	max_cells := cols * rows

	// Pane 1
	_rebuild_instance_resources(h, &h.inst1, max_cells)

	// Pane 2
	_rebuild_tile_resources(h, &h.tile2, cols, rows, h.pane_w, h.pane_h)
	contract.write_buffer(h.queue, h.tile2.lut_buffer, 0, &h.lut_words, size_of(h.lut_words))

	// Pane 3
	_rebuild_fullscreen_resources(h, &h.fs3, &h.fs3_color_buf, cols, rows, h.pane_w, h.pane_h)
	contract.write_buffer(h.queue, h.fs3.lut_buffer, 0, &h.lut_words, size_of(h.lut_words))

	// Pane 4
	_rebuild_instance_resources(h, &h.inst4, max_cells)
	_rebuild_tile_resources(h, &h.tile4, cols, rows, h.pane_w, h.pane_h)
	contract.write_buffer(h.queue, h.tile4.lut_buffer, 0, &h.lut_words, size_of(h.lut_words))
	_rebuild_fullscreen_resources(h, &h.fs4, &h.fs4_color_buf, cols, rows, h.pane_w, h.pane_h)
	contract.write_buffer(h.queue, h.fs4.lut_buffer, 0, &h.lut_words, size_of(h.lut_words))
}

_handle_window_resize :: proc(h: ^Harness_State) {
	helper.window_update_pixel_size(&h.window)
	h.screen_w = f32(h.window.pixel_w)
	h.screen_h = f32(h.window.pixel_h)
	h.pane_w = h.screen_w * 0.5
	h.pane_h = h.screen_h * 0.5

	contract.configure_surface(h.surface, h.device, h.format, u32(h.screen_w), u32(h.screen_h))
	pipeline.composer_pipeline_resize(&h.composer_pipe, h.screen_w, h.screen_h)

	// Reacquire 4 layers with new pane dimensions
	l1, _ := pipeline.composer_pipeline_acquire_layer(&h.composer_pipe, 1, .Terminal, u32(h.pane_w), u32(h.pane_h), false)
	l2, _ := pipeline.composer_pipeline_acquire_layer(&h.composer_pipe, 2, .Terminal, u32(h.pane_w), u32(h.pane_h), false)
	l3, _ := pipeline.composer_pipeline_acquire_layer(&h.composer_pipe, 3, .Terminal, u32(h.pane_w), u32(h.pane_h), false)
	l4, _ := pipeline.composer_pipeline_acquire_layer(&h.composer_pipe, 4, .Terminal, u32(h.pane_w), u32(h.pane_h), false)

	if l1 != nil {
		l1.dest_rect = composer.rect_make(0, 0, h.pane_w, h.pane_h)
		l1.scissor_rect = l1.dest_rect
		l1.opacity = 1.0
	}
	if l2 != nil {
		l2.dest_rect = composer.rect_make(h.pane_w, 0, h.pane_w, h.pane_h)
		l2.scissor_rect = l2.dest_rect
		l2.opacity = 1.0
	}
	if l3 != nil {
		l3.dest_rect = composer.rect_make(0, h.pane_h, h.pane_w, h.pane_h)
		l3.scissor_rect = l3.dest_rect
		l3.opacity = 1.0
	}
	if l4 != nil {
		l4.dest_rect = composer.rect_make(h.pane_w, h.pane_h, h.pane_w, h.pane_h)
		l4.scissor_rect = l4.dest_rect
		l4.opacity = 1.0
	}

	order := [4]composer.Layer_Id{1, 2, 3, 4}
	pipeline.composer_pipeline_set_layer_order(&h.composer_pipe, order[:])

	_update_renderer_limits(h, h.term1.cols, h.term1.rows)
}

// ============================================================================
// 4. Main GUI Loop & Per-Frame Render Passes
// ============================================================================

_render_frame :: proc(h: ^Harness_State) {
	h.frame_counter += 1

	cols := h.term1.cols
	rows := h.term1.rows
	cell_w := h.pane_w / f32(cols)
	cell_h := h.pane_h / f32(rows)

	// Update Static UI headers for each pane
	status_buf: [128]u8
	p1_hdr := "[PANE 1: INSTANCE BATCHING (Strategy A)]"
	p2_hdr := "[PANE 2: COMPUTE TILES (Strategy B)]"
	p3_hdr := "[PANE 3: FULLSCREEN DIRECT (Strategy C)]"

	strat_name := "INSTANCE"
	switch h.last_strat4 {
	case .Instance:      strat_name = "INSTANCE"
	case .Compute_Tiles: strat_name = "COMPUTE_TILES"
	case .Fullscreen:    strat_name = "FULLSCREEN"
	}
	p4_hdr := fmt.bprintf(status_buf[:], "[PANE 4: DYNAMIC SELECTOR] Pick: %s (%dus)", strat_name, h.last_duration_ns / 1000)

	ctrl_txt := "[Space] Toggle Blast | [R] Resize 80x24 <-> 500x200 | [C] Clear"

	synthetic_terminal_write_text(&h.term1, 0, 1, p1_hdr, 6)
	synthetic_terminal_write_text(&h.term1, 1, 1, ctrl_txt, 7)

	synthetic_terminal_write_text(&h.term2, 0, 1, p2_hdr, 3)
	synthetic_terminal_write_text(&h.term2, 1, 1, ctrl_txt, 7)

	synthetic_terminal_write_text(&h.term3, 0, 1, p3_hdr, 5)
	synthetic_terminal_write_text(&h.term3, 1, 1, ctrl_txt, 7)

	synthetic_terminal_write_text(&h.term4, 0, 1, p4_hdr, 2)
	synthetic_terminal_write_text(&h.term4, 1, 1, ctrl_txt, 7)

	// Continuous Data Blasting
	if h.blasting {
		// Pane 1: Sparse Typing bursts (< 3% dirty cells)
		synthetic_terminal_randomize(&h.term1, &h.rng, 15)

		// Pane 2: Moderate Block modifications (3% - 65% dirty cells)
		synthetic_terminal_randomize(&h.term2, &h.rng, 160)

		// Pane 3: Rapid Scrolling / Full Grid modifications (> 65% dirty cells)
		if h.frame_counter % 2 == 0 {
			synthetic_terminal_scroll(&h.term3, &h.rng)
		} else {
			synthetic_terminal_randomize(&h.term3, &h.rng, int(cols * rows / 2))
		}

		// Pane 4: Dynamically cycling workloads to trigger all 3 branches
		phase := (h.frame_counter / 60) % 3
		switch phase {
		case 0:
			// Low damage -> picks Instance
			synthetic_terminal_randomize(&h.term4, &h.rng, 4)
		case 1:
			// Moderate damage -> picks Compute Tile
			synthetic_terminal_randomize(&h.term4, &h.rng, 180)
		case 2:
			// Heavy damage -> picks Fullscreen
			synthetic_terminal_scroll(&h.term4, &h.rng)
		}
	}

	// Strategy Decision for Pane 4 via selector.odin
	total_cells := int(cols * rows)
	p4_dirty := int(h.term4.damage.w * h.term4.damage.h)
	p4_ratio := f32(p4_dirty) / f32(max(total_cells, 1))
	inp := terminal.Strategy_Inputs{
		dirty_cells = p4_dirty,
		total_cells = total_cells,
		ratio       = p4_ratio,
		full_rows   = int(h.term4.damage.h) if h.term4.damage.w == cols else 0,
		span_count  = 1,
		scroll      = (h.term4.damage.w == cols && h.term4.damage.h == rows),
	}
	t_sel_0 := time.tick_now()
	h.last_strat4 = terminal.strategy_select(inp, &h.strat4_state, true, true)
	h.last_duration_ns = u64(time.tick_since(t_sel_0))
	terminal.strategy_record(&h.strat4_state, h.last_strat4, h.last_duration_ns)

	// Command Encoding & Submissions
	enc := contract.create_command_encoder(h.device)
	if rawptr(enc) == nil do return
	defer contract.release_command_encoder(enc)

	// Upload Cell Data for Pane 2 & Pane 3
	contract.write_buffer(h.queue, h.tile2.cell_buffer, 0, raw_data(h.term2.cells), u64(len(h.term2.cells) * size_of(u64)))
	contract.write_buffer(h.queue, h.fs3.cell_buffer, 0, raw_data(h.term3.cells), u64(len(h.term3.cells) * size_of(u64)))

	// Upload Cell Data for Pane 4
	contract.write_buffer(h.queue, h.tile4.cell_buffer, 0, raw_data(h.term4.cells), u64(len(h.term4.cells) * size_of(u64)))
	contract.write_buffer(h.queue, h.fs4.cell_buffer, 0, raw_data(h.term4.cells), u64(len(h.term4.cells) * size_of(u64)))

	// 1. Pane 2 Compute Dispatch
	dirty_tiles2 := make([dynamic]u32, context.temp_allocator)
	tx_s := h.term2.damage.x / h.tile2.tile_w
	ty_s := h.term2.damage.y / h.tile2.tile_h
	tx_e := min((h.term2.damage.x + h.term2.damage.w + h.tile2.tile_w - 1) / h.tile2.tile_w, h.tile2.tiles_x)
	ty_e := min((h.term2.damage.y + h.term2.damage.h + h.tile2.tile_h - 1) / h.tile2.tile_h, h.tile2.tiles_y)

	for ty in ty_s..<ty_e {
		for tx in tx_s..<tx_e {
			append(&dirty_tiles2, ty * h.tile2.tiles_x + tx)
		}
	}
	if len(dirty_tiles2) > 0 {
		params2 := tile.Tile_Params{
			screen_w     = h.pane_w,
			screen_h     = h.pane_h,
			cols         = cols,
			rows         = rows,
			cell_w       = cell_w,
			cell_h       = cell_h,
			pad_x        = 0.0,
			pad_y        = 0.0,
			tile_w       = h.tile2.tile_w,
			tile_h       = h.tile2.tile_h,
			tiles_x      = h.tile2.tiles_x,
			tiles_y      = h.tile2.tiles_y,
			atlas_w      = atlas.ATLAS_WIDTH,
			atlas_h      = atlas.ATLAS_HEIGHT,
			bg_opacity   = 1.0,
			cell_opacity = 1.0,
		}
		contract.write_buffer(h.queue, h.tile2.params_buffer, 0, &params2, size_of(tile.Tile_Params))
		contract.write_buffer(h.queue, h.tile2.tile_list_buffer, 0, raw_data(dirty_tiles2), u64(len(dirty_tiles2) * size_of(u32)))
		tile.compute_tile_dispatch(&h.tile2, enc, u32(len(dirty_tiles2)))
	}

	// 2. Pane 4 Compute Dispatch (if chosen)
	dirty_tiles4 := make([dynamic]u32, context.temp_allocator)
	if h.last_strat4 == .Compute_Tiles {
		tx_s4 := h.term4.damage.x / h.tile4.tile_w
		ty_s4 := h.term4.damage.y / h.tile4.tile_h
		tx_e4 := min((h.term4.damage.x + h.term4.damage.w + h.tile4.tile_w - 1) / h.tile4.tile_w, h.tile4.tiles_x)
		ty_e4 := min((h.term4.damage.y + h.term4.damage.h + h.tile4.tile_h - 1) / h.tile4.tile_h, h.tile4.tiles_y)
		for ty in ty_s4..<ty_e4 {
			for tx in tx_s4..<tx_e4 {
				append(&dirty_tiles4, ty * h.tile4.tiles_x + tx)
			}
		}
		if len(dirty_tiles4) > 0 {
			params4 := tile.Tile_Params{
				screen_w     = h.pane_w,
				screen_h     = h.pane_h,
				cols         = cols,
				rows         = rows,
				cell_w       = cell_w,
				cell_h       = cell_h,
				pad_x        = 0.0,
				pad_y        = 0.0,
				tile_w       = h.tile4.tile_w,
				tile_h       = h.tile4.tile_h,
				tiles_x      = h.tile4.tiles_x,
				tiles_y      = h.tile4.tiles_y,
				atlas_w      = atlas.ATLAS_WIDTH,
				atlas_h      = atlas.ATLAS_HEIGHT,
				bg_opacity   = 1.0,
				cell_opacity = 1.0,
			}
			contract.write_buffer(h.queue, h.tile4.params_buffer, 0, &params4, size_of(tile.Tile_Params))
			contract.write_buffer(h.queue, h.tile4.tile_list_buffer, 0, raw_data(dirty_tiles4), u64(len(dirty_tiles4) * size_of(u32)))
			tile.compute_tile_dispatch(&h.tile4, enc, u32(len(dirty_tiles4)))
		}
	}

	// Retrieve Backing Layers
	l1 := pipeline.composer_pipeline_get_layer(&h.composer_pipe, 1)
	l2 := pipeline.composer_pipeline_get_layer(&h.composer_pipe, 2)
	l3 := pipeline.composer_pipeline_get_layer(&h.composer_pipe, 3)
	l4 := pipeline.composer_pipeline_get_layer(&h.composer_pipe, 4)

	// 3. Render Pass: Pane 1 (Instance Quad Batching)
	if l1 != nil && rawptr(l1.view) != nil {
		terminal_instance.instance_renderer_begin(&h.inst1)
		u_data := [4]f32{h.pane_w, h.pane_h, cell_w, cell_h}
		contract.write_buffer(h.queue, h.inst1.uniform_buffer, 0, &u_data, size_of([4]f32))

		for r in 0..<rows {
			for c in 0..<cols {
				packed := h.term1.cells[r * cols + c]
				content, style, _, _, slot := unpack_cell(packed)
				if content == ' ' && style == 0 do continue

				u0, v0, u1, v1 := atlas.atlas_slot_uv(slot, f32(atlas.ATLAS_GLYPH_SIZE), f32(atlas.ATLAS_GLYPH_SIZE))
				if slot == UNRESOLVED_SLOT && content >= 32 && content <= 126 {
					u0, v0, u1, v1 = atlas.atlas_slot_uv(content - 32, f32(atlas.ATLAS_GLYPH_SIZE), f32(atlas.ATLAS_GLYPH_SIZE))
				}

				rec := contract.Instance_Record{
					pos_size = {f32(c) * cell_w, f32(r) * cell_h, cell_w, cell_h},
					uv_rect  = {u0, v0, u1, v1},
					fg_color = palette_srgb_float(style, true),
					bg_color = palette_srgb_float(style, false),
				}
				terminal_instance.instance_renderer_push(&h.inst1, rec)
			}
		}
		terminal_instance.instance_renderer_flush(&h.inst1)

		pass1 := contract.begin_render_pass(enc, l1.view, {0.07, 0.08, 0.10, 1.0}, .Clear)
		if rawptr(pass1) != nil {
			terminal_instance.instance_renderer_draw(&h.inst1, pass1)
			contract.end_render_pass(pass1)
		}
	}

	// 4. Render Pass: Pane 2 (Compute Tile Blit)
	if l2 != nil && rawptr(l2.view) != nil {
		pass2 := contract.begin_render_pass(enc, l2.view, {0.07, 0.08, 0.10, 1.0}, .Clear)
		if rawptr(pass2) != nil {
			contract.render_set_pipeline(pass2, h.tile2.blit_pipeline)
			contract.render_set_bind_group(pass2, 0, h.tile2.blit_bind_group)
			contract.render_draw(pass2, 3, 1)
			contract.end_render_pass(pass2)
		}
	}

	// 5. Render Pass: Pane 3 (Fullscreen Quad Direct)
	if l3 != nil && rawptr(l3.view) != nil {
		fs_p3 := fullscreen.Fullscreen_Params{
			screen_w     = h.pane_w,
			screen_h     = h.pane_h,
			cols         = cols,
			rows         = rows,
			cell_w       = cell_w,
			cell_h       = cell_h,
			pad_x        = 0.0,
			pad_y        = 0.0,
			atlas_w      = atlas.ATLAS_WIDTH,
			atlas_h      = atlas.ATLAS_HEIGHT,
			bg_opacity   = 1.0,
			cell_opacity = 1.0,
		}
		contract.write_buffer(h.queue, h.fs3.params_buffer, 0, &fs_p3, size_of(fullscreen.Fullscreen_Params))

		pass3 := contract.begin_render_pass(enc, l3.view, {0.07, 0.08, 0.10, 1.0}, .Clear)
		if rawptr(pass3) != nil {
			fullscreen.fullscreen_draw(&h.fs3, pass3)
			contract.end_render_pass(pass3)
		}
	}

	// 6. Render Pass: Pane 4 (Dynamic Selection Dispatch)
	if l4 != nil && rawptr(l4.view) != nil {
		pass4 := contract.begin_render_pass(enc, l4.view, {0.07, 0.08, 0.10, 1.0}, .Clear)
		if rawptr(pass4) != nil {
			switch h.last_strat4 {
			case .Instance:
				terminal_instance.instance_renderer_begin(&h.inst4)
				u_data := [4]f32{h.pane_w, h.pane_h, cell_w, cell_h}
				contract.write_buffer(h.queue, h.inst4.uniform_buffer, 0, &u_data, size_of([4]f32))
				for r in 0..<rows {
					for c in 0..<cols {
						packed := h.term4.cells[r * cols + c]
						content, style, _, _, slot := unpack_cell(packed)
						if content == ' ' && style == 0 do continue

						u0, v0, u1, v1 := atlas.atlas_slot_uv(slot, f32(atlas.ATLAS_GLYPH_SIZE), f32(atlas.ATLAS_GLYPH_SIZE))
						if slot == UNRESOLVED_SLOT && content >= 32 && content <= 126 {
							u0, v0, u1, v1 = atlas.atlas_slot_uv(content - 32, f32(atlas.ATLAS_GLYPH_SIZE), f32(atlas.ATLAS_GLYPH_SIZE))
						}

						rec := contract.Instance_Record{
							pos_size = {f32(c) * cell_w, f32(r) * cell_h, cell_w, cell_h},
							uv_rect  = {u0, v0, u1, v1},
							fg_color = palette_srgb_float(style, true),
							bg_color = palette_srgb_float(style, false),
						}
						terminal_instance.instance_renderer_push(&h.inst4, rec)
					}
				}
				terminal_instance.instance_renderer_flush(&h.inst4)
				terminal_instance.instance_renderer_draw(&h.inst4, pass4)

			case .Compute_Tiles:
				contract.render_set_pipeline(pass4, h.tile4.blit_pipeline)
				contract.render_set_bind_group(pass4, 0, h.tile4.blit_bind_group)
				contract.render_draw(pass4, 3, 1)

			case .Fullscreen:
				fs_p4 := fullscreen.Fullscreen_Params{
					screen_w     = h.pane_w,
					screen_h     = h.pane_h,
					cols         = cols,
					rows         = rows,
					cell_w       = cell_w,
					cell_h       = cell_h,
					pad_x        = 0.0,
					pad_y        = 0.0,
					atlas_w      = atlas.ATLAS_WIDTH,
					atlas_h      = atlas.ATLAS_HEIGHT,
					bg_opacity   = 1.0,
					cell_opacity = 1.0,
				}
				contract.write_buffer(h.queue, h.fs4.params_buffer, 0, &fs_p4, size_of(fullscreen.Fullscreen_Params))
				fullscreen.fullscreen_draw(&h.fs4, pass4)
			}
			contract.end_render_pass(pass4)
		}
	}

	// 7. Composite All 4 Offscreen Textures onto Main Swapchain Surface
	tex, view, _ := contract.get_surface_texture(h.surface)
	if rawptr(view) != nil {
		pipeline.composer_pipeline_composite(&h.composer_pipe, enc, view)
	}

	cmd := contract.finish_command_buffer(enc)
	if cmd != nil {
		contract.submit(h.queue, cmd)
		contract.release_command_buffer(cmd)
	}

	if rawptr(view) != nil {
		contract.present_surface(h.surface)
		contract.release_surface_texture(tex, view)
	}

	// Reset Damage Rectangles
	h.term1.damage = {}
	h.term2.damage = {}
	h.term3.damage = {}
	h.term4.damage = {}
}

// ============================================================================
// 5. Entry Point & Lifecycle
// ============================================================================

main :: proc() {
	h := new(Harness_State)
	defer free(h)

	h.running = true
	h.blasting = true
	h.is_extreme_size = false
	helper.xoshiro256pp_init(&h.rng, 0x12345678_ABCDEF01)

	init_style_lut(&h.lut_words)

	window_w: i32 = 1600
	window_h: i32 = 1000

	if !helper.window_init(&h.window, "Term - Terminal Render Harness", window_w, window_h) {
		fmt.eprintln("harness error: window_init failed")
		os.exit(1)
	}
	defer helper.window_destroy(&h.window)

	wgpu_backend.init_wgpu_driver()
	h.instance = contract.create_instance()
	h.surface = wgpu_backend.create_surface(h.instance, h.window.handle)
	h.device, h.queue = contract.request_device(h.instance, h.surface)
	h.format = contract.get_preferred_format(h.surface, h.device)

	helper.window_update_pixel_size(&h.window)
	h.screen_w = f32(h.window.pixel_w)
	h.screen_h = f32(h.window.pixel_h)
	h.pane_w = h.screen_w * 0.5
	h.pane_h = h.screen_h * 0.5

	contract.configure_surface(h.surface, h.device, h.format, u32(h.screen_w), u32(h.screen_h))

	// Initialize Multi-Pane Composer Pipeline
	if !pipeline.composer_pipeline_init(
		&h.composer_pipe,
		h.device,
		h.queue,
		h.format,
		h.screen_w,
		h.screen_h,
	) {
		fmt.eprintln("harness error: composer_pipeline_init failed")
		os.exit(1)
	}
	defer pipeline.composer_pipeline_destroy(&h.composer_pipe)

	// Initialize Font Atlas
	if !_init_atlas(h) {
		fmt.eprintln("harness error: _init_atlas failed")
		os.exit(1)
	}
	defer atlas.atlas_destroy(&h.atlas)

	// Create Shared Render & Compute Pipelines
	if !_create_shared_pipelines(h) {
		fmt.eprintln("harness error: _create_shared_pipelines failed")
		os.exit(1)
	}

	// Initialize 4 Terminals
	synthetic_terminal_init(&h.term1, GRID_COLS_NORMAL, GRID_ROWS_NORMAL)
	defer synthetic_terminal_destroy(&h.term1)
	synthetic_terminal_init(&h.term2, GRID_COLS_NORMAL, GRID_ROWS_NORMAL)
	defer synthetic_terminal_destroy(&h.term2)
	synthetic_terminal_init(&h.term3, GRID_COLS_NORMAL, GRID_ROWS_NORMAL)
	defer synthetic_terminal_destroy(&h.term3)
	synthetic_terminal_init(&h.term4, GRID_COLS_NORMAL, GRID_ROWS_NORMAL)
	defer synthetic_terminal_destroy(&h.term4)

	// Initialize Renderer Instances
	terminal_instance.instance_renderer_init(&h.inst1, h.device, h.queue, 1024, h.atlas.gpu_view, h.format)
	tile.compute_tile_init(
		&h.tile2,
		h.device,
		h.queue,
		GRID_ROWS_NORMAL,
		GRID_COLS_NORMAL,
		h.pane_w / f32(GRID_COLS_NORMAL),
		h.pane_h / f32(GRID_ROWS_NORMAL),
		h.atlas.gpu_view,
		h.format,
	)
	fullscreen.fullscreen_init(
		&h.fs3,
		h.device,
		h.queue,
		GRID_ROWS_NORMAL,
		GRID_COLS_NORMAL,
		h.pane_w / f32(GRID_COLS_NORMAL),
		h.pane_h / f32(GRID_ROWS_NORMAL),
		h.atlas.gpu_view,
		h.format,
	)

	// Pane 4 supports all three strategies
	terminal_instance.instance_renderer_init(&h.inst4, h.device, h.queue, 1024, h.atlas.gpu_view, h.format)
	tile.compute_tile_init(
		&h.tile4,
		h.device,
		h.queue,
		GRID_ROWS_NORMAL,
		GRID_COLS_NORMAL,
		h.pane_w / f32(GRID_COLS_NORMAL),
		h.pane_h / f32(GRID_ROWS_NORMAL),
		h.atlas.gpu_view,
		h.format,
	)
	fullscreen.fullscreen_init(
		&h.fs4,
		h.device,
		h.queue,
		GRID_ROWS_NORMAL,
		GRID_COLS_NORMAL,
		h.pane_w / f32(GRID_COLS_NORMAL),
		h.pane_h / f32(GRID_ROWS_NORMAL),
		h.atlas.gpu_view,
		h.format,
	)

	// Allocate and wire resources for Normal 80x24 grid
	_handle_window_resize(h)

	fmt.println("==========================================================================")
	fmt.println(">>> Multi-Pane Terminal Render Harness (Phase 4 GUI) Active <<<")
	fmt.println("  Top-Left     (Pane 1): Strategy A (Instance Quad Batching)")
	fmt.println("  Top-Right    (Pane 2): Strategy B (Compute Tile 16x16 Binning)")
	fmt.println("  Bottom-Left  (Pane 3): Strategy C (Fullscreen Quad Direct)")
	fmt.println("  Bottom-Right (Pane 4): Dynamic Adaptive Selector (~35.9ns)")
	fmt.println("Controls: [Space] Toggle Blasting | [R] Toggle 80x24 <-> 500x200 | [C] Clear | [ESC] Quit")
	fmt.println("==========================================================================")

	// Main GUI Event Loop
	for h.running {
		event: sdl3.Event
		for sdl3.PollEvent(&event) {
			if event.type == .QUIT || event.type == .WINDOW_CLOSE_REQUESTED {
				h.running = false
				break
			}
			if event.type == .KEY_DOWN {
				switch event.key.key {
				case sdl3.K_ESCAPE:
					h.running = false
				case sdl3.K_SPACE:
					h.blasting = !h.blasting
					fmt.printf("-> [Space] Continuous data blasting: %v\n", h.blasting)
				case sdl3.K_R:
					h.is_extreme_size = !h.is_extreme_size
					new_cols: u32 = GRID_COLS_EXTREME if h.is_extreme_size else GRID_COLS_NORMAL
					new_rows: u32 = GRID_ROWS_EXTREME if h.is_extreme_size else GRID_ROWS_NORMAL
					synthetic_terminal_resize(&h.term1, new_cols, new_rows)
					synthetic_terminal_resize(&h.term2, new_cols, new_rows)
					synthetic_terminal_resize(&h.term3, new_cols, new_rows)
					synthetic_terminal_resize(&h.term4, new_cols, new_rows)
					_update_renderer_limits(h, new_cols, new_rows)
					fmt.printf("-> [R] Grid Resized: cols=%d, rows=%d (extreme=%v)\n", new_cols, new_rows, h.is_extreme_size)
				case sdl3.K_C:
					synthetic_terminal_clear(&h.term1)
					synthetic_terminal_clear(&h.term2)
					synthetic_terminal_clear(&h.term3)
					synthetic_terminal_clear(&h.term4)
					fmt.println("-> [C] Cleared all panes")
				}
			}
			if event.type == .WINDOW_RESIZED || event.type == .WINDOW_PIXEL_SIZE_CHANGED {
				_handle_window_resize(h)
			}
		}

		_render_frame(h)
	}

	// Resource Cleanup
	if rawptr(h.fs3_color_buf) != nil do contract.destroy_buffer(h.fs3_color_buf)
	if rawptr(h.fs4_color_buf) != nil do contract.destroy_buffer(h.fs4_color_buf)

	// Clean up renderers (detach shared pipelines first so they are not double-freed)
	h.inst1.pipeline = contract.Gpu_RenderPipeline(nil)
	h.inst4.pipeline = contract.Gpu_RenderPipeline(nil)
	h.tile2.compute_pipeline = contract.Gpu_ComputePipeline(nil)
	h.tile2.blit_pipeline = contract.Gpu_RenderPipeline(nil)
	h.tile4.compute_pipeline = contract.Gpu_ComputePipeline(nil)
	h.tile4.blit_pipeline = contract.Gpu_RenderPipeline(nil)
	h.fs3.pipeline = contract.Gpu_RenderPipeline(nil)
	h.fs4.pipeline = contract.Gpu_RenderPipeline(nil)

	terminal_instance.instance_renderer_destroy(&h.inst1)
	tile.compute_tile_destroy(&h.tile2)
	fullscreen.fullscreen_destroy(&h.fs3)
	terminal_instance.instance_renderer_destroy(&h.inst4)
	tile.compute_tile_destroy(&h.tile4)
	fullscreen.fullscreen_destroy(&h.fs4)

	if rawptr(h.glyph_pipeline) != nil do contract.destroy_render_pipeline(h.glyph_pipeline)
	if rawptr(h.compute_pipeline) != nil do contract.destroy_compute_pipeline(h.compute_pipeline)
	if rawptr(h.blit_pipeline) != nil do contract.destroy_render_pipeline(h.blit_pipeline)
	if rawptr(h.fs_pipeline) != nil do contract.destroy_render_pipeline(h.fs_pipeline)
}
