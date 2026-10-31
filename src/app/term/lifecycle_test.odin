package term

import "core:testing"

@(test)
test_resolve_role :: proc(t: ^testing.T) {
	testing.expect_value(t, app_resolve_role(Cli_Options{}), Instance_Role.Primary)
	testing.expect_value(t, app_resolve_role(Cli_Options{telemetry_path = "x"}), Instance_Role.Standalone)
	testing.expect_value(t, app_resolve_role(Cli_Options{grid_dump_dir = "x"}), Instance_Role.Standalone)
	testing.expect_value(t, app_resolve_role(Cli_Options{initial_cmd = "x"}), Instance_Role.Standalone)
}

@(test)
test_request_hide_standalone_quits :: proc(t: ^testing.T) {
	app := new(Term_App)
	defer free(app)
	app.running = true
	app.role = .Standalone
	app_request_hide(app)
	testing.expect_value(t, app.running, false)
	testing.expect_value(t, app.window_hidden, false)
}

@(test)
test_request_hide_primary_hides :: proc(t: ^testing.T) {
	app := new(Term_App)
	defer free(app)
	app.running = true
	app.role = .Primary
	app_request_hide(app)
	testing.expect_value(t, app.running, true)
	testing.expect_value(t, app.window_hidden, true)
	testing.expect_value(t, app.window_focused, false)
	app_request_hide(app)
	testing.expect_value(t, app.running, true)
	testing.expect_value(t, app.window_hidden, true)
	testing.expect_value(t, app.window_focused, false)
}

@(test)
test_wait_timeout_hidden_parks :: proc(t: ^testing.T) {
	app := new(Term_App)
	defer free(app)
	app.window_hidden = true
	testing.expect_value(t, app_compute_wait_timeout_ms(app, false), -1)
	testing.expect_value(t, app_compute_wait_timeout_ms(app, true), 0)

	// Rendering is skipped while hidden, so pending damage must not spin the loop.
	app.composer.sched.damage_pending = true
	app.composer.sched.force_next = true
	app.last_frame_acquire_failed = true
	testing.expect_value(t, app_compute_wait_timeout_ms(app, false), -1)
}