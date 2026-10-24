package modals

// Behavioral unit tests for the Session Safety Confirmation Dialog (Two-Way Interactive Modal).

import "core:testing"
import dl "../draw_list"

@test
test_session_dialog_two_way_transfer :: proc(t: ^testing.T) {
	state: Session_Dialog_State
	session_dialog_init(&state)
	defer session_dialog_destroy(&state)

	// Add 1 active job (defaults to .Background) and 1 idle shell (defaults to .Kill)
	append(&state.items, Dialog_Session_Item{
		session_id    = 1,
		tab_index     = 0,
		process_name  = "cargo",
		pid           = 45120,
		is_active_job = true,
		choice        = .Background,
	})
	append(&state.items, Dialog_Session_Item{
		session_id    = 2,
		tab_index     = 1,
		process_name  = "zsh",
		pid           = 45130,
		is_active_job = false,
		choice        = .Kill,
	})
	state.visible = true

	list: dl.Ui_Draw_List
	dl.ui_draw_list_init(&list)
	defer dl.ui_draw_list_destroy(&list)

	// 1. Emit draw list to populate button bounding boxes
	session_dialog_emit_draw_list(&state, &list, 1280.0, 800.0, 1.0)
	testing.expect_value(t, state.items[0].choice, Session_Action_Choice.Background)
	testing.expect_value(t, state.items[1].choice, Session_Action_Choice.Kill)
	testing.expect(t, len(list.commands) > 0, "draw list must contain dialog primitives")

	// 2. Click the [ Kill ] button on the background item
	btn0 := state.items[0].btn_rect
	act := session_dialog_handle_click(&state, btn0[0] + 5.0, btn0[1] + 5.0)
	testing.expect_value(t, act, Session_Dialog_Action.Repaint)
	testing.expect_value(t, state.items[0].choice, Session_Action_Choice.Kill)

	// 3. Expand the collapsible killed section
	session_dialog_emit_draw_list(&state, &list, 1280.0, 800.0, 1.0)
	toggle := state.toggle_rect
	act_toggle := session_dialog_handle_click(&state, toggle[0] + 5.0, toggle[1] + 5.0)
	testing.expect_value(t, act_toggle, Session_Dialog_Action.Repaint)
	testing.expect(t, state.killed_expanded, "killed section must now be expanded")

	// 4. Click [ Keep in Background ] on the item to move it back to background
	session_dialog_emit_draw_list(&state, &list, 1280.0, 800.0, 1.0)
	btn_rev := state.items[0].btn_rect
	act_rev := session_dialog_handle_click(&state, btn_rev[0] + 5.0, btn_rev[1] + 5.0)
	testing.expect_value(t, act_rev, Session_Dialog_Action.Repaint)
	testing.expect_value(t, state.items[0].choice, Session_Action_Choice.Background)

	// 5. Test Cancel and Apply clicks
	act_cancel := session_dialog_handle_click(&state, state.cancel_rect[0] + 5.0, state.cancel_rect[1] + 5.0)
	testing.expect_value(t, act_cancel, Session_Dialog_Action.Cancel)

	act_apply := session_dialog_handle_click(&state, state.apply_rect[0] + 5.0, state.apply_rect[1] + 5.0)
	testing.expect_value(t, act_apply, Session_Dialog_Action.Apply)
}

@test
test_session_dialog_long_text_truncation :: proc(t: ^testing.T) {
	state: Session_Dialog_State
	session_dialog_init(&state)
	defer session_dialog_destroy(&state)

	append(&state.items, Dialog_Session_Item{
		session_id    = 10,
		tab_index     = 2,
		process_name  = "/usr/local/bin/extremely_long_nested_process_name_that_should_not_clip_pid_or_overflow",
		pid           = 98765,
		is_active_job = true,
		choice        = .Background,
	})
	append(&state.items, Dialog_Session_Item{
		session_id    = 11,
		tab_index     = 3,
		process_name  = "super_long_command_marked_for_termination_with_status_suffix_check",
		pid           = 98766,
		is_active_job = true,
		choice        = .Kill,
	})
	state.visible = true
	state.killed_expanded = true // Expand to emit killed items as well

	list: dl.Ui_Draw_List
	dl.ui_draw_list_init(&list)
	defer dl.ui_draw_list_destroy(&list)

	session_dialog_emit_draw_list(&state, &list, 1024.0, 768.0, 1.0)
	testing.expect(t, len(list.commands) > 0, "commands must be emitted")

	// Ensure PID commands are intact and present
	has_pid_1 := false
	has_pid_2 := false
	for cmd in list.commands {
		if cmd.kind == .Text_Run {
			if cmd.text == "PID 98765" do has_pid_1 = true
			if cmd.text == "PID 98766" do has_pid_2 = true
		}
	}
	testing.expect(t, has_pid_1, "PID 98765 must be preserved in dedicated column")
	testing.expect(t, has_pid_2, "PID 98766 must be preserved in dedicated column")
}
