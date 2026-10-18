package term

// Tab Overview & Switcher Modal Component
// Part of Tier 3 Application Shell (src/app/term/*).
// Invariant: Steady-state zero heap allocations. Decoupled modal rendering via Ui_Draw_List.

import "core:fmt"
import "core:strings"
import "vendor:sdl3"

import chrome_dl "../../core/chrome/draw_list"
import tabs_feat "../../features/tabs"

TAB_SWITCHER_MAX_ITEMS   :: 128
TAB_SWITCHER_VISIBLE_CAP :: 8

Tab_Switcher_State :: struct {
	visible:        bool,
	query_buf:      [64]u8,
	query_len:      int,
	selected_idx:   int,
	scroll_offset:  int,
	accum_wheel:    f32,
	filtered_tabs:  [TAB_SWITCHER_MAX_ITEMS]int,
	filtered_count: int,
	modal_rect:     [4]f32,
	item_h:         f32,
	items_start_y:  f32,
}

tab_switcher_init :: proc(ts: ^Tab_Switcher_State) {
	if ts == nil do return
	ts.visible = false
	ts.query_len = 0
	ts.selected_idx = 0
	ts.scroll_offset = 0
	ts.accum_wheel = 0.0
	ts.filtered_count = 0
}

tab_switcher_open :: proc(ts: ^Tab_Switcher_State, tabs: ^tabs_feat.Tabs_Manager) {
	if ts == nil do return
	ts.visible = true
	ts.query_len = 0
	ts.selected_idx = 0
	ts.scroll_offset = 0
	ts.accum_wheel = 0.0
	tab_switcher_filter(ts, tabs)
	if tabs != nil && tabs.model.active_idx >= 0 {
		for i in 0..<ts.filtered_count {
			if ts.filtered_tabs[i] == tabs.model.active_idx {
				ts.selected_idx = i
				if ts.selected_idx >= TAB_SWITCHER_VISIBLE_CAP {
					ts.scroll_offset = ts.selected_idx - (TAB_SWITCHER_VISIBLE_CAP - 1)
				}
				break
			}
		}
	}
}

tab_switcher_toggle :: proc(ts: ^Tab_Switcher_State, tabs: ^tabs_feat.Tabs_Manager) {
	if ts == nil do return
	if ts.visible {
		ts.visible = false
	} else {
		tab_switcher_open(ts, tabs)
	}
}

tab_switcher_close :: proc(ts: ^Tab_Switcher_State) {
	if ts == nil do return
	ts.visible = false
}

tab_switcher_filter :: proc(ts: ^Tab_Switcher_State, tabs: ^tabs_feat.Tabs_Manager) {
	if ts == nil do return
	ts.filtered_count = 0
	if tabs == nil do return

	q := strings.to_lower(string(ts.query_buf[:ts.query_len]), context.temp_allocator)

	for i in 0..<len(tabs.entries) {
		if ts.filtered_count >= TAB_SWITCHER_MAX_ITEMS do break

		title := string(tabs.entries[i].title_buf[:tabs.entries[i].title_len]) if tabs.entries[i].title_len > 0 else "Shell"
		title_lower := strings.to_lower(title, context.temp_allocator)

		idx_str := fmt.tprintf("%d", i + 1)
		if len(q) == 0 || strings.contains(title_lower, q) || strings.contains(idx_str, q) {
			ts.filtered_tabs[ts.filtered_count] = i
			ts.filtered_count += 1
		}
	}

	max_scroll := max(0, ts.filtered_count - TAB_SWITCHER_VISIBLE_CAP)
	ts.scroll_offset = clamp(ts.scroll_offset, 0, max_scroll)
	if ts.selected_idx >= ts.filtered_count {
		ts.selected_idx = max(0, ts.filtered_count - 1)
	}
}

tab_switcher_handle_wheel :: proc(ts: ^Tab_Switcher_State, dy: f32) {
	if ts == nil || !ts.visible || ts.filtered_count <= TAB_SWITCHER_VISIBLE_CAP do return
	max_scroll := max(0, ts.filtered_count - TAB_SWITCHER_VISIBLE_CAP)

	ts.accum_wheel += dy
	if ts.accum_wheel >= 1.0 {
		step := int(ts.accum_wheel)
		ts.accum_wheel -= f32(step)
		ts.scroll_offset = max(0, ts.scroll_offset - step)
	} else if ts.accum_wheel <= -1.0 {
		step := int(-ts.accum_wheel)
		ts.accum_wheel += f32(step)
		ts.scroll_offset = min(max_scroll, ts.scroll_offset + step)
	}
}

tab_switcher_handle_key :: proc(ts: ^Tab_Switcher_State, tabs: ^tabs_feat.Tabs_Manager, key: sdl3.Keycode) -> (target_tab: int, handled: bool) {
	if ts == nil || !ts.visible do return -1, false

	switch key {
	case sdl3.K_ESCAPE:
		ts.visible = false
		return -1, true
	case sdl3.K_DOWN:
		if ts.filtered_count > 0 {
			ts.selected_idx = (ts.selected_idx + 1) % ts.filtered_count
			if ts.selected_idx >= ts.scroll_offset + TAB_SWITCHER_VISIBLE_CAP {
				ts.scroll_offset = ts.selected_idx - (TAB_SWITCHER_VISIBLE_CAP - 1)
			} else if ts.selected_idx < ts.scroll_offset {
				ts.scroll_offset = ts.selected_idx
			}
		}
		return -1, true
	case sdl3.K_UP:
		if ts.filtered_count > 0 {
			ts.selected_idx = (ts.selected_idx - 1 + ts.filtered_count) % ts.filtered_count
			if ts.selected_idx < ts.scroll_offset {
				ts.scroll_offset = ts.selected_idx
			} else if ts.selected_idx >= ts.scroll_offset + TAB_SWITCHER_VISIBLE_CAP {
				ts.scroll_offset = ts.selected_idx - (TAB_SWITCHER_VISIBLE_CAP - 1)
			}
		}
		return -1, true
	case sdl3.K_RETURN, sdl3.K_KP_ENTER:
		if ts.filtered_count > 0 && ts.selected_idx < ts.filtered_count {
			target_tab = ts.filtered_tabs[ts.selected_idx]
			ts.visible = false
			return target_tab, true
		}
		ts.visible = false
		return -1, true
	case sdl3.K_BACKSPACE:
		if ts.query_len > 0 {
			ts.query_len -= 1
			tab_switcher_filter(ts, tabs)
		}
		return -1, true
	}

	return -1, false
}

tab_switcher_handle_text :: proc(ts: ^Tab_Switcher_State, tabs: ^tabs_feat.Tabs_Manager, text: string) {
	if ts == nil || !ts.visible do return
	for ch in text {
		if ts.query_len < len(ts.query_buf) - 1 && ch >= 32 && ch <= 126 {
			ts.query_buf[ts.query_len] = u8(ch)
			ts.query_len += 1
		}
	}
	tab_switcher_filter(ts, tabs)
}

tab_switcher_handle_click :: proc(ts: ^Tab_Switcher_State, mx, my: f32) -> (target_tab: int, handled: bool) {
	if ts == nil || !ts.visible do return -1, false

	// If click outside modal, dismiss
	if mx < ts.modal_rect[0] || mx > ts.modal_rect[0] + ts.modal_rect[2] ||
	   my < ts.modal_rect[1] || my > ts.modal_rect[1] + ts.modal_rect[3] {
		ts.visible = false
		return -1, true
	}

	// Click on list item
	if my >= ts.items_start_y && ts.item_h > 0 {
		rel_y := my - ts.items_start_y
		row_idx := int(rel_y / ts.item_h)
		item_idx := ts.scroll_offset + row_idx
		if item_idx >= 0 && item_idx < ts.filtered_count {
			target_tab = ts.filtered_tabs[item_idx]
			ts.visible = false
			return target_tab, true
		}
	}

	return -1, true
}

tab_switcher_emit_draw_list :: proc(ts: ^Tab_Switcher_State, tabs: ^tabs_feat.Tabs_Manager, dl: ^chrome_dl.Ui_Draw_List, screen_w, screen_h: f32, scale: f32 = 1.0) {
	if ts == nil || dl == nil || !ts.visible do return

	s := max(1.0, scale)

	// Backdrop dimmer
	chrome_dl.ui_draw_rect(dl, {0, 0, screen_w, screen_h}, {0.0, 0.0, 0.0, 0.40})

	modal_w := 520.0 * s
	ts.item_h = 36.0 * s
	visible_count := min(TAB_SWITCHER_VISIBLE_CAP, ts.filtered_count)
	modal_h := (56.0 + f32(max(1, visible_count)) * 36.0 + 12.0) * s

	modal_x := (screen_w - modal_w) * 0.5
	modal_y := max(60.0 * s, screen_h * 0.15)
	ts.modal_rect = {modal_x, modal_y, modal_w, modal_h}

	// Modal shadow & body
	chrome_dl.ui_draw_shadow(dl, {modal_x - 6 * s, modal_y - 4 * s, modal_w + 12 * s, modal_h + 12 * s}, {0.0, 0.0, 0.0, 0.65}, 16.0 * s)
	chrome_dl.ui_draw_rounded_rect(dl, ts.modal_rect, {0.11, 0.13, 0.17, 0.98}, BORDER_RADIUS * s)
	chrome_dl.ui_draw_border(dl, ts.modal_rect, {0.26, 0.32, 0.44, 0.90}, BORDER_RADIUS * s)

	// Search bar prompt
	chrome_dl.ui_draw_text(dl, {modal_x + 18 * s, modal_y + 16 * s, 20 * s, 24 * s}, "⊞", {0.35, 0.65, 1.0, 1.0})
	query_str := string(ts.query_buf[:ts.query_len]) if ts.query_len > 0 else "Switch tab or type to filter..."
	query_col: [4]f32 = {0.95, 0.96, 0.98, 1.0} if ts.query_len > 0 else {0.45, 0.50, 0.60, 0.85}
	chrome_dl.ui_draw_text(dl, {modal_x + 38 * s, modal_y + 16 * s, modal_w - 60 * s, 24 * s}, query_str, query_col)

	// Divider
	chrome_dl.ui_draw_rect(dl, {modal_x + 12 * s, modal_y + 48 * s, modal_w - 24 * s, 1 * s}, {0.18, 0.22, 0.30, 0.85})

	// Items list
	ts.items_start_y = modal_y + 54.0 * s
	if ts.filtered_count == 0 {
		chrome_dl.ui_draw_text(dl, {modal_x + 24 * s, ts.items_start_y + 8 * s, modal_w - 48 * s, 20 * s}, "No matching tabs found", {0.55, 0.58, 0.65, 0.7})
		return
	}

	draw_count := min(TAB_SWITCHER_VISIBLE_CAP, ts.filtered_count - ts.scroll_offset)
	for r in 0..<draw_count {
		item_idx := ts.scroll_offset + r
		tab_idx := ts.filtered_tabs[item_idx]
		row_y := ts.items_start_y + f32(r) * ts.item_h
		is_sel := (item_idx == ts.selected_idx)
		is_active := (tabs != nil && tab_idx == tabs.model.active_idx)
		row_rect: [4]f32 = {modal_x + 8 * s, row_y, modal_w - 16 * s, ts.item_h - 4.0 * s}

		if is_sel {
			chrome_dl.ui_draw_rounded_rect(dl, row_rect, {0.20, 0.36, 0.65, 0.85}, 6.0 * s)
		} else if is_active {
			chrome_dl.ui_draw_rounded_rect(dl, row_rect, {0.15, 0.19, 0.26, 0.60}, 6.0 * s)
		}

		// Tab number badge: e.g. "1."
		badge_str := fmt.tprintf("%d.", tab_idx + 1)
		badge_col: [4]f32 = {0.45, 0.65, 0.95, 1.0} if is_sel else {0.50, 0.55, 0.65, 0.85}
		chrome_dl.ui_draw_text(dl, {row_rect[0] + 12.0 * s, row_rect[1] + 6.0 * s, 24.0 * s, 18.0 * s}, badge_str, badge_col)

		// Tab Title
		tab_title := "Shell"
		if tabs != nil && tab_idx < len(tabs.entries) {
			if tabs.entries[tab_idx].title_len > 0 {
				tab_title = string(tabs.entries[tab_idx].title_buf[:tabs.entries[tab_idx].title_len])
			}
		}
		title_col: [4]f32 = {1.0, 1.0, 1.0, 1.0} if is_sel else ({0.90, 0.92, 0.96, 1.0} if is_active else {0.70, 0.74, 0.80, 0.90})
		chrome_dl.ui_draw_text(dl, {row_rect[0] + 40.0 * s, row_rect[1] + 6.0 * s, row_rect[2] - 120.0 * s, 18.0 * s}, tab_title, title_col)

		// Active tab indicator badge
		if is_active {
			tag_col: [4]f32 = {0.35, 0.75, 0.55, 0.90}
			tag_x := row_rect[0] + row_rect[2] - 65.0 * s
			chrome_dl.ui_draw_text(dl, {tag_x, row_rect[1] + 6.0 * s, 55.0 * s, 18.0 * s}, "active", tag_col)
		}
	}

	// Scrollbar indicator if items overflow
	if ts.filtered_count > TAB_SWITCHER_VISIBLE_CAP {
		track_y := ts.items_start_y
		track_h := f32(TAB_SWITCHER_VISIBLE_CAP) * ts.item_h
		thumb_h := max(24.0 * s, track_h * (f32(TAB_SWITCHER_VISIBLE_CAP) / f32(ts.filtered_count)))
		max_scroll := f32(ts.filtered_count - TAB_SWITCHER_VISIBLE_CAP)
		scroll_ratio := f32(ts.scroll_offset) / max_scroll if max_scroll > 0 else 0.0
		thumb_y := track_y + (track_h - thumb_h) * scroll_ratio
		thumb_x := modal_x + modal_w - 6.0 * s
		chrome_dl.ui_draw_rounded_rect(dl, {thumb_x, thumb_y, 3.0 * s, thumb_h}, {0.55, 0.65, 0.85, 0.50}, 1.5 * s)
	}
}
