package feature_tabs_tests

import "core:testing"
import feature ".."
import chrome_draw "../../../core/chrome/draw_list"

@test
test_tabs_lifecycle :: proc(t: ^testing.T) {
	tm: feature.Tabs_Manager
	bar_rect: [4]f32 = {0.0, 0.0, 800.0, 36.0}
	feature.tabs_manager_init(&tm, bar_rect)
	defer feature.tabs_manager_destroy(&tm)

	testing.expect_value(t, feature.tabs_manager_tab_count(&tm), 0)

	id1, idx1 := feature.tabs_manager_create_tab(&tm, "Shell 1", 101)
	testing.expect_value(t, id1, u32(1))
	testing.expect_value(t, idx1, 0)
	testing.expect_value(t, feature.tabs_manager_tab_count(&tm), 1)

	id2, idx2 := feature.tabs_manager_create_tab(&tm, "Shell 2", 102)
	testing.expect_value(t, id2, u32(2))
	testing.expect_value(t, idx2, 1)
	testing.expect_value(t, feature.tabs_manager_tab_count(&tm), 2)

	// Check active tab
	act_idx, act_entry := feature.tabs_manager_get_active(&tm)
	testing.expect_value(t, act_idx, 0)
	testing.expect(t, act_entry != nil, "Active entry should not be nil")
	testing.expect_value(t, act_entry.active_pane_id, u32(101))

	// Switch active tab
	ok := feature.tabs_manager_select_tab(&tm, 1)
	testing.expect(t, ok, "Select tab failed")
	act_idx2, act_entry2 := feature.tabs_manager_get_active(&tm)
	testing.expect_value(t, act_idx2, 1)
	testing.expect_value(t, act_entry2.active_pane_id, u32(102))

	// Title update
	feature.tabs_manager_set_title(&tm, 1, "vim project.odin")
	testing.expect_value(t, string(act_entry2.title_buf[:act_entry2.title_len]), "vim project.odin")

	// Layout and draw list emission
	content_rect: [4]f32 = {0.0, 36.0, 800.0, 564.0}
	feature.tabs_manager_update_layout(&tm, content_rect)
	testing.expect_value(t, act_entry2.split_tree.rect, content_rect)

	dl: chrome_draw.Ui_Draw_List
	chrome_draw.ui_draw_list_init(&dl)
	defer chrome_draw.ui_draw_list_destroy(&dl)

	feature.tabs_manager_emit_draw_list(&tm, &dl)
	testing.expect(t, len(dl.commands) > 0, "Draw list commands expected for tabs and dividers")

	// Close tab
	closed := feature.tabs_manager_close_tab(&tm, 0)
	testing.expect(t, closed, "Close tab 0 failed")
	testing.expect_value(t, feature.tabs_manager_tab_count(&tm), 1)
}

@test
test_tabs_many_tabs_and_title_update :: proc(t: ^testing.T) {
	tm: feature.Tabs_Manager
	bar_rect: [4]f32 = {0.0, 0.0, 1000.0, 30.0}
	feature.tabs_manager_init(&tm, bar_rect)
	defer feature.tabs_manager_destroy(&tm)

	// Create 20 tabs
	for i in 0..<20 {
		feature.tabs_manager_create_tab(&tm, "Shell", u32(100 + i))
	}
	testing.expect_value(t, feature.tabs_manager_tab_count(&tm), 20)

	// Set dynamic masked titles
	feature.tabs_manager_set_title(&tm, 5, "~/project/term")
	feature.tabs_manager_set_title(&tm, 19, "nvim config.odin")

	_, entry5 := feature.tabs_manager_get_active(&tm)
	_ = entry5
	testing.expect_value(t, string(tm.entries[5].title_buf[:tm.entries[5].title_len]), "~/project/term")
	testing.expect_value(t, string(tm.entries[19].title_buf[:tm.entries[19].title_len]), "nvim config.odin")
}
