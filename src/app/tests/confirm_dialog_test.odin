package app_test

// TG3 in-app close-confirmation tests. The dialog is exercised against a
// zero-value App (no window, no GPU): the modal gate must swallow input, the
// target must resolve by stable id, and close requests must branch on whether
// the tab's pty still reports a running foreground process. App is heap
// allocated (as elsewhere) because it embeds multi-megabyte backend state.

import "core:testing"
import "core:time"

import app "../"
import ui "../../ui"
import input "../../platform/input"
import pty "../../platform/pty"
import termgrid "../../terminal"

@(test)
test_tab_index_by_id_resolution :: proc(t: ^testing.T) {
	a := new(app.App)
	defer free(a)
	_seeded_manager(&a.session_mgr, 3, 40) // ids 41, 42, 43
	defer app.session_manager_destroy(&a.session_mgr)

	testing.expect_value(t, app._app_tab_index_by_id(a, 41), 0)
	testing.expect_value(t, app._app_tab_index_by_id(a, 43), 2)
	testing.expect_value(t, app._app_tab_index_by_id(a, 999), -1)
	testing.expect_value(t, app._app_tab_index_by_id(nil, 41), -1)
}

@(test)
test_confirm_dialog_modal_swallows_input :: proc(t: ^testing.T) {
	a := new(app.App)
	defer free(a)
	ui.confirm_dialog_init(&a.confirm_dialog)
	ui.confirm_dialog_layout(&a.confirm_dialog, 800, 600)
	ui.confirm_dialog_show(&a.confirm_dialog, 0, 7)

	// An unrelated key is swallowed and the dialog stays visible.
	key := [1]input.Input_Event{{event_type = .Key, kind = .Printable, rune = 'z'}}
	_, ok := app.app_dispatch_input_events(a, key[:])
	testing.expect(t, ok, "dialog must consume a key event")
	testing.expect(t, a.confirm_dialog.visible, "unrelated key must not dismiss the dialog")

	// Pointer motion over the confirm button is consumed and updates hover.
	cx := a.confirm_dialog.confirm_rect.x + a.confirm_dialog.confirm_rect.w * 0.5
	cy := a.confirm_dialog.confirm_rect.y + a.confirm_dialog.confirm_rect.h * 0.5
	motion := [1]input.Input_Event{{event_type = .Pointer, pointer = {kind = .Motion, x = cx, y = cy}}}
	_, ok = app.app_dispatch_input_events(a, motion[:])
	testing.expect(t, ok, "dialog must consume a pointer event")
	testing.expect_value(t, a.confirm_dialog.hover_target, ui.Confirm_Dialog_Target.Btn_Confirm)
	testing.expect(t, a.confirm_dialog.visible, "pointer motion must not dismiss the dialog")

	// A local clipboard action must be swallowed, not copy or paste.
	local := [1]input.Input_Event{{event_type = .Local, action = .Copy}}
	_, ok = app.app_dispatch_input_events(a, local[:])
	testing.expect(t, ok, "dialog must swallow local clipboard actions")
	testing.expect(t, a.confirm_dialog.visible, "local action must not dismiss the dialog")

	// Escape cancels and hides the dialog.
	esc := [1]input.Input_Event{{event_type = .Key, kind = .Escape}}
	_, _ = app.app_dispatch_input_events(a, esc[:])
	testing.expect(t, !a.confirm_dialog.visible, "Escape must cancel the dialog")
}

@(test)
test_request_close_tab_exited_closes_immediately :: proc(t: ^testing.T) {
	a := new(app.App)
	defer free(a)
	a.pty.master = -1
	a.pty.pid = -1
	app.session_manager_init(&a.session_mgr, 4)
	defer app.session_manager_destroy(&a.session_mgr)

	idx, ok := app.session_spawn(&a.session_mgr, "/usr/bin/true", {}, 24, 80, nil, termgrid.Theme{})
	testing.expect(t, ok, "spawn /usr/bin/true must succeed")
	if !ok do return

	// Reap the child so the pty reports no running foreground process.
	for _ in 0 ..< 200 {
		if pty.pty_poll_exit(&a.session_mgr.tabs[idx].backend.pty) do break
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, !pty.pty_has_running_processes(&a.session_mgr.tabs[idx].backend.pty), "exited pty must report no running process")

	app._app_request_close_tab(a, idx)
	testing.expect(t, !a.confirm_dialog.visible, "exited tab must close without a dialog")
	testing.expect_value(t, len(a.session_mgr.tabs), 0)
	testing.expect(t, a.should_quit, "closing the last tab must request quit")
}

@(test)
test_request_close_tab_running_shows_dialog :: proc(t: ^testing.T) {
	a := new(app.App)
	defer free(a)
	a.pty.master = -1
	a.pty.pid = -1
	app.session_manager_init(&a.session_mgr, 4)
	defer app.session_manager_destroy(&a.session_mgr)

	// A long-lived foreground child makes pty_has_running_processes report true.
	idx, ok := app.session_spawn(&a.session_mgr, "/bin/sleep", {"30"}, 24, 80, nil, termgrid.Theme{})
	testing.expect(t, ok, "spawn /bin/sleep must succeed")
	if !ok do return

	running := false
	for _ in 0 ..< 200 {
		if pty.pty_has_running_processes(&a.session_mgr.tabs[idx].backend.pty) {
			running = true
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, running, "sleep child must report as running")
	if running {
		target_id := a.session_mgr.tabs[idx].id
		app._app_request_close_tab(a, idx)
		testing.expect(t, a.confirm_dialog.visible, "running tab must open the confirm dialog")
		testing.expect_value(t, a.confirm_dialog.target_tab_idx, idx)
		testing.expect_value(t, a.confirm_dialog.target_tab_id, target_id)
		testing.expect_value(t, len(a.session_mgr.tabs), 1)
		testing.expect(t, !a.should_quit, "showing the dialog must not close or quit")
	}

	// Cleanup: terminate and reap the sleeping child.
	_s15_kill(&a.session_mgr.tabs[idx].backend.pty)
	for _ in 0 ..< 200 {
		if pty.pty_poll_exit(&a.session_mgr.tabs[idx].backend.pty) do break
		time.sleep(5 * time.Millisecond)
	}
}
