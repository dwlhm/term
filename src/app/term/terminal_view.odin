package term

// Terminal Grid View Orchestrator.
// Part of Tier 3 Application Shell (src/app/term/*).
//
// Delegates rendering entirely to the engine Terminal_Renderer in core_render:
// Evaluates adaptive rendering strategies (Instance, Compute Tiles, Fullscreen)
// without compiling shaders or encoding low-level GPU passes in the application layer.

import contract "../../core/render/contract"
import terminal_render "../../core/render/terminal"
import core_terminal "../../core/terminal"
import sess_feat "../../features/session"
import plat_font "../../platform/font"

MAX_TERMINAL_PANE_SLOTS :: 16

Terminal_Pane_Slot :: struct {
	pane_id: u32,
	rend:    terminal_render.Terminal_Renderer,
	active:  bool,
}

Terminal_View :: struct {
	pipelines:  terminal_render.Terminal_Pipelines,
	slots:      [MAX_TERMINAL_PANE_SLOTS]Terminal_Pane_Slot,
	device:     contract.Gpu_Device,
	queue:      contract.Gpu_Queue,
	format:     contract.Gpu_Format,
	atlas_view: contract.Gpu_TextureView,
	emoji_view: contract.Gpu_TextureView,
}

terminal_view_init :: proc(
	tv: ^Terminal_View,
	device: contract.Gpu_Device,
	queue: contract.Gpu_Queue,
	format: contract.Gpu_Format,
	atlas_view: contract.Gpu_TextureView,
	emoji_view: contract.Gpu_TextureView,
) -> bool {
	if tv == nil do return false
	tv.device = device
	tv.queue = queue
	tv.format = format
	tv.atlas_view = atlas_view
	tv.emoji_view = emoji_view

	if !terminal_render.terminal_pipelines_init(&tv.pipelines, device, format) {
		return false
	}
	return true
}

terminal_view_get_or_create_renderer :: proc(tv: ^Terminal_View, pane_id: u32) -> ^terminal_render.Terminal_Renderer {
	if tv == nil do return nil
	for i in 0..<MAX_TERMINAL_PANE_SLOTS {
		if tv.slots[i].active && tv.slots[i].pane_id == pane_id {
			return &tv.slots[i].rend
		}
	}
	for i in 0..<MAX_TERMINAL_PANE_SLOTS {
		if !tv.slots[i].active {
			tv.slots[i].pane_id = pane_id
			if !terminal_render.terminal_renderer_init_with_pipelines(
				&tv.slots[i].rend,
				tv.device,
				tv.queue,
				tv.format,
				tv.atlas_view,
				tv.emoji_view,
				&tv.pipelines,
			) {
				return nil
			}
			tv.slots[i].active = true
			return &tv.slots[i].rend
		}
	}
	return &tv.slots[0].rend
}

terminal_view_release_pane :: proc(tv: ^Terminal_View, pane_id: u32) {
	if tv == nil do return
	for i in 0..<MAX_TERMINAL_PANE_SLOTS {
		if tv.slots[i].active && tv.slots[i].pane_id == pane_id {
			terminal_render.terminal_renderer_destroy(&tv.slots[i].rend)
			tv.slots[i].active = false
			tv.slots[i].pane_id = 0
			break
		}
	}
}

terminal_view_destroy :: proc(tv: ^Terminal_View) {
	if tv == nil do return
	for i in 0..<MAX_TERMINAL_PANE_SLOTS {
		if tv.slots[i].active {
			terminal_render.terminal_renderer_destroy(&tv.slots[i].rend)
			tv.slots[i].active = false
			tv.slots[i].pane_id = 0
		}
	}
	terminal_render.terminal_pipelines_destroy(&tv.pipelines)
}

terminal_view_resolve_active_bg :: proc(sess: ^sess_feat.Terminal_Session) -> [4]f32 {
	if sess == nil do return COLOR_PANE_BG

	// 1. Explicit OSC 11 background
	if sess.has_custom_bg {
		return sess.custom_bg
	}

	// 2. Active TUI grid background sampling (only active inside alternate screen, e.g. Neovim)
	if dc, pal, ok := core_terminal.terminal_sample_bg(&sess.term, sess.scroll_offset); ok {
		if dc.has_bg {
			return [4]f32{f32(dc.bg[0]) / 255.0, f32(dc.bg[1]) / 255.0, f32(dc.bg[2]) / 255.0, 1.0}
		}
		if pal != 0 {
			return color_from_palette_256(pal)
		}
	}

	return COLOR_PANE_BG
}

terminal_view_encode_pane :: proc(
	tv: ^Terminal_View,
	enc: contract.Gpu_CommandEncoder,
	sess: ^sess_feat.Terminal_Session,
	pane_id: u32,
	pane_rect: [4]f32,
	is_focused: bool,
	mouse: ^Mouse_State,
	time_elapsed: f32,
	target_view: contract.Gpu_TextureView,
	text_atlas: ^plat_font.Text_Atlas,
	metrics: Visual_Metrics,
	screen_w, screen_h: f32,
	load_op: contract.Gpu_Load_Op = .Load,
) -> (strat: terminal_render.Render_Strategy, dirty_cells: int) {
	if tv == nil || rawptr(enc) == nil || sess == nil || rawptr(target_view) == nil || text_atlas == nil do return .Instance, 0

	rend := terminal_view_get_or_create_renderer(tv, pane_id)
	if rend == nil do return .Instance, 0

	sel_active := mouse != nil && mouse.selection.active && mouse.selection.pane_id == pane_id
	sel_r_start := mouse.selection.start_cell.row if sel_active else -1
	sel_c_start := mouse.selection.start_cell.col if sel_active else -1
	sel_r_end := mouse.selection.end_cell.row if sel_active else -1
	sel_c_end := mouse.selection.end_cell.col if sel_active else -1

	terminal_render.terminal_renderer_encode(
		rend,
		enc,
		&sess.term,
		target_view,
		text_atlas,
		pane_rect,
		metrics.cell_w,
		metrics.cell_h,
		metrics.pane_pad_x,
		metrics.pane_pad_y,
		sess.scroll_offset,
		screen_w,
		screen_h,
		sess.has_custom_bg,
		sess.custom_bg,
		sel_r_start,
		sel_c_start,
		sel_r_end,
		sel_c_end,
		sel_active,
		load_op,
		metrics.border_radius,
		is_focused,
	)

	return rend.last_strategy, rend.last_dirty_cells
}

terminal_view_render_pane :: proc(
	tv: ^Terminal_View,
	sess: ^sess_feat.Terminal_Session,
	pane_id: u32,
	pane_rect: [4]f32,
	is_focused: bool,
	mouse: ^Mouse_State,
	time_elapsed: f32,
	target_view: contract.Gpu_TextureView,
	text_atlas: ^plat_font.Text_Atlas,
	metrics: Visual_Metrics,
	screen_w, screen_h: f32,
) {
	if tv == nil || sess == nil || rawptr(target_view) == nil || text_atlas == nil do return

	rend := terminal_view_get_or_create_renderer(tv, pane_id)
	if rend == nil do return

	sel_active := mouse != nil && mouse.selection.active && mouse.selection.pane_id == pane_id
	sel_r_start := mouse.selection.start_cell.row if sel_active else -1
	sel_c_start := mouse.selection.start_cell.col if sel_active else -1
	sel_r_end := mouse.selection.end_cell.row if sel_active else -1
	sel_c_end := mouse.selection.end_cell.col if sel_active else -1

	terminal_render.terminal_renderer_render(
		rend,
		&sess.term,
		target_view,
		text_atlas,
		pane_rect,
		metrics.cell_w,
		metrics.cell_h,
		metrics.pane_pad_x,
		metrics.pane_pad_y,
		sess.scroll_offset,
		screen_w,
		screen_h,
		sess.has_custom_bg,
		sess.custom_bg,
		sel_r_start,
		sel_c_start,
		sel_r_end,
		sel_c_end,
		sel_active,
		metrics.border_radius,
		is_focused,
	)
}
