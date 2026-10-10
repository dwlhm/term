package tabs

// Pure Declarative UI Geometry Engine - Tabs Data Model.
// Part of core_chrome: Tier 1 Autonomous Core Primitives.
//
// Invariant: ZERO GPU Dependencies.
// Translates tab lists and interactions into pure Ui_Draw_List commands.

import "base:runtime"
import "../draw_list"

// Chrome_Tab describes an individual tab state.
Chrome_Tab :: struct {
	id:          u32,
	title:       string,
	active:      bool,
	modified:    bool,
	hover:       bool,
	close_hover: bool,
	rect:        [4]f32,
	close_rect:  [4]f32,
}

// Chrome_Tabs_Model manages ordered tabs and physical layout bounds.
Chrome_Tabs_Model :: struct {
	tabs:       [dynamic]Chrome_Tab,
	active_idx: int,
	bar_rect:   [4]f32,
	allocator:  runtime.Allocator,
}

// tabs_model_init initializes the tab bar model.
tabs_model_init :: proc(m: ^Chrome_Tabs_Model, bar_rect: [4]f32, allocator := context.allocator) {
	if m == nil do return
	m.allocator = allocator
	m.bar_rect = bar_rect
	m.active_idx = -1
	m.tabs = make([dynamic]Chrome_Tab, allocator)
}

// tabs_model_destroy cleans up tab resources.
tabs_model_destroy :: proc(m: ^Chrome_Tabs_Model) {
	if m == nil do return
	delete(m.tabs)
	m.tabs = nil
	m.active_idx = -1
}

// tabs_add appends a new tab. Activates it if it is the first tab.
tabs_add :: proc(m: ^Chrome_Tabs_Model, id: u32, title: string) -> int {
	if m == nil do return -1
	tab := Chrome_Tab{
		id    = id,
		title = title,
	}
	idx := len(m.tabs)
	append(&m.tabs, tab)
	if m.active_idx < 0 || m.active_idx >= len(m.tabs) {
		tabs_set_active(m, idx)
	}
	return idx
}

// tabs_remove removes tab at idx and updates active index.
tabs_remove :: proc(m: ^Chrome_Tabs_Model, idx: int) -> bool {
	if m == nil || idx < 0 || idx >= len(m.tabs) do return false
	ordered_remove(&m.tabs, idx)
	if len(m.tabs) == 0 {
		m.active_idx = -1
	} else if m.active_idx >= len(m.tabs) {
		m.active_idx = len(m.tabs) - 1
		m.tabs[m.active_idx].active = true
	} else if m.active_idx == idx {
		m.tabs[m.active_idx].active = true
	}
	return true
}

// tabs_set_active switches the active tab.
tabs_set_active :: proc(m: ^Chrome_Tabs_Model, idx: int) -> bool {
	if m == nil || idx < 0 || idx >= len(m.tabs) do return false
	for i in 0..<len(m.tabs) {
		m.tabs[i].active = (i == idx)
	}
	m.active_idx = idx
	return true
}

// tabs_emit_draw_list layouts tabs along bar_rect and emits draw commands into dl.
tabs_emit_draw_list :: proc(m: ^Chrome_Tabs_Model, dl: ^draw_list.Ui_Draw_List) {
	if m == nil || dl == nil do return

	// Tab bar background
	draw_list.ui_draw_rect(dl, m.bar_rect, {0.11, 0.12, 0.14, 1.0})

	count := len(m.tabs)
	if count == 0 do return

	tab_h := m.bar_rect[3]
	total_w := m.bar_rect[2]
	tab_w := min(220.0, total_w / f32(count))

	start_x := m.bar_rect[0]
	start_y := m.bar_rect[1]

	for i in 0..<count {
		tab := &m.tabs[i]
		cur_x := start_x + f32(i) * tab_w
		tab.rect = {cur_x, start_y, tab_w, tab_h}

		close_size: f32 = 14.0
		tab.close_rect = {cur_x + tab_w - close_size - 8.0, start_y + (tab_h - close_size) * 0.5, close_size, close_size}

		// Tab body background
		bg_color: [4]f32
		if tab.active {
			bg_color = {0.18, 0.20, 0.24, 1.0}
		} else if tab.hover {
			bg_color = {0.14, 0.15, 0.18, 1.0}
		} else {
			bg_color = {0.12, 0.13, 0.15, 1.0}
		}

		draw_list.ui_draw_rounded_rect(dl, tab.rect, bg_color, 4.0)

		// Active tab bottom accent line
		if tab.active {
			indicator_rect: [4]f32 = {cur_x, start_y + tab_h - 2.0, tab_w, 2.0}
			draw_list.ui_draw_rect(dl, indicator_rect, {0.35, 0.65, 0.95, 1.0})
		}

		// Tab title
		text_rect: [4]f32 = {cur_x + 10.0, start_y + (tab_h - 16.0) * 0.5, tab_w - close_size - 24.0, 16.0}
		text_color: [4]f32 = {0.92, 0.94, 0.96, 1.0} if tab.active else {0.60, 0.62, 0.66, 1.0}
		draw_list.ui_draw_text(dl, text_rect, tab.title, text_color)

		// Modified indicator dot or close button
		if tab.modified {
			dot_size: f32 = 6.0
			dot_rect: [4]f32 = {tab.close_rect[0] + 4.0, tab.close_rect[1] + 4.0, dot_size, dot_size}
			draw_list.ui_draw_rounded_rect(dl, dot_rect, {0.95, 0.70, 0.20, 1.0}, 3.0)
		} else {
			if tab.close_hover {
				draw_list.ui_draw_rounded_rect(dl, tab.close_rect, {0.40, 0.22, 0.22, 0.8}, 3.0)
			}
			close_fg: [4]f32 = {0.95, 0.95, 0.95, 1.0} if tab.close_hover else {0.52, 0.54, 0.58, 1.0}
			draw_list.ui_draw_text(dl, tab.close_rect, "×", close_fg)
		}
	}
}
