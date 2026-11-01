package term

import "core:testing"
import "core:time"
import "vendor:sdl3"

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
