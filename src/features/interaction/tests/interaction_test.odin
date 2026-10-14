package feature_interaction_tests

import "core:testing"
import feature ".."
import tabs "../../tabs"
import multiplexer "../../multiplexer"
import session "../../session"
import chrome_splits "../../../core/chrome/splits"

@test
test_interaction_lifecycle :: proc(t: ^testing.T) {
	tm: tabs.Tabs_Manager
	mux: multiplexer.Multiplexer
	inter: feature.Interaction_State

	bar_rect: [4]f32 = {0.0, 0.0, 800.0, 36.0}
	tabs.tabs_manager_init(&tm, bar_rect)
	multiplexer.multiplexer_init(&mux)
	feature.interaction_init(&inter)

	defer {
		tabs.tabs_manager_destroy(&tm)
		multiplexer.multiplexer_destroy(&mux)
	}

	cfg := session.Session_Config{
		shell = "/bin/sh",
		rows  = 24,
		cols  = 80,
	}

	// 1. Create a terminal pane and tab
	pane_id, err := multiplexer.multiplexer_create_terminal_pane(&mux, cfg)
	testing.expect(t, err == .None, "Create terminal pane failed")
	tabs.tabs_manager_create_tab(&tm, "Shell", pane_id)

	content_rect: [4]f32 = {0.0, 36.0, 800.0, 564.0}
	tabs.tabs_manager_update_layout(&tm, content_rect)
	multiplexer.multiplexer_sync_split_rects(&mux, tm.entries[0].split_tree)

	// 2. Mouse click inside pane
	click_pos: [2]f32 = {100.0, 100.0}
	action := feature.interaction_on_mouse_down(&inter, &tm, &mux, click_pos, 1, {})
	testing.expect_value(t, action.kind, feature.Action_Kind.Pane_Focused)
	testing.expect_value(t, action.pane_id, pane_id)
	testing.expect_value(t, inter.mode, feature.Interaction_Mode.Selecting_Text)

	// 3. Mouse drag text selection
	drag_pos: [2]f32 = {150.0, 120.0}
	feature.interaction_on_mouse_move(&inter, &mux, drag_pos, {})
	testing.expect(t, inter.selection.active, "Selection should be active")

	feature.interaction_on_mouse_up(&inter, &mux, 1)
	testing.expect_value(t, inter.mode, feature.Interaction_Mode.Idle)

	// 4. Keyboard shortcut: Cmd+T -> Tab_New_Requested
	key_act := feature.interaction_on_key_press(&inter, &tm, &mux, 't', {.Cmd})
	testing.expect_value(t, key_act.kind, feature.Action_Kind.Tab_New_Requested)

	// 5. 3D canvas interaction test
	pane_3d := multiplexer.multiplexer_create_3d_pane(&mux)
	p3 := multiplexer.multiplexer_get_pane(&mux, pane_3d)

	// Split tree into two panes
	chrome_splits.split_node_split(tm.entries[0].split_tree, .Horizontal, 0.5, pane_3d)
	tabs.tabs_manager_update_layout(&tm, content_rect)
	multiplexer.multiplexer_sync_split_rects(&mux, tm.entries[0].split_tree)

	multiplexer.multiplexer_focus_pane(&mux, pane_3d)

	// Click in 3D pane
	pos_3d: [2]f32 = {450.0, 200.0}
	action_3d := feature.interaction_on_mouse_down(&inter, &tm, &mux, pos_3d, 1, {})
	testing.expect_value(t, action_3d.kind, feature.Action_Kind.Pane_Focused)
	testing.expect_value(t, inter.mode, feature.Interaction_Mode.Interacting_3D)

	// Drag rotates 3D camera
	feature.interaction_on_mouse_move(&inter, &mux, [2]f32{460.0, 210.0}, {})
	testing.expect(t, p3.interactor.is_dragging, "3D interactor should be dragging")

	// Mouse wheel zooms
	feature.interaction_on_mouse_wheel(&inter, &mux, 1.0)
	testing.expect(t, p3.interactor.distance < 4.2, "3D interactor distance should decrease on zoom in")

	feature.interaction_on_mouse_up(&inter, &mux, 1)
	testing.expect_value(t, inter.mode, feature.Interaction_Mode.Idle)
}
