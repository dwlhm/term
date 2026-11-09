package term

// CLI pre-validation tests for `term session send`
// (spec 4.5, S2, S6, S22, S26).

import "core:testing"

@(test)
test_S2_send_no_action_error :: proc(t: ^testing.T) {
	opts, ok := app_cli_parse_send({"1"})
	testing.expect(t, !ok, "fails without actions")
	testing.expect_value(
		t,
		opts.err_msg,
		"send what? text, --key, --paste, --click...",
	)
}

@(test)
test_S6_send_unknown_key_error :: proc(t: ^testing.T) {
	opts, ok := app_cli_parse_send({"1", "a", "--key", "Bogus", "b"})
	testing.expect(t, !ok, "rejects unknown key")
	testing.expect_value(t, opts.err_msg, "unknown key Bogus")
}

@(test)
test_S22_send_invalid_scroll_error :: proc(t: ^testing.T) {
	bad := [][]string{
		{"1", "--scroll", "10,20", "sideways", "2"},
		{"1", "--scroll", "10,20", "up", "0"},
		{"1", "--scroll", "10,20", "down", "-1"},
	}
	for args in bad {
		opts, ok := app_cli_parse_send(args)
		testing.expect(t, !ok, "rejects invalid scroll args")
		testing.expect_value(
			t,
			opts.err_msg,
			"--scroll ROW,COL up|down N (N >= 1)",
		)
	}
}

@(test)
test_S26_send_bad_escape_error :: proc(t: ^testing.T) {
	opts, ok := app_cli_parse_send({"1", "--raw", "\\q"})
	testing.expect(t, !ok, "rejects bad escape")
	testing.expect_value(t, opts.err_msg, "bad escape \\q")
}
