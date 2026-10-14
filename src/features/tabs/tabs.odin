package feature_tabs

// feature_tabs: Composition slice uniting core_chrome/tabs and core_chrome/splits.
// Part of Tier 2 Feature Composition Layer.
//
// Zero horizontal coupling: Does not depend on feature_session or feature_interaction.
// Manages tab order, active tab index, per-tab split tree topology, and draw list generation.

import "base:runtime"
import "core:strings"
import chrome_tabs "../../core/chrome/tabs"
import chrome_splits "../../core/chrome/splits"
import chrome_draw "../../core/chrome/draw_list"

Tab_Entry :: struct {
	id:             u32,
	title_buf:      [128]u8,
	title_len:      int,
	split_tree:     ^chrome_splits.Split_Node,
	active_pane_id: u32,
}

Tabs_Manager :: struct {
	model:       chrome_tabs.Chrome_Tabs_Model,
	entries:     [dynamic]Tab_Entry,
	next_tab_id: u32,
	allocator:   runtime.Allocator,
}

tabs_manager_init :: proc(tm: ^Tabs_Manager, bar_rect: [4]f32, allocator := context.allocator) {
	if tm == nil do return
	tm.allocator = allocator
	tm.next_tab_id = 1
	chrome_tabs.tabs_model_init(&tm.model, bar_rect, allocator)
	tm.entries = make([dynamic]Tab_Entry, allocator)
}

tabs_manager_destroy :: proc(tm: ^Tabs_Manager) {
	if tm == nil do return
	for &entry in tm.entries {
		if entry.split_tree != nil {
			chrome_splits.split_tree_destroy(entry.split_tree, tm.allocator)
			entry.split_tree = nil
		}
	}
	delete(tm.entries)
	tm.entries = nil
	chrome_tabs.tabs_model_destroy(&tm.model)
}

tabs_manager_create_tab :: proc(tm: ^Tabs_Manager, title: string, initial_pane_id: u32) -> (tab_id: u32, tab_idx: int) {
	if tm == nil do return 0, -1

	tab_id = tm.next_tab_id
	tm.next_tab_id += 1

	entry: Tab_Entry
	entry.id = tab_id
	copy_len := min(len(title), len(entry.title_buf) - 1)
	copy(entry.title_buf[:copy_len], title[:copy_len])
	entry.title_len = copy_len
	entry.active_pane_id = initial_pane_id

	// Create root split leaf for this tab
	entry.split_tree = chrome_splits.split_node_create_leaf(initial_pane_id, tm.allocator)

	append(&tm.entries, entry)
	tab_idx = chrome_tabs.tabs_add(&tm.model, tab_id, string(entry.title_buf[:entry.title_len]))

	return tab_id, tab_idx
}

tabs_manager_close_tab :: proc(tm: ^Tabs_Manager, tab_idx: int) -> bool {
	if tm == nil || tab_idx < 0 || tab_idx >= len(tm.entries) do return false

	if tm.entries[tab_idx].split_tree != nil {
		chrome_splits.split_tree_destroy(tm.entries[tab_idx].split_tree, tm.allocator)
		tm.entries[tab_idx].split_tree = nil
	}

	ordered_remove(&tm.entries, tab_idx)
	return chrome_tabs.tabs_remove(&tm.model, tab_idx)
}

tabs_manager_select_tab :: proc(tm: ^Tabs_Manager, tab_idx: int) -> bool {
	if tm == nil || tab_idx < 0 || tab_idx >= len(tm.entries) do return false
	return chrome_tabs.tabs_set_active(&tm.model, tab_idx)
}

tabs_manager_get_active :: proc(tm: ^Tabs_Manager) -> (tab_idx: int, entry: ^Tab_Entry) {
	if tm == nil || tm.model.active_idx < 0 || tm.model.active_idx >= len(tm.entries) {
		return -1, nil
	}
	return tm.model.active_idx, &tm.entries[tm.model.active_idx]
}

tabs_manager_set_title :: proc(tm: ^Tabs_Manager, tab_idx: int, title: string) -> bool {
	if tm == nil || tab_idx < 0 || tab_idx >= len(tm.entries) do return false

	entry := &tm.entries[tab_idx]
	copy_len := min(len(title), len(entry.title_buf) - 1)
	copy(entry.title_buf[:copy_len], title[:copy_len])
	entry.title_len = copy_len

	if tab_idx < len(tm.model.tabs) {
		tm.model.tabs[tab_idx].title = string(entry.title_buf[:entry.title_len])
	}
	return true
}

tabs_manager_tab_count :: proc(tm: ^Tabs_Manager) -> int {
	if tm == nil do return 0
	return len(tm.entries)
}

tabs_manager_update_layout :: proc(tm: ^Tabs_Manager, content_rect: [4]f32) {
	if tm == nil do return
	_, active_entry := tabs_manager_get_active(tm)
	if active_entry != nil && active_entry.split_tree != nil {
		chrome_splits.split_tree_layout(active_entry.split_tree, content_rect)
	}
}

tabs_manager_emit_draw_list :: proc(tm: ^Tabs_Manager, dl: ^chrome_draw.Ui_Draw_List) {
	if tm == nil || dl == nil do return
	chrome_tabs.tabs_emit_draw_list(&tm.model, dl)

	_, active_entry := tabs_manager_get_active(tm)
	if active_entry != nil && active_entry.split_tree != nil {
		chrome_splits.split_tree_emit_dividers(active_entry.split_tree, dl)
	}
}
