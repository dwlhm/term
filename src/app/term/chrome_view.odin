package term

// Auto-Hide Floating Tab Bar, Detached Rounded Pills & Pane Card Overlays
// Part of Tier 3 Application Shell (src/app/term/*).

import "base:runtime"
import "core:math"
import cursor "../../core/cursor"
import atlas "../../core/render/atlas"
import contract "../../core/render/contract"
import chrome_dl "../../core/chrome/draw_list"
import chrome_splits "../../core/chrome/splits"
import chrome_render "../../core/render/chrome"
import tabs_feat "../../features/tabs"
import mux_feat "../../features/multiplexer"
import sess_feat "../../features/session"

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

chrome_view_set_atlas :: proc(
	cv: ^Chrome_View,
	atlas_view: contract.Gpu_TextureView,
	cell_w, cell_h: f32,
	slots: ^[atlas.ATLAS_SLOT_COUNT]atlas.Atlas_Slot = nil,
) {
	if cv == nil do return
	chrome_render.chrome_renderer_set_atlas(&cv.rend, atlas_view, cell_w, cell_h, slots)
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
	chrome_render.chrome_renderer_set_viewport(&cv.rend, screen_w, screen_h)
	chrome_render.chrome_renderer_mark_dirty(&cv.rend, true)
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
	drop_effect: ^Drop_Effect_State = nil,
	sessions: ^sess_feat.Session_Registry = nil,
	quit: ^App_Quit_State = nil,
	takeover: ^Takeover_Dialog_State = nil,
	notice: Automation_Notice = {},
) -> (dirty: bool) {
	if cv == nil do return false

	chrome_dl.ui_draw_list_clear(&cv.draw_list)

	// 1. Draw Pane Components & Cursor
	if mux != nil {
		has_splits := len(mux.panes) > 1
		for &pane in mux.panes {
			if pane.rect[2] <= 0 || pane.rect[3] <= 0 do continue

			if pane.is_floating {
				surface_view_emit_chrome(&cv.draw_list, layout, &pane)
			} else if has_splits && layout != nil {
				if pane.is_focused {
					chrome_dl.ui_draw_border(&cv.draw_list, pane.rect, {0.30, 0.55, 0.90, 0.70}, layout.metrics.border_radius)
				} else {
					chrome_dl.ui_draw_border(&cv.draw_list, pane.rect, {0.18, 0.20, 0.26, 0.35}, layout.metrics.border_radius)
				}
			}

			automation_banner_emit(&cv.draw_list, layout, &pane, notice.kind if automation_notice_active(notice, pane.session) else nil)

			// 2. Draw Cursor for inactive split panes (focused pane cursor lives on dedicated CURSOR_LAYER_ID)
			if pane.session != nil {
				g, _, p := sess_feat.session_pane_parts(pane.session, pane.surface_id)
				scroll_off := sess_feat.session_pane_scroll_offset(pane.session, pane.surface_id)
				if !pane.is_focused && g != nil && p != nil && scroll_off != nil && p.cursor.visible {
					cur_c := p.cursor.col
					cur_r := p.cursor.row + scroll_off^
					cur_pad_x, cur_pad_y := pane_grid_pad(
						pane.rect,
						g.row_count,
						g.col_count,
						layout.metrics.cell_w,
						layout.metrics.cell_h,
						layout.metrics.pane_pad_x,
						layout.metrics.pane_pad_y,
					)
					rows_visible := int((pane.rect[3] - 2.0 * cur_pad_y) / layout.metrics.cell_h)

					if cur_r >= 0 && cur_r < rows_visible {
						cur_shape: Cursor_Shape = .Block
						switch p.cursor.shape {
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
	tab_bar_view_emit(&cv.draw_list, layout, tabs, cmd_center, sessions)

	// 3b. Search bar (Cmd+F)
	if search != nil && search.active && layout != nil {
		scale := layout.metrics.scale
		bar_w := 360.0 * scale
		bar_h := 34.0 * scale
		x := layout.screen_w - bar_w - 20.0 * scale
		y := layout.metrics.tab_bar_height + 10.0 * scale
		chrome_dl.ui_draw_shadow(&cv.draw_list, {x, y + 4.0 * scale, bar_w, bar_h}, COLOR_CHROME_SHADOW, bar_h * 0.5)
		chrome_dl.ui_draw_rounded_rect(&cv.draw_list, {x, y, bar_w, bar_h}, COLOR_CHROME_SURFACE, bar_h * 0.5)
		chrome_dl.ui_draw_border(&cv.draw_list, {x, y, bar_w, bar_h}, COLOR_CHROME_BORDER, bar_h * 0.5)

		query := text_input_as_string(&search.input)
		has_query := len(query) > 0
		label := query if has_query else "Find in scrollback…"
		label_color := COLOR_CHROME_TEXT if has_query else COLOR_CHROME_TEXT_FAINT
		text_h := FONT_CHROME_BODY * scale
		text_x := x + 14.0 * scale
		text_y := y + (bar_h - text_h) * 0.5
		if s_idx, e_idx, sel_active := text_input_selection_range(&search.input); has_query && sel_active {
			sel_x := text_x + chrome_text_width(layout.metrics, query[:s_idx], text_h)
			sel_w := chrome_text_width(layout.metrics, query[s_idx:e_idx], text_h)
			chrome_dl.ui_draw_rounded_rect(&cv.draw_list, {sel_x, text_y, sel_w, text_h}, COLOR_CHROME_ACCENT_SOFT, 3.0 * scale)
		} else {
			cur_prefix := query[:clamp(search.input.cursor, 0, len(query))] if has_query else ""
			cur_x := text_x + chrome_text_width(layout.metrics, cur_prefix, text_h)
			chrome_dl.ui_draw_rect(&cv.draw_list, {cur_x, text_y + 1.0 * scale, 2.0 * scale, text_h - 2.0 * scale}, COLOR_CHROME_ACCENT)
		}
		chrome_dl.ui_draw_text(
			&cv.draw_list,
			{text_x, text_y, bar_w - 72.0 * scale, text_h},
			label,
			label_color,
		)

		status := "0/0" if len(query) == 0 else ("1/1" if search.has_match else "0/0")
		status_h := FONT_CHROME_META * scale
		status_w := chrome_text_width(layout.metrics, status, status_h)
		status_color := COLOR_CHROME_SUCCESS if search.has_match && has_query else COLOR_CHROME_TEXT_MUTED
		chrome_dl.ui_draw_text(
			&cv.draw_list,
			{x + bar_w - 14.0 * scale - status_w, y + (bar_h - status_h) * 0.5, status_w + 2.0 * scale, status_h},
			status,
			status_color,
		)
	}

	// 4. Modal Overlay (Command Center or Tab Overview)
	if cmd_center != nil && (cmd_center.visible || cmd_center.closing) {
		cc_src := Command_Center_Sources{tabs = tabs, sessions = sessions}
		command_center_emit_draw_list(cmd_center, cc_src, &cv.draw_list, layout)
	}
	if quit != nil do quit_dialog_emit_draw_list(&quit.dialog, quit.candidates[:quit.count], &cv.draw_list, layout)
	takeover_dialog_emit_draw_list(takeover, &cv.draw_list, layout)

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
	if tab_bar_point_in(cc.search_rect, pt.x, pt.y) do return .Text, true
	for r in cc.chip_rects do if tab_bar_point_in(r, pt.x, pt.y) do return .Pointer, true
	for i in 0..<cc.row_rect_count {
		if tab_bar_point_in(cc.row_rects[i], pt.x, pt.y) do return .Pointer, true
	}
	return .Default, true // modal is up: nothing underneath gets a cursor
}

_cursor_for_tab_bar :: proc(layout: ^Layout_State, tabs: ^tabs_feat.Tabs_Manager, pt: [2]f32, sessions: ^sess_feat.Session_Registry = nil) -> (cursor.Mouse_Cursor, bool) {
	if layout == nil do return .Default, false
	tab_count := len(tabs.entries) if tabs != nil else 0
	hover, in_bar := tab_bar_hit_test(layout, tab_count, session_pill_width(layout, sessions), pt.x, pt.y)
	if !in_bar do return .Default, false
	return (.Pointer if hover.kind != .None else .Default), true
}

// chrome_view_cursor determines the mouse cursor shape for all chrome elements.
chrome_view_cursor :: proc(
	cv: ^Chrome_View,
	layout: ^Layout_State,
	tabs: ^tabs_feat.Tabs_Manager,
	cmd_center: ^Command_Center_State,
	pt: [2]f32,
	sessions: ^sess_feat.Session_Registry = nil,
) -> (cursor_shape: cursor.Mouse_Cursor, handled: bool) {
	if cv == nil || layout == nil do return .Default, false

	if c, ok := _cursor_for_command_center(cmd_center, pt); ok do return c, true
	if c, ok := _cursor_for_tab_bar(layout, tabs, pt, sessions); ok do return c, true

	return .Default, false
}
