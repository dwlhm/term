package app_test

import "core:sync"
import "core:testing"
import "core:time"

import app "../"
import termgrid "../../terminal"

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

@(private="file")
_dummy_notify_proc :: proc(user_data: rawptr) {
	if user_data != nil {
		counter := (^int)(user_data)
		counter^ += 1
	}
}

@(private="file")
_dummy_clip_write :: proc(user_data: rawptr, text: string) {}

@(private="file")
_dummy_clip_read :: proc(user_data: rawptr, out: []u8) -> int { return 0 }

@(test)
test_tab_rebase_updates_observer_user_data :: proc(t: ^testing.T) {
	tab := new(app.Tab_Session)
	defer free(tab)
	_ = app.pane_tree_init(&tab.tree, &tab.backend)

	old_backend_ptr := (^app.Backend)(uintptr(0xDEADBEEF))
	tab.backend.observer.user_data = rawptr(old_backend_ptr)
	tab.backend.parser.clipboard_read_user_data = rawptr(old_backend_ptr)

	old_nodes_base := rawptr(uintptr(rawptr(&tab.tree.nodes[0])) - 128)
	app._tab_rebase_tree(tab, old_nodes_base, old_backend_ptr)

	testing.expect(t, tab.backend.observer.user_data == rawptr(&tab.backend), "observer.user_data must be rebased to new backend")
	testing.expect(t, tab.backend.parser.clipboard_read_user_data == rawptr(&tab.backend), "clipboard_read_user_data must be rebased to new backend")
}

@(test)
test_session_manager_callbacks_propagated_to_host_backed :: proc(t: ^testing.T) {
	sm: app.Session_Manager
	app.session_manager_init(&sm, 4)
	defer app.session_manager_destroy(&sm)

	notify_val := 0
	sm.notify_data_ready_cb = _dummy_notify_proc
	sm.notify_user_data = &notify_val
	sm.clipboard_write_cb = _dummy_clip_write
	sm.clipboard_read_cb = _dummy_clip_read
	sm.clipboard_user_data = rawptr(uintptr(0x5678))

	ws_id: u64 = 42
	pane_id: u64 = 99
	idx, ok := app.session_spawn_host_backed(&sm, nil, ws_id, pane_id, 24, 80, nil, termgrid.Theme{})
	testing.expect(t, ok, "session_spawn_host_backed must succeed")
	testing.expect_value(t, idx, 0)

	tab := &sm.tabs[0]
	testing.expect(t, tab.backend.notify_data_ready_cb == _dummy_notify_proc, "notify_data_ready_cb must be propagated")
	testing.expect(t, tab.backend.notify_user_data == &notify_val, "notify_user_data must be propagated")
	testing.expect(t, tab.backend.clipboard_write_cb == _dummy_clip_write, "clipboard_write must be propagated")
	testing.expect(t, tab.backend.clipboard_read_cb == _dummy_clip_read, "clipboard_read must be propagated")
	testing.expect(t, tab.backend.clipboard_user_data == rawptr(uintptr(0x5678)), "clipboard_user_data must be propagated")
	testing.expect_value(t, tab.backend.host_ws_id, ws_id)
	testing.expect_value(t, tab.backend.host_pane_id, pane_id)
}

@(test)
test_concurrent_tabs_loop_output_no_starvation :: proc(t: ^testing.T) {
	sm: app.Session_Manager
	app.session_manager_init(&sm, 4)
	defer app.session_manager_destroy(&sm)

	notify_counter := 0
	sm.notify_data_ready_cb = _dummy_notify_proc
	sm.notify_user_data = &notify_counter

	// Spawn Tab 0 (background) and Tab 1 (foreground) running 2-iteration loops with sleep
	idx0, ok0 := app.session_spawn(&sm, "/bin/sh", {"-c", "printf 'Tab0_Line1\\n'; sleep 0.05; printf 'Tab0_Line2\\n'"}, 24, 80, nil, termgrid.Theme{})
	testing.expect(t, ok0, "tab 0 spawn must succeed")

	idx1, ok1 := app.session_spawn(&sm, "/bin/sh", {"-c", "printf 'Tab1_Line1\\n'; sleep 0.05; printf 'Tab1_Line2\\n'"}, 24, 80, nil, termgrid.Theme{})
	testing.expect(t, ok1, "tab 1 spawn must succeed")

	app.session_switch_tab(&sm, idx1)

	// Wait up to 3 seconds for both background and foreground tabs to reach Line 2
	b0 := app.tab_active_backend(&sm.tabs[idx0])
	b1 := app.tab_active_backend(&sm.tabs[idx1])

	t0_seen_line2 := false
	t1_seen_line2 := false

	for attempt in 0 ..< 150 {
		if !t0_seen_line2 {
			app.backend_lock_render(b0)
			for r in 0 ..< b0.front_terminal.grid.row_count {
				if _row_matches(&b0.front_terminal, r, "Tab0_Line2") {
					t0_seen_line2 = true
					break
				}
			}
			app.backend_unlock_render(b0)
		}

		if !t1_seen_line2 {
			app.backend_lock_render(b1)
			for r in 0 ..< b1.front_terminal.grid.row_count {
				if _row_matches(&b1.front_terminal, r, "Tab1_Line2") {
					t1_seen_line2 = true
					break
				}
			}
			app.backend_unlock_render(b1)
		}

		if t0_seen_line2 && t1_seen_line2 do break
		time.sleep(20 * time.Millisecond)
	}

	testing.expect(t, t0_seen_line2, "background tab must receive and publish output past line 1 without starvation")
	testing.expect(t, t1_seen_line2, "foreground tab must receive and publish output past line 1 without starvation")
	testing.expect(t, notify_counter > 2, "notify_data_ready_cb must be called for subsequent output events")
}

