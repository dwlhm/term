package term

import "core:testing"
import "core:time"
import "vendor:sdl3"
import chrome_dl "../../core/chrome/draw_list"

@(test)
test_resolve_role :: proc(t: ^testing.T) {
	testing.expect_value(t, app_resolve_role(Cli_Options{}), Instance_Role.Primary)
	testing.expect_value(t, app_resolve_role(Cli_Options{telemetry_path = "x"}), Instance_Role.Standalone)
	testing.expect_value(t, app_resolve_role(Cli_Options{grid_dump_dir = "x"}), Instance_Role.Standalone)
	testing.expect_value(t, app_resolve_role(Cli_Options{initial_cmd = "x"}), Instance_Role.Standalone)
}

@(test)
test_quit_with_nothing_shown_quits_at_once :: proc(t: ^testing.T) {
	for role in Instance_Role {
		app := new(Term_App)
		defer free(app)
		app.running, app.role = true, role
		app_request_quit_flow(app)
		testing.expect_value(t, app.running, false)
		testing.expect_value(t, app.quit.phase, Quit_Phase.Idle)
	}
}

@(test)
test_quit_asks_only_about_active_rows_and_cancels :: proc(t: ^testing.T) {
	app := new(Term_App)
	defer free(app)
	app.running, app.quit.phase = true, .Waiting
	app_quit_note_row(app, {id = 3, state = .Idle, title = "zsh"})
	app_quit_note_row(app, {id = 4, state = .Busy, active = true, title = "vim"})
	app_quit_note_row(app, {id = 4, state = .Busy, active = true, title = "vim"})
	app_quit_rows_arrived(app)
	testing.expect_value(t, app.quit.phase, Quit_Phase.Asking)
	testing.expect_value(t, app.quit.count, 1)
	testing.expect(t, app.quit.candidates[0].keep, "running programs default to keep running")
	testing.expect(t, app.quit.dialog.visible, "dialog open")
	testing.expect(t, quit_dialog_handle_key(app, sdl3.K_SPACE), "space handled")
	testing.expect(t, !app.quit.candidates[0].keep, "space toggles to kill")
	quit_dialog_handle_key(app, sdl3.K_ESCAPE)
	testing.expect_value(t, app.quit.phase, Quit_Phase.Idle)
	testing.expect_value(t, app.running, true)
}

@(test)
test_quit_without_active_rows_quits :: proc(t: ^testing.T) {
	app := new(Term_App)
	defer free(app)
	app.running, app.quit.phase = true, .Waiting
	app_quit_note_row(app, {id = 3, state = .Idle})
	app_quit_rows_arrived(app)
	testing.expect_value(t, app.running, false)
}

@(test)
test_wait_timeout_follows_quit_wait :: proc(t: ^testing.T) {
	app := new(Term_App)
	defer free(app)
	testing.expect_value(t, app_compute_wait_timeout_ms(app, false), -1)
	app.quit.phase = .Waiting
	app.quit.due_ns = time.tick_now()._nsec + 200 * 1_000_000
	ms := app_compute_wait_timeout_ms(app, false)
	testing.expect(t, ms > 0 && ms <= 201, "parks only until the quit wait ends")
}

@(test)
test_quit_dialog_emit_bounds_and_buttons :: proc(t: ^testing.T) {
	layout: Layout_State
	layout_init(&layout, 2.0, 8, 8, 1.0)
	layout.screen_w = 2560
	layout.screen_h = 1600

	d: Quit_Dialog_State
	quit_dialog_open(&d)
	_ = quit_dialog_update(&d, 1.0)

	cands := [2]Quit_Candidate{{id = 1, keep = true}, {id = 2, keep = false}}
	dl: chrome_dl.Ui_Draw_List
	chrome_dl.ui_draw_list_init(&dl)
	defer chrome_dl.ui_draw_list_destroy(&dl)

	quit_dialog_emit_draw_list(&d, cands[:], &dl, &layout)
	testing.expect_value(t, d.row_count, 2)
	for i in 0..<d.row_count {
		r := d.row_rects[i]
		testing.expect(t, r[0] >= d.modal_rect[0] && r[1] >= d.modal_rect[1] &&
			r[0]+r[2] <= d.modal_rect[0]+d.modal_rect[2] &&
			r[1]+r[3] <= d.modal_rect[1]+d.modal_rect[3], "quit row inside modal")
	}
	for b in Quit_Button {
		br := d.button_rects[b]
		testing.expect(t, br[2] > 0 && br[0] >= d.modal_rect[0] && br[0]+br[2] <= d.modal_rect[0]+d.modal_rect[2], "button inside modal")
	}
	testing.expect(t, d.button_rects[.Kill_All][0]+d.button_rects[.Kill_All][2] <= d.button_rects[.Keep_All][0], "Kill_All left of Keep_All")
	testing.expect(t, d.button_rects[.Keep_All][0]+d.button_rects[.Keep_All][2] <= d.button_rects[.Quit][0], "Keep_All left of Quit")
}
