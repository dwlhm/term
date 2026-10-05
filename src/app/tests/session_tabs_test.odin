package app_test

import "core:testing"

import app "../"

// _seeded_manager builds a session manager with count parked tabs whose ids are
// base+1 .. base+count, avoiding process/GPU dependencies.
_seeded_manager :: proc(sm: ^app.Session_Manager, count: int, base: u32) {
	app.session_manager_init(sm, 8)
	for i in 0 ..< count {
		resize(&sm.tabs, len(sm.tabs) + 1)
		tab := &sm.tabs[len(sm.tabs) - 1]
		tab.id = base + u32(i) + 1
	}
}

@(test)
test_session_reorder_preserves_active_by_id :: proc(t: ^testing.T) {
	sm: app.Session_Manager
	_seeded_manager(&sm, 4, 0)
	defer app.session_manager_destroy(&sm)

	sm.active_idx = 3
	active_id := sm.tabs[sm.active_idx].id

	// 0 -> 2 yields order [2,3,1,4] and keeps the active id.
	testing.expect(t, app.session_reorder_tab(&sm, 0, 2))
	testing.expect_value(t, sm.tabs[0].id, u32(2))
	testing.expect_value(t, sm.tabs[1].id, u32(3))
	testing.expect_value(t, sm.tabs[2].id, u32(1))
	testing.expect_value(t, sm.tabs[3].id, u32(4))
	testing.expect_value(t, sm.tabs[sm.active_idx].id, active_id)

	// 2 -> 0 restores order [1,2,3,4] and still tracks the active id.
	testing.expect(t, app.session_reorder_tab(&sm, 2, 0))
	testing.expect_value(t, sm.tabs[0].id, u32(1))
	testing.expect_value(t, sm.tabs[1].id, u32(2))
	testing.expect_value(t, sm.tabs[2].id, u32(3))
	testing.expect_value(t, sm.tabs[3].id, u32(4))
	testing.expect_value(t, sm.tabs[sm.active_idx].id, active_id)

	// Idempotent when from == to; out-of-range is rejected without mutation.
	testing.expect(t, app.session_reorder_tab(&sm, 1, 1))
	testing.expect(t, !app.session_reorder_tab(&sm, 0, 4))
	testing.expect(t, !app.session_reorder_tab(&sm, -1, 0))
	testing.expect_value(t, len(sm.tabs), 4)
}

@(test)
test_session_close_others_and_to_right :: proc(t: ^testing.T) {
	sm: app.Session_Manager
	_seeded_manager(&sm, 4, 0)
	defer app.session_manager_destroy(&sm)
	sm.active_idx = 0

	// Closing to the right of index 0 removes ids 2,3,4.
	closed := app.session_close_to_right(&sm, 0)
	testing.expect_value(t, closed, 3)
	testing.expect_value(t, len(sm.tabs), 1)
	testing.expect_value(t, sm.tabs[0].id, u32(1))

	// Rebuild with a fresh id range and keep only the second tab.
	resize(&sm.tabs, 0)
	for i in 0 ..< 4 {
		resize(&sm.tabs, len(sm.tabs) + 1)
		tab := &sm.tabs[len(sm.tabs) - 1]
		tab.id = 10 + u32(i) + 1
	}
	sm.active_idx = 1
	closed = app.session_close_others(&sm, 1)
	testing.expect_value(t, closed, 3)
	testing.expect_value(t, len(sm.tabs), 1)
	testing.expect_value(t, sm.tabs[0].id, u32(12))
	testing.expect_value(t, sm.active_idx, 0)

	// Closing to the right of the now-last tab closes nothing.
	testing.expect_value(t, app.session_close_to_right(&sm, 0), 0)
}

@(test)
test_session_title_override_survives_osc_update :: proc(t: ^testing.T) {
	sm: app.Session_Manager
	_seeded_manager(&sm, 1, 0)
	defer app.session_manager_destroy(&sm)
	s := &sm.tabs[0]

	s.title_len = app.session_sanitize_title(s.title_buf[:], "zsh")
	testing.expect_value(t, app.session_title_display(s), "zsh")

	testing.expect(t, app.session_set_title_override(s, "Deploy"))
	testing.expect_value(t, app.session_title_display(s), "Deploy")

	// A simulated OSC title update writes title_buf (the session_poll_all path)
	// and must not disturb the user override.
	s.title_len = app.session_sanitize_title(s.title_buf[:], "vim README.md")
	testing.expect_value(t, app.session_title_display(s), "Deploy")

	// Clearing the override restores the latest OSC title.
	testing.expect(t, app.session_clear_title_override(s))
	testing.expect_value(t, app.session_title_display(s), "vim README.md")

	// An empty override is not retained as active.
	testing.expect(t, !app.session_set_title_override(s, ""))
	testing.expect(t, !s.title_override_active)
}

// test_session_title_recency pins the title priority chain:
// Priority 1: User title override
// Priority 2: Foreground process name (e.g. yarn, vim)
// Priority 3: Shell prompt: directory basename (e.g. project instead of /project)
// Priority 4: Sanitized OSC title
@(test)
test_session_title_recency :: proc(t: ^testing.T) {
	sm: app.Session_Manager
	_seeded_manager(&sm, 1, 0)
	defer app.session_manager_destroy(&sm)
	s := &sm.tabs[0]

	// 1. Idle in a folder: directory basename is used.
	app.session_update_title(s, "", "/project", "")
	testing.expect_value(t, app.session_title_display(s), "project")

	// 2. A fresh OSC title when no cwd or foreground.
	app.session_update_title(s, "shell-title", "", "", true)
	testing.expect_value(t, app.session_title_display(s), "shell-title")

	// 3. A foreground process starting wins (Priority 2).
	app.session_update_title(s, "", "/project", "yarn")
	testing.expect_value(t, app.session_title_display(s), "yarn")

	// 4. When that process exits the title falls back to directory basename (Priority 3).
	app.session_update_title(s, "", "/project", "")
	testing.expect_value(t, app.session_title_display(s), "project")

	// 5. Running foreground process wins over OSC title (Priority 2 over Priority 4).
	app.session_update_title(s, "vim file.txt", "/project", "vim", true)
	testing.expect_value(t, app.session_title_display(s), "vim")
}

@(test)
test_session_switch_tab_clears_bell :: proc(t: ^testing.T) {
	sm: app.Session_Manager
	_seeded_manager(&sm, 3, 0)
	defer app.session_manager_destroy(&sm)
	sm.active_idx = 0

	// 1. Single pane tab with has_bell = true.
	_ = app.pane_tree_init(&sm.tabs[1].tree, nil)
	leaf_single := app.pane_tree_find_pane(&sm.tabs[1].tree, sm.tabs[1].tree.focused_pane_id)
	testing.expect(t, leaf_single != nil)
	leaf_single.has_bell = true
	sm.tabs[1].has_bell = true

	// Switching to tab 1 must clear both tab.has_bell and leaf.has_bell.
	testing.expect(t, app.session_switch_tab(&sm, 1))
	testing.expect_value(t, sm.active_idx, 1)
	testing.expect(t, !sm.tabs[1].has_bell, "tab 1 has_bell must be cleared on switch")
	testing.expect(t, !leaf_single.has_bell, "tab 1 leaf has_bell must be cleared on switch")

	// 2. Already active tab with has_bell = true.
	sm.tabs[1].has_bell = true
	leaf_single.has_bell = true
	testing.expect(t, app.session_switch_tab(&sm, 1))
	testing.expect_value(t, sm.active_idx, 1)
	testing.expect(t, !sm.tabs[1].has_bell, "already active tab has_bell must be cleared")
	testing.expect(t, !leaf_single.has_bell, "already active tab leaf has_bell must be cleared")

	// 3. Tab with split panes (multiple leaves) with has_bell = true.
	root_id := app.pane_tree_init(&sm.tabs[2].tree, nil)
	child_id, ok_v := app.pane_tree_split(&sm.tabs[2].tree, root_id, .Vertical, nil)
	testing.expect(t, ok_v, "split must succeed")
	leaf_a := app.pane_tree_find_pane(&sm.tabs[2].tree, root_id)
	leaf_b := app.pane_tree_find_pane(&sm.tabs[2].tree, child_id)
	testing.expect(t, leaf_a != nil && leaf_b != nil)

	sm.tabs[2].has_bell = true
	leaf_a.has_bell = true
	leaf_b.has_bell = true

	// Switching to tab 2 must clear tab.has_bell and all split leaf panes' has_bell.
	testing.expect(t, app.session_switch_tab(&sm, 2))
	testing.expect_value(t, sm.active_idx, 2)
	testing.expect(t, !sm.tabs[2].has_bell, "split tab has_bell must be cleared on switch")
	testing.expect(t, !leaf_a.has_bell, "split leaf A has_bell must be cleared on switch")
	testing.expect(t, !leaf_b.has_bell, "split leaf B has_bell must be cleared on switch")
}

