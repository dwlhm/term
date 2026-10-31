package term

// Command Center — rendering.

import "core:fmt"

import chrome_dl "../../core/chrome/draw_list"
import tabs_feat "../../features/tabs"
import sess_feat "../../features/session"

command_center_emit_draw_list :: proc(cc: ^Command_Center_State, src: Command_Center_Sources, dl: ^chrome_dl.Ui_Draw_List, layout: ^Layout_State) {
	if cc == nil || dl == nil || layout == nil || !cc.visible do return

	s := max(1.0, layout.metrics.scale)
	screen_w := layout.screen_w
	screen_h := layout.screen_h

	// Backdrop dimmer
	chrome_dl.ui_draw_rect(dl, {0, 0, screen_w, screen_h}, {0.0, 0.0, 0.0, 0.40})

	modal_w := 540.0 * s

	// compute visible row heights
	vis := min(COMMAND_CENTER_VISIBLE_CAP, cc.row_count - cc.scroll_offset)
	if vis < 0 do vis = 0
	sum_h: f32 = 0
	for r in 0..<vis {
		idx := cc.scroll_offset + r
		if idx < 0 || idx >= cc.row_count do break
		if cc.rows[idx].kind == .Header {
			sum_h += 26.0 * s
		} else {
			sum_h += 36.0 * s
		}
	}
	if vis == 0 {
		sum_h = 36.0 * s
	}
	modal_h := 66.0*s + sum_h + 12.0*s

	modal_x := (screen_w - modal_w) * 0.5
	modal_y := max(60.0 * s, screen_h * 0.15)
	cc.modal_rect = {modal_x, modal_y, modal_w, modal_h}

	// Modal shadow & body
	chrome_dl.ui_draw_shadow(dl, {modal_x - 6 * s, modal_y - 4 * s, modal_w + 12 * s, modal_h + 12 * s}, {0.0, 0.0, 0.0, 0.65}, 16.0 * s)
	chrome_dl.ui_draw_rounded_rect(dl, cc.modal_rect, {0.11, 0.13, 0.17, 0.98}, BORDER_RADIUS * s)
	chrome_dl.ui_draw_border(dl, cc.modal_rect, {0.26, 0.32, 0.44, 0.90}, BORDER_RADIUS * s)

	// Chips row (above search field)
	chip_y := modal_y + 8.0 * s
	chip_h := 20.0 * s
	chip_x := modal_x + 18.0 * s
	chip_labels := [3]string{"Commands", "Tabs", "Sessions"}
	chip_modes := [3]Command_Center_Mode{.Commands, .Tabs, .Sessions}
	for mi in 0..<3 {
		label := chip_labels[mi]
		mode := chip_modes[mi]
		text_h := 14.0 * s
		tw := chrome_text_width(layout.metrics, label, text_h)
		cw := tw + 16.0 * s
		cc.chip_rects[mode] = {chip_x, chip_y, cw, chip_h}
		col: [4]f32
		if cc.mode == mode {
			col = {0.35, 0.65, 1.0, 1.0}
		} else {
			col = {0.55, 0.60, 0.70, 0.85}
		}
		chrome_dl.ui_draw_text(dl, {chip_x + 8.0 * s, chip_y + 3.0 * s, tw, text_h}, label, col)
		chip_x += cw + 8.0 * s
	}

	// Search bar prompt
	prompt_icon := ">" if cc.mode == .Commands else "⊞"
	chrome_dl.ui_draw_text(dl, {modal_x + 18.0 * s, modal_y + 32.0 * s, 20.0 * s, 24.0 * s}, prompt_icon, {0.35, 0.65, 1.0, 1.0})

	placeholder := "Type a command or search action..." if cc.mode == .Commands else "Switch tab or type to filter..."
	query_str := text_input_as_string(&cc.input)
	has_query := len(query_str) > 0
	label := query_str if has_query else placeholder
	query_col: [4]f32 = {0.95, 0.96, 0.98, 1.0} if has_query else {0.45, 0.50, 0.60, 0.85}

	input_x := modal_x + 38.0 * s
	input_y := modal_y + 32.0 * s
	input_w := modal_w - 60.0 * s
	input_h := 24.0 * s
	cc.search_rect = {input_x, input_y, input_w, input_h}

	if has_query {
		text_h := input_h
		if s_idx, e_idx, sel_active := text_input_selection_range(&cc.input); sel_active {
			prefix := query_str[:s_idx]
			sel_x := input_x + chrome_text_width(layout.metrics, prefix, text_h)
			sel_w := chrome_text_width(layout.metrics, query_str[s_idx:e_idx], text_h)
			chrome_dl.ui_draw_rounded_rect(dl, {sel_x, input_y + 2.0 * s, sel_w, input_h - 4.0 * s}, {0.25, 0.45, 0.85, 0.45}, 2.0 * s)
		} else {
			prefix := query_str[:cc.input.cursor]
			cur_x := input_x + chrome_text_width(layout.metrics, prefix, text_h)
			chrome_dl.ui_draw_rect(dl, {cur_x, input_y + 4.0 * s, 1.5 * s, input_h - 8.0 * s}, {0.35, 0.65, 1.0, 0.90})
		}
	}
	chrome_dl.ui_draw_text(dl, {input_x, input_y, input_w, input_h}, label, query_col)

	// Divider
	chrome_dl.ui_draw_rect(dl, {modal_x + 12.0 * s, modal_y + 60.0 * s, modal_w - 24.0 * s, 1.0 * s}, {0.18, 0.22, 0.30, 0.85})

	// Items list
	items_start_y := modal_y + 66.0 * s
	if cc.row_count == 0 {
		empty_msg := "No matching commands found" if cc.mode == .Commands else ("No matching tabs found" if cc.mode == .Tabs else "No matching sessions found")
		chrome_dl.ui_draw_text(dl, {modal_x + 24.0 * s, items_start_y + 8.0 * s, modal_w - 48.0 * s, 20.0 * s}, empty_msg, {0.55, 0.58, 0.65, 0.7})
		// scrollbar none
		return
	}

	cc.row_rect_count = 0
	y := items_start_y
	draw_count := min(COMMAND_CENTER_VISIBLE_CAP, cc.row_count - cc.scroll_offset)
	for r in 0..<draw_count {
		idx := cc.scroll_offset + r
		if idx < 0 || idx >= cc.row_count do break
		row := cc.rows[idx]
		row_h: f32 = 26.0 * s if row.kind == .Header else 36.0 * s
		row_rect: [4]f32 = {modal_x + 8.0 * s, y, modal_w - 16.0 * s, row_h - 4.0 * s}

		if cc.row_rect_count < COMMAND_CENTER_VISIBLE_CAP {
			cc.row_rects[cc.row_rect_count] = row_rect
			cc.row_rect_idx[cc.row_rect_count] = idx
			cc.row_rect_count += 1
		}

		is_sel := idx == cc.selected_idx

		if row.kind == .Header {
			title := ACTION_CATEGORY_TITLES[row.category]
			chrome_dl.ui_draw_text(dl, {row_rect[0] + 14.0 * s, row_rect[1] + 4.0 * s, row_rect[2] - 28.0 * s, 18.0 * s}, title, {0.50, 0.55, 0.65, 0.85})
		} else {
			if is_sel {
				chrome_dl.ui_draw_rounded_rect(dl, row_rect, {0.20, 0.36, 0.65, 0.85}, 6.0 * s)
			}
			switch row.kind {
			case .Action:
				meta, ok := action_get_metadata(row.action)
				if ok {
					title_col: [4]f32 = {1.0, 1.0, 1.0, 1.0} if is_sel else {0.85, 0.88, 0.92, 0.95}
					chrome_dl.ui_draw_text(dl, {row_rect[0] + 14.0 * s, row_rect[1] + 6.0 * s, row_rect[2] - 120.0 * s, 18.0 * s}, meta.title, title_col)
					if len(meta.shortcut) > 0 {
						badge_col: [4]f32 = {0.75, 0.88, 1.0, 1.0} if is_sel else {0.50, 0.56, 0.66, 0.90}
						badge_x := row_rect[0] + row_rect[2] - 90.0 * s
						chrome_dl.ui_draw_text(dl, {badge_x, row_rect[1] + 6.0 * s, 80.0 * s, 18.0 * s}, meta.shortcut, badge_col)
					}
				}
			case .Tab:
				tabs := src.tabs
				tab_idx := row.tab_index
				is_active := tabs != nil && tab_idx == tabs.model.active_idx

				badge_str := fmt.tprintf("%d.", tab_idx + 1)
				badge_col: [4]f32 = {0.45, 0.65, 0.95, 1.0} if is_sel else {0.50, 0.55, 0.65, 0.85}
				chrome_dl.ui_draw_text(dl, {row_rect[0] + 12.0 * s, row_rect[1] + 6.0 * s, 24.0 * s, 18.0 * s}, badge_str, badge_col)

				tab_title := "Shell"
				if tabs != nil && tab_idx >= 0 && tab_idx < len(tabs.entries) {
					if tabs.entries[tab_idx].title_len > 0 {
						tab_title = string(tabs.entries[tab_idx].title_buf[:tabs.entries[tab_idx].title_len])
					}
				}
				title_col: [4]f32 = {1.0, 1.0, 1.0, 1.0} if is_sel else ({0.90, 0.92, 0.96, 1.0} if is_active else {0.70, 0.74, 0.80, 0.90})
				chrome_dl.ui_draw_text(dl, {row_rect[0] + 40.0 * s, row_rect[1] + 6.0 * s, row_rect[2] - 120.0 * s, 18.0 * s}, tab_title, title_col)

				if is_active {
					tag_col: [4]f32 = {0.35, 0.75, 0.55, 0.90}
					tag_x := row_rect[0] + row_rect[2] - 65.0 * s
					chrome_dl.ui_draw_text(dl, {tag_x, row_rect[1] + 6.0 * s, 55.0 * s, 18.0 * s}, "active", tag_col)
				}
			case .Session:
				sessions := src.sessions
				entry := sess_feat.session_registry_find(sessions, row.session_id)
				label := "shell"
				state_str := "idle"
				if entry != nil {
					t := sess_feat.session_get_title(entry.session)
					if len(t) > 0 do label = t
					switch entry.state {
					case .Busy:   state_str = "busy"
					case .Idle:   state_str = "idle"
					case .Exited: state_str = "exited"
					}
				}
				text := fmt.tprintf("%d  %s", row.session_id, label)
				title_col: [4]f32 = {1.0, 1.0, 1.0, 1.0} if is_sel else {0.85, 0.88, 0.92, 0.95}
				chrome_dl.ui_draw_text(dl, {row_rect[0] + 14.0 * s, row_rect[1] + 6.0 * s, row_rect[2] - 80.0 * s, 18.0 * s}, text, title_col)
				state_col: [4]f32 = {0.95, 0.45, 0.48, 0.90} if state_str == "exited" else ({0.35, 0.75, 0.55, 0.90} if state_str == "busy" else {0.50, 0.55, 0.65, 0.85})
				chrome_dl.ui_draw_text(dl, {row_rect[0] + row_rect[2] - 70.0 * s, row_rect[1] + 6.0 * s, 60.0 * s, 18.0 * s}, state_str, state_col)
			case .Header:
			}
		}
		y += row_h
	}

	// Scrollbar
	if cc.row_count > COMMAND_CENTER_VISIBLE_CAP {
		track_y := items_start_y
		track_h := sum_h
		if track_h <= 0 do track_h = f32(COMMAND_CENTER_VISIBLE_CAP) * 36.0 * s
		thumb_h := max(24.0 * s, track_h * (f32(COMMAND_CENTER_VISIBLE_CAP) / f32(cc.row_count)))
		max_scroll := f32(cc.row_count - COMMAND_CENTER_VISIBLE_CAP)
		scroll_ratio := f32(cc.scroll_offset) / max_scroll if max_scroll > 0 else 0.0
		thumb_y := track_y + (track_h - thumb_h) * scroll_ratio
		thumb_x := modal_x + modal_w - 6.0 * s
		chrome_dl.ui_draw_rounded_rect(dl, {thumb_x, thumb_y, 3.0 * s, thumb_h}, {0.55, 0.65, 0.85, 0.50}, 1.5 * s)
	}
}
