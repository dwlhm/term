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
import "core:c"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:slice"
import "core:sys/posix"
import "core:time"
import "vendor:sdl3"
import "vendor:wgpu"

when ODIN_OS == .Darwin {
	foreign import libobjc "system:objc"
	foreign import stb_image_write "vendor:stb/lib/darwin/stb_image_write.a"
	foreign stb_image_write {
		stbi_write_png :: proc(filename: cstring, w, h, comp: c.int, data: rawptr, stride_in_bytes: c.int) -> c.int ---
	}

	foreign import libc "system:c"

	@(default_calling_convention="c")
	foreign libc {
		fflush :: proc(stream: rawptr) -> c.int ---
	}

	@(default_calling_convention="c")
	foreign libobjc {
		objc_getClass :: proc(name: cstring) -> rawptr ---
		sel_registerName :: proc(name: cstring) -> rawptr ---
		object_getClass :: proc(obj: rawptr) -> rawptr ---
		class_getMethodImplementation :: proc(cls: rawptr, name: rawptr) -> rawptr ---
	}

	term_macos_get_thermal_state :: proc() -> i32 {
		cls := objc_getClass("NSProcessInfo")
		if cls == nil do return 0
		sel_proc := sel_registerName("processInfo")
		imp_proc := class_getMethodImplementation(object_getClass(cls), sel_proc)
		if imp_proc == nil do return 0
		Get_Proc :: #type proc "c" (cls: rawptr, sel: rawptr) -> rawptr
		proc_info := (Get_Proc(imp_proc))(cls, sel_proc)
		if proc_info == nil do return 0

		sel_ts := sel_registerName("thermalState")
		imp_ts := class_getMethodImplementation(object_getClass(proc_info), sel_ts)
		if imp_ts == nil do return 0
		Get_Int :: #type proc "c" (target: rawptr, sel: rawptr) -> int
		return i32((Get_Int(imp_ts))(proc_info, sel_ts))
	}
} else {
	stbi_write_png :: proc(filename: cstring, w, h, comp: c.int, data: rawptr, stride_in_bytes: c.int) -> c.int {
		return 0
	}
	term_macos_get_thermal_state :: proc() -> i32 { return 0 }
	fflush :: proc(stream: rawptr) -> c.int { return 0 }
}

_get_thread_time_ns :: proc() -> u64 {
	ts: posix.timespec
	posix.clock_gettime(posix.Clock(posix.CLOCK_THREAD_CPUTIME_ID), &ts)
	return u64(ts.tv_sec) * 1_000_000_000 + u64(ts.tv_nsec)
}

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
BG_WGSL           :: #load("../../core/render/shaders/bg.wgsl", string)
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
	actual_count := min(count, len(t.cells))
	if actual_count == 0 do return

	total := u32(len(t.cells))
	// Realistic terminal stream update: updates occur as a contiguous sequence of cells
	// starting from a random location (like typing, line editing, or stdout bursts).
	// This ensures the damage bounding box is localized and truly proportional to dirty cell count,
	// preventing random scatter from blowing the bounding box up to 100% full screen.
	start_idx := u32(helper.xoshiro256pp_next(rng) % u64(total))
	if start_idx + u32(actual_count) > total {
		start_idx = total - u32(actual_count)
	}

	for i in 0..<actual_count {
		idx := start_idx + u32(i)
		r   := idx / t.cols
		c   := idx % t.cols

		ch    := u32(33 + (helper.xoshiro256pp_next(rng) % 94))
		style := u32(1 + (helper.xoshiro256pp_next(rng) % 15))

		t.cells[idx] = pack_cell(ch, style, 1, 0, UNRESOLVED_SLOT)
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

RAW_PALETTE_COLORS := [16][3]u8{
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

PALETTE_PRECOMPUTED: [16][4]f32
SELECTED_FG_FLOAT:   [4]f32
SELECTED_BG_FLOAT:   [4]f32

init_style_lut :: proc(lut: ^[1025]u32) {
	for i in 0..<16 {
		c := RAW_PALETTE_COLORS[i]
		PALETTE_PRECOMPUTED[i] = unpack_r5g6b5(rgb_to_r5g6b5(c[0], c[1], c[2]))
	}
	SELECTED_FG_FLOAT = unpack_r5g6b5(rgb_to_r5g6b5(255, 255, 255))
	SELECTED_BG_FLOAT = unpack_r5g6b5(rgb_to_r5g6b5(60, 100, 180))

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

unpack_r5g6b5 :: #force_inline proc "contextless" (packed: u16) -> [4]f32 {
	r := math.round(f32((packed >> 11) & 0x1F) / 31.0 * 255.0) / 255.0
	g := math.round(f32((packed >> 5) & 0x3F) / 63.0 * 255.0) / 255.0
	b := math.round(f32(packed & 0x1F) / 31.0 * 255.0) / 255.0
	return {r, g, b, 1.0}
}

palette_srgb_float :: #force_inline proc "contextless" (style: u32, is_fg: bool) -> [4]f32 {
	s := style & 1023
	if s == 0 {
		return PALETTE_PRECOMPUTED[15] if is_fg else PALETTE_PRECOMPUTED[0]
	}
	idx := (s & 15) if is_fg else ((s >> 4) & 15)
	return PALETTE_PRECOMPUTED[idx]
}

palette_style_colors :: #force_inline proc "contextless" (style: u32) -> (fg, bg: [4]f32) {
	s := style & 1023
	if s == 0 {
		return PALETTE_PRECOMPUTED[15], PALETTE_PRECOMPUTED[0]
	}
	return PALETTE_PRECOMPUTED[s & 15], PALETTE_PRECOMPUTED[(s >> 4) & 15]
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
	bg_pipeline:      contract.Gpu_RenderPipeline,
	bg_layout:        contract.Gpu_BindGroupLayout,
	compute_pipeline: contract.Gpu_ComputePipeline,
	compute_layout:   contract.Gpu_BindGroupLayout,
	blit_pipeline:    contract.Gpu_RenderPipeline,
	blit_layout:      contract.Gpu_BindGroupLayout,
	fs_pipeline:      contract.Gpu_RenderPipeline,
	fs_layout:        contract.Gpu_BindGroupLayout,

	// Pane 1: Instance, Tile, Fullscreen
	term1:            Synthetic_Terminal,
	inst1:            terminal_instance.Instance_Renderer,
	tile1:            tile.Compute_Tile_Renderer,
	fs1:              fullscreen.Fullscreen_Renderer,
	fs1_color_buf:    contract.Gpu_Buffer,
	strat1_state:     terminal.Strategy_State,

	// Pane 2: Instance, Tile, Fullscreen
	term2:            Synthetic_Terminal,
	inst2:            terminal_instance.Instance_Renderer,
	tile2:            tile.Compute_Tile_Renderer,
	fs2:              fullscreen.Fullscreen_Renderer,
	fs2_color_buf:    contract.Gpu_Buffer,
	strat2_state:     terminal.Strategy_State,

	// Pane 3: Instance, Tile, Fullscreen
	term3:            Synthetic_Terminal,
	inst3:            terminal_instance.Instance_Renderer,
	tile3:            tile.Compute_Tile_Renderer,
	fs3:              fullscreen.Fullscreen_Renderer,
	fs3_color_buf:    contract.Gpu_Buffer,
	strat3_state:     terminal.Strategy_State,

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

	// 2. Instance Background Render Pipeline (same layout, location 3 is bg_color at offset 48)
	bg_mod := contract.create_shader_module(h.device, BG_WGSL)
	if rawptr(bg_mod) == nil do return false
	defer contract.destroy_shader_module(bg_mod)

	bg_attrs := []contract.Gpu_Vertex_Attribute{
		{format = .Float32x2, offset = 0, shader_location = 0},
		{format = .Float32x2, offset = 8, shader_location = 1},
		{format = .Float32x4, offset = 16, shader_location = 2},
		{format = .Float32x4, offset = 48, shader_location = 3},
	}
	bg_layouts := []contract.Gpu_Vertex_Layout{
		{
			array_stride = size_of(contract.Instance_Record),
			step_mode    = .Instance,
			attributes   = bg_attrs,
		},
	}

	h.bg_pipeline = contract.create_render_pipeline(
		h.device,
		bg_mod,
		"vs_main",
		bg_mod,
		"fs_main",
		bg_layouts,
		h.format,
		.Alpha_Blend,
		.Triangle_List,
	)
	if rawptr(h.bg_pipeline) == nil do return false
	h.bg_layout = contract.pipeline_get_bind_group_layout(h.bg_pipeline, 0)

	// 3. Compute Tile Pipelines (Compute + Blit)
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

	// 4. Fullscreen Quad Direct Render Pipeline
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
	exact_w := max(u32(f32(cols) * cell_w), 1)
	exact_h := max(u32(f32(rows) * cell_h), 1)

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
	if rawptr(r.framebuffer) == nil || r.fb_w_px != exact_w || r.fb_h_px != exact_h {
		if rawptr(r.fb_view) != nil do contract.destroy_texture_view(r.fb_view)
		if rawptr(r.framebuffer) != nil do contract.destroy_texture(r.framebuffer)

		r.fb_w_px = exact_w
		r.fb_h_px = exact_h
		usage := contract.Gpu_Texture_Usage.Storage_Binding |
		         contract.Gpu_Texture_Usage.Texture_Binding |
		         contract.Gpu_Texture_Usage.Copy_Src
		r.framebuffer = contract.create_texture(h.device, exact_w, exact_h, .RGBA8_Unorm, usage)
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
	r.has_params = false
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
	exact_w := max(u32(f32(cols) * cell_w), 1)
	exact_h := max(u32(f32(rows) * cell_h), 1)
	_ = exact_w
	_ = exact_h

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
	r.has_params = false
	r.available = true
	return rawptr(r.bind_group) != nil
}

_rebuild_instance_resources :: proc(
	h: ^Harness_State,
	r: ^terminal_instance.Instance_Renderer,
	cols, rows: u32,
	pane_w, pane_h: f32,
) -> bool {
	cell_w := pane_w / f32(cols)
	cell_h := pane_h / f32(rows)
	exact_w := max(u32(f32(cols) * cell_w), 1)
	exact_h := max(u32(f32(rows) * cell_h), 1)
	_ = exact_w
	_ = exact_h

	r.has_uniforms = false

	max_instances := cols * rows
	if r.max_instances >= max_instances && rawptr(r.instance_buffer) != nil && rawptr(r.bind_group) != nil do return true

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

	if rawptr(r.bg_bind_group) != nil do contract.destroy_bind_group(r.bg_bind_group)
	if rawptr(h.bg_layout) != nil {
		bg_entries := []contract.Gpu_Bind_Entry{
			{binding = 0, buffer = r.uniform_buffer, offset = 0, size = 0, entry_type = .Buffer},
		}
		r.bg_bind_group = contract.create_bind_group(h.device, h.bg_layout, bg_entries)
	}

	r.pipeline = h.glyph_pipeline
	r.available = true
	return rawptr(r.bind_group) != nil
}

Pane_Context :: struct {
	term:        ^Synthetic_Terminal,
	inst:        ^terminal_instance.Instance_Renderer,
	tile:        ^tile.Compute_Tile_Renderer,
	fs:          ^fullscreen.Fullscreen_Renderer,
	color_buf:   ^contract.Gpu_Buffer,
	strat_state: ^terminal.Strategy_State,
	layer_id:    composer.Layer_Id,
}

_get_pane_context :: proc(h: ^Harness_State, pane_idx: int) -> Pane_Context {
	switch pane_idx {
	case 0:
		return {&h.term1, &h.inst1, &h.tile1, &h.fs1, &h.fs1_color_buf, &h.strat1_state, 1}
	case 1:
		return {&h.term2, &h.inst2, &h.tile2, &h.fs2, &h.fs2_color_buf, &h.strat2_state, 2}
	case 2:
		return {&h.term3, &h.inst3, &h.tile3, &h.fs3, &h.fs3_color_buf, &h.strat3_state, 3}
	case 3:
		return {&h.term4, &h.inst4, &h.tile4, &h.fs4, &h.fs4_color_buf, &h.strat4_state, 4}
	}
	return {}
}

_update_renderer_limits :: proc(h: ^Harness_State, cols, rows: u32) {
	cell_w := h.pane_w / f32(cols)
	cell_h := h.pane_h / f32(rows)
	exact_w := max(u32(f32(cols) * cell_w), 1)
	exact_h := max(u32(f32(rows) * cell_h), 1)

	// Update layer textures to exact pixel size to prevent squashing
	l1, _ := pipeline.composer_pipeline_acquire_layer(&h.composer_pipe, 1, .Terminal, exact_w, exact_h, false)
	l2, _ := pipeline.composer_pipeline_acquire_layer(&h.composer_pipe, 2, .Terminal, exact_w, exact_h, false)
	l3, _ := pipeline.composer_pipeline_acquire_layer(&h.composer_pipe, 3, .Terminal, exact_w, exact_h, false)
	l4, _ := pipeline.composer_pipeline_acquire_layer(&h.composer_pipe, 4, .Terminal, exact_w, exact_h, false)
	if l1 != nil { l1.dest_rect = composer.rect_make(0, 0, h.pane_w, h.pane_h); l1.scissor_rect = l1.dest_rect; l1.opacity = 1.0 }
	if l2 != nil { l2.dest_rect = composer.rect_make(h.pane_w, 0, h.pane_w, h.pane_h); l2.scissor_rect = l2.dest_rect; l2.opacity = 1.0 }
	if l3 != nil { l3.dest_rect = composer.rect_make(0, h.pane_h, h.pane_w, h.pane_h); l3.scissor_rect = l3.dest_rect; l3.opacity = 1.0 }
	if l4 != nil { l4.dest_rect = composer.rect_make(h.pane_w, h.pane_h, h.pane_w, h.pane_h); l4.scissor_rect = l4.dest_rect; l4.opacity = 1.0 }

	for p in 0..<4 {
		ctx := _get_pane_context(h, p)
		_rebuild_instance_resources(h, ctx.inst, cols, rows, h.pane_w, h.pane_h)
		_rebuild_tile_resources(h, ctx.tile, cols, rows, h.pane_w, h.pane_h)
		contract.write_buffer(h.queue, ctx.tile.lut_buffer, 0, &h.lut_words, size_of(h.lut_words))
		_rebuild_fullscreen_resources(h, ctx.fs, ctx.color_buf, cols, rows, h.pane_w, h.pane_h)
		contract.write_buffer(h.queue, ctx.fs.lut_buffer, 0, &h.lut_words, size_of(h.lut_words))
	}
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

				u0, v0, u1, v1 := atlas.atlas_slot_uv(slot, cell_w, cell_h)
				if slot == UNRESOLVED_SLOT && content >= 32 && content <= 126 {
					u0, v0, u1, v1 = atlas.atlas_slot_uv(content - 32, cell_w, cell_h)
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
			contract.render_set_pipeline(pass1, h.bg_pipeline)
			bg_bg1 := h.inst1.bg_bind_group if rawptr(h.inst1.bg_bind_group) != nil else h.inst1.bind_group
			contract.render_set_bind_group(pass1, 0, bg_bg1)
			contract.render_set_vertex_buffer(pass1, 0, h.inst1.instance_buffer, 0)
			contract.render_draw(pass1, 6, h.inst1.active_count)
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

						u0, v0, u1, v1 := atlas.atlas_slot_uv(slot, cell_w, cell_h)
						if slot == UNRESOLVED_SLOT && content >= 32 && content <= 126 {
							u0, v0, u1, v1 = atlas.atlas_slot_uv(content - 32, cell_w, cell_h)
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

				contract.render_set_pipeline(pass4, h.bg_pipeline)
				bg_bg4 := h.inst4.bg_bind_group if rawptr(h.inst4.bg_bind_group) != nil else h.inst4.bind_group
				contract.render_set_bind_group(pass4, 0, bg_bg4)
				contract.render_set_vertex_buffer(pass4, 0, h.inst4.instance_buffer, 0)
				contract.render_draw(pass4, 6, h.inst4.active_count)
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
// 5. Automated BGRA8 Truth Fuzzer & Negative Tests (docs/HARNESS_BENCHMARK_PLAN.md §6)
// ============================================================================

_Fuzz_Defects :: struct {
	neg1_disable_dilation:       bool,
	neg2_disable_space_bg:        bool,
	neg3_reverse_pass_order:     bool,
	neg4_reduced_row_damage:     bool,
	neg5_skip_attr_damage:       bool,
	neg6_inject_comparator_byte:  bool,
}

_apply_fuzz_mutation :: proc(
	term_a, term_b: ^Synthetic_Terminal,
	rng: ^helper.Xoshiro256pp,
	class: int,
) -> (kind: int, r, c: u32, is_attr_only: bool, is_erase: bool) {
	kind = class % 8
	cols := term_a.cols
	rows := term_a.rows

	switch kind {
	case 0: // Plain ASCII edit
		r = u32(helper.xoshiro256pp_next(rng) % u64(rows))
		c = u32(helper.xoshiro256pp_next(rng) % u64(cols))
		ch := rune(33 + (helper.xoshiro256pp_next(rng) % 94))
		style := u32(1 + (helper.xoshiro256pp_next(rng) % 15))
		term_a.cells[r * cols + c] = pack_cell(u32(ch), style, 1, 0, u32(ch) - 32)
		term_b.cells[r * cols + c] = term_a.cells[r * cols + c]
		term_a.damage = contract.damage_rect_make(c, r, 1, 1)
		term_b.damage = term_a.damage

	case 1: // Attribute-only change (style changed, same codepoint)
		r = u32(helper.xoshiro256pp_next(rng) % u64(rows))
		c = u32(helper.xoshiro256pp_next(rng) % u64(cols))
		packed := term_a.cells[r * cols + c]
		content, old_style, width, cflags, slot := unpack_cell(packed)
		if content == 0 || content == ' ' {
			content = 'A'
			slot = u32('A') - 32
		}
		new_style := u32((old_style + 1 + u32(helper.xoshiro256pp_next(rng) % 14)) % 16)
		if new_style == 0 do new_style = 1
		term_a.cells[r * cols + c] = pack_cell(content, new_style, width, cflags, slot)
		term_b.cells[r * cols + c] = term_a.cells[r * cols + c]
		term_a.damage = contract.damage_rect_make(c, r, 1, 1)
		term_b.damage = term_a.damage
		is_attr_only = true

	case 2: // Wide CJK at the last column
		r = u32(helper.xoshiro256pp_next(rng) % u64(rows))
		c = cols - 1
		ch := rune('W')
		style := u32(2 + (helper.xoshiro256pp_next(rng) % 14))
		term_a.cells[r * cols + c] = pack_cell(u32(ch), style, 1, 0, u32(ch) - 32)
		term_b.cells[r * cols + c] = term_a.cells[r * cols + c]
		term_a.damage = contract.damage_rect_make(c, r, 1, 1)
		term_b.damage = term_a.damage

	case 3: // Combining and ZWJ clusters / symbols
		r = u32(helper.xoshiro256pp_next(rng) % u64(rows))
		c = u32(helper.xoshiro256pp_next(rng) % u64(cols))
		symbols := []rune{'@', '#', '$', '%', '&', '*', '+', '=', '<', '>', '~', '^', '?', '!', '/'}
		ch := symbols[helper.xoshiro256pp_next(rng) % u64(len(symbols))]
		style := u32(3 + (helper.xoshiro256pp_next(rng) % 13))
		term_a.cells[r * cols + c] = pack_cell(u32(ch), style, 1, 0, u32(ch) - 32)
		term_b.cells[r * cols + c] = term_a.cells[r * cols + c]
		term_a.damage = contract.damage_rect_make(c, r, 1, 1)
		term_b.damage = term_a.damage

	case 4: // Descenders (g y p q j _)
		r = u32(helper.xoshiro256pp_next(rng) % u64(rows))
		c = u32(helper.xoshiro256pp_next(rng) % u64(cols))
		descenders := []rune{'g', 'y', 'p', 'q', 'j', '_'}
		ch := descenders[helper.xoshiro256pp_next(rng) % u64(len(descenders))]
		style := u32(1 + (helper.xoshiro256pp_next(rng) % 15))
		term_a.cells[r * cols + c] = pack_cell(u32(ch), style, 1, 0, u32(ch) - 32)
		term_b.cells[r * cols + c] = term_a.cells[r * cols + c]
		term_a.damage = contract.damage_rect_make(c, r, 1, 1)
		term_b.damage = term_a.damage

	case 5: // Italic overhang next to box drawing
		r = u32(helper.xoshiro256pp_next(rng) % u64(rows))
		c = u32(helper.xoshiro256pp_next(rng) % u64(max(cols - 2, 1)))
		ch1 := rune('|')
		ch2 := rune('/')
		term_a.cells[r * cols + c] = pack_cell(u32(ch1), 4, 1, 0, u32(ch1) - 32)
		term_a.cells[r * cols + c + 1] = pack_cell(u32(ch2), 5, 1, 0, u32(ch2) - 32)
		term_b.cells[r * cols + c] = term_a.cells[r * cols + c]
		term_b.cells[r * cols + c + 1] = term_a.cells[r * cols + c + 1]
		term_a.damage = contract.damage_rect_make(c, r, 2, 1)
		term_b.damage = term_a.damage

	case 6: // Cursor and selection overlay
		r = u32(helper.xoshiro256pp_next(rng) % u64(rows))
		c = u32(helper.xoshiro256pp_next(rng) % u64(cols))
		ch := rune('X')
		term_a.cells[r * cols + c] = pack_cell(u32(ch), 6, 1, 2, u32(ch) - 32)
		term_b.cells[r * cols + c] = term_a.cells[r * cols + c]
		term_a.damage = contract.damage_rect_make(c, r, 1, 1)
		term_b.damage = term_a.damage

	case 7: // Scroll or Erase
		if helper.xoshiro256pp_next(rng) % 2 == 0 {
			r = u32(helper.xoshiro256pp_next(rng) % u64(rows))
			c = u32(helper.xoshiro256pp_next(rng) % u64(cols))
			term_a.cells[r * cols + c] = pack_cell(' ', 0, 1, 0, 0)
			term_b.cells[r * cols + c] = term_a.cells[r * cols + c]
			term_a.damage = contract.damage_rect_make(c, r, 1, 1)
			term_b.damage = term_a.damage
			is_erase = true
		} else {
			for row in 0..<int(rows - 1) {
				for col in 0..<int(cols) {
					term_a.cells[row * int(cols) + col] = term_a.cells[(row + 1) * int(cols) + col]
					term_b.cells[row * int(cols) + col] = term_a.cells[row * int(cols) + col]
				}
			}
			for col in 0..<int(cols) {
				term_a.cells[int(rows - 1) * int(cols) + col] = pack_cell(' ', 0, 1, 0, 0)
				term_b.cells[int(rows - 1) * int(cols) + col] = pack_cell(' ', 0, 1, 0, 0)
			}
			term_a.damage = contract.damage_rect_make(0, 0, cols, rows)
			term_b.damage = term_a.damage
		}
	}
	return
}

_dump_fuzz_pngs :: proc(
	fuzz_w, fuzz_h: u32,
	pixels_a, pixels_b, pixels_diff: []u8,
) {
	os.make_directory("artifacts")
	stbi_write_png("artifacts/fuzz_fail_partial.png", c.int(fuzz_w), c.int(fuzz_h), 4, raw_data(pixels_a), c.int(fuzz_w * 4))
	stbi_write_png("artifacts/fuzz_fail_full.png", c.int(fuzz_w), c.int(fuzz_h), 4, raw_data(pixels_b), c.int(fuzz_w * 4))
	stbi_write_png("artifacts/fuzz_fail_diff.png", c.int(fuzz_w), c.int(fuzz_h), 4, raw_data(pixels_diff), c.int(fuzz_w * 4))
}

_fuzz_render_and_compare :: proc(
	h: ^Harness_State,
	inst: ^terminal_instance.Instance_Renderer,
	fs: ^fullscreen.Fullscreen_Renderer,
	fs_color_buf: ^contract.Gpu_Buffer,
	term_a, term_b: ^Synthetic_Terminal,
	tex_a, tex_b: contract.Gpu_Texture,
	view_a, view_b: contract.Gpu_TextureView,
	buf_a, buf_b: contract.Gpu_Buffer,
	fuzz_w, fuzz_h: u32,
	cell_w, cell_h: f32,
	bytes_per_row: u32,
	buf_size: u64,
	is_full_redraw: bool,
	is_attr_only: bool,
	is_erase: bool,
	defects: _Fuzz_Defects,
) -> (diff_pixels: int, first_x: int, first_y: int, ra, ga, ba, aa, rb, gb, bb, ab: u8) {
	cols := term_a.cols
	rows := term_a.rows

	// 1. Prepare Instance Renderer (Target A)
	terminal_instance.instance_renderer_begin(inst)
	u_data := [4]f32{f32(fuzz_w), f32(fuzz_h), cell_w, cell_h}
	contract.write_buffer(h.queue, inst.uniform_buffer, 0, &u_data, size_of([4]f32))

	x0: u32 = 0
	x1: u32 = cols
	y0: u32 = 0
	y1: u32 = rows

	if !is_full_redraw {
		d := term_a.damage
		if defects.neg1_disable_dilation {
			x0 = d.x
			x1 = min(d.x + d.w, cols)
		} else {
			x0 = u32(max(int(d.x) - 1, 0))
			x1 = min(d.x + d.w + 1, cols)
		}

		if defects.neg4_reduced_row_damage {
			y0 = d.y
			y1 = min(d.y + max(d.h, 1) - 1, rows)
		} else {
			y0 = d.y
			y1 = min(d.y + d.h, rows)
		}
	}

	for r in y0..<y1 {
		for c in x0..<x1 {
			packed := term_a.cells[r * cols + c]
			content, style, _, cflags, slot := unpack_cell(packed)

			if defects.neg5_skip_attr_damage && is_attr_only {
				continue
			}
			if defects.neg2_disable_space_bg && is_erase && !is_full_redraw {
				continue
			}

			u0, v0, u1, v1 := atlas.atlas_slot_uv(slot, cell_w, cell_h)
			if slot == UNRESOLVED_SLOT && content >= 32 && content <= 126 {
				u0, v0, u1, v1 = atlas.atlas_slot_uv(content - 32, cell_w, cell_h)
			}

			is_selected := (cflags & 2) != 0
			fg := unpack_r5g6b5(rgb_to_r5g6b5(255, 255, 255)) if is_selected else palette_srgb_float(style, true)
			bg := unpack_r5g6b5(rgb_to_r5g6b5(60, 100, 180)) if is_selected else palette_srgb_float(style, false)

			rec := contract.Instance_Record{
				pos_size = {f32(c) * cell_w, f32(r) * cell_h, cell_w, cell_h},
				uv_rect  = {u0, v0, u1, v1},
				fg_color = fg,
				bg_color = bg,
			}
			terminal_instance.instance_renderer_push(inst, rec)
		}
	}
	terminal_instance.instance_renderer_flush(inst)

	// 2. Prepare Fullscreen Renderer (Target B)
	contract.write_buffer(h.queue, fs.cell_buffer, 0, raw_data(term_b.cells), u64(len(term_b.cells) * size_of(u64)))
	contract.write_buffer(h.queue, fs.lut_buffer, 0, &h.lut_words, size_of(h.lut_words))
	zeros := make([]u8, len(term_b.cells) * int(FULLSCREEN_CELL_BYTES), context.temp_allocator)
	contract.write_buffer(h.queue, fs_color_buf^, 0, raw_data(zeros), u64(len(zeros)))
	fs_p := fullscreen.Fullscreen_Params{
		screen_w     = f32(fuzz_w),
		screen_h     = f32(fuzz_h),
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
	contract.write_buffer(h.queue, fs.params_buffer, 0, &fs_p, size_of(fullscreen.Fullscreen_Params))

	// 3. Render Passes
	enc := contract.create_command_encoder(h.device)
	if rawptr(enc) == nil do return

	clear_col := [4]f64{f64(2.0/31.0), f64(5.0/63.0), f64(3.0/31.0), 1.0}
	load_op_a := contract.Gpu_Load_Op.Clear if is_full_redraw else contract.Gpu_Load_Op.Load

	pass_a := contract.begin_render_pass(enc, view_a, clear_col, load_op_a)
	if rawptr(pass_a) != nil {
		bg_bg := inst.bg_bind_group if rawptr(inst.bg_bind_group) != nil else inst.bind_group
		if defects.neg3_reverse_pass_order {
			terminal_instance.instance_renderer_draw(inst, pass_a)
			contract.render_set_pipeline(pass_a, h.bg_pipeline)
			contract.render_set_bind_group(pass_a, 0, bg_bg)
			contract.render_set_vertex_buffer(pass_a, 0, inst.instance_buffer, 0)
			contract.render_draw(pass_a, 6, inst.active_count)
		} else {
			contract.render_set_pipeline(pass_a, h.bg_pipeline)
			contract.render_set_bind_group(pass_a, 0, bg_bg)
			contract.render_set_vertex_buffer(pass_a, 0, inst.instance_buffer, 0)
			contract.render_draw(pass_a, 6, inst.active_count)
			terminal_instance.instance_renderer_draw(inst, pass_a)
		}
		contract.end_render_pass(pass_a)
	}

	pass_b := contract.begin_render_pass(enc, view_b, clear_col, .Clear)
	if rawptr(pass_b) != nil {
		fullscreen.fullscreen_draw(fs, pass_b)
		contract.end_render_pass(pass_b)
	}

	// 4. Copy Textures to Readback Buffers
	wgpu_enc := wgpu.CommandEncoder(rawptr(enc))
	src_a := wgpu.TexelCopyTextureInfo{
		texture  = wgpu.Texture(rawptr(tex_a)),
		mipLevel = 0,
		origin   = {0, 0, 0},
		aspect   = .All,
	}
	dst_a := wgpu.TexelCopyBufferInfo{
		layout = {offset = 0, bytesPerRow = bytes_per_row, rowsPerImage = fuzz_h},
		buffer = wgpu.Buffer(rawptr(buf_a)),
	}
	copy_size := wgpu.Extent3D{width = fuzz_w, height = fuzz_h, depthOrArrayLayers = 1}
	wgpu.CommandEncoderCopyTextureToBuffer(wgpu_enc, &src_a, &dst_a, &copy_size)

	src_b := wgpu.TexelCopyTextureInfo{
		texture  = wgpu.Texture(rawptr(tex_b)),
		mipLevel = 0,
		origin   = {0, 0, 0},
		aspect   = .All,
	}
	dst_b := wgpu.TexelCopyBufferInfo{
		layout = {offset = 0, bytesPerRow = bytes_per_row, rowsPerImage = fuzz_h},
		buffer = wgpu.Buffer(rawptr(buf_b)),
	}
	wgpu.CommandEncoderCopyTextureToBuffer(wgpu_enc, &src_b, &dst_b, &copy_size)

	cmd := contract.finish_command_buffer(enc)
	contract.release_command_encoder(enc)
	if cmd != nil {
		contract.submit(h.queue, cmd)
		contract.release_command_buffer(cmd)
	}
	contract.wait_for_idle(h.device)

	// 5. Readback Mapping & Comparison
	map_a_done := false
	map_b_done := false
	_on_map_a :: proc "c" (status: wgpu.MapAsyncStatus, message: wgpu.StringView, userdata1: rawptr, userdata2: rawptr) {
		if userdata1 != nil do (^bool)(userdata1)^ = true
	}

	_ = wgpu.BufferMapAsync(
		wgpu.Buffer(rawptr(buf_a)),
		{.Read},
		0,
		uint(buf_size),
		wgpu.BufferMapCallbackInfo{
			mode      = .AllowProcessEvents,
			callback  = _on_map_a,
			userdata1 = &map_a_done,
		},
	)
	_ = wgpu.BufferMapAsync(
		wgpu.Buffer(rawptr(buf_b)),
		{.Read},
		0,
		uint(buf_size),
		wgpu.BufferMapCallbackInfo{
			mode      = .AllowProcessEvents,
			callback  = _on_map_a,
			userdata1 = &map_b_done,
		},
	)

	wgpu_inst := wgpu.Instance(h.instance)
	wgpu_dev := wgpu.Device(rawptr(h.device))
	for !map_a_done || !map_b_done {
		wgpu.InstanceProcessEvents(wgpu_inst)
		wgpu.DevicePoll(wgpu_dev, true, nil)
	}

	ptr_a := ([^]u8)(wgpu.RawBufferGetConstMappedRange(wgpu.Buffer(rawptr(buf_a)), 0, uint(buf_size)))
	ptr_b := ([^]u8)(wgpu.RawBufferGetConstMappedRange(wgpu.Buffer(rawptr(buf_b)), 0, uint(buf_size)))

	diff_pixels = 0
	first_x = -1
	first_y = -1

	pixels_a := make([]u8, int(fuzz_w * fuzz_h * 4), context.temp_allocator)
	pixels_b := make([]u8, int(fuzz_w * fuzz_h * 4), context.temp_allocator)
	pixels_diff := make([]u8, int(fuzz_w * fuzz_h * 4), context.temp_allocator)

	if ptr_a != nil && ptr_b != nil {
		for y in 0..<int(fuzz_h) {
			row_off := y * int(bytes_per_row)
			dst_row := y * int(fuzz_w) * 4
			for x in 0..<int(fuzz_w) {
				p_src := row_off + x * 4
				p_dst := dst_row + x * 4

				cur_ba := ptr_a[p_src + 0]
				cur_ga := ptr_a[p_src + 1]
				cur_ra := ptr_a[p_src + 2]
				cur_aa := ptr_a[p_src + 3]

				cur_bb := ptr_b[p_src + 0]
				cur_gb := ptr_b[p_src + 1]
				cur_rb := ptr_b[p_src + 2]
				cur_ab := ptr_b[p_src + 3]

				if defects.neg6_inject_comparator_byte && x == 0 && y == 0 {
					cur_bb ~= 0xFF
				}

				pixels_a[p_dst + 0] = cur_ra
				pixels_a[p_dst + 1] = cur_ga
				pixels_a[p_dst + 2] = cur_ba
				pixels_a[p_dst + 3] = cur_aa

				pixels_b[p_dst + 0] = cur_rb
				pixels_b[p_dst + 1] = cur_gb
				pixels_b[p_dst + 2] = cur_bb
				pixels_b[p_dst + 3] = cur_ab

				is_mismatch := (cur_ba != cur_bb || cur_ga != cur_gb || cur_ra != cur_rb || cur_aa != cur_ab)
				if is_mismatch {
					diff_pixels += 1
					if first_x == -1 {
						first_x = x
						first_y = y
						ba = cur_ba
						ga = cur_ga
						ra = cur_ra
						aa = cur_aa
						bb = cur_bb
						gb = cur_gb
						rb = cur_rb
						ab = cur_ab
					}
					pixels_diff[p_dst + 0] = 255
					pixels_diff[p_dst + 1] = 0
					pixels_diff[p_dst + 2] = 255
					pixels_diff[p_dst + 3] = 255
				} else {
					gray := u8((u32(cur_ra) + u32(cur_ga) + u32(cur_ba)) / 6)
					pixels_diff[p_dst + 0] = gray
					pixels_diff[p_dst + 1] = gray
					pixels_diff[p_dst + 2] = gray
					pixels_diff[p_dst + 3] = 255
				}
			}
		}
	}

	wgpu.BufferUnmap(wgpu.Buffer(rawptr(buf_a)))
	wgpu.BufferUnmap(wgpu.Buffer(rawptr(buf_b)))

	if diff_pixels > 0 && !defects.neg1_disable_dilation && !defects.neg2_disable_space_bg && !defects.neg3_reverse_pass_order && !defects.neg4_reduced_row_damage && !defects.neg5_skip_attr_damage && !defects.neg6_inject_comparator_byte {
		_dump_fuzz_pngs(fuzz_w, fuzz_h, pixels_a, pixels_b, pixels_diff)
	}

	return
}

_run_truth_fuzzer_and_negative_tests :: proc(h: ^Harness_State) -> bool {
	fuzz_cols: u32 = 80
	fuzz_rows: u32 = 24
	cell_w: f32 = 10.0
	cell_h: f32 = 20.0
	fuzz_w: u32 = fuzz_cols * u32(cell_w)
	fuzz_h: u32 = fuzz_rows * u32(cell_h)
	bytes_per_row: u32 = ((fuzz_w * 4) + 255) & ~u32(255)
	buf_size: u64 = u64(bytes_per_row) * u64(fuzz_h)

	// Create dedicated offscreen targets A and B
	tex_usage := contract.Gpu_Texture_Usage.Render_Attach | contract.Gpu_Texture_Usage.Copy_Src
	tex_a := contract.create_texture(h.device, fuzz_w, fuzz_h, h.format, tex_usage)
	view_a := contract.create_texture_view(tex_a)
	defer {
		if rawptr(view_a) != nil do contract.destroy_texture_view(view_a)
		if rawptr(tex_a) != nil do contract.destroy_texture(tex_a)
	}

	tex_b := contract.create_texture(h.device, fuzz_w, fuzz_h, h.format, tex_usage)
	view_b := contract.create_texture_view(tex_b)
	defer {
		if rawptr(view_b) != nil do contract.destroy_texture_view(view_b)
		if rawptr(tex_b) != nil do contract.destroy_texture(tex_b)
	}

	buf_usage := contract.Gpu_Buffer_Usage.Map_Read | contract.Gpu_Buffer_Usage.Copy_Dst
	buf_a := contract.create_buffer(h.device, buf_size, buf_usage, false)
	defer if rawptr(buf_a) != nil do contract.destroy_buffer(buf_a)
	buf_b := contract.create_buffer(h.device, buf_size, buf_usage, false)
	defer if rawptr(buf_b) != nil do contract.destroy_buffer(buf_b)

	nearest_desc := wgpu.SamplerDescriptor{
		addressModeU  = .ClampToEdge,
		addressModeV  = .ClampToEdge,
		addressModeW  = .ClampToEdge,
		magFilter     = .Nearest,
		minFilter     = .Nearest,
		mipmapFilter  = .Nearest,
		lodMinClamp   = 0.0,
		lodMaxClamp   = 32.0,
		maxAnisotropy = 1,
	}
	nearest_sampler := contract.Gpu_Sampler(wgpu.DeviceCreateSampler(wgpu.Device(rawptr(h.device)), &nearest_desc))
	defer if rawptr(nearest_sampler) != nil do contract.destroy_sampler(nearest_sampler)

	// Dedicated renderers
	fuzz_inst: terminal_instance.Instance_Renderer
	terminal_instance.instance_renderer_init(&fuzz_inst, h.device, h.queue, fuzz_cols * fuzz_rows, h.atlas.gpu_view, h.format)
	if rawptr(fuzz_inst.sampler) != nil do contract.destroy_sampler(fuzz_inst.sampler)
	fuzz_inst.sampler = nearest_sampler
	defer {
		fuzz_inst.sampler = contract.Gpu_Sampler(nil)
		fuzz_inst.pipeline = contract.Gpu_RenderPipeline(nil)
		terminal_instance.instance_renderer_destroy(&fuzz_inst)
	}
	_rebuild_instance_resources(h, &fuzz_inst, fuzz_cols, fuzz_rows, f32(fuzz_w), f32(fuzz_h))

	fuzz_fs: fullscreen.Fullscreen_Renderer
	fullscreen.fullscreen_init(&fuzz_fs, h.device, h.queue, fuzz_rows, fuzz_cols, cell_w, cell_h, h.atlas.gpu_view, h.format)
	if rawptr(fuzz_fs.sampler) != nil do contract.destroy_sampler(fuzz_fs.sampler)
	fuzz_fs.sampler = nearest_sampler
	defer {
		fuzz_fs.sampler = contract.Gpu_Sampler(nil)
		fuzz_fs.pipeline = contract.Gpu_RenderPipeline(nil)
		fullscreen.fullscreen_destroy(&fuzz_fs)
	}
	fuzz_fs_color_buf: contract.Gpu_Buffer
	defer if rawptr(fuzz_fs_color_buf) != nil do contract.destroy_buffer(fuzz_fs_color_buf)
	_rebuild_fullscreen_resources(h, &fuzz_fs, &fuzz_fs_color_buf, fuzz_cols, fuzz_rows, f32(fuzz_w), f32(fuzz_h))

	term_a: Synthetic_Terminal
	synthetic_terminal_init(&term_a, fuzz_cols, fuzz_rows)
	defer synthetic_terminal_destroy(&term_a)

	term_b: Synthetic_Terminal
	synthetic_terminal_init(&term_b, fuzz_cols, fuzz_rows)
	defer synthetic_terminal_destroy(&term_b)

	fmt.println("================================================================================")
	fmt.println("     RUNNING 6 NEGATIVE MUTATION TESTS (docs/HARNESS_BENCHMARK_PLAN.md §6.4)    ")
	fmt.println("================================================================================")

	// Neg-1: ±1 column dilation disabled
	fmt.println("  [Negative 1] ±1 column dilation disabled:")
	synthetic_terminal_clear(&term_a)
	synthetic_terminal_clear(&term_b)
	_fuzz_render_and_compare(h, &fuzz_inst, &fuzz_fs, &fuzz_fs_color_buf, &term_a, &term_b, tex_a, tex_b, view_a, view_b, buf_a, buf_b, fuzz_w, fuzz_h, cell_w, cell_h, bytes_per_row, buf_size, true, false, false, {})

	// Neighbor edit: column 10 and 11 are modified, but damage is marked only at column 11
	term_a.cells[5 * fuzz_cols + 10] = pack_cell(u32('X'), 2, 1, 0, u32('X') - 32)
	term_a.cells[5 * fuzz_cols + 11] = pack_cell(u32('Y'), 3, 1, 0, u32('Y') - 32)
	term_b.cells[5 * fuzz_cols + 10] = term_a.cells[5 * fuzz_cols + 10]
	term_b.cells[5 * fuzz_cols + 11] = term_a.cells[5 * fuzz_cols + 11]
	term_a.damage = contract.damage_rect_make(11, 5, 1, 1)
	term_b.damage = term_a.damage

	diff1, _, _, _, _, _, _, _, _, _, _ := _fuzz_render_and_compare(h, &fuzz_inst, &fuzz_fs, &fuzz_fs_color_buf, &term_a, &term_b, tex_a, tex_b, view_a, view_b, buf_a, buf_b, fuzz_w, fuzz_h, cell_w, cell_h, bytes_per_row, buf_size, false, false, false, {neg1_disable_dilation = true})
	if diff1 > 0 {
		fmt.printfln("  [PASS] Neg-1: Dilate ±1 disabled caught at seed 0, mutation 0 (%d diff pixels)", diff1)
	} else {
		fmt.println("  [FAIL] Neg-1: Dilate ±1 disabled was NOT caught!")
		return false
	}

	// Neg-2: Space background emission disabled on partial render
	fmt.println("  [Negative 2] Space background emission disabled on partial render:")
	synthetic_terminal_clear(&term_a)
	synthetic_terminal_clear(&term_b)
	term_a.cells[10 * fuzz_cols + 10] = pack_cell(u32('M'), 3, 1, 0, u32('M') - 32)
	term_b.cells[10 * fuzz_cols + 10] = term_a.cells[10 * fuzz_cols + 10]
	_fuzz_render_and_compare(h, &fuzz_inst, &fuzz_fs, &fuzz_fs_color_buf, &term_a, &term_b, tex_a, tex_b, view_a, view_b, buf_a, buf_b, fuzz_w, fuzz_h, cell_w, cell_h, bytes_per_row, buf_size, true, false, false, {})

	term_a.cells[10 * fuzz_cols + 10] = pack_cell(' ', 0, 1, 0, 0)
	term_b.cells[10 * fuzz_cols + 10] = term_a.cells[10 * fuzz_cols + 10]
	term_a.damage = contract.damage_rect_make(10, 10, 1, 1)
	term_b.damage = term_a.damage

	diff2, _, _, _, _, _, _, _, _, _, _ := _fuzz_render_and_compare(h, &fuzz_inst, &fuzz_fs, &fuzz_fs_color_buf, &term_a, &term_b, tex_a, tex_b, view_a, view_b, buf_a, buf_b, fuzz_w, fuzz_h, cell_w, cell_h, bytes_per_row, buf_size, false, false, true, {neg2_disable_space_bg = true})
	if diff2 > 0 {
		fmt.printfln("  [PASS] Neg-2: Space background emission disabled caught at seed 0, mutation 0 (%d diff pixels)", diff2)
	} else {
		fmt.println("  [FAIL] Neg-2: Space background emission disabled was NOT caught!")
		return false
	}

	// Neg-3: Background and glyph pass order reversed
	fmt.println("  [Negative 3] Background and glyph pass order reversed:")
	synthetic_terminal_clear(&term_a)
	synthetic_terminal_clear(&term_b)
	term_a.cells[10 * fuzz_cols + 10] = pack_cell(u32('A'), 1, 1, 0, u32('A') - 32)
	term_b.cells[10 * fuzz_cols + 10] = term_a.cells[10 * fuzz_cols + 10]
	term_a.damage = contract.damage_rect_make(10, 10, 1, 1)
	term_b.damage = term_a.damage

	diff3, _, _, _, _, _, _, _, _, _, _ := _fuzz_render_and_compare(h, &fuzz_inst, &fuzz_fs, &fuzz_fs_color_buf, &term_a, &term_b, tex_a, tex_b, view_a, view_b, buf_a, buf_b, fuzz_w, fuzz_h, cell_w, cell_h, bytes_per_row, buf_size, false, false, false, {neg3_reverse_pass_order = true})
	if diff3 > 0 {
		fmt.printfln("  [PASS] Neg-3: Background and glyph pass order reversed caught at seed 0, mutation 0 (%d diff pixels)", diff3)
	} else {
		fmt.println("  [FAIL] Neg-3: Background and glyph pass order reversed was NOT caught!")
		return false
	}

	// Neg-4: Vertical damage reduced by 1 row
	fmt.println("  [Negative 4] Vertical damage reduced by 1 row:")
	synthetic_terminal_clear(&term_a)
	synthetic_terminal_clear(&term_b)
	term_a.cells[10 * fuzz_cols + 10] = pack_cell(u32('g'), 4, 1, 0, u32('g') - 32)
	term_b.cells[10 * fuzz_cols + 10] = term_a.cells[10 * fuzz_cols + 10]
	term_a.damage = contract.damage_rect_make(10, 10, 1, 1)
	term_b.damage = term_a.damage

	diff4, _, _, _, _, _, _, _, _, _, _ := _fuzz_render_and_compare(h, &fuzz_inst, &fuzz_fs, &fuzz_fs_color_buf, &term_a, &term_b, tex_a, tex_b, view_a, view_b, buf_a, buf_b, fuzz_w, fuzz_h, cell_w, cell_h, bytes_per_row, buf_size, false, false, false, {neg4_reduced_row_damage = true})
	if diff4 > 0 {
		fmt.printfln("  [PASS] Neg-4: Vertical damage reduced by 1 row caught at seed 0, mutation 0 (%d diff pixels)", diff4)
	} else {
		fmt.println("  [FAIL] Neg-4: Vertical damage reduced by 1 row was NOT caught!")
		return false
	}

	// Neg-5: Damage skipped for attribute-only changes
	fmt.println("  [Negative 5] Damage skipped for attribute-only changes:")
	synthetic_terminal_clear(&term_a)
	synthetic_terminal_clear(&term_b)
	term_a.cells[10 * fuzz_cols + 10] = pack_cell(u32('K'), 1, 1, 0, u32('K') - 32)
	term_b.cells[10 * fuzz_cols + 10] = term_a.cells[10 * fuzz_cols + 10]
	_fuzz_render_and_compare(h, &fuzz_inst, &fuzz_fs, &fuzz_fs_color_buf, &term_a, &term_b, tex_a, tex_b, view_a, view_b, buf_a, buf_b, fuzz_w, fuzz_h, cell_w, cell_h, bytes_per_row, buf_size, true, false, false, {})

	term_a.cells[10 * fuzz_cols + 10] = pack_cell(u32('K'), 2, 1, 0, u32('K') - 32)
	term_b.cells[10 * fuzz_cols + 10] = term_a.cells[10 * fuzz_cols + 10]
	term_a.damage = contract.damage_rect_make(10, 10, 1, 1)
	term_b.damage = term_a.damage

	diff5, _, _, _, _, _, _, _, _, _, _ := _fuzz_render_and_compare(h, &fuzz_inst, &fuzz_fs, &fuzz_fs_color_buf, &term_a, &term_b, tex_a, tex_b, view_a, view_b, buf_a, buf_b, fuzz_w, fuzz_h, cell_w, cell_h, bytes_per_row, buf_size, false, true, false, {neg5_skip_attr_damage = true})
	if diff5 > 0 {
		fmt.printfln("  [PASS] Neg-5: Damage skipped for attribute-only changes caught at seed 0, mutation 0 (%d diff pixels)", diff5)
	} else {
		fmt.println("  [FAIL] Neg-5: Damage skipped for attribute-only changes was NOT caught!")
		return false
	}

	// Neg-6: 1-byte change injected into ground-truth copy
	fmt.println("  [Negative 6] 1-byte change injected into ground-truth copy:")
	synthetic_terminal_clear(&term_a)
	synthetic_terminal_clear(&term_b)
	term_a.cells[10 * fuzz_cols + 10] = pack_cell(u32('Z'), 5, 1, 0, u32('Z') - 32)
	term_b.cells[10 * fuzz_cols + 10] = term_a.cells[10 * fuzz_cols + 10]
	term_a.damage = contract.damage_rect_make(10, 10, 1, 1)
	term_b.damage = term_a.damage

	diff6, _, _, _, _, _, _, _, _, _, _ := _fuzz_render_and_compare(h, &fuzz_inst, &fuzz_fs, &fuzz_fs_color_buf, &term_a, &term_b, tex_a, tex_b, view_a, view_b, buf_a, buf_b, fuzz_w, fuzz_h, cell_w, cell_h, bytes_per_row, buf_size, false, false, false, {neg6_inject_comparator_byte = true})
	if diff6 > 0 {
		fmt.printfln("  [PASS] Neg-6: Ground-truth 1-byte injection caught at seed 0, mutation 0 (%d diff pixels)", diff6)
	} else {
		fmt.println("  [FAIL] Neg-6: Ground-truth 1-byte injection was NOT caught!")
		return false
	}

	fmt.println("\nAll 6/6 Negative Tests detected by comparator.")
	fmt.println("\n--- Running Truth Fuzzer (20 seeds × 100 edits) ---")

	rng: helper.Xoshiro256pp
	total_edits := 0

	for seed_idx in 0..<20 {
		seed_val := u64(seed_idx * 7919 + 42)
		helper.xoshiro256pp_init(&rng, seed_val)

		synthetic_terminal_clear(&term_a)
		synthetic_terminal_clear(&term_b)

		// Initial baseline frame
		diff0, _, _, _, _, _, _, _, _, _, _ := _fuzz_render_and_compare(h, &fuzz_inst, &fuzz_fs, &fuzz_fs_color_buf, &term_a, &term_b, tex_a, tex_b, view_a, view_b, buf_a, buf_b, fuzz_w, fuzz_h, cell_w, cell_h, bytes_per_row, buf_size, true, false, false, {})
		if diff0 > 0 {
			fmt.printfln("[FAIL] Seed %02d baseline frame failed: %d mismatching pixels", seed_idx, diff0)
			return false
		}

		class_counts: [8]int

		for edit_idx in 0..<100 {
			total_edits += 1
			class := int(edit_idx % 8)
			kind, r, c, is_attr_only, is_erase := _apply_fuzz_mutation(&term_a, &term_b, &rng, class)
			class_counts[kind] += 1

			diff, fx, fy, ra, ga, ba, aa, rb, gb, bb, ab := _fuzz_render_and_compare(h, &fuzz_inst, &fuzz_fs, &fuzz_fs_color_buf, &term_a, &term_b, tex_a, tex_b, view_a, view_b, buf_a, buf_b, fuzz_w, fuzz_h, cell_w, cell_h, bytes_per_row, buf_size, false, is_attr_only, is_erase, {})
			if diff > 0 {
				fmt.printfln("[FAIL] Seed: %d, Mutation: %d, Kind: %d, Cell: (%d, %d), First Mismatch Pixel: (%d, %d): A=[%d,%d,%d,%d] vs B=[%d,%d,%d,%d]",
					seed_idx, edit_idx, kind, r, c, fx, fy, ra, ga, ba, aa, rb, gb, bb, ab)
				return false
			}
		}

		for k in 0..<8 {
			if class_counts[k] == 0 {
				fmt.printfln("[FAIL] Seed %d failed generator self-audit: missing mutation class %d", seed_idx, k)
				return false
			}
		}

		fmt.printfln("  [PASS] Seed %02d/20: 100 edits verified (0 pixel differences)", seed_idx + 1)
	}

	fmt.println("[PASS] Truth Fuzzer: 20 seeds × 100 edits verified (0 pixel differences)")
	fmt.println("================================================================================")
	return true
}

// ============================================================================
// 6. Automated Multi-Run Shuffled Benchmark Suite (docs/HARNESS_BENCHMARK_PLAN.md §8.3)
// ============================================================================

STRATEGY_AUTO :: terminal.Render_Strategy(-1)

Terminal_Scenario :: struct {
	name:        string,
	cols:        u32,
	rows:        u32,
	dirty_ratio: f32,
	strategy:    terminal.Render_Strategy,
	pane_count:  int,
}

base_scenarios := [17]Terminal_Scenario{
	// Grid Scaling (Dirty 100%, Strategy C)
	{"Grid Scaling: 80x24 (100% dirty, Strat C)", 80, 24, 1.0, .Fullscreen, 0},
	{"Grid Scaling: 120x40 (100% dirty, Strat C)", 120, 40, 1.0, .Fullscreen, 0},
	{"Grid Scaling: 160x50 (100% dirty, Strat C)", 160, 50, 1.0, .Fullscreen, 0},
	{"Grid Scaling: 500x200 (100% dirty, Strat C)", 500, 200, 1.0, .Fullscreen, 0},

	// Dirty Sweep (120x40, Auto Strategy)
	{"Dirty Sweep: 0.0% (120x40, Auto)", 120, 40, 0.000, STRATEGY_AUTO, 0},
	{"Dirty Sweep: 0.1% (120x40, Auto)", 120, 40, 0.001, STRATEGY_AUTO, 0},
	{"Dirty Sweep: 1.0% (120x40, Auto)", 120, 40, 0.010, STRATEGY_AUTO, 0},
	{"Dirty Sweep: 5.0% (120x40, Auto)", 120, 40, 0.050, STRATEGY_AUTO, 0},
	{"Dirty Sweep: 25.0% (120x40, Auto)", 120, 40, 0.250, STRATEGY_AUTO, 0},
	{"Dirty Sweep: 100.0% (120x40, Auto)", 120, 40, 1.000, STRATEGY_AUTO, 0},

	// Crossover Validation (120x40, Auto Strategy)
	{"Crossover: 2.9% (120x40, Auto -> A)", 120, 40, 0.029, STRATEGY_AUTO, 0},
	{"Crossover: 3.0% (120x40, Auto -> B)", 120, 40, 0.030, STRATEGY_AUTO, 0},
	{"Crossover: 64.9% (120x40, Auto -> B)", 120, 40, 0.649, STRATEGY_AUTO, 0},
	{"Crossover: 65.0% (120x40, Auto -> C)", 120, 40, 0.650, STRATEGY_AUTO, 0},

	// Strategy Stress (120x40, 5.0% dirty)
	{"Strategy Stress: Force A (120x40, 5.0%)", 120, 40, 0.050, .Instance, 0},
	{"Strategy Stress: Force B (120x40, 5.0%)", 120, 40, 0.050, .Compute_Tiles, 0},
	{"Strategy Stress: Force C (120x40, 5.0%)", 120, 40, 0.050, .Fullscreen, 0},
}

Stats_Summary :: struct {
	mean:    f64,
	std_dev: f64,
	ci_low:  f64,
	ci_high: f64,
}

compute_stats :: proc(vals: []f64) -> Stats_Summary {
	res: Stats_Summary
	n := len(vals)
	if n == 0 do return res

	sum := 0.0
	for v in vals {
		sum += v
	}
	res.mean = sum / f64(n)

	if n > 1 {
		sum_sq_diff := 0.0
		for v in vals {
			diff := v - res.mean
			sum_sq_diff += diff * diff
		}
		res.std_dev = math.sqrt(sum_sq_diff / f64(n - 1))

		// Locked Value: df=4, 95% CI t-value = 2.776
		t_multiplier := 1.96
		if n - 1 == 4 {
			t_multiplier = 2.776
		} else if n - 1 == 19 {
			t_multiplier = 2.093
		} else if n - 1 == 1 {
			t_multiplier = 12.706
		}
		margin := t_multiplier * (res.std_dev / math.sqrt(f64(n)))
		res.ci_low = res.mean - margin
		res.ci_high = res.mean + margin
	} else {
		res.ci_low = res.mean
		res.ci_high = res.mean
	}

	return res
}

Percentile_Metrics :: struct {
	median_ns: u64,
	p95_ns:    u64,
	p99_ns:    u64,
	median_ms: f64,
	p95_ms:    f64,
	p99_ms:    f64,
}

_calc_percentiles :: proc(samples: []u64) -> Percentile_Metrics {
	if len(samples) == 0 do return {}
	slice.sort(samples)
	n := len(samples)
	idx_50 := n / 2
	idx_95 := min(n - 1, (n * 95) / 100)
	idx_99 := min(n - 1, (n * 99) / 100)

	m50 := samples[idx_50]
	m95 := samples[idx_95]
	m99 := samples[idx_99]

	return {
		median_ns = m50,
		p95_ns    = m95,
		p99_ns    = m99,
		median_ms = f64(m50) / 1_000_000.0,
		p95_ms    = f64(m95) / 1_000_000.0,
		p99_ms    = f64(m99) / 1_000_000.0,
	}
}

_pump_events :: proc() {
	event: sdl3.Event
	for sdl3.PollEvent(&event) {
		if event.type == .QUIT || event.type == .WINDOW_CLOSE_REQUESTED {
			os.exit(0)
		}
	}
}

_acquire_surface :: proc(h: ^Harness_State) -> (contract.Gpu_Texture, contract.Gpu_TextureView) {
	surf := (^wgpu_backend.Wgpu_Surface)(h.surface)
	if surf == nil || surf.handle == nil do return contract.Gpu_Texture(nil), contract.Gpu_TextureView(nil)

	for _ in 0..<3 {
		st := wgpu.SurfaceGetCurrentTexture(surf.handle)
		if (st.status == .SuccessOptimal || st.status == .SuccessSuboptimal || st.status == .Occluded) && st.texture != nil {
			tv := wgpu.TextureCreateView(st.texture, nil)
			if tv != nil {
				return contract.Gpu_Texture(st.texture), contract.Gpu_TextureView(tv)
			}
		}
		_pump_events()
	}
	return contract.Gpu_Texture(nil), contract.Gpu_TextureView(nil)
}

_encode_pane_raster :: proc(
	h: ^Harness_State,
	enc: contract.Gpu_CommandEncoder,
	ctx: ^Pane_Context,
	strat: terminal.Render_Strategy,
	cols, rows: u32,
	cell_w, cell_h: f32,
	dirty_tiles_buf: ^[2048]u32,
) {
	l := pipeline.composer_pipeline_get_layer(&h.composer_pipe, ctx.layer_id)
	if l == nil || rawptr(l.view) == nil do return

	switch strat {
	case .Instance:
		is_empty := contract.damage_rect_is_empty(ctx.term.damage)
		is_full := (ctx.term.damage.x == 0 && ctx.term.damage.y == 0 && ctx.term.damage.w == cols && ctx.term.damage.h == rows)

		terminal_instance.instance_renderer_begin(ctx.inst)

		if !is_empty {
			u_data := [4]f32{h.pane_w, h.pane_h, cell_w, cell_h}
			if !ctx.inst.has_uniforms || ctx.inst.last_uniforms != u_data {
				contract.write_buffer(h.queue, ctx.inst.uniform_buffer, 0, &u_data, size_of([4]f32))
				ctx.inst.last_uniforms = u_data
				ctx.inst.has_uniforms = true
			}

			x0: u32 = 0
			x1: u32 = cols
			y0: u32 = 0
			y1: u32 = rows

			if !is_full {
				d := ctx.term.damage
				x0 = u32(max(int(d.x) - 1, 0))
				x1 = min(d.x + d.w + 1, cols)
				y0 = d.y
				y1 = min(d.y + d.h, rows)
			}

			for r in y0..<y1 {
				r_cols := r * cols
				y_px := f32(r) * cell_h
				for c in x0..<x1 {
					packed := ctx.term.cells[r_cols + c]
					content, style, _, cflags, slot := unpack_cell(packed)
					if content == ' ' && style == 0 && (cflags & 2) == 0 do continue

					u0, v0, u1, v1 := atlas.atlas_slot_uv(slot, cell_w, cell_h)
					if slot == UNRESOLVED_SLOT && content >= 32 && content <= 126 {
						u0, v0, u1, v1 = atlas.atlas_slot_uv(content - 32, cell_w, cell_h)
					}

					is_selected := (cflags & 2) != 0
					fg, bg: [4]f32
					if is_selected {
						fg = SELECTED_FG_FLOAT
						bg = SELECTED_BG_FLOAT
					} else {
						fg, bg = palette_style_colors(style)
					}

					rec := contract.Instance_Record{
						pos_size = {f32(c) * cell_w, y_px, cell_w, cell_h},
						uv_rect  = {u0, v0, u1, v1},
						fg_color = fg,
						bg_color = bg,
					}
					terminal_instance.instance_renderer_push(ctx.inst, rec)
				}
			}
			terminal_instance.instance_renderer_flush(ctx.inst)
		}

		if ctx.inst.active_count == 0 && !is_full {
			return
		}

		load_op := contract.Gpu_Load_Op.Clear if is_full else contract.Gpu_Load_Op.Load
		pass := contract.begin_render_pass(enc, l.view, {0.07, 0.08, 0.10, 1.0}, load_op)
		if rawptr(pass) != nil {
			if ctx.inst.active_count > 0 {
				contract.render_set_pipeline(pass, h.bg_pipeline)
				bg_bg := ctx.inst.bg_bind_group if rawptr(ctx.inst.bg_bind_group) != nil else ctx.inst.bind_group
				contract.render_set_bind_group(pass, 0, bg_bg)
				contract.render_set_vertex_buffer(pass, 0, ctx.inst.instance_buffer, 0)
				contract.render_draw(pass, 6, ctx.inst.active_count)
				terminal_instance.instance_renderer_draw(ctx.inst, pass)
			}
			contract.end_render_pass(pass)
		}

	case .Compute_Tiles:
		if contract.damage_rect_is_empty(ctx.term.damage) {
			return
		}
		contract.write_buffer(h.queue, ctx.tile.cell_buffer, 0, raw_data(ctx.term.cells), u64(len(ctx.term.cells) * size_of(u64)))
		tx_s := ctx.term.damage.x / ctx.tile.tile_w
		ty_s := ctx.term.damage.y / ctx.tile.tile_h
		tx_e := min((ctx.term.damage.x + ctx.term.damage.w + ctx.tile.tile_w - 1) / ctx.tile.tile_w, ctx.tile.tiles_x)
		ty_e := min((ctx.term.damage.y + ctx.term.damage.h + ctx.tile.tile_h - 1) / ctx.tile.tile_h, ctx.tile.tiles_y)
		dirty_count := 0
		for ty in ty_s..<ty_e {
			for tx in tx_s..<tx_e {
				if dirty_count < len(dirty_tiles_buf) {
					dirty_tiles_buf[dirty_count] = ty * ctx.tile.tiles_x + tx
					dirty_count += 1
				}
			}
		}
		if dirty_count > 0 {
			params := tile.Tile_Params{
				screen_w     = h.pane_w,
				screen_h     = h.pane_h,
				cols         = cols,
				rows         = rows,
				cell_w       = cell_w,
				cell_h       = cell_h,
				pad_x        = 0.0,
				pad_y        = 0.0,
				tile_w       = ctx.tile.tile_w,
				tile_h       = ctx.tile.tile_h,
				tiles_x      = ctx.tile.tiles_x,
				tiles_y      = ctx.tile.tiles_y,
				atlas_w      = atlas.ATLAS_WIDTH,
				atlas_h      = atlas.ATLAS_HEIGHT,
				bg_opacity   = 1.0,
				cell_opacity = 1.0,
			}
			if !ctx.tile.has_params || ctx.tile.params != params {
				contract.write_buffer(h.queue, ctx.tile.params_buffer, 0, &params, size_of(tile.Tile_Params))
				ctx.tile.params = params
				ctx.tile.has_params = true
			}
			contract.write_buffer(h.queue, ctx.tile.tile_list_buffer, 0, &dirty_tiles_buf[0], u64(dirty_count * size_of(u32)))
			tile.compute_tile_dispatch(ctx.tile, enc, u32(dirty_count))

			pass := contract.begin_render_pass(enc, l.view, {0.07, 0.08, 0.10, 1.0}, .Clear)
			if rawptr(pass) != nil {
				contract.render_set_pipeline(pass, ctx.tile.blit_pipeline)
				contract.render_set_bind_group(pass, 0, ctx.tile.blit_bind_group)
				contract.render_draw(pass, 3, 1)
				contract.end_render_pass(pass)
			}
		}

	case .Fullscreen:
		if contract.damage_rect_is_empty(ctx.term.damage) {
			return
		}
		contract.write_buffer(h.queue, ctx.fs.cell_buffer, 0, raw_data(ctx.term.cells), u64(len(ctx.term.cells) * size_of(u64)))
		fs_p := fullscreen.Fullscreen_Params{
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
		if !ctx.fs.has_params || ctx.fs.params != fs_p {
			contract.write_buffer(h.queue, ctx.fs.params_buffer, 0, &fs_p, size_of(fullscreen.Fullscreen_Params))
			ctx.fs.params = fs_p
			ctx.fs.has_params = true
		}

		pass := contract.begin_render_pass(enc, l.view, {0.07, 0.08, 0.10, 1.0}, .Clear)
		if rawptr(pass) != nil {
			fullscreen.fullscreen_draw(ctx.fs, pass)
			contract.end_render_pass(pass)
		}
	}
}

Single_Run_Result :: struct {
	f_enc:    []u64,
	measured: int,
	skipped:  int,
	allocs:   i64,
}

execute_scenario_single_run :: proc(
	h: ^Harness_State,
	cfg: ^Terminal_Scenario,
	frames: int,
) -> Single_Run_Result {
	for p in 0..<cfg.pane_count {
		ctx := _get_pane_context(h, p)
		synthetic_terminal_resize(ctx.term, cfg.cols, cfg.rows)
	}
	_update_renderer_limits(h, cfg.cols, cfg.rows)

	order: [4]composer.Layer_Id
	for p in 0..<cfg.pane_count {
		order[p] = composer.Layer_Id(p + 1)
	}
	pipeline.composer_pipeline_set_layer_order(&h.composer_pipe, order[:cfg.pane_count])

	cell_w := h.pane_w / f32(cfg.cols)
	cell_h := h.pane_h / f32(cfg.rows)
	total_cells := int(cfg.cols * cfg.rows)
	dirty_cells := int(f32(total_cells) * cfg.dirty_ratio)

	// Preallocated buffer for dirty tile indices to maintain zero-alloc steady state
	dirty_tiles_buf: [2048]u32

	f_enc := make([]u64, frames)
	measured := 0
	skipped := 0

	// Wrap context.allocator in mem.Tracking_Allocator to monitor steady-state allocations
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	// Pre-fill terminal grids 100% before the measurement loop
	for p in 0..<cfg.pane_count {
		ctx := _get_pane_context(h, p)
		synthetic_terminal_clear(ctx.term)
		if cfg.name != "[Empty Frame Baseline]" {
			synthetic_terminal_randomize(ctx.term, &h.rng, total_cells)
		}
	}

	// Pre-render the initial pre-filled grid into each pane layer so layers are valid
	if cfg.name != "[Empty Frame Baseline]" {
		enc_init := contract.create_command_encoder(h.device)
		if rawptr(enc_init) != nil {
			for p in 0..<cfg.pane_count {
				ctx := _get_pane_context(h, p)
				ctx.term.damage = contract.damage_rect_make(0, 0, cfg.cols, cfg.rows)
				_encode_pane_raster(h, enc_init, &ctx, .Fullscreen, cfg.cols, cfg.rows, cell_w, cell_h, &dirty_tiles_buf)
			}
			cmd_init := contract.finish_command_buffer(enc_init)
			contract.release_command_encoder(enc_init)
			if cmd_init != nil {
				contract.submit(h.queue, cmd_init)
				contract.release_command_buffer(cmd_init)
			}
		}
		contract.wait_for_idle(h.device)
	}

	{
		context.allocator = mem.tracking_allocator(&track)

		for _ in 0..<frames {
			_pump_events()

			tex, view := _acquire_surface(h)
			if rawptr(view) == nil {
				skipped += 1
				continue
			}

			strats: [4]terminal.Render_Strategy
			for p in 0..<cfg.pane_count {
				ctx := _get_pane_context(h, p)

				ctx.term.damage = {}
				if dirty_cells > 0 {
					synthetic_terminal_randomize(ctx.term, &h.rng, dirty_cells)
				}

				if cfg.strategy != STRATEGY_AUTO {
					terminal.strategy_pin(ctx.strat_state, cfg.strategy)
				} else {
					terminal.strategy_unpin(ctx.strat_state)
				}

				// Use actual damage from the randomize pass, not the static config ratio.
				// A stride walk or any other pattern can produce a bbox much larger than
				// the real dirty area, causing strategy_select to always pick Fullscreen.
				actual_dirty := int(ctx.term.damage.w * ctx.term.damage.h)
				actual_ratio := f32(actual_dirty) / f32(max(total_cells, 1))
				inp := terminal.Strategy_Inputs{
					dirty_cells = actual_dirty,
					total_cells = total_cells,
					ratio       = actual_ratio,
					full_rows   = int(ctx.term.damage.h) if ctx.term.damage.w == cfg.cols else 0,
					span_count  = 1,
					scroll      = (actual_dirty >= total_cells),
				}
				strats[p] = terminal.strategy_select(inp, ctx.strat_state, true, true)
			}

			// t0..t1 covers the full CPU cost of a frame: upload to GPU (write_buffer
			// inside encode_pane_raster), command encoding, finish, and submit.
			// This matches the intent of "total including GPU upload".
			t0 := _get_thread_time_ns()

			enc := contract.create_command_encoder(h.device)
			if rawptr(enc) == nil {
				contract.release_surface_texture(tex, view)
				skipped += 1
				continue
			}

			if cfg.name != "[Empty Frame Baseline]" {
				for p in 0..<cfg.pane_count {
					ctx := _get_pane_context(h, p)
					_encode_pane_raster(h, enc, &ctx, strats[p], cfg.cols, cfg.rows, cell_w, cell_h, &dirty_tiles_buf)
				}
				pipeline.composer_pipeline_composite(&h.composer_pipe, enc, view)
			} else {
				pass := contract.begin_render_pass(enc, view, {0.07, 0.08, 0.10, 1.0}, .Clear)
				if rawptr(pass) != nil {
					contract.end_render_pass(pass)
				}
			}

			cmd := contract.finish_command_buffer(enc)
			contract.release_command_encoder(enc)

			if cmd != nil {
				contract.submit(h.queue, cmd)
				contract.release_command_buffer(cmd)
			}

			t1 := _get_thread_time_ns()

			f_enc[measured] = u64(max(i64(0), i64(t1) - i64(t0)))
			measured += 1

			contract.present_surface(h.surface)
			contract.release_surface_texture(tex, view)
		}
	}

	contract.wait_for_idle(h.device)
	allocations := i64(len(track.allocation_map))

	res: Single_Run_Result
	res.f_enc = f_enc
	res.measured = measured
	res.skipped = skipped
	res.allocs = allocations
	return res
}

_run_honest_benchmark :: proc(h: ^Harness_State, quick: bool = false) {
	NUM_RUNS := 2 if quick else 20
	FRAMES_PER_RUN := 20 if quick else 60
	SCENARIOS_TOTAL :: 69

	contract.set_present_mode(h.surface, .Immediate)
	contract.configure_surface(h.surface, h.device, h.format, u32(h.screen_w), u32(h.screen_h))

	bench_scenarios: [SCENARIOS_TOTAL]Terminal_Scenario
	bench_scenarios[0] = {
		name        = fmt.aprintf("[Empty Frame Baseline]"),
		cols        = 120,
		rows        = 40,
		dirty_ratio = 0.0,
		strategy    = STRATEGY_AUTO,
		pane_count  = 1,
	}
	idx := 1
	for p in 1..=4 {
		for base in base_scenarios {
			bench_scenarios[idx] = {
				name        = fmt.aprintf("[%d-Pane] %s", p, base.name),
				cols        = base.cols,
				rows        = base.rows,
				dirty_ratio = base.dirty_ratio,
				strategy    = base.strategy,
				pane_count  = p,
			}
			idx += 1
		}
	}
	defer {
		for s in bench_scenarios {
			delete(s.name)
		}
	}

	all_frames_enc: [SCENARIOS_TOTAL][]u64
	scen_measured:  [SCENARIOS_TOTAL]int
	scen_skipped:   [SCENARIOS_TOTAL]int
	scen_allocs:    [SCENARIOS_TOTAL]i64

	for i in 0..<SCENARIOS_TOTAL {
		all_frames_enc[i] = make([]u64, NUM_RUNS * FRAMES_PER_RUN)
	}
	defer {
		for i in 0..<SCENARIOS_TOTAL {
			delete(all_frames_enc[i])
		}
	}

	fmt.println("================================================================================")
	fmt.println("               STARTING TERMINAL RENDER HONEST BENCHMARK SUITE                  ")
	fmt.println("================================================================================")
	fmt.printfln("Configuration: %d Scenarios (1-4 Panes), %d Runs, %d Frames/Run (df=19, t=2.093)", SCENARIOS_TOTAL, NUM_RUNS, FRAMES_PER_RUN)
	fmt.println()

	// 1. Interleaved Warmup across all scenarios (10 frames each)
	fmt.println("Running interleaved warmup across all scenarios (10 frames each)...")
	fflush(nil)
	for s_idx in 0..<SCENARIOS_TOTAL {
		cfg := &bench_scenarios[s_idx]
		res := execute_scenario_single_run(h, cfg, 10)
		delete(res.f_enc)
	}
	fmt.println("Interleaved warmup complete.")
	fmt.println()
	fflush(nil)

	// 2. Multi-Run Shuffled Benchmark Loop
	r := 0
	for r < NUM_RUNS {
		t_start := term_macos_get_thermal_state()
		if t_start != 0 {
			fmt.printfln("WARNING: Non-nominal thermal state (%d) at start of Run %d/%d. Cooling down 2s...", t_start, r + 1, NUM_RUNS)
			fflush(nil)
			time.sleep(2 * time.Second)
			continue
		}

		scenario_indices: [SCENARIOS_TOTAL]int
		for i in 0..<SCENARIOS_TOTAL {
			scenario_indices[i] = i
		}
		helper.xoshiro256pp_shuffle(&h.rng, scenario_indices[:])

		fmt.printfln("--- Starting Run %d/%d (Shuffled with seed) ---", r + 1, NUM_RUNS)
		fflush(nil)

		scen_count := 0
		for s_idx in scenario_indices {
			cfg := &bench_scenarios[s_idx]
			res := execute_scenario_single_run(h, cfg, FRAMES_PER_RUN)

			if res.measured > 0 {
				dst_start := scen_measured[s_idx]
				copy_len := min(res.measured, len(all_frames_enc[s_idx]) - dst_start)
				if copy_len > 0 {
					copy(all_frames_enc[s_idx][dst_start : dst_start + copy_len], res.f_enc[:copy_len])
				}
			}
			scen_measured[s_idx] += res.measured
			scen_skipped[s_idx] += res.skipped
			scen_allocs[s_idx] += res.allocs

			delete(res.f_enc)

			scen_count += 1
			if scen_count % 15 == 0 || scen_count == SCENARIOS_TOTAL {
				fmt.printfln("  [Run %d/%d] Progress: %d/%d scenarios completed", r + 1, NUM_RUNS, scen_count, SCENARIOS_TOTAL)
				fflush(nil)
			}
		}

		t_end := term_macos_get_thermal_state()
		if t_end != 0 {
			fmt.printfln("WARNING: Non-nominal thermal state (%d) at end of Run %d/%d. Repeating run...", t_end, r + 1, NUM_RUNS)
			fflush(nil)
			time.sleep(2 * time.Second)
			continue
		}

		r += 1
	}

	// 3. Post-Run Statistical Aggregation & Reporting Table
	fmt.println()
	fmt.println("==============================================================================================================================================================")
	fmt.println("                                                            HARNESS TERMINAL BENCHMARK REPORT (V2.2)")
	fmt.println("==============================================================================================================================================================")
	fmt.printfln("%-52s | %-12s | %-12s | %-12s | %-18s | %-8s", "Scenario", "Meas/Skip", "Enc P50 (µs)", "Enc P95 (µs)", "95% CI (µs)", "Allocs")
	fmt.println("-----------------------------------------------------+--------------+--------------+--------------+--------------------+---------")

	for s in 0..<SCENARIOS_TOTAL {
		cfg := &bench_scenarios[s]
		n_meas := scen_measured[s]
		n_skip := scen_skipped[s]
		meas_str := fmt.tprintf("%d/%d", n_meas, n_skip)

		p50_str := "N/A"
		p95_str := "N/A"
		ci_str := "N/A"

		if n_meas > 0 {
			f_enc_us := make([]f64, n_meas)
			for i in 0..<n_meas {
				f_enc_us[i] = f64(all_frames_enc[s][i]) / 1000.0
			}
			stats_s := compute_stats(f_enc_us)
			delete(f_enc_us)

			p_stats := _calc_percentiles(all_frames_enc[s][:n_meas])
			p50_str = fmt.tprintf("%.1f", f64(p_stats.median_ns) / 1000.0)
			p95_str = fmt.tprintf("%.1f", f64(p_stats.p95_ns) / 1000.0)
			ci_str = fmt.tprintf("[%.1f, %.1f]", stats_s.ci_low, stats_s.ci_high)
		}

		alloc_str := fmt.tprintf("%d", scen_allocs[s])

		fmt.printfln("%-52s | %-12s | %12s | %12s | %-18s | %8s", cfg.name, meas_str, p50_str, p95_str, ci_str, alloc_str)
	}
	fmt.println("==============================================================================================================================================================")
	fmt.println()

	// 4. Locked Thresholds Evaluation
	fmt.println("================================================================================")
	fmt.println("                         LOCKED THRESHOLDS EVALUATION                           ")
	fmt.println("================================================================================")
	strat_a_idx := -1
	for s in 0..<SCENARIOS_TOTAL {
		if bench_scenarios[s].name == "[1-Pane] Strategy Stress: Force A (120x40, 5.0%)" {
			strat_a_idx = s
			break
		}
	}
	if strat_a_idx >= 0 && scen_measured[strat_a_idx] > 0 {
		n_meas := scen_measured[strat_a_idx]
		p_stats := _calc_percentiles(all_frames_enc[strat_a_idx][:n_meas])
		p50_a := f64(p_stats.median_ns) / 1000.0
		p95_a := f64(p_stats.p95_ns) / 1000.0

		f_enc_us := make([]f64, n_meas)
		for i in 0..<n_meas {
			f_enc_us[i] = f64(all_frames_enc[strat_a_idx][i]) / 1000.0
		}
		stats_a := compute_stats(f_enc_us)
		delete(f_enc_us)

		v_str := "PASS" if p50_a < 80.0 else "FAIL"
		fmt.printfln("1. Terminal Strategy A CPU Encode Time per Frame (120x40, 5%% dirty, 1-Pane):")
		fmt.printfln("   Enc P50:          %.2f µs", p50_a)
		fmt.printfln("   Enc P95:          %.2f µs", p95_a)
		fmt.printfln("   Mean:             %.2f µs (95%% CI: [%.2f, %.2f] µs)", stats_a.mean, stats_a.ci_low, stats_a.ci_high)
		fmt.printfln("   Locked Threshold: < 80.0 µs (P50)")
		fmt.printfln("   Verdict:          [%s]", v_str)
	}
	fmt.println("================================================================================")
	fmt.println()
	fflush(nil)
}

// ============================================================================
// 7. Entry Point & Lifecycle
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

	for arg in os.args {
		if arg == "--test" {
			if !_run_truth_fuzzer_and_negative_tests(h) {
				os.exit(1)
			}
			os.exit(0)
		}
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

	// Initialize Renderer Instances for All 4 Panes
	for p in 0..<4 {
		ctx := _get_pane_context(h, p)
		terminal_instance.instance_renderer_init(ctx.inst, h.device, h.queue, 1024, h.atlas.gpu_view, h.format)
		tile.compute_tile_init(
			ctx.tile,
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
			ctx.fs,
			h.device,
			h.queue,
			GRID_ROWS_NORMAL,
			GRID_COLS_NORMAL,
			h.pane_w / f32(GRID_COLS_NORMAL),
			h.pane_h / f32(GRID_ROWS_NORMAL),
			h.atlas.gpu_view,
			h.format,
		)
	}

	// Allocate and wire resources for Normal 80x24 grid
	_handle_window_resize(h)

	is_bench := false
	is_quick := false
	for arg in os.args {
		if arg == "--bench" || arg == "-b" {
			is_bench = true
		} else if arg == "--quick" || arg == "-q" {
			is_quick = true
			is_bench = true
		}
	}
	if is_bench {
		_run_honest_benchmark(h, is_quick)
		os.exit(0)
	}

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
	for p in 0..<4 {
		ctx := _get_pane_context(h, p)
		if rawptr(ctx.color_buf^) != nil do contract.destroy_buffer(ctx.color_buf^)
		ctx.inst.pipeline = contract.Gpu_RenderPipeline(nil)
		ctx.tile.compute_pipeline = contract.Gpu_ComputePipeline(nil)
		ctx.tile.blit_pipeline = contract.Gpu_RenderPipeline(nil)
		ctx.fs.pipeline = contract.Gpu_RenderPipeline(nil)

		terminal_instance.instance_renderer_destroy(ctx.inst)
		tile.compute_tile_destroy(ctx.tile)
		fullscreen.fullscreen_destroy(ctx.fs)
	}

	if rawptr(h.glyph_pipeline) != nil do contract.destroy_render_pipeline(h.glyph_pipeline)
	if rawptr(h.bg_pipeline) != nil do contract.destroy_render_pipeline(h.bg_pipeline)
	if rawptr(h.compute_pipeline) != nil do contract.destroy_compute_pipeline(h.compute_pipeline)
	if rawptr(h.blit_pipeline) != nil do contract.destroy_render_pipeline(h.blit_pipeline)
	if rawptr(h.fs_pipeline) != nil do contract.destroy_render_pipeline(h.fs_pipeline)
}
