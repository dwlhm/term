package term

// CLI pre-validation tests for `term session read --tail` (spec 4.4, T21–T23).

import "core:testing"

@(test)
test_T21_tail_two_conditions_error :: proc(t: ^testing.T) {
	bad := [][]string{
		{"1", "--tail", "--until", "x", "--exit"},
		{"1", "--tail", "--prompt", "--idle"},
		{"1", "--tail", "--until", "x", "--prompt"},
		{"1", "--tail", "--quiet", "1", "--exit"},
	}
	for args in bad {
		opts, ok := app_cli_parse_read(args)
		testing.expect(t, !ok, "rejects multiple conditions")
		testing.expect_value(t, opts.err_msg, "give one condition")
	}
}

@(test)
test_T22_condition_without_tail_error :: proc(t: ^testing.T) {
	bad := [][]string{
		{"1", "--until", "ready"},
		{"1", "--prompt"},
		{"1", "--exit"},
		{"1", "--idle"},
		{"1", "--quiet", "2"},
	}
	for args in bad {
		opts, ok := app_cli_parse_read(args)
		testing.expect(t, !ok, "rejects condition without --tail")
		testing.expect(
			t,
			opts.err_msg == "--until needs --tail" ||
			opts.err_msg == "--prompt needs --tail" ||
			opts.err_msg == "--exit needs --tail" ||
			opts.err_msg == "--idle needs --tail" ||
			opts.err_msg == "--quiet needs --tail",
			"requires condition needs --tail error",
		)
	}
}

@(test)
test_T23_tail_with_last_or_elements_error :: proc(t: ^testing.T) {
	bad := [][]string{
		{"1", "--tail", "--last"},
		{"1", "--tail", "--elements"},
	}
	for args in bad {
		opts, ok := app_cli_parse_read(args)
		testing.expect(t, !ok, "rejects --tail with --last/--elements")
		testing.expect_value(
			t,
			opts.err_msg,
			"--tail follows the screen: not with --last/--elements",
		)
	}
}
