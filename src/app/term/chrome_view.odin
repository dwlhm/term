package term

// Auto-Hide Floating Tab Bar, Detached Rounded Pills & Pane Card Overlays
// Part of Tier 3 Application Shell (src/app/term/*).

import "base:runtime"
import "core:math"
import contract "../../core/render/contract"
import chrome_dl "../../core/chrome/draw_list"
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
	tab_switcher: ^Tab_Switcher_State,
	cursor_state: ^Cursor_State,
	time_elapsed: f32,
) -> (dirty: bool) {
	if cv == nil do return false

	chrome_dl.ui_draw_list_clear(&cv.draw_list)

	// 1. Draw Pane Components & Cursor (No borders/shadows: focus indicated by background contrast)
	if mux != nil {
		for &pane in mux.panes {
			if pane.rect[2] <= 0 || pane.rect[3] <= 0 do continue

			// 2. Draw Cursor for this terminal pane
			if pane.session != nil {
				if pane.session.term.parser.cursor.visible {
					cur_c := pane.session.term.parser.cursor.col
					cur_r := pane.session.term.parser.cursor.row + pane.session.scroll_offset
					rows_visible := int((pane.rect[3] - 2.0 * layout.metrics.pane_pad_y) / layout.metrics.cell_h)

					if cur_r >= 0 && cur_r < rows_visible {
						cur_shape: Cursor_Shape = .Block
						switch pane.session.term.parser.cursor.shape {
						case .Block:     cur_shape = .Block
						case .Beam:      cur_shape = .Beam
						case .Underline: cur_shape = .Underline
						}

						cur_rect := cursor_compute_rect(cur_c, cur_r, pane.rect, layout.metrics.cell_w, layout.metrics.cell_h, layout.metrics.pane_pad_x, layout.metrics.pane_pad_y, cur_shape)

						// Clip cursor to pane bounds
						if cur_rect[0] + cur_rect[2] <= pane.rect[0] + pane.rect[2] &&
						   cur_rect[1] + cur_rect[3] <= pane.rect[1] + pane.rect[3] {
							opacity: f32 = 1.0
							if pane.session.term.parser.cursor.blinking {
								opacity = cursor_compute_opacity(time_elapsed, pane.is_focused)
							} else if !pane.is_focused {
								opacity = 0.50
							}
							cur_col: [4]f32 = {COLOR_CURSOR_BLOCK[0], COLOR_CURSOR_BLOCK[1], COLOR_CURSOR_BLOCK[2], opacity}
							if pane.is_focused {
								chrome_dl.ui_draw_rounded_rect(&cv.draw_list, cur_rect, cur_col, 2.0 * layout.metrics.scale)
							} else {
								chrome_dl.ui_draw_border(&cv.draw_list, cur_rect, {0.60, 0.65, 0.75, 0.60}, 2.0 * layout.metrics.scale)
							}
						}
					}
				}

				// 2b. Draw scrollback indicator thumb if scrolled into history
				if pane.session.term.grid.history_count > 0 && pane.session.scroll_offset > 0 {
					hist := f32(pane.session.term.grid.history_count)
					off := f32(pane.session.scroll_offset)
					track_h := pane.rect[3] - 16.0
					rows_vis := (pane.rect[3] - 2.0 * layout.metrics.pane_pad_y) / layout.metrics.cell_h
					thumb_h := max(20.0, track_h * (rows_vis / (hist + rows_vis)))
					thumb_y := pane.rect[1] + 8.0 + (track_h - thumb_h) * (1.0 - (off / hist))
					thumb_x := pane.rect[0] + pane.rect[2] - 5.0
					chrome_dl.ui_draw_rounded_rect(&cv.draw_list, {thumb_x, thumb_y, 3.0, thumb_h}, {0.6, 0.7, 0.9, 0.45}, 1.5)
				}
			}
		}
	}

	// 3. Render Modern Integrated Top Bar & Tabs
	if layout != nil && tabs != nil {
		bar_h := layout.metrics.tab_bar_height
		scale := layout.metrics.scale

		tab_h: f32 = 22.0 * scale
		tab_y := (bar_h - tab_h) * 0.5
		tabs_x := layout.metrics.traffic_clearance + 6.0 * scale
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
				text_y := tab_y + (tab_h - 14.0 * scale) * 0.5
				chrome_dl.ui_draw_text(&cv.draw_list, {text_x, text_y, text_max_w, 14.0 * scale}, tab_title, txt_col)
			}

			if has_close {
				close_col: [4]f32 = {0.75, 0.80, 0.90, 0.85} if is_active else {0.40, 0.45, 0.55, 0.45}
				close_x := tab_item_x + tab_w - 18.0 * scale
				close_y := tab_y + (tab_h - 13.0 * scale) * 0.5
				chrome_dl.ui_draw_text(&cv.draw_list, {close_x, close_y, 10.0 * scale, 13.0 * scale}, "x", close_col)
			}
		}

		// New Tab Button [+]
		if btn_plus_x > tabs_x {
			plus_rect: [4]f32 = {btn_plus_x, tab_y, btn_w, tab_h}
			plus_bg: [4]f32 = {0.11, 0.13, 0.17, 0.50}
			chrome_dl.ui_draw_rounded_rect(&cv.draw_list, plus_rect, plus_bg, capsule_radius)

			// Plus icon
			icon_col: [4]f32 = {0.70, 0.75, 0.85, 0.75}
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
			is_ov_open := (tab_switcher != nil && tab_switcher.visible)
			ov_bg: [4]f32 = {0.18, 0.22, 0.30, 0.90} if is_ov_open else {0.11, 0.13, 0.17, 0.50}
			chrome_dl.ui_draw_rounded_rect(&cv.draw_list, ov_rect, ov_bg, capsule_radius)

			// Grid icon [⊞] (four small squares)
			sq_s: f32 = 3.5 * scale
			sq_gap: f32 = 1.5 * scale
			top_left_x := btn_ov_x + (btn_w - (sq_s * 2.0 + sq_gap)) * 0.5
			top_left_y := tab_y + (tab_h - (sq_s * 2.0 + sq_gap)) * 0.5
			icon_col: [4]f32 = {0.80, 0.88, 1.0, 0.90} if is_ov_open else {0.70, 0.75, 0.85, 0.75}

			chrome_dl.ui_draw_rounded_rect(&cv.draw_list, {top_left_x, top_left_y, sq_s, sq_s}, icon_col, 0.8 * scale)
			chrome_dl.ui_draw_rounded_rect(&cv.draw_list, {top_left_x + sq_s + sq_gap, top_left_y, sq_s, sq_s}, icon_col, 0.8 * scale)
			chrome_dl.ui_draw_rounded_rect(&cv.draw_list, {top_left_x, top_left_y + sq_s + sq_gap, sq_s, sq_s}, icon_col, 0.8 * scale)
			chrome_dl.ui_draw_rounded_rect(&cv.draw_list, {top_left_x + sq_s + sq_gap, top_left_y + sq_s + sq_gap, sq_s, sq_s}, icon_col, 0.8 * scale)
		}
	}

	// 4. Spotlight Command Center Overlay
	if cmd_center != nil && cmd_center.visible {
		command_center_emit_draw_list(cmd_center, &cv.draw_list, layout.screen_w, layout.screen_h, layout.metrics.scale)
	}

	// 5. Tab Overview & Switcher Overlay (Top Layer)
	if tab_switcher != nil && tab_switcher.visible {
		tab_switcher_emit_draw_list(tab_switcher, tabs, &cv.draw_list, layout.screen_w, layout.screen_h, layout.metrics.scale)
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
	tab_switcher: ^Tab_Switcher_State,
	cursor_state: ^Cursor_State,
	time_elapsed: f32,
	target_view: contract.Gpu_TextureView,
) {
	if cv == nil || rawptr(target_view) == nil do return
	_ = chrome_view_build_draw_list(cv, layout, tabs, mux, cmd_center, tab_switcher, cursor_state, time_elapsed)
	_ = chrome_render.chrome_renderer_render(&cv.rend, &cv.draw_list, target_view)
}
