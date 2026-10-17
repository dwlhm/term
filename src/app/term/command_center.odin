package term

// Spotlight / Command Palette Overlay, Fuzzy Filter & Execution Engine
// Part of Tier 3 Application Shell (src/app/term/*).
// Invariant: Decoupled modal rendering via Ui_Draw_List.

import "core:strings"
import "vendor:sdl3"

import chrome_dl "../../core/chrome/draw_list"

COMMAND_CENTER_MAX_FILTERED :: 16

Command_Center_State :: struct {
	visible:          bool,
	query_buf:        [128]u8,
	query_len:        int,
	selected_idx:     int,
	filtered_actions: [COMMAND_CENTER_MAX_FILTERED]Action_Id,
	filtered_count:   int,
}

command_center_init :: proc(cc: ^Command_Center_State) {
	if cc == nil do return
	cc.visible = false
	cc.query_len = 0
	cc.selected_idx = 0
	command_center_filter(cc)
}

command_center_toggle :: proc(cc: ^Command_Center_State) {
	if cc == nil do return
	cc.visible = !cc.visible
	if cc.visible {
		cc.query_len = 0
		cc.selected_idx = 0
		command_center_filter(cc)
	}
}

command_center_close :: proc(cc: ^Command_Center_State) {
	if cc == nil do return
	cc.visible = false
}

command_center_filter :: proc(cc: ^Command_Center_State) {
	if cc == nil do return
	q := strings.to_lower(string(cc.query_buf[:cc.query_len]), context.temp_allocator)

	cc.filtered_count = 0
	for m in ACTION_CATALOG {
		if cc.filtered_count >= COMMAND_CENTER_MAX_FILTERED do break

		// Don't show the command center toggle inside itself
		if m.id == .Command_Center_Toggle do continue

		title_lower := strings.to_lower(m.title, context.temp_allocator)
		if len(q) == 0 || strings.contains(title_lower, q) {
			cc.filtered_actions[cc.filtered_count] = m.id
			cc.filtered_count += 1
		}
	}

	if cc.selected_idx >= cc.filtered_count {
		cc.selected_idx = max(0, cc.filtered_count - 1)
	}
}

command_center_handle_key :: proc(cc: ^Command_Center_State, key: sdl3.Keycode) -> (Action_Id, bool) {
	if cc == nil || !cc.visible do return .None, false

	switch key {
	case sdl3.K_ESCAPE:
		cc.visible = false
		return .None, true
	case sdl3.K_DOWN:
		if cc.filtered_count > 0 {
			cc.selected_idx = (cc.selected_idx + 1) % cc.filtered_count
		}
		return .None, true
	case sdl3.K_UP:
		if cc.filtered_count > 0 {
			cc.selected_idx = (cc.selected_idx - 1 + cc.filtered_count) % cc.filtered_count
		}
		return .None, true
	case sdl3.K_RETURN, sdl3.K_KP_ENTER:
		if cc.filtered_count > 0 && cc.selected_idx < cc.filtered_count {
			act := cc.filtered_actions[cc.selected_idx]
			cc.visible = false
			return act, true
		}
		cc.visible = false
		return .None, true
	case sdl3.K_BACKSPACE:
		if cc.query_len > 0 {
			cc.query_len -= 1
			command_center_filter(cc)
		}
		return .None, true
	}
	return .None, false
}

command_center_handle_text :: proc(cc: ^Command_Center_State, text: string) {
	if cc == nil || !cc.visible do return
	for ch in text {
		if cc.query_len < len(cc.query_buf) - 1 && ch >= 32 && ch <= 126 {
			cc.query_buf[cc.query_len] = u8(ch)
			cc.query_len += 1
		}
	}
	command_center_filter(cc)
}

command_center_emit_draw_list :: proc(cc: ^Command_Center_State, dl: ^chrome_dl.Ui_Draw_List, screen_w, screen_h: f32, scale: f32 = 1.0) {
	if cc == nil || dl == nil || !cc.visible do return

	s := max(1.0, scale)

	// Backdrop dimmer
	chrome_dl.ui_draw_rect(dl, {0, 0, screen_w, screen_h}, {0.0, 0.0, 0.0, 0.35})

	modal_w := 540.0 * s
	item_h  := 36.0 * s
	visible_items := min(7, cc.filtered_count)
	modal_h := (56.0 + f32(max(1, visible_items)) * 36.0 + 12.0) * s

	modal_x := (screen_w - modal_w) * 0.5
	modal_y := max(60.0 * s, screen_h * 0.15)
	modal_rect: [4]f32 = {modal_x, modal_y, modal_w, modal_h}

	// Modal shadow & body
	chrome_dl.ui_draw_shadow(dl, {modal_x - 6 * s, modal_y - 4 * s, modal_w + 12 * s, modal_h + 12 * s}, {0.0, 0.0, 0.0, 0.65}, 16.0 * s)
	chrome_dl.ui_draw_rounded_rect(dl, modal_rect, {0.11, 0.13, 0.17, 0.98}, BORDER_RADIUS * s)
	chrome_dl.ui_draw_border(dl, modal_rect, {0.26, 0.32, 0.44, 0.90}, BORDER_RADIUS * s)

	// Search bar prompt
	chrome_dl.ui_draw_text(dl, {modal_x + 18 * s, modal_y + 16 * s, 20 * s, 24 * s}, ">", {0.35, 0.65, 1.0, 1.0})
	query_str := string(cc.query_buf[:cc.query_len]) if cc.query_len > 0 else "Type a command or search action..."
	query_col: [4]f32 = {0.95, 0.96, 0.98, 1.0} if cc.query_len > 0 else {0.45, 0.50, 0.60, 0.85}
	chrome_dl.ui_draw_text(dl, {modal_x + 38 * s, modal_y + 16 * s, modal_w - 60 * s, 24 * s}, query_str, query_col)

	// Divider
	chrome_dl.ui_draw_rect(dl, {modal_x + 12 * s, modal_y + 48 * s, modal_w - 24 * s, 1 * s}, {0.18, 0.22, 0.30, 0.85})

	// Items list
	start_y := modal_y + 54.0 * s
	if cc.filtered_count == 0 {
		chrome_dl.ui_draw_text(dl, {modal_x + 24 * s, start_y + 8 * s, modal_w - 48 * s, 20 * s}, "No matching commands found", {0.55, 0.58, 0.65, 0.7})
		return
	}

	for i in 0..<visible_items {
		act := cc.filtered_actions[i]
		meta, ok := action_get_metadata(act)
		if !ok do continue

		row_y := start_y + f32(i) * item_h
		is_sel := (i == cc.selected_idx)
		row_rect: [4]f32 = {modal_x + 8 * s, row_y, modal_w - 16 * s, item_h - 4.0 * s}

		if is_sel {
			chrome_dl.ui_draw_rounded_rect(dl, row_rect, {0.20, 0.36, 0.65, 0.85}, 6.0 * s)
		}

		// Action Title
		title_col: [4]f32 = {1.0, 1.0, 1.0, 1.0} if is_sel else {0.85, 0.88, 0.92, 0.95}
		chrome_dl.ui_draw_text(dl, {row_rect[0] + 14.0 * s, row_rect[1] + 6.0 * s, row_rect[2] - 120.0 * s, 18.0 * s}, meta.title, title_col)

		// Shortcut Badge
		if len(meta.shortcut) > 0 {
			badge_col: [4]f32 = {0.75, 0.88, 1.0, 1.0} if is_sel else {0.50, 0.56, 0.66, 0.90}
			badge_x := row_rect[0] + row_rect[2] - 90.0 * s
			chrome_dl.ui_draw_text(dl, {badge_x, row_rect[1] + 6.0 * s, 80.0 * s, 18.0 * s}, meta.shortcut, badge_col)
		}
	}
}
