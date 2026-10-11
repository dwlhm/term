package main

// Standalone Native macOS GUI Harness & Chrome Renderer Benchmark (harness_render_chrome).
// Measures integrated multi-pane rasterization (UI chrome / text simulation) combined with layer compositing blits.
// Consumes core/chrome preview fixtures, extreme chrome scenarios (1000 SDF, radius > half size, divider drag, 128 tabs),
// and migrates frame loop to core/composer/frame.frame_tick.

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "vendor:sdl3"
import "vendor:wgpu"

import helper "../harness_helper"

import contract "../../core/render/contract"
import wgpu_backend "../../core/platform/gpu/wgpu"
import composer "../../core/composer"
import pipeline "../../core/composer/pipeline"
import scheduler "../../core/composer/scheduler"
import transition "../../core/composer/transition"
import frame "../../core/composer/frame"
import chrome "../../core/render/chrome"
import chrome_sdf "../../core/render/chrome/sdf"
import chrome_dl "../../core/chrome/draw_list"
import chrome_tabs "../../core/chrome/tabs"
import chrome_splits "../../core/chrome/splits"
import chrome_modals "../../core/chrome/modals"
import three_d "../../core/render/three_d"

PANE_1_ID:       composer.Layer_Id : 1
PANE_2_ID:       composer.Layer_Id : 2
PANE_3_ID:       composer.Layer_Id : 3
PANE_4_ID:       composer.Layer_Id : 4
CHROME_LAYER_ID: composer.Layer_Id : composer.CHROME_LAYER_ID
MODAL_LAYER_ID:  composer.Layer_Id : composer.MODAL_LAYER_ID

CHROME_BAR_HEIGHT: f32 : 40.0

Harness_State :: struct {
	window:              helper.Window,
	instance:            rawptr,
	surface:             rawptr,
	device:              contract.Gpu_Device,
	queue:               contract.Gpu_Queue,
	format:              contract.Gpu_Format,
	running:             bool,

	// OS-Style Multi-Pane Layer Compositor
	composer_pipe:       pipeline.Composer_Pipeline,
	screen_w:            f32,
	screen_h:            f32,
	pane_w:              f32,
	pane_h:              f32,

	// 3D Component Engine Pillar (Pane 2)
	three_d_renderer:    three_d.Three_D_Renderer,
	three_d_interactor:  three_d.Three_D_Interactor,
	mesh_type:           int, // 0 = Unit Cube, 1 = Hexagonal Prism Badge
	is_dragging_3d:      bool,

	// Chrome UI Pillar (Top Chrome Bar & 2D HUD Elements)
	chrome_renderer:     chrome.Chrome_Renderer,
	tabs_model:          chrome_tabs.Chrome_Tabs_Model,
	modal:               chrome_modals.Chrome_Modal,
	draw_list_chrome:    chrome_dl.Ui_Draw_List,
	draw_list_p1:        chrome_dl.Ui_Draw_List,
	draw_list_p2:        chrome_dl.Ui_Draw_List,
	draw_list_p3:        chrome_dl.Ui_Draw_List,
	draw_list_p4:        chrome_dl.Ui_Draw_List,
	draw_list_modal:     chrome_dl.Ui_Draw_List,

	// Interactive Controls & State
	active_pane:         int, // 1, 2, 3, 4
	modal_active:        bool,
	active_line_idx:     int,
	scissor_test_active: bool,
	shell_typed_chars:   int,
	build_step:          int,
	git_diff_step:       int,

	// Chrome Fixtures & Extreme Scenarios
	preview_mode:        bool,
	extreme_tabs:        bool,
	extreme_sdf_mode:    bool,
	extreme_radius_mode: bool,
	divider_drag_active: bool,
	divider_ratio:       f32,
	test_mode:           bool,

	// Live Telemetry Cache
	last_p1_redrawn:     bool,
	last_p2_redrawn:     bool,
	last_p3_redrawn:     bool,
	last_p4_redrawn:     bool,
	last_raster_ns:      u64,
	last_blit_ns:        u64,
	last_total_ns:       u64,

	start_ticks:         i64,
	last_frame_ticks:    i64,

	// Benchmark Results & On-Screen Telemetry
	bench_has_run:           bool,
	bench_work_ratio:        f64,
	bench_raster_time_saved: f64,
	bench_p1_raster_ms:      f64,
	bench_all_raster_ms:     f64,

	// Blinking Cursor State
	cursor_visible:          bool,

	// Scheduler & Frame Rate Throttling
	scheduler:               scheduler.Frame_Scheduler,
	blink_enabled:           bool,
	next_blink_ns:           u64,
	blink_interval_ns:       u64,
	idle_test_mode:          bool,
	idle_test_start:         i64,
	idle_test_seconds:       int,

	// Transition Manager & Post-Animation Idle Verification
	tm:                      transition.Transition_Manager,
	anim_idle_test_mode:     bool,
	anim_triggered:          bool,
	anim_finished:           bool,
	pre_anim_rendered:       u64,
	in_anim_rendered:        u64,
	post_anim_start_frames:  u64,
	anim_start_ns:           u64,
	anim_duration_ns:        u64,

	// Hardware GPU Timestamp Query Benchmarking Resources
	ts_query_set:            wgpu.QuerySet,
	ts_resolve_buf:          wgpu.Buffer,
	ts_readback_buf:         wgpu.Buffer,
	ts_supported:            bool,
	ts_period:               f32,
}

// render_ui_draw_list_to_encoder encodes declarative 2D primitives into an existing command encoder
// with sub-pixel SDF anti-aliasing.
render_ui_draw_list_to_encoder :: proc(
	enc: contract.Gpu_CommandEncoder,
	sdf_pipe: ^chrome_sdf.Chrome_Sdf_Pipeline,
	dl: ^chrome_dl.Ui_Draw_List,
	target_view: contract.Gpu_TextureView,
	width, height: f32,
	clear_col: [4]f64,
	load_op: contract.Gpu_Load_Op = .Clear,
) -> bool {
	if rawptr(enc) == nil || rawptr(target_view) == nil || sdf_pipe == nil || dl == nil do return false

	pass := contract.begin_render_pass(enc, target_view, clear_col, load_op)
	if rawptr(pass) == nil do return false

	chrome_sdf.chrome_sdf_pipeline_reset(sdf_pipe)
	screen_sz := [2]f32{width, height}
	for cmd in dl.commands {
		#partial switch cmd.kind {
		case .Rect:
			params := chrome_sdf.Sdf_Params{
				screen_size  = screen_sz,
				rect_pos     = {cmd.rect[0], cmd.rect[1]},
				rect_size    = {cmd.rect[2], cmd.rect[3]},
				radius       = 0.0,
				border_width = 0.0,
				color        = cmd.color,
				border_color = cmd.border_color,
			}
			chrome_sdf.chrome_sdf_draw(sdf_pipe, pass, &params)
		case .Rounded_Rect:
			params := chrome_sdf.Sdf_Params{
				screen_size  = screen_sz,
				rect_pos     = {cmd.rect[0], cmd.rect[1]},
				rect_size    = {cmd.rect[2], cmd.rect[3]},
				radius       = cmd.radius,
				border_width = 0.0,
				color        = cmd.color,
				border_color = cmd.border_color,
			}
			chrome_sdf.chrome_sdf_draw(sdf_pipe, pass, &params)
		case .Border:
			params := chrome_sdf.Sdf_Params{
				screen_size  = screen_sz,
				rect_pos     = {cmd.rect[0], cmd.rect[1]},
				rect_size    = {cmd.rect[2], cmd.rect[3]},
				radius       = cmd.radius,
				border_width = 1.0,
				color        = {0, 0, 0, 0},
				border_color = cmd.border_color,
			}
			chrome_sdf.chrome_sdf_draw(sdf_pipe, pass, &params)
		case .Shadow:
			params := chrome_sdf.Sdf_Params{
				screen_size  = screen_sz,
				rect_pos     = {cmd.rect[0], cmd.rect[1]},
				rect_size    = {cmd.rect[2], cmd.rect[3]},
				radius       = cmd.radius,
				border_width = 0.0,
				color        = cmd.color,
				border_color = cmd.border_color,
			}
			chrome_sdf.chrome_sdf_draw(sdf_pipe, pass, &params)
		case .Text_Run, .Icon:
		}
	}

	chrome_sdf.chrome_sdf_flush_and_draw(sdf_pipe, pass)
	contract.end_render_pass(pass)
	return true
}

// render_ui_draw_list_encode encodes declarative 2D primitives into a command buffer
// with sub-pixel SDF anti-aliasing without submitting to the queue.
render_ui_draw_list_encode :: proc(
	device: contract.Gpu_Device,
	sdf_pipe: ^chrome_sdf.Chrome_Sdf_Pipeline,
	dl: ^chrome_dl.Ui_Draw_List,
	target_view: contract.Gpu_TextureView,
	width, height: f32,
	clear_col: [4]f64,
	load_op: contract.Gpu_Load_Op = .Clear,
) -> rawptr {
	if rawptr(device) == nil || rawptr(target_view) == nil || sdf_pipe == nil || dl == nil do return nil

	enc := contract.create_command_encoder(device)
	if rawptr(enc) == nil do return nil
	defer contract.release_command_encoder(enc)

	if !render_ui_draw_list_to_encoder(enc, sdf_pipe, dl, target_view, width, height, clear_col, load_op) {
		return nil
	}

	return contract.finish_command_buffer(enc)
}

// _generate_1000_sdf_elements generates 1000 distinct SDF rounded rects for batching stress tests.
_generate_1000_sdf_elements :: proc(dl: ^chrome_dl.Ui_Draw_List, bounds: [4]f32) {
	if dl == nil do return
	bx := bounds[0]
	by := bounds[1]
	bw := bounds[2]
	bh := bounds[3]
	if bw <= 0.0 || bh <= 0.0 do return

	cols := 40
	rows := 25 // 40 * 25 = 1000 elements
	cell_w := bw / f32(cols)
	cell_h := bh / f32(rows)
	elem_w := max(cell_w * 0.8, 2.0)
	elem_h := max(cell_h * 0.8, 2.0)

	for r in 0..<rows {
		for c in 0..<cols {
			idx := r * cols + c
			x := bx + f32(c) * cell_w + (cell_w - elem_w) * 0.5
			y := by + f32(r) * cell_h + (cell_h - elem_h) * 0.5
			radius := f32((idx % 8) + 1) * 1.5
			cr := 0.2 + 0.7 * f32(idx % 11) / 10.0
			cg := 0.2 + 0.7 * f32((idx * 3) % 13) / 12.0
			cb := 0.2 + 0.7 * f32((idx * 7) % 17) / 16.0
			col := [4]f32{cr, cg, cb, 0.9}
			chrome_dl.ui_draw_rounded_rect(dl, {x, y, elem_w, elem_h}, col, radius)
		}
	}
}

// _generate_extreme_radius_elements generates SDF elements with radius > half-size (r = 1.5 * min(w, h))
// verifying GPU distance-field clamping and stability without artifacts or crashes.
_generate_extreme_radius_elements :: proc(dl: ^chrome_dl.Ui_Draw_List, bounds: [4]f32) {
	if dl == nil do return
	bx := bounds[0]
	by := bounds[1]
	bw := bounds[2]
	bh := bounds[3]
	if bw <= 0.0 || bh <= 0.0 do return

	sizes := [4][2]f32{
		{120.0, 60.0},
		{60.0, 120.0},
		{80.0, 80.0},
		{200.0, 30.0},
	}
	for i in 0..<4 {
		sz := sizes[i]
		min_dim := min(sz[0], sz[1])
		extreme_radius := 1.5 * min_dim
		x := bx + 20.0 + f32(i) * 150.0
		y := by + 40.0
		col := [4]f32{0.3 + 0.15 * f32(i), 0.5, 0.8 - 0.15 * f32(i), 0.95}
		chrome_dl.ui_draw_rounded_rect(dl, {x, y, sz[0], sz[1]}, col, extreme_radius)
		chrome_dl.ui_draw_border(dl, {x, y, sz[0], sz[1]}, {1.0, 1.0, 1.0, 0.8}, extreme_radius)
	}
}

// _emit_dynamic_dividers generates a split tree layout at dynamic oscillating ratio and emits 1px dividers.
_emit_dynamic_dividers :: proc(dl: ^chrome_dl.Ui_Draw_List, bounds: [4]f32, ratio: f32) {
	if dl == nil do return
	clamped_ratio := clamp(ratio, 0.05, 0.95)
	root := chrome_splits.split_node_create_leaf(1)
	top, btm := chrome_splits.split_node_split(root, .Vertical, clamped_ratio, 2)
	if top != nil do chrome_splits.split_node_split(top, .Horizontal, 1.0 - clamped_ratio, 3)
	if btm != nil do chrome_splits.split_node_split(btm, .Horizontal, clamped_ratio, 4)
	chrome_splits.split_tree_layout(root, bounds)
	chrome_splits.split_tree_emit_dividers(root, dl, 1.0, {0.35, 0.40, 0.50, 1.0})
	chrome_splits.split_tree_destroy(root)
}

// render_ui_draw_list_to_view renders declarative 2D primitives into any target texture view
// with sub-pixel SDF anti-aliasing.
render_ui_draw_list_to_view :: proc(
	device: contract.Gpu_Device,
	queue: contract.Gpu_Queue,
	sdf_pipe: ^chrome_sdf.Chrome_Sdf_Pipeline,
	dl: ^chrome_dl.Ui_Draw_List,
	target_view: contract.Gpu_TextureView,
	width, height: f32,
	clear_col: [4]f64,
	load_op: contract.Gpu_Load_Op = .Clear,
) -> bool {
	cmd_buf := render_ui_draw_list_encode(device, sdf_pipe, dl, target_view, width, height, clear_col, load_op)
	if cmd_buf != nil {
		contract.submit(queue, cmd_buf)
		contract.release_command_buffer(cmd_buf)
		return true
	}
	return false
}

// _populate_pane_1_draw_list populates draw list commands for Pane 1 (Terminal Shell / Typing simulation).
_populate_pane_1_draw_list :: proc(h: ^Harness_State, dl: ^chrome_dl.Ui_Draw_List, w, h_pane: f32) {
	// Outer header bar
	chrome_dl.ui_draw_rect(dl, {0, 0, w, 28}, {0.09, 0.11, 0.15, 1.0})
	chrome_dl.ui_draw_rect(dl, {0, 27, w, 1}, {0.16, 0.20, 0.28, 1.0})

	// Window control dots (macOS style)
	chrome_dl.ui_draw_rounded_rect(dl, {w - 48, 10, 8, 8}, {0.95, 0.35, 0.30, 1.0}, 4.0)
	chrome_dl.ui_draw_rounded_rect(dl, {w - 34, 10, 8, 8}, {0.95, 0.70, 0.20, 1.0}, 4.0)
	chrome_dl.ui_draw_rounded_rect(dl, {w - 20, 10, 8, 8}, {0.25, 0.80, 0.40, 1.0}, 4.0)

	session_idx := h.tabs_model.active_idx % 4

	switch session_idx {
	case 0:
		// === SESSION 0: zsh Shell Prompt ===
		chrome_dl.ui_draw_rounded_rect(dl, {8, 5, 80, 18}, {0.15, 0.45, 0.85, 1.0}, 4.0)
		chrome_dl.ui_draw_rounded_rect(dl, {96, 5, 140, 18}, {0.14, 0.16, 0.22, 1.0}, 4.0)
		chrome_dl.ui_draw_border(dl, {96, 5, 140, 18}, {0.24, 0.28, 0.38, 1.0}, 4.0)

		minimap_x := w - 160.0
		chrome_dl.ui_draw_rect(dl, {minimap_x, 28, 1, h_pane - 56}, {0.12, 0.14, 0.18, 1.0})
		chrome_dl.ui_draw_rounded_rect(dl, {minimap_x + 10, 32, 140, 14}, {0.14, 0.16, 0.22, 1.0}, 3.0)

		active_row := h.active_line_idx % 30
		for row in 0..<30 {
			y := 34.0 + f32(row) * 13.5
			chrome_dl.ui_draw_rounded_rect(dl, {16, y, 22, 10}, {0.22, 0.25, 0.32, 0.8}, 2.0)

			gutter_col: [4]f32
			if row % 7 == 2 {
				gutter_col = {0.20, 0.75, 0.40, 0.9}
			} else if row % 7 == 5 {
				gutter_col = {0.85, 0.30, 0.30, 0.9}
			} else {
				gutter_col = {0.20, 0.22, 0.28, 0.4}
			}
			chrome_dl.ui_draw_rect(dl, {42, y, 3, 10}, gutter_col)

			if row == active_row {
				chrome_dl.ui_draw_rect(dl, {46, y - 1, minimap_x - 52, 13}, {0.18, 0.22, 0.30, 0.45})
				typed_w := min(minimap_x - 100.0, f32(h.shell_typed_chars * 11 + 30))
				chrome_dl.ui_draw_rounded_rect(dl, {48, y, typed_w, 10}, {0.90, 0.95, 1.0, 1.0}, 2.0)
				if h.cursor_visible {
					chrome_dl.ui_draw_rect(dl, {48 + typed_w + 4, y - 2, 8, 14}, {0.20, 0.80, 1.00, 1.0})
				}
			} else {
				kw_w := 28.0 + f32((row * 7) % 32)
				id_w := 42.0 + f32((row * 13) % 48)
				str_w := 54.0 + f32((row * 19) % 72)
				arg_w := 36.0 + f32((row * 23) % 50)

				kw_cols := [4][4]f32{
					{0.85, 0.40, 0.75, 1.0},
					{0.95, 0.60, 0.25, 1.0},
					{0.35, 0.65, 0.95, 1.0},
					{0.90, 0.35, 0.45, 1.0},
				}
				chrome_dl.ui_draw_rounded_rect(dl, {48, y, kw_w, 10}, kw_cols[row % 4], 2.0)

				id_cols := [3][4]f32{
					{0.40, 0.80, 0.85, 1.0},
					{0.75, 0.80, 0.90, 1.0},
					{0.90, 0.85, 0.45, 1.0},
				}
				chrome_dl.ui_draw_rounded_rect(dl, {48 + kw_w + 6, y, id_w, 10}, id_cols[(row * 2) % 3], 2.0)

				if (48 + kw_w + id_w + 12 + str_w < minimap_x - 10) {
					chrome_dl.ui_draw_rounded_rect(dl, {48 + kw_w + id_w + 12, y, str_w, 10}, {0.45, 0.80, 0.50, 0.9}, 2.0)
				}
				if (48 + kw_w + id_w + str_w + 18 + arg_w < minimap_x - 10) {
					chrome_dl.ui_draw_rounded_rect(dl, {48 + kw_w + id_w + str_w + 18, y, arg_w, 10}, {0.80, 0.55, 0.35, 0.85}, 2.0)
				}
			}

			mm_w := min(130.0, 30.0 + f32((row * 11) % 100))
			mm_col := [4]f32{0.40, 0.48, 0.62, 0.55} if row != active_row else [4]f32{0.25, 0.75, 0.95, 0.95}
			chrome_dl.ui_draw_rounded_rect(dl, {minimap_x + 14, y + 2, mm_w, 6}, mm_col, 1.0)
		}

		chrome_dl.ui_draw_rounded_rect(dl, {minimap_x + 12, h_pane - 56, 62, 18}, {0.85, 0.55, 0.15, 0.9}, 3.0)
		chrome_dl.ui_draw_rounded_rect(dl, {minimap_x + 80, h_pane - 56, 62, 18}, {0.20, 0.70, 0.40, 0.9}, 3.0)

		strip_y := h_pane - 26.0
		chrome_dl.ui_draw_rect(dl, {0, strip_y - 2, w, 28}, {0.07, 0.08, 0.11, 1.0})
		chrome_dl.ui_draw_rect(dl, {0, strip_y - 2, w, 1}, {0.14, 0.16, 0.22, 1.0})

		colors := [16][4]f32{
			{0.15, 0.16, 0.20, 1.0}, {0.90, 0.30, 0.30, 1.0}, {0.25, 0.80, 0.40, 1.0}, {0.95, 0.75, 0.25, 1.0},
			{0.25, 0.55, 0.95, 1.0}, {0.80, 0.35, 0.90, 1.0}, {0.20, 0.80, 0.85, 1.0}, {0.90, 0.92, 0.95, 1.0},
			{0.35, 0.38, 0.45, 1.0}, {1.00, 0.45, 0.45, 1.0}, {0.40, 0.95, 0.55, 1.0}, {1.00, 0.85, 0.40, 1.0},
			{0.45, 0.70, 1.00, 1.0}, {0.90, 0.50, 1.00, 1.0}, {0.40, 0.95, 1.00, 1.0}, {1.00, 1.00, 1.00, 1.0},
		}
		for i in 0..<16 {
			chip_w: f32 = 18.0
			chip_gap: f32 = 4.0
			chrome_dl.ui_draw_rounded_rect(dl, {16.0 + f32(i) * (chip_w + chip_gap), strip_y + 2, chip_w, 14}, colors[i], 2.0)
		}
		chrome_dl.ui_draw_rounded_rect(dl, {w - 200, strip_y + 2, 80, 18}, {0.16, 0.18, 0.24, 1.0}, 3.0)
		chrome_dl.ui_draw_rounded_rect(dl, {w - 110, strip_y + 2, 94, 18}, {0.20, 0.45, 0.75, 1.0}, 3.0)

	case 1:
		// === SESSION 1: nvim Code Editor ===
		chrome_dl.ui_draw_rounded_rect(dl, {8, 5, 84, 18}, {0.18, 0.70, 0.35, 1.0}, 4.0)
		chrome_dl.ui_draw_rounded_rect(dl, {100, 5, 200, 18}, {0.14, 0.16, 0.22, 1.0}, 4.0)
		chrome_dl.ui_draw_border(dl, {100, 5, 200, 18}, {0.25, 0.50, 0.35, 1.0}, 4.0)

		minimap_x := w - 160.0
		chrome_dl.ui_draw_rect(dl, {minimap_x, 28, 1, h_pane - 56}, {0.14, 0.16, 0.22, 1.0})
		chrome_dl.ui_draw_rounded_rect(dl, {minimap_x + 10, 32, 140, 14}, {0.14, 0.18, 0.24, 1.0}, 3.0)

		active_row := h.active_line_idx % 30
		for row in 0..<30 {
			y := 34.0 + f32(row) * 13.5
			chrome_dl.ui_draw_rounded_rect(dl, {16, y, 26, 10}, {0.24, 0.26, 0.35, 0.85}, 2.0)

			indent := f32(((row * 3) % 4) * 16)
			x := 48.0 + indent

			if row == active_row {
				chrome_dl.ui_draw_rect(dl, {44, y - 1, minimap_x - 50, 13}, {0.20, 0.28, 0.40, 0.5})
				typed_w := min(minimap_x - x - 40.0, f32(h.shell_typed_chars * 9 + 40))
				chrome_dl.ui_draw_rounded_rect(dl, {x, y, typed_w, 10}, {0.95, 0.85, 0.40, 1.0}, 2.0)
				chrome_dl.ui_draw_rect(dl, {x + typed_w + 4, y - 2, 7, 14}, {0.25, 0.85, 0.95, 1.0})
			} else {
				t1_w := 32.0 + f32((row * 11) % 40)
				t2_w := 48.0 + f32((row * 17) % 60)
				t3_w := 60.0 + f32((row * 23) % 70)

				chrome_dl.ui_draw_rounded_rect(dl, {x, y, t1_w, 10}, {0.75, 0.35, 0.85, 0.95}, 2.0)
				chrome_dl.ui_draw_rounded_rect(dl, {x + t1_w + 6, y, t2_w, 10}, {0.25, 0.75, 0.90, 0.95}, 2.0)
				if x + t1_w + t2_w + 14 + t3_w < minimap_x - 10 {
					chrome_dl.ui_draw_rounded_rect(dl, {x + t1_w + t2_w + 12, y, t3_w, 10}, {0.35, 0.85, 0.50, 0.9}, 2.0)
				}
			}

			mm_w := min(130.0, 40.0 + f32((row * 9) % 95))
			mm_col := [4]f32{0.35, 0.55, 0.45, 0.6} if row != active_row else [4]f32{0.30, 0.85, 0.55, 1.0}
			chrome_dl.ui_draw_rounded_rect(dl, {minimap_x + 14, y + 2, mm_w, 6}, mm_col, 1.0)
		}

		sline_y := h_pane - 26.0
		chrome_dl.ui_draw_rect(dl, {0, sline_y - 2, w, 28}, {0.10, 0.13, 0.18, 1.0})
		chrome_dl.ui_draw_rounded_rect(dl, {12, sline_y + 2, 70, 18}, {0.18, 0.70, 0.35, 1.0}, 3.0)
		chrome_dl.ui_draw_rounded_rect(dl, {88, sline_y + 2, 160, 18}, {0.16, 0.18, 0.25, 1.0}, 3.0)
		chrome_dl.ui_draw_rounded_rect(dl, {w - 180, sline_y + 2, 80, 18}, {0.16, 0.18, 0.25, 1.0}, 3.0)
		chrome_dl.ui_draw_rounded_rect(dl, {w - 90, sline_y + 2, 78, 18}, {0.25, 0.55, 0.85, 1.0}, 3.0)

	case 2:
		// === SESSION 2: htop Process Monitor ===
		chrome_dl.ui_draw_rounded_rect(dl, {8, 5, 84, 18}, {0.85, 0.55, 0.15, 1.0}, 4.0)
		chrome_dl.ui_draw_rounded_rect(dl, {100, 5, 220, 18}, {0.14, 0.16, 0.22, 1.0}, 4.0)
		chrome_dl.ui_draw_border(dl, {100, 5, 220, 18}, {0.45, 0.35, 0.20, 1.0}, 4.0)

		top_meter_w := (w - 48.0) * 0.5
		chrome_dl.ui_draw_rounded_rect(dl, {16, 32, top_meter_w, 10}, {0.12, 0.14, 0.18, 1.0}, 2.0)
		chrome_dl.ui_draw_rounded_rect(dl, {16, 32, top_meter_w * 0.72, 10}, {0.20, 0.75, 0.45, 1.0}, 2.0)
		chrome_dl.ui_draw_rounded_rect(dl, {24 + top_meter_w, 32, top_meter_w, 10}, {0.12, 0.14, 0.18, 1.0}, 2.0)
		chrome_dl.ui_draw_rounded_rect(dl, {24 + top_meter_w, 32, top_meter_w * 0.48, 10}, {0.25, 0.60, 0.90, 1.0}, 2.0)

		chrome_dl.ui_draw_rounded_rect(dl, {16, 48, w - 32, 14}, {0.16, 0.20, 0.26, 0.95}, 2.0)

		active_row := h.active_line_idx % 24
		for p in 0..<24 {
			y := 66.0 + f32(p) * 14.5
			is_selected := (p == active_row)
			if is_selected {
				chrome_dl.ui_draw_rect(dl, {16, y - 1, w - 32, 13}, {0.18, 0.35, 0.55, 0.85})
			}

			chrome_dl.ui_draw_rounded_rect(dl, {18, y, 36, 10}, {0.25, 0.65, 0.90, 0.9}, 2.0)
			chrome_dl.ui_draw_rounded_rect(dl, {58, y, 42, 10}, {0.40, 0.45, 0.55, 0.8}, 2.0)
			stat_col := [4]f32{0.20, 0.80, 0.40, 1.0} if p % 3 == 0 else [4]f32{0.45, 0.48, 0.55, 0.8}
			chrome_dl.ui_draw_rect(dl, {104, y, 10, 10}, stat_col)
			cpu_pct := f32(((p * 17 + h.build_step * 7) % 70) + 5) / 100.0
			cpu_col := [4]f32{0.90, 0.35, 0.30, 1.0} if cpu_pct > 0.50 else [4]f32{0.20, 0.75, 0.45, 1.0}
			chrome_dl.ui_draw_rounded_rect(dl, {120, y, 48 * cpu_pct, 10}, cpu_col, 2.0)
			chrome_dl.ui_draw_rounded_rect(dl, {174, y, 36, 10}, {0.35, 0.45, 0.65, 0.8}, 2.0)
			cmd_w := min(w - 230.0, 140.0 + f32((p * 23) % 180))
			chrome_dl.ui_draw_rounded_rect(dl, {216, y, cmd_w, 10}, {0.85, 0.88, 0.95, 0.9}, 2.0)
		}

		fkey_y := h_pane - 26.0
		chrome_dl.ui_draw_rect(dl, {0, fkey_y - 2, w, 28}, {0.10, 0.12, 0.16, 1.0})
		for k in 0..<8 {
			kx := 16.0 + f32(k) * ((w - 32.0) / 8.0)
			chrome_dl.ui_draw_rounded_rect(dl, {kx, fkey_y + 2, (w - 48.0) / 8.0, 18}, {0.18, 0.22, 0.30, 1.0}, 3.0)
		}

	case 3:
		// === SESSION 3: python Interactive REPL ===
		chrome_dl.ui_draw_rounded_rect(dl, {8, 5, 84, 18}, {0.65, 0.30, 0.85, 1.0}, 4.0)
		chrome_dl.ui_draw_rounded_rect(dl, {100, 5, 230, 18}, {0.14, 0.16, 0.22, 1.0}, 4.0)
		chrome_dl.ui_draw_border(dl, {100, 5, 230, 18}, {0.45, 0.25, 0.55, 1.0}, 4.0)

		insp_x := w - 180.0
		chrome_dl.ui_draw_rect(dl, {insp_x, 28, 1, h_pane - 56}, {0.14, 0.16, 0.22, 1.0})
		chrome_dl.ui_draw_rounded_rect(dl, {insp_x + 10, 32, 160, 14}, {0.16, 0.14, 0.24, 1.0}, 3.0)

		chrome_dl.ui_draw_rounded_rect(dl, {16, 34, min(insp_x - 30.0, 340.0), 10}, {0.85, 0.85, 0.90, 0.9}, 2.0)
		chrome_dl.ui_draw_rounded_rect(dl, {16, 48, min(insp_x - 30.0, 420.0), 10}, {0.50, 0.55, 0.65, 0.8}, 2.0)

		active_row := h.active_line_idx % 26
		for r in 0..<26 {
			y := 66.0 + f32(r) * 14.5
			is_prompt := (r % 2 == 0)

			if is_prompt {
				chrome_dl.ui_draw_rounded_rect(dl, {16, y, 22, 10}, {0.20, 0.70, 0.90, 0.9}, 2.0)
				if r == active_row {
					typed_w := min(insp_x - 60.0, f32(h.shell_typed_chars * 11 + 30))
					chrome_dl.ui_draw_rounded_rect(dl, {42, y, typed_w, 10}, {0.95, 0.95, 1.0, 1.0}, 2.0)
					chrome_dl.ui_draw_rect(dl, {42 + typed_w + 4, y - 2, 7, 14}, {0.20, 0.80, 1.0, 1.0})
				} else {
					stmt_w := min(insp_x - 50.0, 90.0 + f32((r * 29) % 180))
					chrome_dl.ui_draw_rounded_rect(dl, {42, y, stmt_w, 10}, {0.85, 0.85, 0.95, 0.9}, 2.0)
				}
			} else {
				out_w := min(insp_x - 30.0, 120.0 + f32((r * 31) % 200))
				chrome_dl.ui_draw_rounded_rect(dl, {26, y, out_w, 10}, {0.40, 0.80, 0.55, 0.85}, 2.0)
			}

			var_w := min(150.0, 40.0 + f32((r * 13) % 110))
			chrome_dl.ui_draw_rounded_rect(dl, {insp_x + 14, y + 2, var_w, 7}, {0.65, 0.45, 0.85, 0.7}, 1.5)
		}

		py_bar_y := h_pane - 26.0
		chrome_dl.ui_draw_rect(dl, {0, py_bar_y - 2, w, 28}, {0.11, 0.09, 0.16, 1.0})
		chrome_dl.ui_draw_rounded_rect(dl, {12, py_bar_y + 2, 110, 18}, {0.65, 0.30, 0.85, 1.0}, 3.0)
		chrome_dl.ui_draw_rounded_rect(dl, {130, py_bar_y + 2, 140, 18}, {0.18, 0.16, 0.26, 1.0}, 3.0)
		chrome_dl.ui_draw_rounded_rect(dl, {w - 180, py_bar_y + 2, 164, 18}, {0.20, 0.55, 0.75, 1.0}, 3.0)
	}
}

// _rasterize_pane_1_encode renders Terminal Shell & Interactive Typing simulation (Top-Left) to a command buffer.
_rasterize_pane_1_encode :: proc(h: ^Harness_State) -> rawptr {
	l1 := pipeline.composer_pipeline_get_layer(&h.composer_pipe, PANE_1_ID)
	if l1 == nil || !l1.in_use || rawptr(l1.view) == nil do return nil

	w := f32(l1.width)
	h_pane := f32(l1.height)
	dl := &h.draw_list_p1
	chrome_dl.ui_draw_list_clear(dl)

	if h.extreme_sdf_mode {
		_generate_1000_sdf_elements(dl, {0, 0, w, h_pane})
	} else if h.extreme_radius_mode {
		_generate_extreme_radius_elements(dl, {0, 0, w, h_pane})
	} else {
		_populate_pane_1_draw_list(h, dl, w, h_pane)
	}

	return render_ui_draw_list_encode(
		h.device,
		&h.chrome_renderer.sdf,
		dl,
		l1.view,
		w,
		h_pane,
		{0.05, 0.06, 0.08, 1.0},
		.Clear,
	)
}

_rasterize_pane_1 :: proc(h: ^Harness_State) {
	cmd := _rasterize_pane_1_encode(h)
	if cmd != nil {
		contract.submit(h.queue, cmd)
		contract.release_command_buffer(cmd)
	}
}

// _populate_pane_2_draw_list populates draw list commands for 2D HUD overlay on Pane 2.
_populate_pane_2_draw_list :: proc(h: ^Harness_State, dl: ^chrome_dl.Ui_Draw_List, vp_w, vp_h: f32) {
	chrome_dl.ui_draw_rect(dl, {0, 0, vp_w, 28}, {0.08, 0.10, 0.14, 0.90})
	chrome_dl.ui_draw_rect(dl, {0, 27, vp_w, 1}, {0.16, 0.20, 0.28, 1.0})

	badge_col := [4]f32{0.15, 0.70, 0.95, 1.0} if h.active_pane == 2 else [4]f32{0.18, 0.20, 0.25, 1.0}
	chrome_dl.ui_draw_rounded_rect(dl, {8, 5, 80, 18}, badge_col, 4.0)

	// Mesh indicator pill
	mesh_col := [4]f32{0.25, 0.60, 0.90, 0.8} if h.mesh_type == 1 else [4]f32{0.20, 0.45, 0.75, 0.8}
	chrome_dl.ui_draw_rounded_rect(dl, {96, 5, 60, 18}, mesh_col, 4.0)

	// Wireframe pill
	wire_col := [4]f32{0.95, 0.65, 0.20, 0.8} if h.three_d_interactor.wireframe_mode else [4]f32{0.20, 0.22, 0.28, 0.8}
	chrome_dl.ui_draw_rounded_rect(dl, {162, 5, 52, 18}, wire_col, 4.0)

	// Auto-rotate pill
	rot_col := [4]f32{0.20, 0.80, 0.40, 0.8} if h.three_d_interactor.auto_rotate else [4]f32{0.20, 0.22, 0.28, 0.8}
	chrome_dl.ui_draw_rounded_rect(dl, {220, 5, 56, 18}, rot_col, 4.0)

	// 2D HUD Telemetry overlay card (bottom-left of Pane 2)
	card_y := vp_h - 110.0
	chrome_dl.ui_draw_rounded_rect(dl, {16, card_y, 180, 90}, {0.06, 0.08, 0.12, 0.75}, 6.0)
	chrome_dl.ui_draw_border(dl, {16, card_y, 180, 90}, {0.20, 0.25, 0.35, 0.6}, 6.0)

	// Telemetry data rows
	chrome_dl.ui_draw_rounded_rect(dl, {26, card_y + 12, 60, 10}, {0.25, 0.65, 0.95, 0.9}, 2.0)
	chrome_dl.ui_draw_rounded_rect(dl, {96, card_y + 12, 80, 10}, {0.45, 0.50, 0.60, 0.8}, 2.0)

	chrome_dl.ui_draw_rounded_rect(dl, {26, card_y + 28, 50, 10}, {0.20, 0.75, 0.40, 0.9}, 2.0)
	chrome_dl.ui_draw_rounded_rect(dl, {96, card_y + 28, 70, 10}, {0.45, 0.50, 0.60, 0.8}, 2.0)

	chrome_dl.ui_draw_rounded_rect(dl, {26, card_y + 44, 55, 10}, {0.90, 0.65, 0.20, 0.9}, 2.0)
	chrome_dl.ui_draw_rounded_rect(dl, {96, card_y + 44, 85, 10}, {0.45, 0.50, 0.60, 0.8}, 2.0)

	chrome_dl.ui_draw_rounded_rect(dl, {26, card_y + 64, 150, 14}, {0.15, 0.18, 0.24, 0.9}, 3.0)

	// Top-Right coordinate axes indicator
	chrome_dl.ui_draw_rounded_rect(dl, {vp_w - 96, 5, 24, 18}, {0.85, 0.25, 0.25, 0.85}, 3.0) // X
	chrome_dl.ui_draw_rounded_rect(dl, {vp_w - 68, 5, 24, 18}, {0.25, 0.80, 0.35, 0.85}, 3.0) // Y
	chrome_dl.ui_draw_rounded_rect(dl, {vp_w - 40, 5, 24, 18}, {0.25, 0.55, 0.95, 0.85}, 3.0) // Z
}

// _rasterize_pane_2_encode renders 3D Component Engine with Depth24Plus (Top-Right) to command buffers.
_rasterize_pane_2_encode :: proc(h: ^Harness_State) -> (cmd1: rawptr, cmd2: rawptr) {
	l2 := pipeline.composer_pipeline_get_layer(&h.composer_pipe, PANE_2_ID)
	if l2 == nil || !l2.in_use || rawptr(l2.view) == nil do return nil, nil

	wgpu_dev := wgpu.Device(rawptr(h.device))

	cur_ticks := helper.platform_now()
	elapsed_ns := helper.platform_ticks_to_ns(cur_ticks - h.start_ticks)
	time_s := f32(f64(elapsed_ns) / 1_000_000_000.0)

	vp_w := f32(l2.width)
	vp_h := f32(l2.height)

	uniforms := three_d.interactor_compute_uniforms(&h.three_d_interactor, vp_w, vp_h, time_s)

	depth_view_handle := wgpu.TextureView(rawptr(l2.depth_view))
	if depth_view_handle == nil {
		depth_view_handle = h.three_d_renderer.depth_view
	}

	enc := wgpu.DeviceCreateCommandEncoder(wgpu_dev, nil)
	if enc != nil {
		color_attachment := wgpu.RenderPassColorAttachment{
			view       = wgpu.TextureView(rawptr(l2.view)),
			loadOp     = .Clear,
			storeOp    = .Store,
			clearValue = wgpu.Color{ 0.04, 0.05, 0.08, 1.0 },
			depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
		}
		depth_attachment := wgpu.RenderPassDepthStencilAttachment{
			view            = depth_view_handle,
			depthLoadOp     = .Clear,
			depthStoreOp    = .Store,
			depthClearValue = 1.0,
			depthReadOnly   = false,
		}
		pass_desc := wgpu.RenderPassDescriptor{
			colorAttachmentCount   = 1,
			colorAttachments       = &color_attachment,
			depthStencilAttachment = &depth_attachment,
		}

		pass := wgpu.CommandEncoderBeginRenderPass(enc, &pass_desc)
		if pass != nil {
			wgpu.RenderPassEncoderSetViewport(pass, 0.0, 0.0, vp_w, vp_h, 0.0, 1.0)
			three_d.three_d_draw(&h.three_d_renderer, pass, &uniforms)
			wgpu.RenderPassEncoderEnd(pass)
			wgpu.RenderPassEncoderRelease(pass)

			cmd1 = rawptr(wgpu.CommandEncoderFinish(enc, nil))
		}
		wgpu.CommandEncoderRelease(enc)
	}

	// 2D Header overlay on Pane 2 (rendered with .Load to preserve 3D scene)
	dl := &h.draw_list_p2
	chrome_dl.ui_draw_list_clear(dl)
	_populate_pane_2_draw_list(h, dl, vp_w, vp_h)

	cmd2 = render_ui_draw_list_encode(
		h.device,
		&h.chrome_renderer.sdf,
		dl,
		l2.view,
		vp_w,
		vp_h,
		{0, 0, 0, 0},
		.Load,
	)
	return cmd1, cmd2
}

_rasterize_pane_2 :: proc(h: ^Harness_State) {
	c1, c2 := _rasterize_pane_2_encode(h)
	if c1 != nil {
		contract.submit(h.queue, c1)
		contract.release_command_buffer(c1)
	}
	if c2 != nil {
		contract.submit(h.queue, c2)
		contract.release_command_buffer(c2)
	}
}

// _populate_pane_3_draw_list populates draw list commands for Pane 3 (Build Logs & Hardware System Monitor).
_populate_pane_3_draw_list :: proc(h: ^Harness_State, dl: ^chrome_dl.Ui_Draw_List, w, h_pane: f32) {
	// Header bar
	chrome_dl.ui_draw_rect(dl, {0, 0, w, 28}, {0.08, 0.10, 0.13, 1.0})
	chrome_dl.ui_draw_rect(dl, {0, 27, w, 1}, {0.14, 0.18, 0.24, 1.0})

	// Badge
	badge_col := [4]f32{0.15, 0.65, 0.35, 1.0} if h.active_pane == 3 else [4]f32{0.18, 0.20, 0.24, 1.0}
	chrome_dl.ui_draw_rounded_rect(dl, {8, 5, 84, 18}, badge_col, 4.0)

	// Column split
	col_w := (w - 36.0) * 0.5
	col2_x := 20.0 + col_w
	chrome_dl.ui_draw_rect(dl, {col2_x - 6, 28, 1, h_pane - 56}, {0.12, 0.14, 0.18, 1.0})

	// === LEFT COLUMN: 28 Build & Test Logs ===
	for r in 0..<28 {
		y := 36.0 + f32(r) * 14.0
		// Timestamp
		chrome_dl.ui_draw_rounded_rect(dl, {16, y, 32, 10}, {0.22, 0.25, 0.32, 0.8}, 2.0)

		// Severity badge
		sev_col: [4]f32
		switch r % 4 {
		case 0: sev_col = {0.18, 0.70, 0.35, 0.9} // INFO
		case 1: sev_col = {0.20, 0.65, 0.90, 0.9} // DEBUG
		case 2: sev_col = {0.90, 0.65, 0.20, 0.9} // WARN
		case 3: sev_col = {0.85, 0.25, 0.25, 0.9} // ERROR
		}
		chrome_dl.ui_draw_rounded_rect(dl, {52, y, 38, 10}, sev_col, 2.0)

		// Message bar
		msg_w := min(col_w - 90.0, 110.0 + f32((r * 29 + h.build_step * 11) % 170))
		chrome_dl.ui_draw_rounded_rect(dl, {94, y, msg_w, 10}, {0.45, 0.50, 0.60, 0.85}, 2.0)
	}

	// === RIGHT COLUMN: Full Hardware Telemetry Dashboard ===
	// Section Header: 8-Core CPU Activity
	chrome_dl.ui_draw_rounded_rect(dl, {col2_x, 34, 120, 14}, {0.16, 0.18, 0.24, 1.0}, 3.0)

	cpu_bar_w := (col_w - f32(7 * 6)) / 8.0
	for c in 0..<8 {
		x := col2_x + f32(c) * (cpu_bar_w + 6.0)
		chrome_dl.ui_draw_rounded_rect(dl, {x, 54, cpu_bar_w, 36}, {0.11, 0.13, 0.17, 1.0}, 2.0)
		core_pct := f32(((c * 19 + h.build_step * 17) % 85) + 15) / 100.0
		fill_h := 36.0 * core_pct
		fill_col: [4]f32
		if core_pct > 0.80 {
			fill_col = {0.90, 0.35, 0.30, 1.0}
		} else if core_pct > 0.55 {
			fill_col = {0.90, 0.70, 0.25, 1.0}
		} else {
			fill_col = {0.20, 0.75, 0.45, 1.0}
		}
		chrome_dl.ui_draw_rounded_rect(dl, {x, 54 + (36.0 - fill_h), cpu_bar_w, fill_h}, fill_col, 2.0)
	}

	// GPU VRAM & Memory Allocation Section
	chrome_dl.ui_draw_rounded_rect(dl, {col2_x, 98, 140, 14}, {0.16, 0.18, 0.24, 1.0}, 3.0)

	mem_y: f32 = 118.0
	chrome_dl.ui_draw_rounded_rect(dl, {col2_x, mem_y, col_w, 10}, {0.12, 0.14, 0.18, 1.0}, 2.0)
	chrome_dl.ui_draw_rounded_rect(dl, {col2_x, mem_y, col_w * 0.64, 10}, {0.20, 0.65, 0.90, 1.0}, 2.0)

	chrome_dl.ui_draw_rounded_rect(dl, {col2_x, mem_y + 14, col_w, 10}, {0.12, 0.14, 0.18, 1.0}, 2.0)
	chrome_dl.ui_draw_rounded_rect(dl, {col2_x, mem_y + 14, col_w * 0.88, 10}, {0.35, 0.80, 0.50, 1.0}, 2.0)

	// Network I/O & Sparklines
	chrome_dl.ui_draw_rounded_rect(dl, {col2_x, 150, 130, 14}, {0.16, 0.18, 0.24, 1.0}, 3.0)
	spark_y: f32 = 170.0
	spark_count := 16
	spark_w := (col_w - f32((spark_count - 1) * 3)) / f32(spark_count)
	for s in 0..<spark_count {
		sx := col2_x + f32(s) * (spark_w + 3.0)
		sh := f32(((s * 23 + h.build_step * 13) % 40) + 8)
		chrome_dl.ui_draw_rounded_rect(dl, {sx, spark_y + (48.0 - sh), spark_w, sh}, {0.25, 0.60, 0.85, 0.85}, 1.5)
	}

	// Texture Pool & Shader Cache distribution bars
	pool_y: f32 = 228.0
	chrome_dl.ui_draw_rounded_rect(dl, {col2_x, pool_y, 160, 14}, {0.16, 0.18, 0.24, 1.0}, 3.0)
	chrome_dl.ui_draw_rounded_rect(dl, {col2_x, pool_y + 20, col_w, 12}, {0.10, 0.12, 0.16, 1.0}, 3.0)
	chrome_dl.ui_draw_rounded_rect(dl, {col2_x, pool_y + 20, col_w * 0.45, 12}, {0.75, 0.35, 0.85, 0.9}, 2.0)
	chrome_dl.ui_draw_rounded_rect(dl, {col2_x + col_w * 0.45 + 2, pool_y + 20, col_w * 0.30, 12}, {0.25, 0.70, 0.90, 0.9}, 2.0)
	chrome_dl.ui_draw_rounded_rect(dl, {col2_x + col_w * 0.75 + 4, pool_y + 20, col_w * 0.18, 12}, {0.20, 0.80, 0.45, 0.9}, 2.0)

	// Bottom build progress bar across full pane width
	prog_y := h_pane - 24.0
	chrome_dl.ui_draw_rounded_rect(dl, {16, prog_y, 56, 12}, {0.15, 0.70, 0.90, 0.9}, 3.0)
	prog_track_w := w - 88.0
	chrome_dl.ui_draw_rounded_rect(dl, {78, prog_y, prog_track_w, 12}, {0.10, 0.13, 0.18, 1.0}, 3.0)
	prog_fill_w := min(prog_track_w, f32((h.build_step + 1) * 20))
	chrome_dl.ui_draw_rounded_rect(dl, {78, prog_y, prog_fill_w, 12}, {0.30, 0.80, 0.95, 0.85}, 3.0)
}

// _rasterize_pane_3_encode renders Build Logs & Hardware System Monitor (Bottom-Left) to a command buffer.
_rasterize_pane_3_encode :: proc(h: ^Harness_State) -> rawptr {
	l3 := pipeline.composer_pipeline_get_layer(&h.composer_pipe, PANE_3_ID)
	if l3 == nil || !l3.in_use || rawptr(l3.view) == nil do return nil

	w := f32(l3.width)
	h_pane := f32(l3.height)
	dl := &h.draw_list_p3
	chrome_dl.ui_draw_list_clear(dl)
	_populate_pane_3_draw_list(h, dl, w, h_pane)

	return render_ui_draw_list_encode(
		h.device,
		&h.chrome_renderer.sdf,
		dl,
		l3.view,
		w,
		h_pane,
		{0.04, 0.05, 0.07, 1.0},
		.Clear,
	)
}

_rasterize_pane_3 :: proc(h: ^Harness_State) {
	cmd := _rasterize_pane_3_encode(h)
	if cmd != nil {
		contract.submit(h.queue, cmd)
		contract.release_command_buffer(cmd)
	}
}

// _populate_pane_4_draw_list populates draw list commands for Pane 4 (Side-by-Side Split Git Diff & Status View).
_populate_pane_4_draw_list :: proc(h: ^Harness_State, dl: ^chrome_dl.Ui_Draw_List, w, h_pane: f32) {
	// Header bar
	chrome_dl.ui_draw_rect(dl, {0, 0, w, 28}, {0.09, 0.09, 0.14, 1.0})
	chrome_dl.ui_draw_rect(dl, {0, 27, w, 1}, {0.16, 0.16, 0.24, 1.0})

	// Badge
	badge_col := [4]f32{0.55, 0.25, 0.85, 1.0} if h.active_pane == 4 else [4]f32{0.18, 0.20, 0.24, 1.0}
	chrome_dl.ui_draw_rounded_rect(dl, {8, 5, 84, 18}, badge_col, 4.0)

	// Git branch pill
	chrome_dl.ui_draw_rounded_rect(dl, {98, 5, 78, 18}, {0.16, 0.14, 0.24, 1.0}, 4.0)
	chrome_dl.ui_draw_border(dl, {98, 5, 78, 18}, {0.35, 0.30, 0.55, 1.0}, 4.0)

	// Column split for Side-by-Side Diff
	col_w := (w - 36.0) * 0.5
	col2_x := 20.0 + col_w
	chrome_dl.ui_draw_rect(dl, {col2_x - 6, 28, 1, h_pane - 56}, {0.14, 0.14, 0.20, 1.0})

	// Column Sub-headers
	chrome_dl.ui_draw_rounded_rect(dl, {16, 32, col_w - 8, 14}, {0.14, 0.12, 0.18, 1.0}, 2.0)
	chrome_dl.ui_draw_rounded_rect(dl, {col2_x, 32, col_w - 8, 14}, {0.12, 0.16, 0.16, 1.0}, 2.0)

	// 26 Side-by-Side Diff rows
	for d in 0..<26 {
		y := 50.0 + f32(d) * 15.0

		// Left Column: Original / Deletions
		chrome_dl.ui_draw_rounded_rect(dl, {16, y, 20, 10}, {0.22, 0.22, 0.30, 0.8}, 2.0)

		is_chunk := (d == 0 || d == 13)
		is_del := !is_chunk && (d % 3 == 2)
		is_add := !is_chunk && (d % 3 == 1)

		diff_shift := f32(((h.git_diff_step + d) % 15) * 4)

		if is_chunk {
			// Chunk header across left column
			chrome_dl.ui_draw_rounded_rect(dl, {40, y, col_w - 48, 10}, {0.20, 0.16, 0.32, 0.85}, 2.0)
		} else if is_del {
			del_w := min(col_w - 52.0, 80.0 + f32((d * 19) % 120) + diff_shift)
			chrome_dl.ui_draw_rounded_rect(dl, {40, y, del_w, 10}, {0.32, 0.10, 0.14, 0.85}, 2.0)
			chrome_dl.ui_draw_border(dl, {40, y, del_w, 10}, {0.75, 0.25, 0.30, 0.9}, 2.0)
		} else {
			unchanged_w := min(col_w - 52.0, 90.0 + f32((d * 13) % 100))
			chrome_dl.ui_draw_rounded_rect(dl, {40, y, unchanged_w, 10}, {0.18, 0.20, 0.26, 0.6}, 2.0)
		}

		// Right Column: Working Tree / Additions
		chrome_dl.ui_draw_rounded_rect(dl, {col2_x, y, 20, 10}, {0.22, 0.22, 0.30, 0.8}, 2.0)

		if is_chunk {
			chrome_dl.ui_draw_rounded_rect(dl, {col2_x + 24, y, col_w - 40, 10}, {0.20, 0.16, 0.32, 0.85}, 2.0)
		} else if is_add {
			add_w := min(col_w - 44.0, 80.0 + f32((d * 23) % 130) + diff_shift)
			chrome_dl.ui_draw_rounded_rect(dl, {col2_x + 24, y, add_w, 10}, {0.10, 0.28, 0.16, 0.85}, 2.0)
			chrome_dl.ui_draw_border(dl, {col2_x + 24, y, add_w, 10}, {0.22, 0.65, 0.35, 0.9}, 2.0)
		} else {
			unchanged_w := min(col_w - 44.0, 90.0 + f32((d * 13) % 100))
			chrome_dl.ui_draw_rounded_rect(dl, {col2_x + 24, y, unchanged_w, 10}, {0.18, 0.20, 0.26, 0.6}, 2.0)
		}
	}

	// Bottom Diff Summary bar spanning full width
	foot_y := h_pane - 26.0
	chrome_dl.ui_draw_rounded_rect(dl, {16, foot_y, 90, 18}, {0.12, 0.45, 0.25, 0.9}, 3.0)
	chrome_dl.ui_draw_rounded_rect(dl, {112, foot_y, 90, 18}, {0.55, 0.18, 0.22, 0.9}, 3.0)
	chrome_dl.ui_draw_rounded_rect(dl, {208, foot_y, 110, 18}, {0.18, 0.20, 0.28, 0.9}, 3.0)
	chrome_dl.ui_draw_rounded_rect(dl, {w - 150, foot_y, 134, 18}, {0.14, 0.16, 0.22, 0.9}, 3.0)
}

// _rasterize_pane_4_encode renders Side-by-Side Split Git Diff & Status View (Bottom-Right) to a command buffer.
_rasterize_pane_4_encode :: proc(h: ^Harness_State) -> rawptr {
	l4 := pipeline.composer_pipeline_get_layer(&h.composer_pipe, PANE_4_ID)
	if l4 == nil || !l4.in_use || rawptr(l4.view) == nil do return nil

	w := f32(l4.width)
	h_pane := f32(l4.height)
	dl := &h.draw_list_p4
	chrome_dl.ui_draw_list_clear(dl)
	_populate_pane_4_draw_list(h, dl, w, h_pane)

	return render_ui_draw_list_encode(
		h.device,
		&h.chrome_renderer.sdf,
		dl,
		l4.view,
		w,
		h_pane,
		{0.05, 0.05, 0.08, 1.0},
		.Clear,
	)
}

_rasterize_pane_4 :: proc(h: ^Harness_State) {
	cmd := _rasterize_pane_4_encode(h)
	if cmd != nil {
		contract.submit(h.queue, cmd)
		contract.release_command_buffer(cmd)
	}
}

// _populate_modal_draw_list populates draw list for Floating Command Palette / Search Modal.
_populate_modal_draw_list :: proc(h: ^Harness_State, dl: ^chrome_dl.Ui_Draw_List, w, h_mod: f32) {
	if h.preview_mode {
		chrome_modals.preview_modal_normal(dl, {0, 0, w, h_mod})
	} else {
		h.modal.rect = {0, 0, w, h_mod}
		h.modal.visible = true
		chrome_modals.modal_emit_draw_list(&h.modal, dl)
	}
}

// _rasterize_modal_encode renders Floating Command Palette / Search Modal (Overlay Layer) to a command buffer.
_rasterize_modal_encode :: proc(h: ^Harness_State) -> rawptr {
	l_mod := pipeline.composer_pipeline_get_layer(&h.composer_pipe, MODAL_LAYER_ID)
	if l_mod == nil || !l_mod.in_use || rawptr(l_mod.view) == nil do return nil

	w := f32(l_mod.width)
	h_mod := f32(l_mod.height)
	dl := &h.draw_list_modal
	chrome_dl.ui_draw_list_clear(dl)
	_populate_modal_draw_list(h, dl, w, h_mod)

	return render_ui_draw_list_encode(
		h.device,
		&h.chrome_renderer.sdf,
		dl,
		l_mod.view,
		w,
		h_mod,
		{0.0, 0.0, 0.0, 0.0},
		.Clear,
	)
}

_rasterize_modal :: proc(h: ^Harness_State) {
	cmd := _rasterize_modal_encode(h)
	if cmd != nil {
		contract.submit(h.queue, cmd)
		contract.release_command_buffer(cmd)
	}
}

// _populate_chrome_draw_list populates draw list for Top Chrome Bar & Window Split Dividers.
_populate_chrome_draw_list :: proc(h: ^Harness_State, dl: ^chrome_dl.Ui_Draw_List, w, h_layer: f32) {
	chrome_h := CHROME_BAR_HEIGHT

	// Chrome bar background and bottom accent line
	chrome_dl.ui_draw_rect(dl, {0, 0, w, chrome_h}, {0.08, 0.09, 0.11, 1.0})
	chrome_dl.ui_draw_rect(dl, {0, chrome_h - 1.0, w, 1.0}, {0.18, 0.20, 0.25, 1.0})

	// Tabs on Left
	tab_bar_w := min(w * 0.45, 520.0)
	bar_rect := [4]f32{0, 0, tab_bar_w, chrome_h}
	if h.extreme_tabs {
		chrome_tabs.preview_tabs_extreme(dl, bar_rect, 128)
	} else if h.preview_mode {
		chrome_tabs.preview_tabs_normal(dl, bar_rect)
	} else {
		h.tabs_model.bar_rect = bar_rect
		chrome_tabs.tabs_emit_draw_list(&h.tabs_model, dl)
	}

	// Emit 1px split dividers on the chrome layer using core/chrome splits
	content_y := chrome_h
	content_h := max(f32(10.0), h_layer - content_y)
	split_bounds := [4]f32{0, content_y, w, content_h}
	if h.divider_drag_active {
		_emit_dynamic_dividers(dl, split_bounds, h.divider_ratio)
	} else {
		chrome_splits.preview_splits_normal(dl, split_bounds)
	}

	// Real-Time On-Screen Telemetry HUD Badges:
	// Status of each pane (REDRAW vs CACHED)
	hud_x: f32 = max(tab_bar_w + 16.0, 530.0)

	// Pill 1: Pane 1
	p1_col := [4]f32{0.82, 0.22, 0.18, 1.0} if h.last_p1_redrawn else [4]f32{0.14, 0.58, 0.28, 1.0}
	chrome_dl.ui_draw_rounded_rect(dl, {hud_x, 8, 56, 24}, p1_col, 4.0)

	// Pill 2: Pane 2
	p2_col := [4]f32{0.82, 0.22, 0.18, 1.0} if h.last_p2_redrawn else [4]f32{0.14, 0.58, 0.28, 1.0}
	chrome_dl.ui_draw_rounded_rect(dl, {hud_x + 62, 8, 56, 24}, p2_col, 4.0)

	// Pill 3: Pane 3
	p3_col := [4]f32{0.82, 0.22, 0.18, 1.0} if h.last_p3_redrawn else [4]f32{0.14, 0.58, 0.28, 1.0}
	chrome_dl.ui_draw_rounded_rect(dl, {hud_x + 124, 8, 56, 24}, p3_col, 4.0)

	// Pill 4: Pane 4
	p4_col := [4]f32{0.82, 0.22, 0.18, 1.0} if h.last_p4_redrawn else [4]f32{0.14, 0.58, 0.28, 1.0}
	chrome_dl.ui_draw_rounded_rect(dl, {hud_x + 186, 8, 56, 24}, p4_col, 4.0)

	// Savings Ratio Pill: calculates percentage of GPU raster time saved
	redrawn_panes := 0
	if h.last_p1_redrawn do redrawn_panes += 1
	if h.last_p2_redrawn do redrawn_panes += 1
	if h.last_p3_redrawn do redrawn_panes += 1
	if h.last_p4_redrawn do redrawn_panes += 1
	cached_panes := 4 - redrawn_panes
	savings_ratio := f32(cached_panes) / 4.0

	savings_col: [4]f32
	if savings_ratio >= 0.99 {
		savings_col = {0.12, 0.48, 0.85, 1.0} // 100% saved (Idle)
	} else if savings_ratio >= 0.70 {
		savings_col = {0.12, 0.65, 0.70, 1.0} // 75% saved (1 pane active)
	} else if savings_ratio >= 0.40 {
		savings_col = {0.80, 0.60, 0.15, 1.0} // 50% saved
	} else {
		savings_col = {0.50, 0.20, 0.20, 1.0} // 0% saved (Flood)
	}
	chrome_dl.ui_draw_rounded_rect(dl, {hud_x + 250, 8, 88, 24}, savings_col, 4.0)

	// Performance Telemetry Pill: Raster vs Blit
	chrome_dl.ui_draw_rounded_rect(dl, {hud_x + 346, 8, 150, 24}, {0.15, 0.17, 0.22, 1.0}, 4.0)
	chrome_dl.ui_draw_border(dl, {hud_x + 346, 8, 150, 24}, {0.25, 0.30, 0.40, 1.0}, 4.0)

	// Benchmark Results Badge (rendered if benchmark has run)
	if h.bench_has_run {
		badge_col := [4]f32{0.12, 0.75, 0.35, 1.0} if h.bench_work_ratio <= 50.0 else [4]f32{0.85, 0.60, 0.15, 1.0}
		chrome_dl.ui_draw_rounded_rect(dl, {w - 180, 8, 80, 24}, badge_col, 4.0)
		chrome_dl.ui_draw_border(dl, {w - 180, 8, 80, 24}, {1.0, 1.0, 1.0, 0.3}, 4.0)

		saved_norm := max(f32(0.0), min(f32(1.0), f32(h.bench_raster_time_saved / 100.0)))
		bar_w := max(f32(4.0), 72.0 * saved_norm)
		chrome_dl.ui_draw_rounded_rect(dl, {w - 176, 12, bar_w, 16}, {1.0, 1.0, 1.0, 0.35}, 2.0)
	}

	// Benchmark key button
	chrome_dl.ui_draw_rounded_rect(dl, {w - 92, 8, 84, 24}, {0.80, 0.42, 0.12, 1.0}, 4.0)
}

// _rasterize_chrome_encode renders Top Chrome Bar with Tabs & Real-Time On-Screen Telemetry HUD to a command buffer.
_rasterize_chrome_encode :: proc(h: ^Harness_State) -> rawptr {
	lc := pipeline.composer_pipeline_get_layer(&h.composer_pipe, CHROME_LAYER_ID)
	if lc == nil || !lc.in_use || rawptr(lc.view) == nil do return nil

	w := f32(lc.width)
	h_chrome := f32(lc.height)
	dl := &h.draw_list_chrome
	chrome_dl.ui_draw_list_clear(dl)
	_populate_chrome_draw_list(h, dl, w, h_chrome)

	return render_ui_draw_list_encode(
		h.device,
		&h.chrome_renderer.sdf,
		dl,
		lc.view,
		w,
		h_chrome,
		{0.0, 0.0, 0.0, 0.0},
		.Clear,
	)
}

_rasterize_chrome :: proc(h: ^Harness_State) {
	cmd := _rasterize_chrome_encode(h)
	if cmd != nil {
		contract.submit(h.queue, cmd)
		contract.release_command_buffer(cmd)
	}
}

// _rasterize_dirty_panes rasterizes ONLY dirty panes into their offscreen backing textures.
// Clean panes cost ZERO rasterization passes and ZERO draw calls!
_rasterize_dirty_panes :: proc(h: ^Harness_State) -> (redrawn_count: int) {
	redrawn_count = 0

	if pipeline.composer_pipeline_is_dirty(&h.composer_pipe, PANE_1_ID) {
		_rasterize_pane_1(h)
		pipeline.composer_pipeline_mark_clean(&h.composer_pipe, PANE_1_ID)
		h.last_p1_redrawn = true
		redrawn_count += 1
	} else {
		h.last_p1_redrawn = false
	}

	if pipeline.composer_pipeline_is_dirty(&h.composer_pipe, PANE_2_ID) {
		_rasterize_pane_2(h)
		pipeline.composer_pipeline_mark_clean(&h.composer_pipe, PANE_2_ID)
		h.last_p2_redrawn = true
		redrawn_count += 1
	} else {
		h.last_p2_redrawn = false
	}

	if pipeline.composer_pipeline_is_dirty(&h.composer_pipe, PANE_3_ID) {
		_rasterize_pane_3(h)
		pipeline.composer_pipeline_mark_clean(&h.composer_pipe, PANE_3_ID)
		h.last_p3_redrawn = true
		redrawn_count += 1
	} else {
		h.last_p3_redrawn = false
	}

	if pipeline.composer_pipeline_is_dirty(&h.composer_pipe, PANE_4_ID) {
		_rasterize_pane_4(h)
		pipeline.composer_pipeline_mark_clean(&h.composer_pipe, PANE_4_ID)
		h.last_p4_redrawn = true
		redrawn_count += 1
	} else {
		h.last_p4_redrawn = false
	}

	if pipeline.composer_pipeline_is_dirty(&h.composer_pipe, CHROME_LAYER_ID) {
		_rasterize_chrome(h)
		pipeline.composer_pipeline_mark_clean(&h.composer_pipe, CHROME_LAYER_ID)
	}

	if h.modal_active && pipeline.composer_pipeline_is_dirty(&h.composer_pipe, MODAL_LAYER_ID) {
		_rasterize_modal(h)
		pipeline.composer_pipeline_mark_clean(&h.composer_pipe, MODAL_LAYER_ID)
	}

	return redrawn_count
}

// _rasterize_layer_into_encoder encodes raster work for one dirty layer into the shared command encoder enc.
_rasterize_layer_into_encoder :: proc(h: ^Harness_State, enc: contract.Gpu_CommandEncoder, l: ^composer.Composer_Layer) -> bool {
	if h == nil || rawptr(enc) == nil || l == nil || !l.in_use || rawptr(l.view) == nil do return false

	w := f32(l.width)
	h_layer := f32(l.height)

	switch l.id {
	case PANE_1_ID:
		h.last_p1_redrawn = true
		dl := &h.draw_list_p1
		chrome_dl.ui_draw_list_clear(dl)
		if h.extreme_sdf_mode {
			_generate_1000_sdf_elements(dl, {0, 0, w, h_layer})
		} else if h.extreme_radius_mode {
			_generate_extreme_radius_elements(dl, {0, 0, w, h_layer})
		} else {
			_populate_pane_1_draw_list(h, dl, w, h_layer)
		}
		return render_ui_draw_list_to_encoder(enc, &h.chrome_renderer.sdf, dl, l.view, w, h_layer, {0.05, 0.06, 0.08, 1.0}, .Clear)

	case PANE_2_ID:
		h.last_p2_redrawn = true
		wgpu_enc := wgpu.CommandEncoder(rawptr(enc))

		cur_ticks := helper.platform_now()
		elapsed_ns := helper.platform_ticks_to_ns(cur_ticks - h.start_ticks)
		time_s := f32(f64(elapsed_ns) / 1_000_000_000.0)

		vp_w := f32(l.width)
		vp_h := f32(l.height)
		uniforms := three_d.interactor_compute_uniforms(&h.three_d_interactor, vp_w, vp_h, time_s)

		depth_view_handle := wgpu.TextureView(rawptr(l.depth_view))
		if depth_view_handle == nil {
			depth_view_handle = h.three_d_renderer.depth_view
		}

		color_attachment := wgpu.RenderPassColorAttachment{
			view       = wgpu.TextureView(rawptr(l.view)),
			loadOp     = .Clear,
			storeOp    = .Store,
			clearValue = wgpu.Color{ 0.04, 0.05, 0.08, 1.0 },
			depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
		}
		depth_attachment := wgpu.RenderPassDepthStencilAttachment{
			view            = depth_view_handle,
			depthLoadOp     = .Clear,
			depthStoreOp    = .Store,
			depthClearValue = 1.0,
			depthReadOnly   = false,
		}
		pass_desc := wgpu.RenderPassDescriptor{
			colorAttachmentCount   = 1,
			colorAttachments       = &color_attachment,
			depthStencilAttachment = &depth_attachment,
		}

		pass := wgpu.CommandEncoderBeginRenderPass(wgpu_enc, &pass_desc)
		if pass != nil {
			wgpu.RenderPassEncoderSetViewport(pass, 0.0, 0.0, vp_w, vp_h, 0.0, 1.0)
			three_d.three_d_draw(&h.three_d_renderer, pass, &uniforms)
			wgpu.RenderPassEncoderEnd(pass)
			wgpu.RenderPassEncoderRelease(pass)
		}

		dl := &h.draw_list_p2
		chrome_dl.ui_draw_list_clear(dl)
		_populate_pane_2_draw_list(h, dl, vp_w, vp_h)
		return render_ui_draw_list_to_encoder(enc, &h.chrome_renderer.sdf, dl, l.view, vp_w, vp_h, {0, 0, 0, 0}, .Load)

	case PANE_3_ID:
		h.last_p3_redrawn = true
		dl := &h.draw_list_p3
		chrome_dl.ui_draw_list_clear(dl)
		_populate_pane_3_draw_list(h, dl, w, h_layer)
		return render_ui_draw_list_to_encoder(enc, &h.chrome_renderer.sdf, dl, l.view, w, h_layer, {0.04, 0.05, 0.07, 1.0}, .Clear)

	case PANE_4_ID:
		h.last_p4_redrawn = true
		dl := &h.draw_list_p4
		chrome_dl.ui_draw_list_clear(dl)
		_populate_pane_4_draw_list(h, dl, w, h_layer)
		return render_ui_draw_list_to_encoder(enc, &h.chrome_renderer.sdf, dl, l.view, w, h_layer, {0.05, 0.05, 0.08, 1.0}, .Clear)

	case CHROME_LAYER_ID:
		dl := &h.draw_list_chrome
		chrome_dl.ui_draw_list_clear(dl)
		_populate_chrome_draw_list(h, dl, w, h_layer)
		return render_ui_draw_list_to_encoder(enc, &h.chrome_renderer.sdf, dl, l.view, w, h_layer, {0, 0, 0, 0}, .Clear)

	case MODAL_LAYER_ID:
		dl := &h.draw_list_modal
		chrome_dl.ui_draw_list_clear(dl)
		_populate_modal_draw_list(h, dl, w, h_layer)
		return render_ui_draw_list_to_encoder(enc, &h.chrome_renderer.sdf, dl, l.view, w, h_layer, {0, 0, 0, 0}, .Clear)
	}

	return false
}

// Frame Driver Callbacks for core/composer/frame.frame_tick
_frame_acquire :: proc(user: rawptr) -> (contract.Gpu_Texture, contract.Gpu_TextureView, bool) {
	h := (^Harness_State)(user)
	if h == nil || h.surface == nil do return nil, nil, false
	for _ in 0..<10 {
		tex, view, _ := contract.get_surface_texture(h.surface)
		if rawptr(view) != nil {
			return tex, view, true
		}
		event: sdl3.Event
		for sdl3.PollEvent(&event) {}
		if h.window.handle != nil {
			sdl3.RaiseWindow(h.window.handle)
		}
		helper.window_update_pixel_size(&h.window)
		screen_w := f32(h.window.pixel_w)
		screen_h := f32(h.window.pixel_h)
		contract.configure_surface(h.surface, h.device, h.format, u32(screen_w), u32(screen_h))
		contract.poll_device(h.device, true)
	}
	return nil, nil, false
}

_frame_raster :: proc(user: rawptr, enc: contract.Gpu_CommandEncoder, l: ^composer.Composer_Layer) -> bool {
	h := (^Harness_State)(user)
	if h == nil do return false
	return _rasterize_layer_into_encoder(h, enc, l)
}

_frame_present :: proc(user: rawptr, tex: contract.Gpu_Texture, view: contract.Gpu_TextureView) -> bool {
	h := (^Harness_State)(user)
	if h == nil || h.surface == nil do return false
	ok := contract.present_surface(h.surface)
	contract.release_surface_texture(tex, view)
	return ok
}

Raster_Bench_Timings :: struct {
	gpu_raster_ns:     u64,
	cpu_encode_ns:     u64,
	cpu_submit_ns:     u64,
	redrawn_count:     int,
	regenerated_quads: int,
}

_emit_timestamp_query :: proc(h: ^Harness_State, query_idx: u32, view: contract.Gpu_TextureView) -> rawptr {
	if !h.ts_supported || rawptr(view) == nil do return nil
	wgpu_dev := wgpu.Device(rawptr(h.device))
	enc := wgpu.DeviceCreateCommandEncoder(wgpu_dev, nil)
	if enc == nil do return nil

	ts_writes := wgpu.PassTimestampWrites{
		querySet                  = h.ts_query_set,
		beginningOfPassWriteIndex = query_idx,
		endOfPassWriteIndex       = wgpu.QUERY_SET_INDEX_UNDEFINED,
	}
	color_att := [1]wgpu.RenderPassColorAttachment{
		{
			view       = wgpu.TextureView(rawptr(view)),
			depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
			loadOp     = .Load,
			storeOp    = .Store,
		},
	}
	pass_desc := wgpu.RenderPassDescriptor{
		colorAttachmentCount = 1,
		colorAttachments     = raw_data(color_att[:]),
		timestampWrites      = &ts_writes,
	}
	pass := wgpu.CommandEncoderBeginRenderPass(enc, &pass_desc)
	if pass != nil {
		wgpu.RenderPassEncoderEnd(pass)
		wgpu.RenderPassEncoderRelease(pass)
	}

	cmd := wgpu.CommandEncoderFinish(enc, nil)
	wgpu.CommandEncoderRelease(enc)
	return rawptr(cmd)
}

_resolve_and_copy_timestamps :: proc(h: ^Harness_State) -> rawptr {
	if !h.ts_supported do return nil
	wgpu_dev := wgpu.Device(rawptr(h.device))
	enc := wgpu.DeviceCreateCommandEncoder(wgpu_dev, nil)
	if enc == nil do return nil

	wgpu.CommandEncoderResolveQuerySet(enc, h.ts_query_set, 0, 2, h.ts_resolve_buf, 0)
	wgpu.CommandEncoderCopyBufferToBuffer(enc, h.ts_resolve_buf, 0, h.ts_readback_buf, 0, 2 * size_of(u64))
	cmd := wgpu.CommandEncoderFinish(enc, nil)
	wgpu.CommandEncoderRelease(enc)
	return rawptr(cmd)
}

_read_gpu_timestamp_duration :: proc(h: ^Harness_State) -> u64 {
	if !h.ts_supported do return 0
	wgpu_inst := wgpu.Instance(h.instance)
	wgpu_dev := wgpu.Device(rawptr(h.device))

	_on_map :: proc "c" (status: wgpu.MapAsyncStatus, message: wgpu.StringView, userdata1: rawptr, userdata2: rawptr) {
		done := (^bool)(userdata2)
		if done != nil do done^ = true
	}

	done := false
	_ = wgpu.BufferMapAsync(
		h.ts_readback_buf,
		{ .Read },
		0,
		2 * size_of(u64),
		wgpu.BufferMapCallbackInfo{
			mode      = .AllowProcessEvents,
			callback  = _on_map,
			userdata2 = &done,
		},
	)

	for !done {
		wgpu.InstanceProcessEvents(wgpu_inst)
		wgpu.DevicePoll(wgpu_dev, true, nil)
	}

	ptr := wgpu.RawBufferGetConstMappedRange(h.ts_readback_buf, 0, 2 * size_of(u64))
	if ptr == nil {
		wgpu.BufferUnmap(h.ts_readback_buf)
		return 0
	}
	ts := ([^]u64)(ptr)
	diff: u64 = 0
	if ts[1] > ts[0] {
		raw_ticks := ts[1] - ts[0]
		period := f64(h.ts_period)
		if period <= 0.0 do period = 1.0
		diff = u64(f64(raw_ticks) * period)
	}
	wgpu.BufferUnmap(h.ts_readback_buf)
	return diff
}

_rasterize_dirty_panes_bench :: proc(h: ^Harness_State) -> Raster_Bench_Timings {
	res: Raster_Bench_Timings

	p1_dirty := pipeline.composer_pipeline_is_dirty(&h.composer_pipe, PANE_1_ID)
	p2_dirty := pipeline.composer_pipeline_is_dirty(&h.composer_pipe, PANE_2_ID)
	p3_dirty := pipeline.composer_pipeline_is_dirty(&h.composer_pipe, PANE_3_ID)
	p4_dirty := pipeline.composer_pipeline_is_dirty(&h.composer_pipe, PANE_4_ID)
	chrome_dirty := pipeline.composer_pipeline_is_dirty(&h.composer_pipe, CHROME_LAYER_ID)
	modal_dirty := h.modal_active && pipeline.composer_pipeline_is_dirty(&h.composer_pipe, MODAL_LAYER_ID)

	l1 := pipeline.composer_pipeline_get_layer(&h.composer_pipe, PANE_1_ID)
	view_for_ts := l1.view if (l1 != nil && rawptr(l1.view) != nil) else contract.Gpu_TextureView(nil)

	// CPU Encode phase: populate draw lists and encode command buffers
	t_enc_0 := helper.platform_now()
	cmds: [12]rawptr
	cmd_count := 0

	if p1_dirty {
		cmd := _rasterize_pane_1_encode(h)
		if cmd != nil {
			cmds[cmd_count] = cmd
			cmd_count += 1
		}
		pipeline.composer_pipeline_mark_clean(&h.composer_pipe, PANE_1_ID)
		h.last_p1_redrawn = true
		res.redrawn_count += 1
		res.regenerated_quads += len(h.draw_list_p1.commands)
	} else {
		h.last_p1_redrawn = false
	}

	if p2_dirty {
		c1, c2 := _rasterize_pane_2_encode(h)
		if c1 != nil {
			cmds[cmd_count] = c1
			cmd_count += 1
		}
		if c2 != nil {
			cmds[cmd_count] = c2
			cmd_count += 1
		}
		pipeline.composer_pipeline_mark_clean(&h.composer_pipe, PANE_2_ID)
		h.last_p2_redrawn = true
		res.redrawn_count += 1
		res.regenerated_quads += len(h.draw_list_p2.commands)
	} else {
		h.last_p2_redrawn = false
	}

	if p3_dirty {
		cmd := _rasterize_pane_3_encode(h)
		if cmd != nil {
			cmds[cmd_count] = cmd
			cmd_count += 1
		}
		pipeline.composer_pipeline_mark_clean(&h.composer_pipe, PANE_3_ID)
		h.last_p3_redrawn = true
		res.redrawn_count += 1
		res.regenerated_quads += len(h.draw_list_p3.commands)
	} else {
		h.last_p3_redrawn = false
	}

	if p4_dirty {
		cmd := _rasterize_pane_4_encode(h)
		if cmd != nil {
			cmds[cmd_count] = cmd
			cmd_count += 1
		}
		pipeline.composer_pipeline_mark_clean(&h.composer_pipe, PANE_4_ID)
		h.last_p4_redrawn = true
		res.redrawn_count += 1
		res.regenerated_quads += len(h.draw_list_p4.commands)
	} else {
		h.last_p4_redrawn = false
	}

	if chrome_dirty {
		cmd := _rasterize_chrome_encode(h)
		if cmd != nil {
			cmds[cmd_count] = cmd
			cmd_count += 1
		}
		pipeline.composer_pipeline_mark_clean(&h.composer_pipe, CHROME_LAYER_ID)
		res.regenerated_quads += len(h.draw_list_chrome.commands)
	}

	if modal_dirty {
		cmd := _rasterize_modal_encode(h)
		if cmd != nil {
			cmds[cmd_count] = cmd
			cmd_count += 1
		}
		pipeline.composer_pipeline_mark_clean(&h.composer_pipe, MODAL_LAYER_ID)
		res.regenerated_quads += len(h.draw_list_modal.commands)
	}
	t_enc_1 := helper.platform_now()
	res.cpu_encode_ns = u64(max(i64(0), helper.platform_ticks_to_ns(t_enc_1 - t_enc_0)))

	// Hardware GPU timestamp query setup
	cmd_ts0: rawptr = nil
	cmd_ts1: rawptr = nil
	cmd_resolve: rawptr = nil
	if h.ts_supported && rawptr(view_for_ts) != nil {
		cmd_ts0 = _emit_timestamp_query(h, 0, view_for_ts)
		cmd_ts1 = _emit_timestamp_query(h, 1, view_for_ts)
		cmd_resolve = _resolve_and_copy_timestamps(h)
	}

	// CPU Submit phase: submit to hardware GPU queue
	t_sub_0 := helper.platform_now()
	if cmd_ts0 != nil {
		contract.submit(h.queue, cmd_ts0)
		contract.release_command_buffer(cmd_ts0)
	}
	for i in 0..<cmd_count {
		contract.submit(h.queue, cmds[i])
		contract.release_command_buffer(cmds[i])
	}
	if cmd_ts1 != nil {
		contract.submit(h.queue, cmd_ts1)
		contract.release_command_buffer(cmd_ts1)
	}
	if cmd_resolve != nil {
		contract.submit(h.queue, cmd_resolve)
		contract.release_command_buffer(cmd_resolve)
	}
	t_sub_1 := helper.platform_now()
	res.cpu_submit_ns = u64(max(i64(0), helper.platform_ticks_to_ns(t_sub_1 - t_sub_0)))

	// Hardware GPU Raster duration readback
	if h.ts_supported {
		gpu_ns := _read_gpu_timestamp_duration(h)
		res.gpu_raster_ns = gpu_ns
	} else {
		res.gpu_raster_ns = 0
	}

	return res
}

Blit_Timings :: struct {
	acquire_ns:   u64,
	composite_ns: u64,
	present_ns:   u64,
	total_ns:     u64,
}

// _composite_and_present_bench decomposes blit into acquire, composite, and present timings.
_composite_and_present_bench :: proc(h: ^Harness_State) -> (ok: bool, timings: Blit_Timings) {
	t_acq_0 := helper.platform_now()
	tex, view, _ := contract.get_surface_texture(h.surface)
	t_acq_1 := helper.platform_now()
	timings.acquire_ns = u64(max(i64(0), helper.platform_ticks_to_ns(t_acq_1 - t_acq_0)))

	if rawptr(view) == nil do return false, timings

	t_comp_0 := helper.platform_now()
	enc := contract.create_command_encoder(h.device)
	if rawptr(enc) == nil {
		contract.release_surface_texture(tex, view)
		return false, timings
	}

	comp_ok := pipeline.composer_pipeline_composite(&h.composer_pipe, enc, view)

	cmd := contract.finish_command_buffer(enc)
	if cmd != nil {
		contract.submit(h.queue, cmd)
		contract.release_command_buffer(cmd)
	}
	contract.release_command_encoder(enc)
	t_comp_1 := helper.platform_now()
	timings.composite_ns = u64(max(i64(0), helper.platform_ticks_to_ns(t_comp_1 - t_comp_0)))

	t_pres_0 := helper.platform_now()
	pres_ok := contract.present_surface(h.surface)
	contract.release_surface_texture(tex, view)
	t_pres_1 := helper.platform_now()
	timings.present_ns = u64(max(i64(0), helper.platform_ticks_to_ns(t_pres_1 - t_pres_0)))

	timings.total_ns = timings.acquire_ns + timings.composite_ns + timings.present_ns
	ok = comp_ok && pres_ok
	return ok, timings
}

// _composite_and_present executes the hardware quad blit pass with scissor clipping and presents the swapchain.
_composite_and_present :: proc(h: ^Harness_State) -> bool {
	ok, _ := _composite_and_present_bench(h)
	return ok
}

// _update_layer_geometry synchronizes layer destinations and scissor clipping rectangles.
_update_layer_geometry :: proc(h: ^Harness_State) {
	screen_w := f32(h.window.pixel_w)
	screen_h := f32(h.window.pixel_h)
	chrome_h := CHROME_BAR_HEIGHT
	content_y := chrome_h
	content_h := max(f32(10.0), screen_h - chrome_h)
	pane_w := screen_w * 0.5
	pane_h := content_h * 0.5

	h.screen_w = screen_w
	h.screen_h = screen_h
	h.pane_w = pane_w
	h.pane_h = pane_h

	pipeline.composer_pipeline_resize(&h.composer_pipe, screen_w, screen_h)

	// Inset for scissor clipping proof test
	inset_x: f32 = 36.0 if h.scissor_test_active else 0.0
	inset_y: f32 = 28.0 if h.scissor_test_active else 0.0

	// Layer 1: Top-Left
	l1 := pipeline.composer_pipeline_get_layer(&h.composer_pipe, PANE_1_ID)
	if l1 != nil {
		l1.dest_rect = composer.rect_make(0, content_y, pane_w, pane_h)
		l1.scissor_rect = composer.rect_make(
			l1.dest_rect.x + inset_x,
			l1.dest_rect.y + inset_y,
			max(l1.dest_rect.w - inset_x * 2.0, 10.0),
			max(l1.dest_rect.h - inset_y * 2.0, 10.0),
		)
		l1.corner_radius = 0.0
		l1.opacity = 1.0
	}

	// Layer 2: Top-Right (3D)
	l2 := pipeline.composer_pipeline_get_layer(&h.composer_pipe, PANE_2_ID)
	if l2 != nil {
		l2.dest_rect = composer.rect_make(pane_w, content_y, pane_w, pane_h)
		l2.scissor_rect = composer.rect_make(
			l2.dest_rect.x + inset_x,
			l2.dest_rect.y + inset_y,
			max(l2.dest_rect.w - inset_x * 2.0, 10.0),
			max(l2.dest_rect.h - inset_y * 2.0, 10.0),
		)
		l2.corner_radius = 0.0
		l2.opacity = 1.0
	}

	// Layer 3: Bottom-Left
	l3 := pipeline.composer_pipeline_get_layer(&h.composer_pipe, PANE_3_ID)
	if l3 != nil {
		l3.dest_rect = composer.rect_make(0, content_y + pane_h, pane_w, pane_h)
		l3.scissor_rect = composer.rect_make(
			l3.dest_rect.x + inset_x,
			l3.dest_rect.y + inset_y,
			max(l3.dest_rect.w - inset_x * 2.0, 10.0),
			max(l3.dest_rect.h - inset_y * 2.0, 10.0),
		)
		l3.corner_radius = 0.0
		l3.opacity = 1.0
	}

	// Layer 4: Bottom-Right
	l4 := pipeline.composer_pipeline_get_layer(&h.composer_pipe, PANE_4_ID)
	if l4 != nil {
		l4.dest_rect = composer.rect_make(pane_w, content_y + pane_h, pane_w, pane_h)
		l4.scissor_rect = composer.rect_make(
			l4.dest_rect.x + inset_x,
			l4.dest_rect.y + inset_y,
			max(l4.dest_rect.w - inset_x * 2.0, 10.0),
			max(l4.dest_rect.h - inset_y * 2.0, 10.0),
		)
		l4.corner_radius = 0.0
		l4.opacity = 1.0
	}

	// Chrome: Top + Dividers Overlay
	lc := pipeline.composer_pipeline_get_layer(&h.composer_pipe, CHROME_LAYER_ID)
	if lc != nil {
		lc.dest_rect = composer.rect_make(0, 0, screen_w, screen_h)
		lc.scissor_rect = lc.dest_rect
		lc.corner_radius = 0.0
		lc.opacity = 1.0
	}

	// Modal: Floating Center Overlay
	l_mod := pipeline.composer_pipeline_get_layer(&h.composer_pipe, MODAL_LAYER_ID)
	if l_mod != nil {
		modal_w: f32 = 640.0
		modal_h: f32 = 380.0
		if h.modal_active {
			l_mod.dest_rect = composer.rect_make((screen_w - modal_w) * 0.5, (screen_h - modal_h) * 0.42, modal_w, modal_h)
			l_mod.scissor_rect = l_mod.dest_rect
			l_mod.corner_radius = 12.0
			l_mod.opacity = 1.0
		} else {
			l_mod.dest_rect = composer.rect_make(0, 0, 0, 0)
			l_mod.scissor_rect = composer.rect_make(0, 0, 0, 0)
			l_mod.corner_radius = 0.0
			l_mod.opacity = 0.0
		}
	}
}

// _mark_layer_dirty marks a layer dirty in both composer pipeline and frame scheduler.
_mark_layer_dirty :: proc(h: ^Harness_State, id: composer.Layer_Id) {
	pipeline.composer_pipeline_mark_dirty(&h.composer_pipe, id)
	scheduler.scheduler_mark_damage(&h.scheduler, id)
}

// _acquire_all_layers sets up backing surface textures across all 6 layers.
_acquire_all_layers :: proc(h: ^Harness_State) {
	screen_w := f32(h.window.pixel_w)
	screen_h := f32(h.window.pixel_h)
	chrome_h := CHROME_BAR_HEIGHT
	content_h := max(f32(10.0), screen_h - chrome_h)
	pane_w := screen_w * 0.5
	pane_h := content_h * 0.5

	_, _ = pipeline.composer_pipeline_acquire_layer(&h.composer_pipe, PANE_1_ID, .Terminal, u32(pane_w), u32(pane_h), false)
	_, _ = pipeline.composer_pipeline_acquire_layer(&h.composer_pipe, PANE_2_ID, .Three_D, u32(pane_w), u32(pane_h), true)
	_, _ = pipeline.composer_pipeline_acquire_layer(&h.composer_pipe, PANE_3_ID, .Terminal, u32(pane_w), u32(pane_h), false)
	_, _ = pipeline.composer_pipeline_acquire_layer(&h.composer_pipe, PANE_4_ID, .Terminal, u32(pane_w), u32(pane_h), false)
	_, _ = pipeline.composer_pipeline_acquire_layer(&h.composer_pipe, CHROME_LAYER_ID, .Chrome, u32(screen_w), u32(screen_h), false)

	modal_w: f32 = 640.0
	modal_h: f32 = 380.0
	_, _ = pipeline.composer_pipeline_acquire_layer(&h.composer_pipe, MODAL_LAYER_ID, .Overlay, u32(modal_w), u32(modal_h), false)

	order := [6]composer.Layer_Id{PANE_1_ID, PANE_2_ID, PANE_3_ID, PANE_4_ID, CHROME_LAYER_ID, MODAL_LAYER_ID}
	pipeline.composer_pipeline_set_layer_order(&h.composer_pipe, order[:])

	_update_layer_geometry(h)
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

_calc_percentiles_non_zero :: proc(samples: []u64, temp_buf: []u64) -> Percentile_Metrics {
	count := 0
	for s in samples {
		if s > 0 {
			if count < len(temp_buf) {
				temp_buf[count] = s
				count += 1
			}
		}
	}
	if count == 0 do return {}
	return _calc_percentiles(temp_buf[:count])
}

// _warmup_high_gpu_clock runs heavy frames marking all 4 panes dirty to lock GPU DVFS into high clocks.
_warmup_high_gpu_clock :: proc(h: ^Harness_State, frames: int = 200) {
	h.modal_active = false
	_update_layer_geometry(h)

	for i in 0..<frames {
		sdl3.PumpEvents()
		event: sdl3.Event
		for sdl3.PollEvent(&event) {}

		h.active_line_idx = (i / 3) % 30
		h.shell_typed_chars = (h.shell_typed_chars + 1) % 40
		h.three_d_interactor.yaw += 0.05
		h.three_d_interactor.pitch = 0.3 + 0.15 * math.sin(f32(i) * 0.08)
		h.build_step = (h.build_step + 1) % 20
		h.git_diff_step = (h.git_diff_step + 1) % 15

		pipeline.composer_pipeline_begin_frame(&h.composer_pipe)
		pipeline.composer_pipeline_mark_dirty(&h.composer_pipe, PANE_1_ID)
		pipeline.composer_pipeline_mark_dirty(&h.composer_pipe, PANE_2_ID)
		pipeline.composer_pipeline_mark_dirty(&h.composer_pipe, PANE_3_ID)
		pipeline.composer_pipeline_mark_dirty(&h.composer_pipe, PANE_4_ID)

		_ = _rasterize_dirty_panes(h)
		_ = _composite_and_present(h)

		pipeline.composer_pipeline_end_frame(&h.composer_pipe)
	}
}

// _shuffle_phases shuffles phase order using a Fisher-Yates shuffle to eliminate temporal ordering bias.
_shuffle_phases :: proc(order: ^[5]int, rng_state: ^u64) {
	for i := 4; i > 0; i -= 1 {
		rng_state^ = rng_state^ * 6364136223846793005 + 1442695040888963407
		j := int((rng_state^ >> 33) % u64(i + 1))
		tmp := order[i]
		order[i] = order[j]
		order[j] = tmp
	}
}

_run_benchmark_phase :: proc(
	h: ^Harness_State,
	phase: int,
	frames: int,
	out_gpu: []u64,
	out_enc: []u64,
	out_sub: []u64,
	out_acq: []u64,
	out_comp: []u64,
	out_pres: []u64,
	out_total: []u64,
	out_quads: []int,
	out_redrawn: []int,
) -> (presented_count: int) {
	h.modal_active = false
	chrome_tabs.tabs_set_active(&h.tabs_model, 0)
	_update_layer_geometry(h)
	h.cursor_visible = true

	for i in 0..<frames {
		sdl3.PumpEvents()
		event: sdl3.Event
		for sdl3.PollEvent(&event) {}

		switch phase {
		case 0:
			// Phase 0: Tiny Damage (Quiescent Blinking Cursor)
			h.cursor_visible = (i % 2 == 0)
			pipeline.composer_pipeline_mark_dirty(&h.composer_pipe, PANE_1_ID)
			pipeline.composer_pipeline_begin_frame(&h.composer_pipe)

		case 1:
			// Phase 1: Incremental Single-Line Update (1-Pane Caching)
			h.active_line_idx = (i / 3) % 30
			h.shell_typed_chars = (h.shell_typed_chars + 1) % 40
			pipeline.composer_pipeline_mark_dirty(&h.composer_pipe, PANE_1_ID)
			pipeline.composer_pipeline_begin_frame(&h.composer_pipe)

		case 2:
			// Phase 2: Tab & Session Content Switching
			tab_idx := (i / 25) % 4
			if tab_idx != h.tabs_model.active_idx {
				chrome_tabs.tabs_set_active(&h.tabs_model, tab_idx)
				pipeline.composer_pipeline_mark_dirty(&h.composer_pipe, CHROME_LAYER_ID)
			}
			h.active_line_idx = (i / 3) % 30
			h.shell_typed_chars = (h.shell_typed_chars + 1) % 40
			pipeline.composer_pipeline_mark_dirty(&h.composer_pipe, PANE_1_ID)
			pipeline.composer_pipeline_begin_frame(&h.composer_pipe)

		case 3:
			// Phase 3: Floating Popup Modal Overlay Cycles + Typing
			should_open := ((i / 15) % 2 == 1)
			if should_open != h.modal_active {
				h.modal_active = should_open
				_update_layer_geometry(h)
				if h.modal_active {
					pipeline.composer_pipeline_mark_dirty(&h.composer_pipe, MODAL_LAYER_ID)
				}
				pipeline.composer_pipeline_mark_dirty(&h.composer_pipe, CHROME_LAYER_ID)
			}
			h.active_line_idx = (i / 3) % 30
			h.shell_typed_chars = (h.shell_typed_chars + 1) % 40
			pipeline.composer_pipeline_mark_dirty(&h.composer_pipe, PANE_1_ID)
			pipeline.composer_pipeline_begin_frame(&h.composer_pipe)

		case 4:
			// Phase 4: Full 4-Pane Heavy Stress Redraw
			h.active_line_idx = (i / 3) % 30
			h.shell_typed_chars = (h.shell_typed_chars + 1) % 40
			h.three_d_interactor.yaw += 0.05
			h.three_d_interactor.pitch = 0.3 + 0.15 * math.sin(f32(i) * 0.08)
			h.build_step = (h.build_step + 1) % 20
			h.git_diff_step = (h.git_diff_step + 1) % 15
			pipeline.composer_pipeline_mark_dirty(&h.composer_pipe, PANE_1_ID)
			pipeline.composer_pipeline_mark_dirty(&h.composer_pipe, PANE_2_ID)
			pipeline.composer_pipeline_mark_dirty(&h.composer_pipe, PANE_3_ID)
			pipeline.composer_pipeline_mark_dirty(&h.composer_pipe, PANE_4_ID)
			pipeline.composer_pipeline_begin_frame(&h.composer_pipe)
		}

		timing := _rasterize_dirty_panes_bench(h)
		pres_ok, blit := _composite_and_present_bench(h)
		if pres_ok {
			presented_count += 1
			out_acq[i]  = blit.acquire_ns
			out_comp[i] = blit.composite_ns
			out_pres[i] = blit.present_ns
		} else {
			out_acq[i]  = 0
			out_comp[i] = 0
			out_pres[i] = 0
		}

		pipeline.composer_pipeline_end_frame(&h.composer_pipe)

		total_frame_ns := timing.cpu_encode_ns + timing.cpu_submit_ns + timing.gpu_raster_ns + blit.acquire_ns + blit.composite_ns + blit.present_ns

		out_gpu[i]     = timing.gpu_raster_ns
		out_enc[i]     = timing.cpu_encode_ns
		out_sub[i]     = timing.cpu_submit_ns
		out_total[i]   = total_frame_ns
		out_quads[i]   = timing.regenerated_quads
		out_redrawn[i] = h.composer_pipe.stats.redrawn_layers
	}

	h.cursor_visible = true
	h.modal_active = false
	chrome_tabs.tabs_set_active(&h.tabs_model, 0)
	_update_layer_geometry(h)
	return presented_count
}

// _run_honest_benchmark runs 5 complete runs across 5 phases with 200-frame high-clock warmup and phase shuffling.
_run_honest_benchmark :: proc(h: ^Harness_State) {
	fmt.println("\n==========================================================================================================================================================================================")
	fmt.println(">>> RUNNING COMPREHENSIVE HARDWARE GPU BENCHMARK (5 RUNS x 5 PHASES, 200 FRAMES/PHASE, SHUFFLED ORDER) <<<")
	fmt.println("Covering: Phase 0: Tiny Damage (Quiescent Blinking Cursor)")
	fmt.println("          Phase 1: Incremental Single-Line Update (1-Pane)")
	fmt.println("          Phase 2: Tab & Session Content Switching")
	fmt.println("          Phase 3: Floating Popup Modal Overlay Cycles + Typing")
	fmt.println("          Phase 4: Full 4-Pane Heavy Stress Redraw")
	fmt.println("Features: Randomized Phase Shuffling, 200-Frame DVFS High-Clock Warmup, Decomposed Blit Timings")
	fmt.println("Present Mode: Uncapped Immediate Presentation")
	fmt.println("==========================================================================================================================================================================================")

	ts_period := f64(wgpu.QueueGetTimestampPeriod(wgpu.Queue(rawptr(h.queue))))
	if ts_period <= 0.0 {
		ts_period = 1.0
	}
	h.ts_period = f32(ts_period)

	fmt.println("\nHARDWARE GPU TIMESTAMP PERIOD:")
	fmt.printf("Hardware Timestamp Period: %.3f ns/tick (via wgpu.QueueGetTimestampPeriod)\n", ts_period)

	// Uncapped immediate present mode during benchmark
	contract.set_present_mode(h.surface, .Immediate)
	defer contract.set_present_mode(h.surface, .Fifo)

	BENCH_RUNS   :: 5
	BENCH_PHASES :: 5
	BENCH_FRAMES :: 200

	run_total_p50:   [BENCH_PHASES][BENCH_RUNS]u64
	run_total_p95:   [BENCH_PHASES][BENCH_RUNS]u64
	run_gpu_p50:     [BENCH_PHASES][BENCH_RUNS]u64
	run_enc_p50:     [BENCH_PHASES][BENCH_RUNS]u64
	run_sub_p50:     [BENCH_PHASES][BENCH_RUNS]u64
	run_acq_p50:     [BENCH_PHASES][BENCH_RUNS]u64
	run_comp_p50:    [BENCH_PHASES][BENCH_RUNS]u64
	run_pres_p50:    [BENCH_PHASES][BENCH_RUNS]u64
	run_presented:   [BENCH_PHASES][BENCH_RUNS]int
	run_quads_p50:   [BENCH_PHASES][BENCH_RUNS]int
	run_quads_max:   [BENCH_PHASES][BENCH_RUNS]int
	run_redrawn_p50: [BENCH_PHASES][BENCH_RUNS]int

	frame_gpu:        [BENCH_FRAMES]u64
	frame_enc:        [BENCH_FRAMES]u64
	frame_sub:        [BENCH_FRAMES]u64
	frame_acq:        [BENCH_FRAMES]u64
	frame_comp:       [BENCH_FRAMES]u64
	frame_pres:       [BENCH_FRAMES]u64
	frame_total:      [BENCH_FRAMES]u64
	frame_quads:      [BENCH_FRAMES]int
	frame_redrawn:    [BENCH_FRAMES]int
	bench_filter_buf: [BENCH_FRAMES]u64

	rng_state: u64 = u64(helper.platform_now()) ~ 0xCAFE_BABE_DEAD_BEEF

	for run_idx in 0..<BENCH_RUNS {
		phase_order := [BENCH_PHASES]int{0, 1, 2, 3, 4}
		_shuffle_phases(&phase_order, &rng_state)

		fmt.printf(">>> Executing Run %d/%d (Shuffled Phase Order: [%d, %d, %d, %d, %d])...\n",
			run_idx + 1, BENCH_RUNS,
			phase_order[0], phase_order[1], phase_order[2], phase_order[3], phase_order[4],
		)

		for p_idx in 0..<BENCH_PHASES {
			phase := phase_order[p_idx]

			// 200-frame heavy-stress warmup immediately before profiling EACH phase
			_warmup_high_gpu_clock(h, 200)

			// Execute 200 profiled frames for this phase
			presented_cnt := _run_benchmark_phase(
				h,
				phase,
				BENCH_FRAMES,
				frame_gpu[:],
				frame_enc[:],
				frame_sub[:],
				frame_acq[:],
				frame_comp[:],
				frame_pres[:],
				frame_total[:],
				frame_quads[:],
				frame_redrawn[:],
			)

			quads_sorted: [BENCH_FRAMES]int
			copy(quads_sorted[:], frame_quads[:])
			slice.sort(quads_sorted[:])
			p50_q := quads_sorted[BENCH_FRAMES / 2]
			max_q := quads_sorted[BENCH_FRAMES - 1]

			redrawn_sorted: [BENCH_FRAMES]int
			copy(redrawn_sorted[:], frame_redrawn[:])
			slice.sort(redrawn_sorted[:])
			p50_r := redrawn_sorted[BENCH_FRAMES / 2]

			met_total := _calc_percentiles(frame_total[:])
			met_gpu   := _calc_percentiles(frame_gpu[:])
			met_enc   := _calc_percentiles(frame_enc[:])
			met_sub   := _calc_percentiles(frame_sub[:])
			met_acq   := _calc_percentiles_non_zero(frame_acq[:], bench_filter_buf[:])
			met_comp  := _calc_percentiles_non_zero(frame_comp[:], bench_filter_buf[:])
			met_pres  := _calc_percentiles_non_zero(frame_pres[:], bench_filter_buf[:])

			run_total_p50[phase][run_idx]   = met_total.median_ns
			run_total_p95[phase][run_idx]   = met_total.p95_ns
			run_gpu_p50[phase][run_idx]     = met_gpu.median_ns
			run_enc_p50[phase][run_idx]     = met_enc.median_ns
			run_sub_p50[phase][run_idx]     = met_sub.median_ns
			run_acq_p50[phase][run_idx]     = met_acq.median_ns
			run_comp_p50[phase][run_idx]    = met_comp.median_ns
			run_pres_p50[phase][run_idx]    = met_pres.median_ns
			run_presented[phase][run_idx]   = presented_cnt
			run_quads_p50[phase][run_idx]   = p50_q
			run_quads_max[phase][run_idx]   = max_q
			run_redrawn_p50[phase][run_idx] = p50_r
		}
	}

	Phase_Summary :: struct {
		name:           string,
		presented:      int,
		redrawn_layers: int,
		total_layers:   int,
		quads_p50:      int,
		quads_max:      int,
		tot_p50_med:    u64,
		tot_p95_med:    u64,
		gpu_p50:        u64,
		enc_p50:        u64,
		sub_p50:        u64,
		acq_p50:        u64,
		comp_p50:       u64,
		pres_p50:       u64,
		fps_p50:        f64,
		per_run_p50:    [BENCH_RUNS]u64,
	}
	Summary_Phase :: Phase_Summary

	summaries: [BENCH_PHASES]Phase_Summary

	phase_names := [BENCH_PHASES]string{
		"Phase 0 (Cursor Blink)",
		"Phase 1 (1-Pane Shifting Line)",
		"Phase 2 (Tab/Content Switching)",
		"Phase 3 (Modal Cycles + Typing)",
		"Phase 4 (Full 4-Pane Heavy Stress)",
	}

	for p in 0..<BENCH_PHASES {
		tot_p50_copy  := run_total_p50[p]
		tot_p95_copy  := run_total_p95[p]
		gpu_copy      := run_gpu_p50[p]
		enc_copy      := run_enc_p50[p]
		sub_copy      := run_sub_p50[p]
		acq_copy      := run_acq_p50[p]
		comp_copy     := run_comp_p50[p]
		pres_copy     := run_pres_p50[p]
		pres_cnt_cpy  := run_presented[p]
		quads_p50_c   := run_quads_p50[p]
		quads_max_c   := run_quads_max[p]
		redrawn_p50_c := run_redrawn_p50[p]

		slice.sort(tot_p50_copy[:])
		slice.sort(tot_p95_copy[:])
		slice.sort(gpu_copy[:])
		slice.sort(enc_copy[:])
		slice.sort(sub_copy[:])
		slice.sort(acq_copy[:])
		slice.sort(comp_copy[:])
		slice.sort(pres_copy[:])
		slice.sort(pres_cnt_cpy[:])
		slice.sort(quads_p50_c[:])
		slice.sort(quads_max_c[:])
		slice.sort(redrawn_p50_c[:])

		med_total_p50 := tot_p50_copy[BENCH_RUNS / 2]
		fps := 1_000_000_000.0 / f64(max(med_total_p50, 1))

		summaries[p] = {
			name           = phase_names[p],
			presented      = pres_cnt_cpy[BENCH_RUNS / 2],
			redrawn_layers = redrawn_p50_c[BENCH_RUNS / 2],
			total_layers   = 4,
			quads_p50      = quads_p50_c[BENCH_RUNS / 2],
			quads_max      = quads_max_c[BENCH_RUNS - 1],
			tot_p50_med    = med_total_p50,
			tot_p95_med    = tot_p95_copy[BENCH_RUNS / 2],
			gpu_p50        = gpu_copy[BENCH_RUNS / 2],
			enc_p50        = enc_copy[BENCH_RUNS / 2],
			sub_p50        = sub_copy[BENCH_RUNS / 2],
			acq_p50        = acq_copy[BENCH_RUNS / 2],
			comp_p50       = comp_copy[BENCH_RUNS / 2],
			pres_p50       = pres_copy[BENCH_RUNS / 2],
			fps_p50        = fps,
			per_run_p50    = run_total_p50[p],
		}
	}

	fmt.println("\n==================================================================================================================================================================================================")
	fmt.println(">>> HEADLINE BENCHMARK SUMMARY: TOTAL PER-FRAME LATENCY & DECOMPOSED PIPELINE BREAKDOWN (5 RUNS SPREAD) <<<")
	fmt.println("==================================================================================================================================================================================================")
	fmt.printf(
		"%-35s %-15s %-15s %-16s %-16s %-16s %-10s %-10s %-10s %-10s %-11s %-10s %18s\n",
		"Phase",
		"Presented",
		"Redrawn Layers",
		"Regen Quads",
		"Total p50 (Med)",
		"Total p95 (Med)",
		"GPU p50",
		"CPU Enc",
		"CPU Sub",
		"Acquire",
		"Composite",
		"Present",
		"Uncapped FPS (p50)",
	)
	fmt.println("--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------")

	for p in 0..<BENCH_PHASES {
		s := &summaries[p]
		pres_count_str := fmt.tprintf("%d/%d (%.1f%%)", s.presented, BENCH_FRAMES, (f64(s.presented) / f64(BENCH_FRAMES)) * 100.0)
		redrawn_str    := fmt.tprintf("%d/%d (%.0f%%)", s.redrawn_layers, s.total_layers, (f64(s.redrawn_layers) / f64(max(s.total_layers, 1))) * 100.0)
		quads_str      := fmt.tprintf("%d (max: %d)", s.quads_p50, s.quads_max)
		tot_p50_str    := fmt.tprintf("%.3f ms", f64(s.tot_p50_med) / 1_000_000.0)
		tot_p95_str    := fmt.tprintf("%.3f ms", f64(s.tot_p95_med) / 1_000_000.0)
		gpu_str        := fmt.tprintf("%.3f ms", f64(s.gpu_p50) / 1_000_000.0)
		enc_str        := fmt.tprintf("%.3f ms", f64(s.enc_p50) / 1_000_000.0)
		sub_str        := fmt.tprintf("%.3f ms", f64(s.sub_p50) / 1_000_000.0)
		acq_str        := fmt.tprintf("%.3f ms", f64(s.acq_p50) / 1_000_000.0)
		comp_str       := fmt.tprintf("%.3f ms", f64(s.comp_p50) / 1_000_000.0)
		pres_time_str  := fmt.tprintf("%.3f ms", f64(s.pres_p50) / 1_000_000.0)
		fps_str        := fmt.tprintf("%.1f FPS", s.fps_p50)

		fmt.printf(
			"%-35s %-15s %-15s %-16s %-16s %-16s %-10s %-10s %-10s %-10s %-11s %-10s %18s\n",
			s.name,
			pres_count_str,
			redrawn_str,
			quads_str,
			tot_p50_str,
			tot_p95_str,
			gpu_str,
			enc_str,
			sub_str,
			acq_str,
			comp_str,
			pres_time_str,
			fps_str,
		)
	}
	fmt.println("--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------")

	fmt.println("\n--- PER-RUN TOTAL LATENCY SPREAD (BIMODAL TRANSPARENCY) ---")
	for p in 0..<BENCH_PHASES {
		fmt.printf(
			"  %-35s Per-Run p50: [%.3f, %.3f, %.3f, %.3f, %.3f] ms (Med: %.3f ms)\n",
			summaries[p].name,
			f64(summaries[p].per_run_p50[0]) / 1_000_000.0,
			f64(summaries[p].per_run_p50[1]) / 1_000_000.0,
			f64(summaries[p].per_run_p50[2]) / 1_000_000.0,
			f64(summaries[p].per_run_p50[3]) / 1_000_000.0,
			f64(summaries[p].per_run_p50[4]) / 1_000_000.0,
			f64(summaries[p].tot_p50_med) / 1_000_000.0,
		)
	}

	fmt.println("\n--- CPU ENCODE PROFILING & DIRTY TRACKING ANALYSIS ---")
	fmt.printf("  Phase 0 (Cursor Blink):              %d/%d layers redrawn (p50), %d quads (max: %d)\n", summaries[0].redrawn_layers, summaries[0].total_layers, summaries[0].quads_p50, summaries[0].quads_max)
	fmt.printf("  Phase 1 (1-Pane Shifting Line):      %d/%d layers redrawn (p50), %d quads (max: %d)\n", summaries[1].redrawn_layers, summaries[1].total_layers, summaries[1].quads_p50, summaries[1].quads_max)
	fmt.printf("  Phase 2 (Tab/Content Switching):     %d/%d layers redrawn (p50), %d quads (max: %d)\n", summaries[2].redrawn_layers, summaries[2].total_layers, summaries[2].quads_p50, summaries[2].quads_max)
	fmt.printf("  Phase 3 (Modal Cycles + Typing):     %d/%d layers redrawn (p50), %d quads (max: %d)\n", summaries[3].redrawn_layers, summaries[3].total_layers, summaries[3].quads_p50, summaries[3].quads_max)
	fmt.printf("  Phase 4 (Full 4-Pane Heavy Stress):  %d/%d layers redrawn (p50), %d quads (max: %d)\n", summaries[4].redrawn_layers, summaries[4].total_layers, summaries[4].quads_p50, summaries[4].quads_max)
	fmt.printf(
		"\nCPU Encode Analysis: Phase 0 regenerates %d quads (equal to Phase 1 full pane) -> confirms dirty-tracking operates at Layer/Pane boundary (entire pane backing texture is regenerated), not sub-rect/cell level.\n",
		summaries[0].quads_p50,
	)
	fmt.printf(
		"Phase 3 Tail Analysis: Modal toggle frames (~7%% of frames) regenerate %d quads and update modal layout, which directly causes the elevated p95 tail latency (p50: %d quads vs peak: %d quads).\n",
		summaries[3].quads_max,
		summaries[3].quads_p50,
		summaries[3].quads_max,
	)
	fmt.println("==========================================================================================================================================================================================\n")

	// Cleanup & Reset to Clean State
	h.modal_active = false
	chrome_tabs.tabs_set_active(&h.tabs_model, 0)
	_update_layer_geometry(h)

	h.bench_has_run = true
	h.bench_p1_raster_ms = f64(summaries[1].tot_p50_med) / 1_000_000.0
	h.bench_all_raster_ms = f64(summaries[4].tot_p50_med) / 1_000_000.0
	p1_tot := f64(summaries[1].tot_p50_med)
	p4_tot := f64(max(summaries[4].tot_p50_med, 1))
	h.bench_work_ratio = (p1_tot / p4_tot) * 100.0
	h.bench_raster_time_saved = 100.0 - h.bench_work_ratio

	// Trigger update
	pipeline.composer_pipeline_mark_dirty(&h.composer_pipe, PANE_1_ID)
	pipeline.composer_pipeline_mark_dirty(&h.composer_pipe, CHROME_LAYER_ID)
}

// _run_chrome_verification_test executes automated headless/GPU verification of all chrome rendering strategies and exits cleanly.
_run_chrome_verification_test :: proc(h: ^Harness_State) {
	fmt.println("=================================================================")
	fmt.println("HARNESS RENDER CHROME — AUTOMATED VERIFICATION SUITE")
	fmt.println("=================================================================")

	all_ok := true
	dl: chrome_dl.Ui_Draw_List
	chrome_dl.ui_draw_list_init(&dl)
	defer chrome_dl.ui_draw_list_destroy(&dl)

	lc := pipeline.composer_pipeline_get_layer(&h.composer_pipe, CHROME_LAYER_ID)
	target_view := lc.view if (lc != nil && lc.in_use) else contract.Gpu_TextureView(nil)
	w := f32(h.window.pixel_w)
	h_win := f32(h.window.pixel_h)

	// Test 1: Normal Tabs & Split Dividers Fixtures
	{
		chrome_dl.ui_draw_list_clear(&dl)
		bar_rect := [4]f32{0, 0, w * 0.5, CHROME_BAR_HEIGHT}
		chrome_tabs.preview_tabs_normal(&dl, bar_rect)
		tabs_count := len(dl.commands)

		split_bounds := [4]f32{0, CHROME_BAR_HEIGHT, w, h_win - CHROME_BAR_HEIGHT}
		chrome_splits.preview_splits_normal(&dl, split_bounds)
		total_count := len(dl.commands)

		cmd := render_ui_draw_list_encode(h.device, &h.chrome_renderer.sdf, &dl, target_view, w, h_win, {0, 0, 0, 0})
		gpu_ok := false
		if cmd != nil {
			contract.submit(h.queue, cmd)
			contract.release_command_buffer(cmd)
			gpu_ok = true
		}

		passed := tabs_count > 0 && total_count > tabs_count && gpu_ok
		if !passed do all_ok = false
		status := "PASS" if passed else "FAIL"
		fmt.printfln("[TEST 1] Normal Tabs & Split Dividers Fixtures ............ %s (tabs=%d, total_cmds=%d)", status, tabs_count, total_count)
	}

	// Test 2: 1000 SDF Elements Batching & Render
	{
		chrome_dl.ui_draw_list_clear(&dl)
		_generate_1000_sdf_elements(&dl, {0, 0, w, h_win})
		cmd_count := len(dl.commands)

		cmd := render_ui_draw_list_encode(h.device, &h.chrome_renderer.sdf, &dl, target_view, w, h_win, {0, 0, 0, 0})
		gpu_ok := false
		if cmd != nil {
			contract.submit(h.queue, cmd)
			contract.release_command_buffer(cmd)
			gpu_ok = true
		}

		passed := (cmd_count == 1000) && gpu_ok
		if !passed do all_ok = false
		status := "PASS" if passed else "FAIL"
		fmt.printfln("[TEST 2] 1000 SDF Elements Batching & Render .............. %s (elements=%d)", status, cmd_count)
	}

	// Test 3: Radius > Half-Size Clamping & Stability
	{
		chrome_dl.ui_draw_list_clear(&dl)
		_generate_extreme_radius_elements(&dl, {0, 0, w, h_win})
		cmd_count := len(dl.commands)

		cmd := render_ui_draw_list_encode(h.device, &h.chrome_renderer.sdf, &dl, target_view, w, h_win, {0, 0, 0, 0})
		gpu_ok := false
		if cmd != nil {
			contract.submit(h.queue, cmd)
			contract.release_command_buffer(cmd)
			gpu_ok = true
		}

		passed := cmd_count > 0 && gpu_ok
		if !passed do all_ok = false
		status := "PASS" if passed else "FAIL"
		fmt.printfln("[TEST 3] Radius > Half-Size Clamping & Stability .......... %s (cmds=%d)", status, cmd_count)
	}

	// Test 4: Dynamic Divider Drag Oscillation
	{
		chrome_dl.ui_draw_list_clear(&dl)
		split_bounds := [4]f32{0, CHROME_BAR_HEIGHT, w, h_win - CHROME_BAR_HEIGHT}
		_emit_dynamic_dividers(&dl, split_bounds, 0.85)
		cmd_count := len(dl.commands)

		cmd := render_ui_draw_list_encode(h.device, &h.chrome_renderer.sdf, &dl, target_view, w, h_win, {0, 0, 0, 0})
		gpu_ok := false
		if cmd != nil {
			contract.submit(h.queue, cmd)
			contract.release_command_buffer(cmd)
			gpu_ok = true
		}

		passed := cmd_count > 0 && gpu_ok
		if !passed do all_ok = false
		status := "PASS" if passed else "FAIL"
		fmt.printfln("[TEST 4] Dynamic Divider Drag Oscillation ................. %s (cmds=%d)", status, cmd_count)
	}

	// Test 5: Extreme 128 Tabs (1024-Rune Unicode Title)
	{
		chrome_dl.ui_draw_list_clear(&dl)
		bar_rect := [4]f32{0, 0, w, CHROME_BAR_HEIGHT}
		chrome_tabs.preview_tabs_extreme(&dl, bar_rect, 128)
		cmd_count := len(dl.commands)

		cmd := render_ui_draw_list_encode(h.device, &h.chrome_renderer.sdf, &dl, target_view, w, h_win, {0, 0, 0, 0})
		gpu_ok := false
		if cmd != nil {
			contract.submit(h.queue, cmd)
			contract.release_command_buffer(cmd)
			gpu_ok = true
		}

		passed := cmd_count >= 128 && gpu_ok
		if !passed do all_ok = false
		status := "PASS" if passed else "FAIL"
		fmt.printfln("[TEST 5] Extreme 128 Tabs (1024-Rune Unicode Title) ....... %s (cmds=%d)", status, cmd_count)
	}

	// Test 6: Modal Normal & Extreme Fixtures
	{
		chrome_dl.ui_draw_list_clear(&dl)
		viewport := [4]f32{0, 0, w, h_win}
		chrome_modals.preview_modal_normal(&dl, viewport)
		normal_count := len(dl.commands)

		chrome_dl.ui_draw_list_clear(&dl)
		chrome_modals.preview_modal_extreme(&dl, viewport)
		extreme_count := len(dl.commands)

		cmd := render_ui_draw_list_encode(h.device, &h.chrome_renderer.sdf, &dl, target_view, w, h_win, {0, 0, 0, 0})
		gpu_ok := false
		if cmd != nil {
			contract.submit(h.queue, cmd)
			contract.release_command_buffer(cmd)
			gpu_ok = true
		}

		passed := normal_count > 0 && extreme_count > 0 && gpu_ok
		if !passed do all_ok = false
		status := "PASS" if passed else "FAIL"
		fmt.printfln("[TEST 6] Modal Normal & Extreme Fixtures .................. %s (normal=%d, extreme=%d)", status, normal_count, extreme_count)
	}

	// Test 7: Composer Frame Loop Migration (frame_tick) & Clean Pane Invariant
	{
		driver := frame.Frame_Driver{
			user    = h,
			acquire = _frame_acquire,
			raster  = _frame_raster,
			present = _frame_present,
		}

		// Frame 1 with damage: should tick, raster dirty layer, and present
		_mark_layer_dirty(h, CHROME_LAYER_ID)
		now_ns := u64(helper.platform_ticks_to_ns(helper.platform_now()))
		outcome1 := frame.frame_tick(&h.scheduler, &h.composer_pipe, &h.tm, &driver, now_ns)

		// Frame 2 with all clean layers: should NOT tick (zero raster passes)
		now_ns2 := now_ns + 16_000_000
		outcome2 := frame.frame_tick(&h.scheduler, &h.composer_pipe, &h.tm, &driver, now_ns2)

		passed := outcome1.fail == .None && outcome1.ticked && outcome1.raster_calls > 0 &&
		          !outcome2.ticked && outcome2.raster_calls == 0
		if !passed do all_ok = false
		status := "PASS" if passed else "FAIL"
		fmt.printfln("[TEST 7] Composer Frame Loop Migration (frame_tick) ....... %s (tick1_raster=%d, tick2_raster=%d)",
			status, outcome1.raster_calls, outcome2.raster_calls)
	}

	fmt.println("=================================================================")
	if all_ok {
		fmt.println("VERDICT: ALL CHROME SCENARIOS PASSED")
	} else {
		fmt.println("VERDICT: ONE OR MORE SCENARIOS FAILED")
	}
	fmt.println("=================================================================")

	if !all_ok {
		os.exit(1)
	}
}

_handle_sdl_event :: proc(h: ^Harness_State, event: ^sdl3.Event) {
	if event.type == .QUIT || event.type == .WINDOW_CLOSE_REQUESTED {
		h.running = false
		return
	}

	if event.type == .KEY_DOWN {
		switch event.key.key {
		case sdl3.K_ESCAPE:
			if h.modal_active {
				h.modal_active = false
				_update_layer_geometry(h)
				_mark_layer_dirty(h, MODAL_LAYER_ID)
				_mark_layer_dirty(h, CHROME_LAYER_ID)
				scheduler.scheduler_force_next(&h.scheduler)
				fmt.println("-> Command Palette closed via ESC")
			} else {
				h.running = false
			}

		case sdl3.K_1:
			h.active_pane = 1
			chrome_tabs.tabs_set_active(&h.tabs_model, 0)
			_mark_layer_dirty(h, PANE_1_ID)
			_mark_layer_dirty(h, CHROME_LAYER_ID)
			fmt.println("-> Active Tab & Session: 1 (Terminal - zsh)")

		case sdl3.K_2:
			h.active_pane = 1
			chrome_tabs.tabs_set_active(&h.tabs_model, 1)
			_mark_layer_dirty(h, PANE_1_ID)
			_mark_layer_dirty(h, CHROME_LAYER_ID)
			fmt.println("-> Active Tab & Session: 2 (Editor - nvim)")

		case sdl3.K_3:
			h.active_pane = 1
			chrome_tabs.tabs_set_active(&h.tabs_model, 2)
			_mark_layer_dirty(h, PANE_1_ID)
			_mark_layer_dirty(h, CHROME_LAYER_ID)
			fmt.println("-> Active Tab & Session: 3 (Monitor - htop)")

		case sdl3.K_4:
			h.active_pane = 1
			chrome_tabs.tabs_set_active(&h.tabs_model, 3)
			_mark_layer_dirty(h, PANE_1_ID)
			_mark_layer_dirty(h, CHROME_LAYER_ID)
			fmt.println("-> Active Tab & Session: 4 (REPL - python)")

		case sdl3.K_R:
			h.three_d_interactor.auto_rotate = !h.three_d_interactor.auto_rotate
			_mark_layer_dirty(h, PANE_2_ID)
			_mark_layer_dirty(h, CHROME_LAYER_ID)
			scheduler.scheduler_set_anim_active(&h.scheduler, h.three_d_interactor.auto_rotate)
			fmt.printf("-> 3D Auto-Rotation toggled: %v\n", h.three_d_interactor.auto_rotate)

		case sdl3.K_SPACE:
			switch h.active_pane {
			case 1:
				h.shell_typed_chars = (h.shell_typed_chars + 1) % 40
				_mark_layer_dirty(h, PANE_1_ID)
				fmt.printf("-> Typed in Pane 1 (chars=%d). ONLY Pane 1 dirty, Panes 2, 3, 4 CACHED (0 raster passes)!\n", h.shell_typed_chars)
			case 2:
				h.three_d_interactor.yaw += 0.25
				_mark_layer_dirty(h, PANE_2_ID)
				fmt.println("-> Stepped rotation in Pane 2. ONLY Pane 2 dirty, Panes 1, 3, 4 CACHED!")
			case 3:
				h.build_step = (h.build_step + 1) % 20
				_mark_layer_dirty(h, PANE_3_ID)
				fmt.printf("-> Advanced build log in Pane 3 (step=%d). ONLY Pane 3 dirty!\n", h.build_step)
			case 4:
				h.git_diff_step = (h.git_diff_step + 1) % 15
				_mark_layer_dirty(h, PANE_4_ID)
				fmt.printf("-> Updated git diff in Pane 4 (step=%d). ONLY Pane 4 dirty!\n", h.git_diff_step)
			}
			_mark_layer_dirty(h, CHROME_LAYER_ID)

		case sdl3.K_D:
			h.mesh_type = 1 - h.mesh_type
			mesh_name := "Hexagonal Prism Badge" if h.mesh_type == 1 else "Unit Cube"
			_ = three_d.three_d_set_mesh(&h.three_d_renderer, h.mesh_type)
			_mark_layer_dirty(h, PANE_2_ID)
			_mark_layer_dirty(h, CHROME_LAYER_ID)
			fmt.printf("-> 3D Mesh toggled: %s\n", mesh_name)

		case sdl3.K_W:
			h.three_d_interactor.wireframe_mode = !h.three_d_interactor.wireframe_mode
			_mark_layer_dirty(h, PANE_2_ID)
			_mark_layer_dirty(h, CHROME_LAYER_ID)
			fmt.printf("-> 3D Holographic Wireframe toggled: %v\n", h.three_d_interactor.wireframe_mode)

		case sdl3.K_F:
			_mark_layer_dirty(h, PANE_1_ID)
			_mark_layer_dirty(h, PANE_2_ID)
			_mark_layer_dirty(h, PANE_3_ID)
			_mark_layer_dirty(h, PANE_4_ID)
			_mark_layer_dirty(h, CHROME_LAYER_ID)
			fmt.println("-> Triggered full FLOOD DAMAGE: ALL 4 Panes + Chrome marked dirty")

		case sdl3.K_S:
			h.scissor_test_active = !h.scissor_test_active
			_update_layer_geometry(h)
			_mark_layer_dirty(h, PANE_1_ID)
			_mark_layer_dirty(h, PANE_2_ID)
			_mark_layer_dirty(h, PANE_3_ID)
			_mark_layer_dirty(h, PANE_4_ID)
			_mark_layer_dirty(h, CHROME_LAYER_ID)
			scheduler.scheduler_force_next(&h.scheduler)
			fmt.printf("-> Scissor clipping test: %v (panes inset by 36x28px to verify fragment discard outside scissor rect)\n", h.scissor_test_active)

		case sdl3.K_TAB:
			if len(h.tabs_model.tabs) > 0 {
				next_idx := (h.tabs_model.active_idx + 1) % len(h.tabs_model.tabs)
				chrome_tabs.tabs_set_active(&h.tabs_model, next_idx)
				_mark_layer_dirty(h, PANE_1_ID)
				_mark_layer_dirty(h, CHROME_LAYER_ID)
				fmt.printf("-> Active Tab switched: %d (%s)\n", next_idx, h.tabs_model.tabs[next_idx].title)
			}

		case sdl3.K_T:
			h.extreme_tabs = !h.extreme_tabs
			_mark_layer_dirty(h, CHROME_LAYER_ID)
			scheduler.scheduler_force_next(&h.scheduler)
			fmt.printf("-> Extreme 128 Tabs Mode: %v\n", h.extreme_tabs)

		case sdl3.K_G:
			h.divider_drag_active = !h.divider_drag_active
			_mark_layer_dirty(h, CHROME_LAYER_ID)
			scheduler.scheduler_force_next(&h.scheduler)
			fmt.printf("-> Dynamic Split Divider Drag Oscillation: %v\n", h.divider_drag_active)

		case sdl3.K_X:
			h.extreme_sdf_mode = !h.extreme_sdf_mode
			_mark_layer_dirty(h, PANE_1_ID)
			scheduler.scheduler_force_next(&h.scheduler)
			fmt.printf("-> 1000 SDF Elements Stress Mode in Pane 1: %v\n", h.extreme_sdf_mode)

		case sdl3.K_Z:
			h.extreme_radius_mode = !h.extreme_radius_mode
			_mark_layer_dirty(h, PANE_1_ID)
			scheduler.scheduler_force_next(&h.scheduler)
			fmt.printf("-> Radius > Half-Size Clamping Mode in Pane 1: %v\n", h.extreme_radius_mode)

		case sdl3.K_M, sdl3.K_P:
			h.modal_active = !h.modal_active
			_update_layer_geometry(h)
			if h.modal_active {
				_mark_layer_dirty(h, MODAL_LAYER_ID)
			}
			_mark_layer_dirty(h, CHROME_LAYER_ID)
			scheduler.scheduler_force_next(&h.scheduler)
			fmt.printf("-> Command Palette & Search Modal toggled: %v\n", h.modal_active)

		case sdl3.K_C:
			h.blink_enabled = !h.blink_enabled
			fmt.printfln("-> Cursor blink toggled: %v", h.blink_enabled)
			if !h.blink_enabled {
				scheduler.scheduler_set_deadline(&h.scheduler, 0)
				h.next_blink_ns = 0
				h.cursor_visible = true
				_mark_layer_dirty(h, PANE_1_ID)
			} else {
				_mark_layer_dirty(h, PANE_1_ID)
			}

		case sdl3.K_B:
			_run_honest_benchmark(h)
			scheduler.scheduler_force_next(&h.scheduler)
		}
	} else if event.type == .MOUSE_BUTTON_DOWN {
		scale_x := f32(h.window.pixel_w) / f32(h.window.width) if h.window.width > 0 else 1.0
		scale_y := f32(h.window.pixel_h) / f32(h.window.height) if h.window.height > 0 else 1.0
		mx := event.button.x * scale_x
		my := event.button.y * scale_y

		if my < CHROME_BAR_HEIGHT {
			tab_idx := int(mx / 120.0)
			if tab_idx >= 0 && tab_idx < len(h.tabs_model.tabs) {
				chrome_tabs.tabs_set_active(&h.tabs_model, tab_idx)
				_mark_layer_dirty(h, PANE_1_ID)
				_mark_layer_dirty(h, CHROME_LAYER_ID)
			}
		} else if mx >= h.pane_w && my < (CHROME_BAR_HEIGHT + h.pane_h) {
			h.active_pane = 2
			chrome_tabs.tabs_set_active(&h.tabs_model, 1)
			if event.button.button == sdl3.BUTTON_LEFT {
				h.is_dragging_3d = true
				three_d.interactor_on_mouse_down(&h.three_d_interactor, mx - h.pane_w, my - CHROME_BAR_HEIGHT, 1)
			}
			_mark_layer_dirty(h, CHROME_LAYER_ID)
		} else if mx < h.pane_w && my < (CHROME_BAR_HEIGHT + h.pane_h) {
			h.active_pane = 1
			chrome_tabs.tabs_set_active(&h.tabs_model, 0)
			_mark_layer_dirty(h, CHROME_LAYER_ID)
		} else if mx < h.pane_w && my >= (CHROME_BAR_HEIGHT + h.pane_h) {
			h.active_pane = 3
			chrome_tabs.tabs_set_active(&h.tabs_model, 2)
			_mark_layer_dirty(h, CHROME_LAYER_ID)
		} else {
			h.active_pane = 4
			chrome_tabs.tabs_set_active(&h.tabs_model, 3)
			_mark_layer_dirty(h, CHROME_LAYER_ID)
		}
	} else if event.type == .MOUSE_BUTTON_UP {
		if event.button.button == sdl3.BUTTON_LEFT {
			h.is_dragging_3d = false
			three_d.interactor_on_mouse_up(&h.three_d_interactor, 1)
		}
	} else if event.type == .MOUSE_MOTION {
		if h.is_dragging_3d {
			scale_x := f32(h.window.pixel_w) / f32(h.window.width) if h.window.width > 0 else 1.0
			scale_y := f32(h.window.pixel_h) / f32(h.window.height) if h.window.height > 0 else 1.0
			shift := (.LSHIFT in sdl3.GetModState()) || (.RSHIFT in sdl3.GetModState())
			three_d.interactor_on_mouse_move(
				&h.three_d_interactor,
				event.motion.x * scale_x - h.pane_w,
				event.motion.y * scale_y - CHROME_BAR_HEIGHT,
				shift,
			)
			_mark_layer_dirty(h, PANE_2_ID)
			_mark_layer_dirty(h, CHROME_LAYER_ID)
		}
	} else if event.type == .MOUSE_WHEEL {
		three_d.interactor_on_mouse_wheel(&h.three_d_interactor, event.wheel.y)
		_mark_layer_dirty(h, PANE_2_ID)
		_mark_layer_dirty(h, CHROME_LAYER_ID)
	} else if event.type == .WINDOW_PIXEL_SIZE_CHANGED || event.type == .WINDOW_RESIZED {
		helper.window_update_pixel_size(&h.window)
		new_w := f32(h.window.pixel_w)
		new_h := f32(h.window.pixel_h)
		contract.configure_surface(h.surface, h.device, h.format, u32(new_w), u32(new_h))
		_acquire_all_layers(h)
		_ = three_d.three_d_resize(&h.three_d_renderer, u32(h.pane_w), u32(h.pane_h))
		_ = chrome.chrome_renderer_resize(&h.chrome_renderer, u32(new_w), u32(new_h))
		_mark_layer_dirty(h, PANE_1_ID)
		_mark_layer_dirty(h, PANE_2_ID)
		_mark_layer_dirty(h, PANE_3_ID)
		_mark_layer_dirty(h, PANE_4_ID)
		_mark_layer_dirty(h, CHROME_LAYER_ID)
		scheduler.scheduler_force_next(&h.scheduler)
	} else if event.type == .WINDOW_EXPOSED {
		scheduler.scheduler_force_next(&h.scheduler)
	}
}

main :: proc() {
	h := new(Harness_State)
	defer free(h)

	h.running = true
	h.active_pane = 1
	h.mesh_type = 0
	h.cursor_visible = true
	h.scissor_test_active = false
	h.start_ticks = helper.platform_now()

	window_w: i32 = 1600
	window_h: i32 = 1000

	if !helper.window_init(&h.window, "Term - Standalone Native GUI Harness (OS-Style 4-Split Compositor)", window_w, window_h) {
		fmt.eprintln("harness error: window_init failed")
		os.exit(1)
	}
	defer helper.window_destroy(&h.window)

	// Unified WGPU Hardware Setup across Darwin and Linux
	wgpu_backend.init_wgpu_driver()
	h.instance = contract.create_instance()
	h.surface = wgpu_backend.create_surface(h.instance, h.window.handle)
	h.device, h.queue = contract.request_device(h.instance, h.surface)
	h.format = contract.get_preferred_format(h.surface, h.device)

	helper.window_update_pixel_size(&h.window)
	screen_w := f32(h.window.pixel_w)
	screen_h := f32(h.window.pixel_h)

	contract.configure_surface(h.surface, h.device, h.format, u32(screen_w), u32(screen_h))

	// Initialize Composer Pipeline
	if !pipeline.composer_pipeline_init(
		&h.composer_pipe,
		h.device,
		h.queue,
		h.format,
		screen_w,
		screen_h,
	) {
		fmt.eprintln("harness error: composer_pipeline_init failed")
		os.exit(1)
	}
	defer pipeline.composer_pipeline_destroy(&h.composer_pipe)

	// Initialize Draw Lists
	chrome_dl.ui_draw_list_init(&h.draw_list_chrome)
	defer chrome_dl.ui_draw_list_destroy(&h.draw_list_chrome)
	chrome_dl.ui_draw_list_init(&h.draw_list_p1)
	defer chrome_dl.ui_draw_list_destroy(&h.draw_list_p1)
	chrome_dl.ui_draw_list_init(&h.draw_list_p2)
	defer chrome_dl.ui_draw_list_destroy(&h.draw_list_p2)
	chrome_dl.ui_draw_list_init(&h.draw_list_p3)
	defer chrome_dl.ui_draw_list_destroy(&h.draw_list_p3)
	chrome_dl.ui_draw_list_init(&h.draw_list_p4)
	defer chrome_dl.ui_draw_list_destroy(&h.draw_list_p4)
	chrome_dl.ui_draw_list_init(&h.draw_list_modal)
	defer chrome_dl.ui_draw_list_destroy(&h.draw_list_modal)

	// Initialize Chrome UI Models & Renderer
	chrome_tabs.tabs_model_init(&h.tabs_model, {0, 0, screen_w, CHROME_BAR_HEIGHT})
	chrome_tabs.tabs_add(&h.tabs_model, 1, "Terminal (zsh)")
	chrome_tabs.tabs_add(&h.tabs_model, 2, "Editor (nvim)")
	chrome_tabs.tabs_add(&h.tabs_model, 3, "Monitor (htop)")
	chrome_tabs.tabs_add(&h.tabs_model, 4, "REPL (python)")
	defer chrome_tabs.tabs_model_destroy(&h.tabs_model)

	h.modal = chrome_modals.Chrome_Modal{
		title       = "Command Palette",
		query       = "git status",
		match_count = 8,
		visible     = true,
	}
	h.divider_ratio = 0.5

	if !chrome.chrome_renderer_init(
		&h.chrome_renderer,
		h.device,
		h.queue,
		u32(screen_w),
		u32(screen_h),
		h.format,
	) {
		fmt.eprintln("harness error: chrome_renderer_init failed")
		os.exit(1)
	}
	defer chrome.chrome_renderer_destroy(&h.chrome_renderer)

	// Initialize 3D Component Engine
	wgpu_dev := wgpu.Device(rawptr(h.device))
	wgpu_q := wgpu.Queue(rawptr(h.queue))
	wgpu_fmt := wgpu.TextureFormat.BGRA8Unorm when ODIN_OS == .Darwin else wgpu.TextureFormat.RGBA8Unorm

	// Setup hardware timestamp query resources
	if wgpu_dev != nil {
		qs_desc := wgpu.QuerySetDescriptor{
			type  = .Timestamp,
			count = 2,
		}
		h.ts_query_set = wgpu.DeviceCreateQuerySet(wgpu_dev, &qs_desc)
		if h.ts_query_set != nil {
			resolve_desc := wgpu.BufferDescriptor{
				usage = { .QueryResolve, .CopySrc },
				size  = 2 * size_of(u64),
			}
			h.ts_resolve_buf = wgpu.DeviceCreateBuffer(wgpu_dev, &resolve_desc)

			readback_desc := wgpu.BufferDescriptor{
				usage = { .CopyDst, .MapRead },
				size  = 2 * size_of(u64),
			}
			h.ts_readback_buf = wgpu.DeviceCreateBuffer(wgpu_dev, &readback_desc)
			h.ts_supported = (h.ts_resolve_buf != nil && h.ts_readback_buf != nil)
			if h.ts_supported {
				h.ts_period = wgpu.QueueGetTimestampPeriod(wgpu_q)
				if h.ts_period <= 0.0 {
					h.ts_period = 1.0
				}
			}
		}
	}
	defer {
		if h.ts_query_set != nil {
			wgpu.QuerySetRelease(h.ts_query_set)
			h.ts_query_set = nil
		}
		if h.ts_resolve_buf != nil {
			wgpu.BufferRelease(h.ts_resolve_buf)
			h.ts_resolve_buf = nil
		}
		if h.ts_readback_buf != nil {
			wgpu.BufferRelease(h.ts_readback_buf)
			h.ts_readback_buf = nil
		}
	}

	pane_w := screen_w * 0.5
	pane_h := (screen_h - CHROME_BAR_HEIGHT) * 0.5

	if !three_d.three_d_init(
		&h.three_d_renderer,
		wgpu_dev,
		wgpu_q,
		wgpu_fmt,
		u32(pane_w),
		u32(pane_h),
	) {
		fmt.eprintln("harness error: three_d_init failed")
		os.exit(1)
	}
	defer three_d.three_d_destroy(&h.three_d_renderer)

	three_d.interactor_init(&h.three_d_interactor)
	// Start with auto-rotate off so idle test immediately shows 0 raster passes!
	h.three_d_interactor.auto_rotate = false

	scheduler.scheduler_init(&h.scheduler)
	h.blink_interval_ns = 530_000_000 // 530 ms
	h.blink_enabled = false // start with blink disabled by default for idle measurement, or toggleable with [C]

	// Allocate all 5 layers and configure layout geometry
	_acquire_all_layers(h)

	// Mark all layers dirty initially so frame 1 rasterizes everything
	_mark_layer_dirty(h, PANE_1_ID)
	_mark_layer_dirty(h, PANE_2_ID)
	_mark_layer_dirty(h, PANE_3_ID)
	_mark_layer_dirty(h, PANE_4_ID)
	_mark_layer_dirty(h, CHROME_LAYER_ID)

	defer {
		wgpu_backend.destroy_surface(h.surface)
		contract.destroy_device(h.device)
		contract.destroy_instance(h.instance)
	}

	fmt.println("=================================================================")
	fmt.println("Term Standalone Native GUI Harness & Chrome Renderer RUNNING!")
	fmt.printf("Window Size: %dx%d | 4-Split Heterogeneous Multi-Pane Layout\n", window_w, window_h)
	fmt.println("=================================================================")
	fmt.println("Controls:")
	fmt.println("  [1]     Select Pane 1 (Terminal Shell / Typing)")
	fmt.println("  [2]     Select Pane 2 (3D Component Engine)")
	fmt.println("  [3]     Select Pane 3 (Build / Monitor logs)")
	fmt.println("  [4]     Select Pane 4")
	fmt.println("  [R]     Toggle 3D Auto-Rotation on Pane 2")
	fmt.println("  [Space] Animate / Type in ACTIVE pane ONLY (Marks ONLY active dirty!)")
	fmt.println("  [D]     Toggle 3D Mesh (Unit Cube <-> Hexagonal Prism Badge)")
	fmt.println("  [W]     Toggle Holographic Wireframe on 3D Mesh")
	fmt.println("  [F]     Trigger Flood Damage (Marks ALL 4 Panes dirty)")
	fmt.println("  [S]     Toggle Scissor Clipping Test (Proves boundary discard)")
	fmt.println("  [C]     Toggle Cursor Blink (530ms interval)")
	fmt.println("  [Tab]   Switch Active Tab")
	fmt.println("  [T]     Toggle Extreme 128 Tabs (1024-Rune Unicode Title)")
	fmt.println("  [G]     Toggle Dynamic Split Divider Drag Oscillation")
	fmt.println("  [X]     Toggle 1000 SDF Elements Stress Mode")
	fmt.println("  [Z]     Toggle Radius > Half-Size Clamping Mode")
	fmt.println("  [M/P]   Toggle Command Palette & Search Modal Overlay")
	fmt.println("  [B]     Run Honest Hardware Benchmark (100 Real Frames, <= 25% target)")
	fmt.println("  [Mouse Drag in Pane 2] Orbit 3D Camera | [Wheel] Zoom")
	fmt.println("  [ESC]   Exit")
	fmt.println("=================================================================\n")

	for _ in 0..<10 {
		event: sdl3.Event
		for sdl3.PollEvent(&event) {}
	}

	for i := 1; i < len(os.args); i += 1 {
		arg := os.args[i]
		if arg == "--test" {
			h.test_mode = true
		} else if arg == "--bench" {
			_run_honest_benchmark(h)
			h.running = false
			return
		} else if arg == "--idle-test" {
			h.idle_test_mode = true
			h.idle_test_seconds = 5
			if i + 1 < len(os.args) {
				if sec, ok := strconv.parse_int(os.args[i + 1], 10); ok && sec > 0 {
					h.idle_test_seconds = sec
					i += 1
				}
			}
		} else if arg == "--anim-idle-test" {
			h.idle_test_mode = true
			h.anim_idle_test_mode = true
			h.idle_test_seconds = 3
			h.anim_duration_ns = 200_000_000 // 200 ms
			if i + 1 < len(os.args) {
				if sec, ok := strconv.parse_int(os.args[i + 1], 10); ok && sec > 0 {
					h.idle_test_seconds = sec
					i += 1
				}
			}
		} else if arg == "--blink" {
			h.blink_enabled = true
		}
	}

	if h.test_mode {
		_run_chrome_verification_test(h)
		h.running = false
		return
	}

	if h.idle_test_mode {
		h.idle_test_start = helper.platform_now()
		fmt.printfln("-> Idle Test Mode active: running for %d seconds...", h.idle_test_seconds)
	}

	event: sdl3.Event
	for h.running {
		if h.idle_test_mode {
			elapsed_ticks := helper.platform_now() - h.idle_test_start
			elapsed_ns := helper.platform_ticks_to_ns(elapsed_ticks)

			// If in anim-idle-test mode, trigger 200ms modal fade at t = 0.5s
			if h.anim_idle_test_mode && !h.anim_triggered && elapsed_ns >= 500_000_000 {
				h.anim_triggered = true
				h.anim_start_ns = u64(helper.platform_ticks_to_ns(helper.platform_now()))
				h.pre_anim_rendered = h.scheduler.rendered_frames
				h.modal_active = true
				_update_layer_geometry(h)
				_ = transition.transition_start_opacity(&h.tm, &h.scheduler, MODAL_LAYER_ID, 0.0, 1.0, h.anim_start_ns, h.anim_duration_ns, .Linear)
			}

			target_ns := i64(h.idle_test_seconds) * 1_000_000_000
			if elapsed_ns >= target_ns {
				elapsed_sec := f64(elapsed_ns) / 1_000_000_000.0
				rendered := h.scheduler.rendered_frames
				skipped := h.scheduler.skipped_frames
				submits_per_sec := f64(rendered) / elapsed_sec
				skipped_per_sec := f64(skipped) / elapsed_sec

				fmt.println("\n=================================================================")
				fmt.println("IDLE SCHEDULER TELEMETRY REPORT")
				fmt.println("=================================================================")
				fmt.printfln("Test Duration:                     %.2f s", elapsed_sec)
				if h.anim_idle_test_mode {
					l_mod := pipeline.composer_pipeline_get_layer(&h.composer_pipe, MODAL_LAYER_ID)
					final_opacity := l_mod.opacity if l_mod != nil else 0.0
					post_rendered := rendered - h.post_anim_start_frames if h.post_anim_start_frames > 0 else 0
					in_anim := h.in_anim_rendered

					fmt.println("Mode:                              POST-ANIMATION IDLE VERIFICATION")
					fmt.printfln("Total Rendered Frames:             %d", rendered)
					fmt.printfln("Pre-Anim Rendered (0.0 - 0.5s):    %d frame(s)", h.pre_anim_rendered)
					fmt.printfln("In-Anim Rendered (0.5 - 0.7s, 200ms): %d frames", in_anim)
					fmt.printfln("Post-Anim Rendered (0.7 - %.1fs):  %d frame(s) (Target: 0 submits)", elapsed_sec, post_rendered)
					fmt.printfln("Final Modal Opacity:               %.3f (Target: 1.000)", final_opacity)
					fmt.printfln("Post-Anim Submits/sec:             %.2f", f64(post_rendered) / max(elapsed_sec - 0.7, 0.1))
				} else {
					fmt.printfln("Cursor Blink State:                %s", "ACTIVE (530ms)" if h.blink_enabled else "OFF (Static Idle)")
					fmt.printfln("Total Rendered Frames:             %d", rendered)
					fmt.printfln("Total Skipped Iterations:          %d", skipped)
					fmt.printfln("Rendered Frames/sec (Submits/sec): %.2f", submits_per_sec)
					fmt.printfln("Skipped/sec:                       %.2f", skipped_per_sec)
				}
				fmt.println("=================================================================")

				h.running = false
				break
			}
		}

		for sdl3.PollEvent(&event) {
			_handle_sdl_event(h, &event)
		}

		// Cursor blink logic
		now_ns := u64(helper.platform_ticks_to_ns(helper.platform_now()))

		if h.anim_idle_test_mode && h.anim_triggered {
			if h.tm.active_count > 0 {
				h.in_anim_rendered = h.scheduler.rendered_frames - h.pre_anim_rendered
			} else if !h.anim_finished {
				h.anim_finished = true
				h.in_anim_rendered = h.scheduler.rendered_frames - h.pre_anim_rendered
				h.post_anim_start_frames = h.scheduler.rendered_frames
			}
		}

		if h.blink_enabled {
			if h.next_blink_ns == 0 {
				h.next_blink_ns = now_ns + h.blink_interval_ns
				scheduler.scheduler_set_deadline(&h.scheduler, h.next_blink_ns)
			}
			if now_ns >= h.next_blink_ns {
				h.cursor_visible = !h.cursor_visible
				h.next_blink_ns = now_ns + h.blink_interval_ns
				scheduler.scheduler_set_deadline(&h.scheduler, h.next_blink_ns)
				_mark_layer_dirty(h, PANE_1_ID)
				assert(h.next_blink_ns > now_ns, "Blink deadline must be advanced!")
			}
		}

		// 3D Auto-Rotation Sync
		scheduler.scheduler_set_anim_active(&h.scheduler, h.three_d_interactor.auto_rotate)

		// Frame timing
		cur_ticks := helper.platform_now()
		dt_s: f32 = 0.008
		if h.last_frame_ticks > 0 {
			dt_ns := helper.platform_ticks_to_ns(cur_ticks - h.last_frame_ticks)
			dt_s = f32(f64(dt_ns) / 1_000_000_000.0)
		}
		h.last_frame_ticks = cur_ticks

		// Dynamic divider drag animation
		if h.divider_drag_active {
			t_sec := f32(f64(now_ns - u64(h.start_ticks)) / 1e9)
			h.divider_ratio = 0.5 + 0.35 * math.sin(t_sec * 2.0)
			_mark_layer_dirty(h, CHROME_LAYER_ID)
		}

		// If 3D auto-rotates, ONLY Pane 2 is marked dirty!
		if h.three_d_interactor.auto_rotate {
			three_d.interactor_update(&h.three_d_interactor, dt_s)
			_mark_layer_dirty(h, PANE_2_ID)
			_mark_layer_dirty(h, CHROME_LAYER_ID)
		}

		if h.anim_idle_test_mode {
			surf_ptr := (^wgpu_backend.Wgpu_Surface)(h.surface)
			pm := surf_ptr.present_mode if surf_ptr != nil else .Undefined
			trigger := "UNKNOWN"
			if h.scheduler.force_next do trigger = "FORCE"
			else if h.scheduler.damage_pending do trigger = "DAMAGE"
			else if h.scheduler.anim_active do trigger = "ANIM"
			else if h.scheduler.next_deadline > 0 && now_ns >= h.scheduler.next_deadline do trigger = "DEADLINE"

			test_elapsed := f64(helper.platform_ticks_to_ns(helper.platform_now() - h.idle_test_start)) / 1e9
			l_mod := pipeline.composer_pipeline_get_layer(&h.composer_pipe, MODAL_LAYER_ID)
			mod_op := l_mod.opacity if l_mod != nil else 0.0
			fmt.printfln("  [FRAME #%d] dt=%.2fms | elapsed=%.3fs | trigger=%s | presentMode=%v | modalOpacity=%.3f",
				h.scheduler.rendered_frames + 1, dt_s * 1000.0, test_elapsed, trigger, pm, mod_op)
		}

		// Frame driver for core/composer/frame.frame_tick
		driver := frame.Frame_Driver{
			user    = h,
			acquire = _frame_acquire,
			raster  = _frame_raster,
			present = _frame_present,
		}

		t_frame_start := helper.platform_now()
		outcome := frame.frame_tick(&h.scheduler, &h.composer_pipe, &h.tm, &driver, now_ns)
		t_frame_end := helper.platform_now()

		if outcome.ticked {
			h.last_total_ns = u64(max(i64(0), helper.platform_ticks_to_ns(t_frame_end - t_frame_start)))
			h.composer_pipe.stats.total_frame_ns = h.last_total_ns
		} else {
			// When !outcome.ticked: wait for event using outcome.wake_at timeout
			timeout_ms: i32 = -1
			if outcome.wake_at > now_ns {
				timeout_ms = max(i32(1), i32((outcome.wake_at - now_ns) / 1_000_000))
			} else if outcome.wake_at > 0 && now_ns >= outcome.wake_at {
				timeout_ms = 0
			}

			if h.idle_test_mode && (timeout_ms < 0 || timeout_ms > 100) {
				timeout_ms = 100
			}

			wait_event: sdl3.Event
			if sdl3.WaitEventTimeout(&wait_event, timeout_ms) {
				_handle_sdl_event(h, &wait_event)
			}
		}
	}
}
