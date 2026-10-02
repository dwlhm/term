package app_test

import "core:testing"
import "core:time"
import app "../"
import termgrid "../../terminal"
import pty "../../platform/pty"
import session_core "../../session_core"
import ui "../../ui"
import input "../../platform/input"
import tabs "../../platform/tabs"
import "core:sync"

@(test)
test_ui_shortcuts_detach_attach_labels :: proc(t: ^testing.T) {
	testing.expect_value(t, ui.ui_shortcut_label(.Detach_Tab), "\u2325\u2318B")
	testing.expect_value(t, ui.ui_shortcut_label(.Attach_Session), "\u2318O")
	testing.expect_value(t, ui.ui_shortcut_label(.Close_Tab), "\u2318D")
}

@(test)
test_session_detach_preserves_child_and_registers :: proc(t: ^testing.T) {
	sm: app.Session_Manager
	app.session_manager_init(&sm, 8)
	custom_reg: session_core.Session_Registry
	session_core.session_registry_init(&custom_reg)
	sm.registry = &custom_reg
	defer session_core.session_registry_destroy(&custom_reg)
	defer app.session_manager_destroy(&sm)

	idx0, ok0 := app.session_spawn(&sm, "/bin/sleep", {"30"}, 24, 80, nil, termgrid.Theme{})
	testing.expect(t, ok0, "spawn tab 0 must succeed")
	idx1, ok1 := app.session_spawn(&sm, "/bin/sleep", {"30"}, 24, 80, nil, termgrid.Theme{})
	testing.expect(t, ok1, "spawn tab 1 must succeed")
	testing.expect_value(t, len(sm.tabs), 2)

	tab0_pid := sm.tabs[idx0].backend.pty.pid
	testing.expect(t, tab0_pid > 1, "tab 0 pid must be valid")

	// Detach tab 0
	detach_ok := app.session_detach_tab(&sm, 0)
	testing.expect(t, detach_ok, "detach tab 0 must succeed")
	testing.expect_value(t, len(sm.tabs), 1)

	// Check registry contains detached session
	out: [4]string
	count := session_core.session_registry_list_detached(&custom_reg, out[:])
	testing.expect_value(t, count, 1)

	detached_sess := session_core.session_registry_lookup(&custom_reg, out[0])
	testing.expect(t, detached_sess != nil, "detached session must be in registry")
	testing.expect(t, detached_sess.is_detached, "detached session must have is_detached == true")
	testing.expect_value(t, detached_sess.pty_handle.pid, tab0_pid)

	// Child process is STILL RUNNING (not killed with SIGHUP or SIGKILL)
	testing.expect(t, pty.pty_has_running_processes(&detached_sess.pty_handle), "child process must still be running")
	testing.expect_value(t, detached_sess.pty_handle.state, pty.Pty_State.Running)

	// Now re-attach tab via session_attach_tab
	popped := session_core.session_registry_pop_latest_detached(&custom_reg)
	testing.expect(t, popped == detached_sess, "popped session must match detached session")

	new_idx, attach_ok := app.session_attach_tab(&sm, popped)
	testing.expect(t, attach_ok, "session_attach_tab must succeed")
	testing.expect_value(t, len(sm.tabs), 2)
	testing.expect(t, app.backend_is_threaded(&sm.tabs[new_idx].backend), "attached tab backend must be threaded")
	testing.expect_value(t, sm.tabs[new_idx].backend.pty.pid, tab0_pid)

	// Clean up child processes
	_ = app.session_close_tab(&sm, 0)
	_ = app.session_close_tab(&sm, 0)
}

@(test)
test_session_detach_all_spawns_default_shell :: proc(t: ^testing.T) {
	sm: app.Session_Manager
	app.session_manager_init(&sm, 8)
	custom_reg: session_core.Session_Registry
	session_core.session_registry_init(&custom_reg)
	sm.registry = &custom_reg
	defer session_core.session_registry_destroy(&custom_reg)
	defer app.session_manager_destroy(&sm)

	_, ok := app.session_spawn(&sm, "/bin/sleep", {"30"}, 24, 80, nil, termgrid.Theme{})
	testing.expect(t, ok, "spawn must succeed")
	testing.expect_value(t, len(sm.tabs), 1)

	// Detaching the sole tab must spawn a fresh shell tab so window stays usable
	detach_ok := app.session_detach_tab(&sm, 0)
	testing.expect(t, detach_ok, "detach tab must succeed")

	// Registry must hold the detached session
	out: [4]string
	count := session_core.session_registry_list_detached(&custom_reg, out[:])
	testing.expect_value(t, count, 1)

	// sm.tabs must still have 1 tab (the fresh default shell tab spawned)
	testing.expect_value(t, len(sm.tabs), 1)
	testing.expect_value(t, sm.active_idx, 0)

	// Clean up detached session
	popped := session_core.session_registry_pop_latest_detached(&custom_reg)
	if popped != nil {
		session_core.session_destroy(popped)
		free(popped)
	}
}

@(test)
test_session_detach_metadata_capacity_and_local_modal_flow :: proc(t: ^testing.T) {
	a := new(app.App)
	defer free(a)
	app.session_manager_init(&a.session_mgr, 2)
	reg: session_core.Session_Registry
	session_core.session_registry_init(&reg)
	a.session_mgr.registry = &reg
	defer session_core.session_registry_destroy(&reg)
	defer app.session_manager_destroy(&a.session_mgr)
	a.window.width = 800
	a.window.height = 600
	idx, spawned := app.session_spawn(&a.session_mgr, "/bin/sleep", {"30"}, 24, 80, nil, termgrid.Theme{})
	testing.expect(t, spawned)
	_, spawned = app.session_spawn(&a.session_mgr, "/bin/sleep", {"30"}, 24, 80, nil, termgrid.Theme{})
	testing.expect(t, spawned)
	a.session_mgr.active_idx = idx
	pid := a.session_mgr.tabs[idx].backend.pty.pid
	_ = app.session_set_title_override(&a.session_mgr.tabs[idx], "Deploy")
	_, ok := app.app_dispatch_input_events(a, []input.Input_Event{{event_type = .Local, action = .Detach_Tab}})
	testing.expect(t, ok)
	testing.expect_value(t, session_core.session_registry_detached_count(&reg), 1)
	_, ok = app.app_dispatch_input_events(a, []input.Input_Event{{event_type = .Local, action = .Attach_Session}})
	testing.expect(t, ok && a.session_switcher.visible)
	_, ok = app.app_dispatch_input_events(a, []input.Input_Event{{event_type = .Local, action = .Paste}, {event_type = .Key, kind = .Printable, rune = 'D'}})
	testing.expect(t, ok)
	testing.expect_value(t, a.session_switcher.query_len, 1)
	ids: [2]string
	_ = session_core.session_registry_list_detached(&reg, ids[:])
	cs := session_core.session_registry_lookup(&reg, ids[0])
	testing.expect_value(t, cs.pty_handle.pid, pid)
	testing.expect_value(t, string(cs.title_override_buf[:cs.title_override_len]), "Deploy")
	_, spawned = app.session_spawn(&a.session_mgr, "/bin/sleep", {"30"}, 24, 80, nil, termgrid.Theme{})
	testing.expect(t, spawned)
	_, attached := app.session_attach_tab(&a.session_mgr, cs)
	testing.expect(t, !attached)
	testing.expect(t, session_core.session_registry_lookup(&reg, ids[0]) == cs)
	_ = app.session_close_tab(&a.session_mgr, 1)
	attached_idx, attached_now := app.session_attach_tab(&a.session_mgr, cs)
	testing.expect(t, attached_now)
	testing.expect_value(t, a.session_mgr.tabs[attached_idx].backend.pty.pid, pid)
	testing.expect_value(t, app.session_title_display(&a.session_mgr.tabs[attached_idx]), "Deploy")
	testing.expect_value(t, a.session_mgr.tabs[attached_idx].backend.prog, "/bin/sleep")
	testing.expect_value(t, a.session_mgr.tabs[attached_idx].backend.argv[0], "30")
}

@(test)
test_background_output_pointer_attach_and_termination_confirmation :: proc(t: ^testing.T) {
	a := new(app.App)
	defer free(a)
	app.session_manager_init(&a.session_mgr, 4)
	reg: session_core.Session_Registry
	session_core.session_registry_init(&reg)
	a.session_mgr.registry = &reg
	defer session_core.session_registry_destroy(&reg)
	defer app.session_manager_destroy(&a.session_mgr)
	a.window.width = 800
	a.window.height = 600
	_, spawned := app.session_spawn(&a.session_mgr, "/bin/sh", {"-c", "sleep 0.1; printf background-output; sleep 30"}, 24, 80, nil, termgrid.Theme{})
	testing.expect(t, spawned)
	_, spawned = app.session_spawn(&a.session_mgr, "/bin/sleep", {"30"}, 24, 80, nil, termgrid.Theme{})
	testing.expect(t, spawned)
	testing.expect(t, app.session_detach_tab(&a.session_mgr, 0))
	ids: [2]string
	_ = session_core.session_registry_list_detached(&reg, ids[:])
	cs := session_core.session_registry_lookup(&reg, ids[0])
	output_seen := false
	for attempt in 0 ..< 100 {
		sync.mutex_lock(&cs.lock)
		output_seen = _row_matches(&cs.term, 0, "background-output")
		sync.mutex_unlock(&cs.lock)
		if output_seen do break
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, output_seen, "background PTY output must reach its terminal grid")
	app._app_layout_ui(a)
	badge := a.tab_bar.detached_badge_rect
	testing.expect(t, badge.w > 0)
	_, _ = app.app_dispatch_input_events(a, []input.Input_Event{{event_type = .Pointer, pointer = {kind = .Button_Down, button = 1, x = badge.x + 2, y = badge.y + 2}}})
	testing.expect(t, a.session_switcher.visible)
	row := tabs.session_switcher_row_rect(&a.session_switcher, a.session_switcher.selected_match_idx - a.session_switcher.scroll_offset)
	_, _ = app.app_dispatch_input_events(a, []input.Input_Event{{event_type = .Pointer, pointer = {kind = .Button_Down, button = 1, x = row.x + 2, y = row.y + 2}}})
	testing.expect(t, !a.session_switcher.visible)
	testing.expect_value(t, session_core.session_registry_detached_count(&reg), 0)
	b := app.app_active_backend(a)
	app.backend_lock_render(b)
	testing.expect(t, _row_matches(&b.front_terminal, 0, "background-output"))
	app.backend_unlock_render(b)
	testing.expect(t, app.session_detach_tab(&a.session_mgr, a.session_mgr.active_idx))
	app._app_open_session_switcher(a, true)
	_, _ = app.app_dispatch_input_events(a, []input.Input_Event{{event_type = .Key, gui = true, rune = 'x'}})
	testing.expect(t, a.confirm_dialog.visible && a.confirm_dialog.background_session)
	testing.expect_value(t, session_core.session_registry_detached_count(&reg), 1)
	_, _ = app.app_dispatch_input_events(a, []input.Input_Event{{event_type = .Key, kind = .Escape}})
	testing.expect(t, a.session_switcher.visible)
	testing.expect_value(t, session_core.session_registry_detached_count(&reg), 1)
	_, _ = app.app_dispatch_input_events(a, []input.Input_Event{{event_type = .Key, gui = true, rune = 'x'}, {event_type = .Key, kind = .Enter}})
	testing.expect_value(t, session_core.session_registry_detached_count(&reg), 0)
}

@(test)
test_session_switcher_pane_count_tracks_split_leaves :: proc(t: ^testing.T) {
	a := new(app.App)
	defer free(a)
	app.session_manager_init(&a.session_mgr, 4)
	reg: session_core.Session_Registry
	session_core.session_registry_init(&reg)
	a.session_mgr.registry = &reg
	defer session_core.session_registry_destroy(&reg)
	defer app.session_manager_destroy(&a.session_mgr)
	a.window.width = 800
	a.window.height = 600
	idx, spawned := app.session_spawn(&a.session_mgr, "/bin/sleep", {"30"}, 24, 80, nil, termgrid.Theme{})
	testing.expect(t, spawned, "spawn tab must succeed")

	// Split the first tab so it owns two leaves and, with the split node, three nodes.
	tab := &a.session_mgr.tabs[idx]
	testing.expect(t, tab.tree.root != nil && tab.tree.root.kind == .Leaf, "a fresh tab owns a single leaf")
	b2 := new(app.Backend)
	testing.expect(t, app.backend_init(b2, 24, 40, "/bin/sleep", {"pane2"}, nil, termgrid.Theme{}), "backend2 init must succeed")
	_, split_ok := app.pane_tree_split(&tab.tree, tab.tree.root.id, .Vertical, b2)
	testing.expect(t, split_ok, "split pane must succeed")
	leaves: [app.MAX_PANE_NODES]^app.Pane_Node
	testing.expect_value(t, app.tab_leaf_panes(tab, leaves[:]), 2)
	testing.expect(t, tab.tree.node_count == 3, "a two-pane split also allocates the split node itself")

	// A second, single-pane tab is detached so the list carries a background row too.
	_, spawned = app.session_spawn(&a.session_mgr, "/bin/sleep", {"30"}, 24, 80, nil, termgrid.Theme{})
	testing.expect(t, spawned, "spawn second tab must succeed")
	testing.expect(t, app.session_detach_tab(&a.session_mgr, 1), "detach the single-pane tab")

	state: tabs.Session_Switcher_State
	tabs.session_switcher_init(&state)
	tabs.session_switcher_show(&state, a.session_mgr.tabs[:], a.session_mgr.active_idx, &reg)
	split_row := -1
	background_row := -1
	for i in 0 ..< state.item_count {
		if state.items[i].is_detached {
			background_row = i
		} else if split_row < 0 {
			split_row = i
		}
	}
	testing.expect(t, split_row >= 0 && background_row >= 0, "the list must hold both a tab and a background session")
	testing.expect(t, state.items[split_row].pane_count == 2, "a split tab reports its leaf count, not node_count")
	testing.expect(t, state.items[background_row].pane_count == 1, "background rows are single-session")

	// The footer stays honest about detach, which the app rejects for split panes.
	testing.expect_value(t, tabs.session_switcher_footer_hint(&state.items[split_row]), tabs.SESSION_SWITCHER_HINT_SPLIT_TAB)
	testing.expect_value(t, tabs.session_switcher_footer_hint(&state.items[background_row]), tabs.SESSION_SWITCHER_HINT_BACKGROUND)
}
