package term

// The window's side of automation (term auto): the pane banner, the
// held-input warning and the takeover confirmation.

import "core:testing"
import "vendor:sdl3"
import chrome_dl "../../core/chrome/draw_list"
import mux_feat "../../features/multiplexer"
import sess_feat "../../features/session"

@(private = "file")
_layout :: proc() -> (layout: Layout_State) {
	layout_init(&layout, 2.0, 8, 8, 1.0)
	layout.screen_w, layout.screen_h = 2560, 1600
	return
}

@(test)
test_takeover_shortcut_and_catalog :: proc(t: ^testing.T) {
	act, ok := keymap_evaluate(sdl3.K_PERIOD, sdl3.KMOD_GUI | sdl3.KMOD_SHIFT)
	testing.expect(t, ok && act == .Automation_Takeover, "⇧⌘. takes over")
	m, listed := action_get_metadata(.Automation_Takeover)
	testing.expect(t, listed && m.category == .Sessions, "the Command Center lists it")
}

@(test)
test_banner_only_on_controlled_panes :: proc(t: ^testing.T) {
	layout := _layout()
	dl: chrome_dl.Ui_Draw_List
	chrome_dl.ui_draw_list_init(&dl)
	defer chrome_dl.ui_draw_list_destroy(&dl)
	sess := new(sess_feat.Terminal_Session)
	defer free(sess)
	pane := mux_feat.Pane_Entry{session = sess, rect = {0, 0, 1200, 800}}

	automation_banner_emit(&dl, &layout, &pane, false)
	testing.expect_value(t, len(dl.commands), 0) // nobody drives it
	testing.expect(t, sess_feat.session_set_controller(sess, "flow.lua:commit", false), "a row names the controller")
	testing.expect(t, !sess_feat.session_set_controller(sess, "flow.lua:commit", false), "the same row changes nothing")
	automation_banner_emit(&dl, &layout, &pane, false)
	plain := len(dl.commands)
	testing.expect(t, plain > 0, "a controlled pane shows who drives it")
	for c in dl.commands {
		r := c.rect
		testing.expect(t, r[0] >= pane.rect[0] && r[0] + r[2] <= pane.rect[0] + pane.rect[2] && r[1] >= pane.rect[1], "the banner stays inside its pane")
	}

	tiny := mux_feat.Pane_Entry{session = sess, rect = {0, 0, 60, 40}}
	chrome_dl.ui_draw_list_clear(&dl)
	automation_banner_emit(&dl, &layout, &tiny, false)
	testing.expect_value(t, len(dl.commands), 0) // no room: nothing rather than a clipped pill
}

@(test)
test_held_notice_follows_typing_into_a_held_session :: proc(t: ^testing.T) {
	app := new(Term_App)
	defer free(app)
	sess := new(sess_feat.Terminal_Session)
	defer free(sess)
	app_automation_note_input(app, sess)
	testing.expect(t, !automation_notice_active(app.automation_notice, sess), "no automation: no warning")
	sess_feat.session_set_controller(sess, "flow.lua:commit", true)
	app_automation_note_input(app, sess)
	testing.expect(t, !automation_notice_active(app.automation_notice, sess), "a handoff passes input through: no warning")
	sess_feat.session_set_controller(sess, "flow.lua:commit", false)
	app_automation_note_input(app, sess)
	testing.expect(t, automation_notice_active(app.automation_notice, sess), "held input warns")
	other := new(sess_feat.Terminal_Session)
	defer free(other)
	testing.expect(t, !automation_notice_active(app.automation_notice, other), "only on that pane")
}

@(test)
test_takeover_dialog_is_modal_with_two_buttons :: proc(t: ^testing.T) {
	app := new(Term_App)
	defer free(app)
	layout := _layout()
	d := &app.takeover
	modal_anim_open(&d.anim)
	_ = modal_anim_update(&d.anim, 1.0)
	d.owner_len = copy(d.owner_buf[:], "flow.lua:commit")
	dl: chrome_dl.Ui_Draw_List
	chrome_dl.ui_draw_list_init(&dl)
	defer chrome_dl.ui_draw_list_destroy(&dl)
	takeover_dialog_emit_draw_list(d, &dl, &layout)
	cancel, take := d.button_rects[.Cancel], d.button_rects[.Take_Over]
	testing.expect(t, cancel[2] > 0 && take[2] > 0 && cancel[0] + cancel[2] <= take[0], "Cancel left of Take over")
	testing.expect(t, takeover_dialog_handle_key(app, sdl3.K_A), "modal: other keys are swallowed")
	testing.expect(t, takeover_dialog_handle_click(app, 1, 1), "modal: clicks outside are swallowed")
	testing.expect(t, takeover_dialog_handle_key(app, sdl3.K_ESCAPE) && !d.anim.visible, "esc cancels")
	testing.expect(t, !takeover_dialog_handle_key(app, sdl3.K_RETURN), "closed: keys go to the pane again")
}
