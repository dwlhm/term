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
