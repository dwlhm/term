package term

// Spotlight / Command Palette & Tab Overview Modal Component
// Part of Tier 3 Application Shell (src/app/term/*).
// Invariant: Steady-state zero heap allocations. Decoupled modal rendering via Ui_Draw_List.

import "core:fmt"
import "core:strings"
import "vendor:sdl3"

import chrome_dl "../../core/chrome/draw_list"
import tabs_feat "../../features/tabs"

COMMAND_CENTER_MAX_FILTERED :: 128
COMMAND_CENTER_VISIBLE_CAP  :: 8

Command_Center_Mode :: enum {
	Commands,
	Tabs,
}

Command_Center_Result :: struct {
	action:     Action_Id,
	target_tab: int,
	handled:    bool,
}

Command_Center_State :: struct {
	visible:          bool,
	mode:             Command_Center_Mode,
	query_buf:        [128]u8,
	query_len:        int,
	selected_idx:     int,
	scroll_offset:    int,
	accum_wheel:      f32,
	filtered_actions: [COMMAND_CENTER_MAX_FILTERED]Action_Id,
	filtered_tabs:    [COMMAND_CENTER_MAX_FILTERED]int,
	filtered_count:   int,
	modal_rect:       [4]f32,
	item_h:           f32,
	items_start_y:    f32,
}

command_center_init :: proc(cc: ^Command_Center_State) {
	if cc == nil do return
	cc.visible = false
	cc.mode = .Commands
	cc.query_len = 0
	cc.selected_idx = 0
	cc.scroll_offset = 0
	cc.accum_wheel = 0.0
	cc.filtered_count = 0
}

command_center_open :: proc(cc: ^Command_Center_State, mode: Command_Center_Mode, tabs: ^tabs_feat.Tabs_Manager = nil) {
	if cc == nil do return
	cc.visible = true
	cc.mode = mode
	cc.query_len = 0
	cc.selected_idx = 0
	cc.scroll_offset = 0
	cc.accum_wheel = 0.0
	command_center_filter(cc, tabs)

	if mode == .Tabs && tabs != nil && tabs.model.active_idx >= 0 {
		for i in 0..<cc.filtered_count {
			if cc.filtered_tabs[i] == tabs.model.active_idx {
				cc.selected_idx = i
				if cc.selected_idx >= COMMAND_CENTER_VISIBLE_CAP {
					cc.scroll_offset = cc.selected_idx - (COMMAND_CENTER_VISIBLE_CAP - 1)
				}
				break
			}
		}
	}
}

command_center_toggle :: proc(cc: ^Command_Center_State, mode: Command_Center_Mode = .Commands, tabs: ^tabs_feat.Tabs_Manager = nil) {
	if cc == nil do return
	if cc.visible && cc.mode == mode {
		cc.visible = false
	} else {
		command_center_open(cc, mode, tabs)
	}
}

command_center_close :: proc(cc: ^Command_Center_State) {
	if cc == nil do return
	cc.visible = false
}

command_center_filter :: proc(cc: ^Command_Center_State, tabs: ^tabs_feat.Tabs_Manager = nil) {
	if cc == nil do return
	q := strings.to_lower(string(cc.query_buf[:cc.query_len]), context.temp_allocator)
	cc.filtered_count = 0

	switch cc.mode {
	case .Commands:
		for m in ACTION_CATALOG {
			if cc.filtered_count >= COMMAND_CENTER_MAX_FILTERED do break
			if m.id == .Command_Center_Toggle do continue

			title_lower := strings.to_lower(m.title, context.temp_allocator)
			desc_lower := strings.to_lower(m.description, context.temp_allocator)
			if len(q) == 0 || strings.contains(title_lower, q) || strings.contains(desc_lower, q) {
				cc.filtered_actions[cc.filtered_count] = m.id
				cc.filtered_count += 1
			}
		}

	case .Tabs:
		if tabs != nil {
			for i in 0..<len(tabs.entries) {
				if cc.filtered_count >= COMMAND_CENTER_MAX_FILTERED do break

				title := string(tabs.entries[i].title_buf[:tabs.entries[i].title_len]) if tabs.entries[i].title_len > 0 else "Shell"
				title_lower := strings.to_lower(title, context.temp_allocator)
				idx_str := fmt.tprintf("%d", i + 1)
				if len(q) == 0 || strings.contains(title_lower, q) || strings.contains(idx_str, q) {
					cc.filtered_tabs[cc.filtered_count] = i
					cc.filtered_count += 1
				}
			}
		}
	}

	max_scroll := max(0, cc.filtered_count - COMMAND_CENTER_VISIBLE_CAP)
	cc.scroll_offset = clamp(cc.scroll_offset, 0, max_scroll)
	if cc.selected_idx >= cc.filtered_count {
		cc.selected_idx = max(0, cc.filtered_count - 1)
	}
}

command_center_handle_wheel :: proc(cc: ^Command_Center_State, dy: f32) {
	if cc == nil || !cc.visible || cc.filtered_count <= COMMAND_CENTER_VISIBLE_CAP do return
	max_scroll := max(0, cc.filtered_count - COMMAND_CENTER_VISIBLE_CAP)

	cc.accum_wheel += dy
	if cc.accum_wheel >= 1.0 {
		step := int(cc.accum_wheel)
		cc.accum_wheel -= f32(step)
		cc.scroll_offset = max(0, cc.scroll_offset - step)
	} else if cc.accum_wheel <= -1.0 {
		step := int(-cc.accum_wheel)
		cc.accum_wheel += f32(step)
		cc.scroll_offset = min(max_scroll, cc.scroll_offset + step)
	}
}

command_center_handle_key :: proc(cc: ^Command_Center_State, key: sdl3.Keycode, tabs: ^tabs_feat.Tabs_Manager = nil) -> Command_Center_Result {
	if cc == nil || !cc.visible do return {handled = false}

	switch key {
	case sdl3.K_ESCAPE:
		cc.visible = false
		return {handled = true}

	case sdl3.K_DOWN:
		if cc.filtered_count > 0 {
			cc.selected_idx = (cc.selected_idx + 1) % cc.filtered_count
			if cc.selected_idx >= cc.scroll_offset + COMMAND_CENTER_VISIBLE_CAP {
				cc.scroll_offset = cc.selected_idx - (COMMAND_CENTER_VISIBLE_CAP - 1)
			} else if cc.selected_idx < cc.scroll_offset {
				cc.scroll_offset = cc.selected_idx
			}
		}
		return {handled = true}

	case sdl3.K_UP:
		if cc.filtered_count > 0 {
			cc.selected_idx = (cc.selected_idx - 1 + cc.filtered_count) % cc.filtered_count
			if cc.selected_idx < cc.scroll_offset {
				cc.scroll_offset = cc.selected_idx
			} else if cc.selected_idx >= cc.scroll_offset + COMMAND_CENTER_VISIBLE_CAP {
				cc.scroll_offset = cc.selected_idx - (COMMAND_CENTER_VISIBLE_CAP - 1)
			}
		}
		return {handled = true}

	case sdl3.K_RETURN, sdl3.K_KP_ENTER:
		if cc.filtered_count > 0 && cc.selected_idx < cc.filtered_count {
			cc.visible = false
			switch cc.mode {
			case .Commands:
				return {action = cc.filtered_actions[cc.selected_idx], handled = true}
			case .Tabs:
				return {target_tab = cc.filtered_tabs[cc.selected_idx], handled = true}
			}
		}
		cc.visible = false
		return {handled = true}

	case sdl3.K_BACKSPACE:
		if cc.query_len > 0 {
			cc.query_len -= 1
			command_center_filter(cc, tabs)
		}
		return {handled = true}
	}

	return {handled = false}
}

command_center_handle_text :: proc(cc: ^Command_Center_State, text: string, tabs: ^tabs_feat.Tabs_Manager = nil) {
	if cc == nil || !cc.visible do return
	for ch in text {
		if cc.query_len < len(cc.query_buf) - 1 && ch >= 32 && ch <= 126 {
			cc.query_buf[cc.query_len] = u8(ch)
			cc.query_len += 1
		}
	}
	command_center_filter(cc, tabs)
}

command_center_handle_click :: proc(cc: ^Command_Center_State, mx, my: f32) -> Command_Center_Result {
	if cc == nil || !cc.visible do return {handled = false}

	// Click outside modal bounds dismisses it
	if mx < cc.modal_rect[0] || mx > cc.modal_rect[0] + cc.modal_rect[2] ||
	   my < cc.modal_rect[1] || my > cc.modal_rect[1] + cc.modal_rect[3] {
		cc.visible = false
		return {handled = true}
	}

	// Click on list item
	if my >= cc.items_start_y && cc.item_h > 0 {
		rel_y := my - cc.items_start_y
		row_idx := int(rel_y / cc.item_h)
		item_idx := cc.scroll_offset + row_idx
		if item_idx >= 0 && item_idx < cc.filtered_count {
			cc.visible = false
			switch cc.mode {
			case .Commands:
				return {action = cc.filtered_actions[item_idx], handled = true}
			case .Tabs:
				return {target_tab = cc.filtered_tabs[item_idx], handled = true}
			}
		}
	}

	return {handled = true}
}

command_center_emit_draw_list :: proc(
	cc: ^Command_Center_State,
	tabs: ^tabs_feat.Tabs_Manager,
	dl: ^chrome_dl.Ui_Draw_List,
	screen_w, screen_h: f32,
	scale: f32 = 1.0,
) {
	if cc == nil || dl == nil || !cc.visible do return

	s := max(1.0, scale)

	// Backdrop dimmer
	chrome_dl.ui_draw_rect(dl, {0, 0, screen_w, screen_h}, {0.0, 0.0, 0.0, 0.40})

	modal_w := 540.0 * s
	cc.item_h = 36.0 * s
	visible_count := min(COMMAND_CENTER_VISIBLE_CAP, cc.filtered_count)
	modal_h := (56.0 + f32(max(1, visible_count)) * 36.0 + 12.0) * s

	modal_x := (screen_w - modal_w) * 0.5
	modal_y := max(60.0 * s, screen_h * 0.15)
	cc.modal_rect = {modal_x, modal_y, modal_w, modal_h}

	// Modal shadow & body
	chrome_dl.ui_draw_shadow(dl, {modal_x - 6 * s, modal_y - 4 * s, modal_w + 12 * s, modal_h + 12 * s}, {0.0, 0.0, 0.0, 0.65}, 16.0 * s)
	chrome_dl.ui_draw_rounded_rect(dl, cc.modal_rect, {0.11, 0.13, 0.17, 0.98}, BORDER_RADIUS * s)
	chrome_dl.ui_draw_border(dl, cc.modal_rect, {0.26, 0.32, 0.44, 0.90}, BORDER_RADIUS * s)

	// Search bar prompt
	prompt_icon := ">" if cc.mode == .Commands else "⊞"
	chrome_dl.ui_draw_text(dl, {modal_x + 18 * s, modal_y + 16 * s, 20 * s, 24 * s}, prompt_icon, {0.35, 0.65, 1.0, 1.0})

	placeholder := "Type a command or search action..." if cc.mode == .Commands else "Switch tab or type to filter..."
	query_str := string(cc.query_buf[:cc.query_len]) if cc.query_len > 0 else placeholder
	query_col: [4]f32 = {0.95, 0.96, 0.98, 1.0} if cc.query_len > 0 else {0.45, 0.50, 0.60, 0.85}
	chrome_dl.ui_draw_text(dl, {modal_x + 38 * s, modal_y + 16 * s, modal_w - 60 * s, 24 * s}, query_str, query_col)

	// Divider
	chrome_dl.ui_draw_rect(dl, {modal_x + 12 * s, modal_y + 48 * s, modal_w - 24 * s, 1 * s}, {0.18, 0.22, 0.30, 0.85})

	// Items list
	cc.items_start_y = modal_y + 54.0 * s
	if cc.filtered_count == 0 {
		empty_msg := "No matching commands found" if cc.mode == .Commands else "No matching tabs found"
		chrome_dl.ui_draw_text(dl, {modal_x + 24 * s, cc.items_start_y + 8 * s, modal_w - 48 * s, 20 * s}, empty_msg, {0.55, 0.58, 0.65, 0.7})
		return
	}

	draw_count := min(COMMAND_CENTER_VISIBLE_CAP, cc.filtered_count - cc.scroll_offset)
	for r in 0..<draw_count {
		item_idx := cc.scroll_offset + r
		row_y := cc.items_start_y + f32(r) * cc.item_h
		is_sel := (item_idx == cc.selected_idx)
		row_rect: [4]f32 = {modal_x + 8 * s, row_y, modal_w - 16 * s, cc.item_h - 4.0 * s}

		switch cc.mode {
		case .Commands:
			act := cc.filtered_actions[item_idx]
			meta, ok := action_get_metadata(act)
			if !ok do continue

			if is_sel {
				chrome_dl.ui_draw_rounded_rect(dl, row_rect, {0.20, 0.36, 0.65, 0.85}, 6.0 * s)
			}

			title_col: [4]f32 = {1.0, 1.0, 1.0, 1.0} if is_sel else {0.85, 0.88, 0.92, 0.95}
			chrome_dl.ui_draw_text(dl, {row_rect[0] + 14.0 * s, row_rect[1] + 6.0 * s, row_rect[2] - 120.0 * s, 18.0 * s}, meta.title, title_col)

			if len(meta.shortcut) > 0 {
				badge_col: [4]f32 = {0.75, 0.88, 1.0, 1.0} if is_sel else {0.50, 0.56, 0.66, 0.90}
				badge_x := row_rect[0] + row_rect[2] - 90.0 * s
				chrome_dl.ui_draw_text(dl, {badge_x, row_rect[1] + 6.0 * s, 80.0 * s, 18.0 * s}, meta.shortcut, badge_col)
			}

		case .Tabs:
			tab_idx := cc.filtered_tabs[item_idx]
			is_active := (tabs != nil && tab_idx == tabs.model.active_idx)

			if is_sel {
				chrome_dl.ui_draw_rounded_rect(dl, row_rect, {0.20, 0.36, 0.65, 0.85}, 6.0 * s)
			} else if is_active {
				chrome_dl.ui_draw_rounded_rect(dl, row_rect, {0.15, 0.19, 0.26, 0.60}, 6.0 * s)
			}

			badge_str := fmt.tprintf("%d.", tab_idx + 1)
			badge_col: [4]f32 = {0.45, 0.65, 0.95, 1.0} if is_sel else {0.50, 0.55, 0.65, 0.85}
			chrome_dl.ui_draw_text(dl, {row_rect[0] + 12.0 * s, row_rect[1] + 6.0 * s, 24.0 * s, 18.0 * s}, badge_str, badge_col)

			tab_title := "Shell"
			if tabs != nil && tab_idx < len(tabs.entries) {
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
		}
	}

	// Scrollbar indicator
	if cc.filtered_count > COMMAND_CENTER_VISIBLE_CAP {
		track_y := cc.items_start_y
		track_h := f32(COMMAND_CENTER_VISIBLE_CAP) * cc.item_h
		thumb_h := max(24.0 * s, track_h * (f32(COMMAND_CENTER_VISIBLE_CAP) / f32(cc.filtered_count)))
		max_scroll := f32(cc.filtered_count - COMMAND_CENTER_VISIBLE_CAP)
		scroll_ratio := f32(cc.scroll_offset) / max_scroll if max_scroll > 0 else 0.0
		thumb_y := track_y + (track_h - thumb_h) * scroll_ratio
		thumb_x := modal_x + modal_w - 6.0 * s
		chrome_dl.ui_draw_rounded_rect(dl, {thumb_x, thumb_y, 3.0 * s, thumb_h}, {0.55, 0.65, 0.85, 0.50}, 1.5 * s)
	}
}
