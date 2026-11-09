package term

import "core:testing"

@(test)
test_cli_quit_help :: proc(t: ^testing.T) {
	handled, code := app_run_control_cli([]string{"term", "quit", "--help"})
	testing.expect(t, handled)
	testing.expect_value(t, code, 0)
}

@(test)
test_cli_quit_not_running :: proc(t: ^testing.T) {
	handled, code := app_run_control_cli([]string{"term", "quit"})
	testing.expect(t, handled)
	testing.expect_value(t, code, 0)
}

@(test)
test_cli_kill_not_running :: proc(t: ^testing.T) {
	handled, code := app_run_control_cli([]string{"term", "kill"})
	testing.expect(t, handled)
	testing.expect_value(t, code, 0)
}
