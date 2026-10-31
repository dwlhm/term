package term

// Auto-Hide Floating Tab Bar, Detached Rounded Pills & Pane Card Overlays
// Part of Tier 3 Application Shell (src/app/term/*).

import "base:runtime"
import "core:math"
import cursor "../../core/cursor"
import contract "../../core/render/contract"
import chrome_dl "../../core/chrome/draw_list"
import chrome_modals "../../core/chrome/modals"
import chrome_splits "../../core/chrome/splits"
import chrome_render "../../core/render/chrome"
import tabs_feat "../../features/tabs"
import mux_feat "../../features/multiplexer"

Chrome_View :: struct {
	rend:         chrome_render.Chrome_Renderer,
	draw_list:    chrome_dl.Ui_Draw_List,
	device:       contract.Gpu_Device,
	queue:        contract.Gpu_Queue,
	format:       contract.Gpu_Format,
	last_dl_hash: u64,
	has_dl_hash:  bool,
}

_fnv1a_bytes :: #force_inline proc "contextless" (h: u64, data: []byte) -> u64 {
	hash := h
	for b in data {
		hash = (hash ~ u64(b)) * 1099511628211
	}
	return hash
}

_chrome_draw_list_hash :: proc "contextless" (dl: ^chrome_dl.Ui_Draw_List, screen_w, screen_h: f32) -> u64 {
	hash: u64 = 14695981039346656037
	dims := [2]f32{screen_w, screen_h}
	hash = _fnv1a_bytes(hash, ([^]byte)(&dims)[:size_of(dims)])
	if dl == nil do return hash

	for i in 0..<len(dl.commands) {
		cmd := dl.commands[i]
		kind_u := u32(cmd.kind)
		hash = _fnv1a_bytes(hash, ([^]byte)(&kind_u)[:size_of(u32)])
		hash = _fnv1a_bytes(hash, ([^]byte)(&cmd.rect)[:size_of([4]f32)])
		hash = _fnv1a_bytes(hash, ([^]byte)(&cmd.color)[:size_of([4]f32)])
		hash = _fnv1a_bytes(hash, ([^]byte)(&cmd.border_color)[:size_of([4]f32)])
		hash = _fnv1a_bytes(hash, ([^]byte)(&cmd.radius)[:size_of(f32)])
		hash = _fnv1a_bytes(hash, ([^]byte)(&cmd.border_width)[:size_of(f32)])
		hash = _fnv1a_bytes(hash, ([^]byte)(&cmd.clip_rect)[:size_of([4]f32)])
		if len(cmd.text) > 0 {
			hash = _fnv1a_bytes(hash, transmute([]byte)(cmd.text))
		}
	}
	return hash
}

chrome_view_init :: proc(
	cv: ^Chrome_View,
	device: contract.Gpu_Device,
	queue: contract.Gpu_Queue,
	format: contract.Gpu_Format,
	screen_w, screen_h: u32,
) -> bool {
	if cv == nil do return false
	cv.device = device
	cv.queue = queue
	cv.format = format
	cv.last_dl_hash = 0
	cv.has_dl_hash = false

	chrome_render.chrome_renderer_init(&cv.rend, device, queue, screen_w, screen_h, format)
	chrome_dl.ui_draw_list_init(&cv.draw_list)
	return true
}

chrome_view_set_atlas :: proc(cv: ^Chrome_View, atlas_view: contract.Gpu_TextureView, cell_w, cell_h: f32) {
	if cv == nil do return
	chrome_render.chrome_renderer_set_atlas(&cv.rend, atlas_view, cell_w, cell_h)
	cv.has_dl_hash = false
	chrome_render.chrome_renderer_mark_dirty(&cv.rend, true)
}

chrome_view_destroy :: proc(cv: ^Chrome_View) {
	if cv == nil do return
	chrome_dl.ui_draw_list_destroy(&cv.draw_list)
	chrome_render.chrome_renderer_destroy(&cv.rend)
}

chrome_view_resize :: proc(cv: ^Chrome_View, screen_w, screen_h: u32) {
	if cv == nil do return
	cv.has_dl_hash = false
	chrome_render.chrome_renderer_resize(&cv.rend, screen_w, screen_h)
}

chrome_view_build_draw_list :: proc(
	cv: ^Chrome_View,
	layout: ^Layout_State,
	tabs: ^tabs_feat.Tabs_Manager,
	mux: ^mux_feat.Multiplexer,
	cmd_center: ^Command_Center_State,
	search: ^Search_State,
	cursor_state: ^Cursor_State,
	time_elapsed: f32,
	hovered_divider: ^chrome_splits.Split_Node = nil,
	dragged_divider: ^chrome_splits.Split_Node = nil,
	hovered_scrollbar: u32 = 0,
	dragged_scrollbar: u32 = 0,
	session_dlg: ^chrome_modals.Session_Dialog_State = nil,
	drop_effect: ^Drop_Effect_State = nil,
) -> (dirty: bool) {
	if cv == nil do return false

	chrome_dl.ui_draw_list_clear(&cv.draw_list)

	// 1. Draw Pane Components & Cursor
	if mux != nil {
		has_splits := len(mux.panes) > 1
		for &pane in mux.panes {
			if pane.rect[2] <= 0 || pane.rect[3] <= 0 do continue

			// Draw focus boundary border when multiple split panes exist
			if has_splits && layout != nil {
				if pane.is_focused {
					chrome_dl.ui_draw_border(&cv.draw_list, pane.rect, {0.30, 0.55, 0.90, 0.70}, layout.metrics.border_radius)
				} else {
					chrome_dl.ui_draw_border(&cv.draw_list, pane.rect, {0.18, 0.20, 0.26, 0.35}, layout.metrics.border_radius)
				}
			}

			// 2. Draw Cursor for inactive split panes (focused pane cursor lives on dedicated CURSOR_LAYER_ID)
			if pane.session != nil {
				if !pane.is_focused && pane.session.term.parser.cursor.visible {
					cur_c := pane.session.term.parser.cursor.col
					cur_r := pane.session.term.parser.cursor.row + pane.session.scroll_offset
					cur_pad_x, cur_pad_y := pane_grid_pad(
						pane.rect,
						pane.session.term.rows,
						pane.session.term.cols,
						layout.metrics.cell_w,
						layout.metrics.cell_h,
						layout.metrics.pane_pad_x,
						layout.metrics.pane_pad_y,
					)
					rows_visible := int((pane.rect[3] - 2.0 * cur_pad_y) / layout.metrics.cell_h)

					if cur_r >= 0 && cur_r < rows_visible {
						cur_shape: Cursor_Shape = .Block
						switch pane.session.term.parser.cursor.shape {
						case .Block:     cur_shape = .Block
						case .Beam:      cur_shape = .Beam
						case .Underline: cur_shape = .Underline
						}

						cur_rect := cursor_compute_rect(cur_c, cur_r, pane.rect, layout.metrics.cell_w, layout.metrics.cell_h, cur_pad_x, cur_pad_y, cur_shape)

						// Clip cursor to pane bounds
						if cur_rect[0] + cur_rect[2] <= pane.rect[0] + pane.rect[2] &&
						   cur_rect[1] + cur_rect[3] <= pane.rect[1] + pane.rect[3] {
							switch cur_shape {
							case .Block:
								chrome_dl.ui_draw_border(&cv.draw_list, cur_rect, {0.55, 0.60, 0.70, 0.35}, 1.0 * layout.metrics.scale)
							case .Beam, .Underline:
								chrome_dl.ui_draw_rounded_rect(&cv.draw_list, cur_rect, {0.55, 0.60, 0.70, 0.30}, 0.0)
							}
						}
					}
				}

				// 2b. Scrollback thumb: always visible with history, brighter when
				// hovered or dragged (geometry comes from scrollbar.odin so the hit
				// test and the drawing can never disagree).
				geometry := scrollbar_geometry_for_pane(&pane, layout.metrics.scale)
				if geometry.valid {
					active := dragged_scrollbar == pane.id
					hovered := hovered_scrollbar == pane.id
					alpha: f32 = 0.35
					if active do alpha = 0.85
					else if hovered do alpha = 0.60
					width := SCROLLBAR_WIDTH * layout.metrics.scale if (active || hovered) else 3.0 * layout.metrics.scale
					thumb_x := pane.rect[0] + pane.rect[2] - (SCROLLBAR_WIDTH + SCROLLBAR_MARGIN) * layout.metrics.scale
					chrome_dl.ui_draw_rounded_rect(
						&cv.draw_list,
						{thumb_x, geometry.thumb_y, width, geometry.thumb_h},
						{0.70, 0.78, 0.92, alpha},
						width * 0.5,
					)
				}
			}
		}
	}

	// 2. Render Split Dividers & Center Drag Handle Grip Buttons
	if tabs != nil {
		_, active_tab := tabs_feat.tabs_manager_get_active(tabs)
		if active_tab != nil && active_tab.split_tree != nil {
			s := layout.metrics.scale if layout != nil else 1.0
			divider_view_emit_tree(&cv.draw_list, active_tab.split_tree, hovered_divider, dragged_divider, s)
		}
	}

	// 2b. Drag & Drop Tactile Feedback & Crystal 3D Water Ripple
	if drop_effect != nil && drop_effect.enabled && drop_effect_is_active(drop_effect) && layout != nil {
		fade := drop_effect.exit_fade_t if drop_effect.is_exiting else 1.0
		if (drop_effect.is_dragging || drop_effect.is_exiting) && drop_effect.target_rect[2] > 20.0 && fade > 0.001 {
			p_rect := drop_effect.target_rect
			r := layout.metrics.border_radius
			// Tactile Drop Target Pane Card: concentric soft ambient glow & subtle ice-blue border
			chrome_dl.ui_draw_rounded_rect(&cv.draw_list, p_rect, {0.35, 0.65, 1.0, 0.035 * fade}, r)
			chrome_dl.ui_draw_border(&cv.draw_list, p_rect, {0.45, 0.72, 1.0, 0.35 * fade}, r, 1.5 * layout.metrics.scale)
		}
		drop_effect_emit_draw_list(drop_effect, &cv.draw_list, layout.screen_w, layout.screen_h, layout.metrics.scale)
	}

	// 3. Render Modern Integrated Top Bar & Tabs
	if layout != nil && tabs != nil && layout.tab_bar_anim_t > 0.001 {
		bar_h := layout.metrics.tab_bar_height
		scale := layout.metrics.scale

		anim_offset_y: f32 = -(1.0 - layout.tab_bar_anim_t) * (bar_h + 6.0 * scale) if layout.is_fullscreen else 0.0
		alpha_factor: f32 = layout.tab_bar_anim_t if layout.is_fullscreen else 1.0

		// Subtle backdrop banner when sliding down over terminal panes in fullscreen
		if layout.is_fullscreen {
			banner_rect: [4]f32 = {0, anim_offset_y, layout.screen_w, bar_h + 2.0 * scale}
			banner_bg: [4]f32 = {0.08, 0.09, 0.11, 0.92 * alpha_factor}
			chrome_dl.ui_draw_rounded_rect(&cv.draw_list, banner_rect, banner_bg, 0)
		}

		tab_h: f32 = 22.0 * scale
		tab_y := (bar_h - tab_h) * 0.5 + anim_offset_y
		tabs_x := (12.0 * scale) if layout.is_fullscreen else (layout.metrics.traffic_clearance + 6.0 * scale)
		tab_w: f32 = 140.0 * scale
		tab_gap: f32 = 6.0 * scale
		capsule_radius := tab_h * 0.5

		// Fixed right-side buttons: [⊞] Overview and [+] New Tab
		btn_w: f32 = tab_h
		btn_gap: f32 = 4.0 * scale
		right_margin: f32 = 12.0 * scale

		btn_ov_x := layout.screen_w - right_margin - btn_w
		btn_plus_x := btn_ov_x - btn_gap - btn_w
		tabs_end_x := btn_plus_x - 8.0 * scale

		avail_tabs_w := max(40.0 * scale, tabs_end_x - tabs_x)

		// Clamp tab scroll offset
		total_tabs_w := f32(len(tabs.entries)) * (tab_w + tab_gap)
		max_scroll := max(0.0, total_tabs_w - avail_tabs_w)
		layout.tab_scroll_offset = clamp(layout.tab_scroll_offset, 0.0, max_scroll)

		// Render visible tabs
		for i in 0..<len(tabs.entries) {
			tab_item_x := tabs_x + f32(i) * (tab_w + tab_gap) - layout.tab_scroll_offset
			draw_x := max(tabs_x, tab_item_x)
			draw_r := min(tabs_end_x, tab_item_x + tab_w)
			draw_w := draw_r - draw_x

			// Skip tabs completely outside the visible tab viewport
			if draw_w <= 2.0 * scale do continue

			is_active := (i == tabs.model.active_idx)
			pill_rect: [4]f32 = {draw_x, tab_y, draw_w, tab_h}

			pill_bg := COLOR_TAB_ACTIVE_BG if is_active else COLOR_TAB_INACTIVE_BG
			pill_bg[3] *= alpha_factor
			chrome_dl.ui_draw_rounded_rect(&cv.draw_list, pill_rect, pill_bg, capsule_radius)

			// Close button [x]
			close_w: f32 = 24.0 * scale
			has_close := (tab_item_x + tab_w - 18.0 * scale <= draw_r) && (draw_w >= 36.0 * scale)

			// Tab Title
			text_x := draw_x + 10.0 * scale
			text_max_w := (draw_r - (close_w if has_close else 8.0 * scale)) - text_x

			if text_max_w > 8.0 * scale {
				tab_title := string(tabs.entries[i].title_buf[:tabs.entries[i].title_len]) if tabs.entries[i].title_len > 0 else "Shell"
				txt_col := COLOR_TAB_TEXT_ACTIVE if is_active else COLOR_TAB_TEXT_INACT
				txt_col[3] *= alpha_factor
				text_y := tab_y + (tab_h - 14.0 * scale) * 0.5
				chrome_dl.ui_draw_text(&cv.draw_list, {text_x, text_y, text_max_w, 14.0 * scale}, tab_title, txt_col)
			}

			if has_close {
				close_col: [4]f32 = {0.75, 0.80, 0.90, 0.85 * alpha_factor} if is_active else {0.40, 0.45, 0.55, 0.45 * alpha_factor}
				close_x := tab_item_x + tab_w - 18.0 * scale
				close_y := tab_y + (tab_h - 13.0 * scale) * 0.5
				chrome_dl.ui_draw_text(&cv.draw_list, {close_x, close_y, 10.0 * scale, 13.0 * scale}, "x", close_col)
			}
		}

		// New Tab Button [+]
		if btn_plus_x > tabs_x {
			plus_rect: [4]f32 = {btn_plus_x, tab_y, btn_w, tab_h}
			plus_bg: [4]f32 = {0.11, 0.13, 0.17, 0.50 * alpha_factor}
			chrome_dl.ui_draw_rounded_rect(&cv.draw_list, plus_rect, plus_bg, capsule_radius)

			// Plus icon
			icon_col: [4]f32 = {0.70, 0.75, 0.85, 0.75 * alpha_factor}
			cx := btn_plus_x + (btn_w - 8.0 * scale) * 0.5
			cy := tab_y + (tab_h - 1.5 * scale) * 0.5
			chrome_dl.ui_draw_rounded_rect(&cv.draw_list, {cx, cy, 8.0 * scale, 1.5 * scale}, icon_col, 0.75 * scale)
			cx2 := btn_plus_x + (btn_w - 1.5 * scale) * 0.5
			cy2 := tab_y + (tab_h - 8.0 * scale) * 0.5
			chrome_dl.ui_draw_rounded_rect(&cv.draw_list, {cx2, cy2, 1.5 * scale, 8.0 * scale}, icon_col, 0.75 * scale)
		}

		// Tab Overview Button [⊞]
		if btn_ov_x > tabs_x {
			ov_rect: [4]f32 = {btn_ov_x, tab_y, btn_w, tab_h}
			is_ov_open := (cmd_center != nil && cmd_center.visible && cmd_center.mode == .Tabs)
			ov_bg: [4]f32 = {0.18, 0.22, 0.30, 0.90 * alpha_factor} if is_ov_open else {0.11, 0.13, 0.17, 0.50 * alpha_factor}
			chrome_dl.ui_draw_rounded_rect(&cv.draw_list, ov_rect, ov_bg, capsule_radius)

			// Grid icon [⊞] (four small squares)
			sq_s: f32 = 3.5 * scale
			sq_gap: f32 = 1.5 * scale
			top_left_x := btn_ov_x + (btn_w - (sq_s * 2.0 + sq_gap)) * 0.5
			top_left_y := tab_y + (tab_h - (sq_s * 2.0 + sq_gap)) * 0.5
			icon_col: [4]f32 = {0.80, 0.88, 1.0, 0.90 * alpha_factor} if is_ov_open else {0.70, 0.75, 0.85, 0.75 * alpha_factor}

			chrome_dl.ui_draw_rounded_rect(&cv.draw_list, {top_left_x, top_left_y, sq_s, sq_s}, icon_col, 0.8 * scale)
			chrome_dl.ui_draw_rounded_rect(&cv.draw_list, {top_left_x + sq_s + sq_gap, top_left_y, sq_s, sq_s}, icon_col, 0.8 * scale)
			chrome_dl.ui_draw_rounded_rect(&cv.draw_list, {top_left_x, top_left_y + sq_s + sq_gap, sq_s, sq_s}, icon_col, 0.8 * scale)
			chrome_dl.ui_draw_rounded_rect(&cv.draw_list, {top_left_x + sq_s + sq_gap, top_left_y + sq_s + sq_gap, sq_s, sq_s}, icon_col, 0.8 * scale)
		}
	}

	// 3b. Search bar (Cmd+F)
	if search != nil && search.active && layout != nil {
		scale := layout.metrics.scale
		bar_w := 340.0 * scale
		bar_h := 28.0 * scale
		x := layout.screen_w - bar_w - 20.0 * scale
		y := layout.metrics.tab_bar_height + 10.0 * scale
		chrome_dl.ui_draw_rounded_rect(&cv.draw_list, {x, y, bar_w, bar_h}, {0.10, 0.12, 0.17, 0.97}, bar_h * 0.5)
		chrome_dl.ui_draw_border(&cv.draw_list, {x, y, bar_w, bar_h}, {0.30, 0.55, 0.90, 0.65}, bar_h * 0.5)

		query := text_input_as_string(&search.input)
		has_query := len(query) > 0
		label := query if has_query else "Find in scrollback…"
		label_color: [4]f32 = {0.92, 0.94, 0.98, 1.0} if has_query else {0.55, 0.58, 0.66, 1.0}
		text_h := 14.0 * scale
		text_x := x + 12.0 * scale
		text_y := y + (bar_h - text_h) * 0.5
		if has_query {
			char_w := 7.5 * scale
			if s_idx, e_idx, sel_active := text_input_selection_range(&search.input); sel_active {
				sel_x := text_x + f32(s_idx) * char_w
				sel_w := f32(e_idx - s_idx) * char_w
				chrome_dl.ui_draw_rounded_rect(&cv.draw_list, {sel_x, text_y, sel_w, text_h}, {0.25, 0.45, 0.85, 0.45}, 2.0 * scale)
			} else {
				cur_x := text_x + f32(search.input.cursor) * char_w
				chrome_dl.ui_draw_rect(&cv.draw_list, {cur_x, text_y + 1 * scale, 1.5 * scale, text_h - 2 * scale}, {0.35, 0.65, 1.0, 0.90})
			}
		}
		chrome_dl.ui_draw_text(
			&cv.draw_list,
			{text_x, text_y, bar_w - 70.0 * scale, text_h},
			label,
			label_color,
		)

		status := "0/0" if len(query) == 0 else ("1/1" if search.has_match else "0/0")
		status_color: [4]f32 = {0.55, 0.58, 0.66, 1.0} if !search.has_match else {0.45, 0.75, 0.55, 1.0}
		chrome_dl.ui_draw_text(
			&cv.draw_list,
			{x + bar_w - 52.0 * scale, y + (bar_h - text_h) * 0.5, 40.0 * scale, text_h},
			status,
			status_color,
		)
	}

	// 4. Modal Overlay (Command Center or Tab Overview)
	if cmd_center != nil && cmd_center.visible {
		command_center_emit_draw_list(cmd_center, tabs, &cv.draw_list, layout.screen_w, layout.screen_h, layout.metrics.scale)
	}

	// 5. Session Safety Confirmation Modal Sheet
	if session_dlg != nil && session_dlg.visible {
		chrome_modals.session_dialog_emit_draw_list(session_dlg, &cv.draw_list, layout.screen_w, layout.screen_h, layout.metrics.scale)
	}

	screen_w := layout.screen_w if layout != nil else f32(cv.rend.width)
	screen_h := layout.screen_h if layout != nil else f32(cv.rend.height)
	dl_hash := _chrome_draw_list_hash(&cv.draw_list, screen_w, screen_h)
	if !cv.has_dl_hash || dl_hash != cv.last_dl_hash {
		cv.last_dl_hash = dl_hash
		cv.has_dl_hash = true
		chrome_render.chrome_renderer_mark_dirty(&cv.rend, true)
		return true
	}
	return chrome_render.chrome_renderer_is_dirty(&cv.rend)
}

chrome_view_encode :: proc(
	cv: ^Chrome_View,
	enc: contract.Gpu_CommandEncoder,
	target_view: contract.Gpu_TextureView,
	load_op: contract.Gpu_Load_Op = .Clear,
) -> bool {
	if cv == nil || rawptr(enc) == nil || rawptr(target_view) == nil do return false
	return chrome_render.chrome_renderer_encode(&cv.rend, enc, &cv.draw_list, target_view, load_op)
}

chrome_view_build_and_render :: proc(
	cv: ^Chrome_View,
	layout: ^Layout_State,
	tabs: ^tabs_feat.Tabs_Manager,
	mux: ^mux_feat.Multiplexer,
	cmd_center: ^Command_Center_State,
	cursor_state: ^Cursor_State,
	time_elapsed: f32,
	target_view: contract.Gpu_TextureView,
) {
	if cv == nil || rawptr(target_view) == nil do return
	_ = chrome_view_build_draw_list(cv, layout, tabs, mux, cmd_center, nil, cursor_state, time_elapsed)
	_ = chrome_render.chrome_renderer_render(&cv.rend, &cv.draw_list, target_view)
}

_cursor_for_command_center :: proc(cc: ^Command_Center_State, pt: [2]f32) -> (cursor.Mouse_Cursor, bool) {
	if cc == nil || !cc.visible do return .Default, false
	mx, my := pt.x, pt.y
	if mx >= cc.modal_rect[0] && mx <= cc.modal_rect[0] + cc.modal_rect[2] &&
	   my >= cc.modal_rect[1] && my <= cc.modal_rect[1] + cc.modal_rect[3] {
		input_top := cc.modal_rect[1] + 16.0
		input_bot := input_top + 36.0
		if my >= input_top && my <= input_bot do return .Text, true
		if my >= cc.items_start_y && cc.item_h > 0 {
			row_idx := int((my - cc.items_start_y) / cc.item_h)
			if row_idx >= 0 && row_idx < 8 && (cc.scroll_offset + row_idx) < cc.filtered_count {
				return .Pointer, true
			}
		}
		return .Default, true
	}
	return .Default, true
}

_cursor_for_tab_bar :: proc(layout: ^Layout_State, tabs: ^tabs_feat.Tabs_Manager, pt: [2]f32) -> (cursor.Mouse_Cursor, bool) {
	if layout == nil do return .Default, false
	scale := layout.metrics.scale
	bar_h := layout.metrics.tab_bar_height
	anim_offset_y: f32 = -(1.0 - layout.tab_bar_anim_t) * (bar_h + 6.0 * scale) if layout.is_fullscreen else 0.0
	tab_bar_interactive := !layout.is_fullscreen || layout.tab_bar_anim_t > 0.5
	if !tab_bar_interactive || pt.y < 0 || pt.y > (bar_h + anim_offset_y) {
		return .Default, false
	}

	tab_h: f32 = 22.0 * scale
	tab_y := (bar_h - tab_h) * 0.5 + anim_offset_y
	tab_w: f32 = 140.0 * scale
	tab_gap: f32 = 6.0 * scale
	tabs_x := (12.0 * scale) if layout.is_fullscreen else (layout.metrics.traffic_clearance + 6.0 * scale)
	btn_w: f32 = tab_h
	btn_gap: f32 = 4.0 * scale
	right_margin: f32 = 12.0 * scale
	btn_ov_x := layout.screen_w - right_margin - btn_w
	btn_plus_x := btn_ov_x - btn_gap - btn_w
	tabs_end_x := btn_plus_x - 8.0 * scale

	if pt.x >= btn_ov_x && pt.x <= btn_ov_x + btn_w && pt.y >= tab_y && pt.y <= tab_y + tab_h do return .Pointer, true
	if pt.x >= btn_plus_x && pt.x <= btn_plus_x + btn_w && pt.y >= tab_y && pt.y <= tab_y + tab_h do return .Pointer, true
	if tabs != nil {
		for i in 0..<len(tabs.entries) {
			tab_item_x := tabs_x + f32(i) * (tab_w + tab_gap) - layout.tab_scroll_offset
			draw_x := max(tabs_x, tab_item_x)
			draw_r := min(tabs_end_x, tab_item_x + tab_w)
			if draw_x < draw_r && pt.x >= draw_x && pt.x <= draw_r && pt.y >= tab_y && pt.y <= tab_y + tab_h {
				return .Pointer, true
			}
		}
	}
	return .Default, true
}

// chrome_view_cursor determines the mouse cursor shape for all chrome elements.
_cursor_for_session_dialog :: proc(dlg: ^chrome_modals.Session_Dialog_State, pt: [2]f32) -> (cursor.Mouse_Cursor, bool) {
	if dlg == nil || !dlg.visible do return .Default, false

	in_box :: #force_inline proc "contextless" (p: [2]f32, rect: [4]f32) -> bool {
		return rect[2] > 0 && rect[3] > 0 &&
		       p.x >= rect[0] && p.x <= rect[0] + rect[2] &&
		       p.y >= rect[1] && p.y <= rect[1] + rect[3]
	}

	if in_box(pt, dlg.cancel_rect) do return .Pointer, true
	if in_box(pt, dlg.apply_rect) do return .Pointer, true
	if in_box(pt, dlg.toggle_rect) do return .Pointer, true

	for item in dlg.items {
		if in_box(pt, item.btn_rect) do return .Pointer, true
	}

	return .Default, true
}

chrome_view_cursor :: proc(
	cv: ^Chrome_View,
	layout: ^Layout_State,
	tabs: ^tabs_feat.Tabs_Manager,
	cmd_center: ^Command_Center_State,
	pt: [2]f32,
	session_dlg: ^chrome_modals.Session_Dialog_State = nil,
) -> (cursor_shape: cursor.Mouse_Cursor, handled: bool) {
	if session_dlg != nil && session_dlg.visible {
		return _cursor_for_session_dialog(session_dlg, pt)
	}
	if cv == nil || layout == nil do return .Default, false

	if c, ok := _cursor_for_command_center(cmd_center, pt); ok do return c, true
	if c, ok := _cursor_for_tab_bar(layout, tabs, pt); ok do return c, true

	return .Default, false
}
