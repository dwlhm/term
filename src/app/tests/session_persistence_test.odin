package app_test

import "core:testing"
import "core:time"
import app "../"
import termgrid "../../terminal"
import pty "../../platform/pty"
import session_core "../../session_core"
import ui "../../ui"

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
