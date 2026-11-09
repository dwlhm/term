package term

// CLI pre-validation tests for `term session cancel` (spec 4.7, C3, U7).

import "core:testing"

@(test)
test_cancel_parse_args_defaults_and_custom :: proc(t: ^testing.T) {
	// Default is 3s
	sec, ok := _cancel_parse_args(nil)
	testing.expect(t, ok, "nil args ok")
	testing.expect_value(t, sec, 3)

	// -t 5
	sec, ok = _cancel_parse_args([]string{"-t", "5"})
	testing.expect(t, ok, "-t 5 ok")
	testing.expect_value(t, sec, 5)

	// --timeout 10
	sec, ok = _cancel_parse_args([]string{"--timeout", "10"})
	testing.expect(t, ok, "--timeout 10 ok")
	testing.expect_value(t, sec, 10)
}

@(test)
test_cancel_parse_args_invalid_rejected :: proc(t: ^testing.T) {
	// Missing argument to -t
	_, ok := _cancel_parse_args([]string{"-t"})
	testing.expect(t, !ok, "missing timeout rejected")

	// Negative or non-numeric timeout
	_, ok = _cancel_parse_args([]string{"-t", "0"})
	testing.expect(t, !ok, "0 timeout rejected")

	_, ok = _cancel_parse_args([]string{"-t", "-5"})
	testing.expect(t, !ok, "negative timeout rejected")

	_, ok = _cancel_parse_args([]string{"-t", "abc"})
	testing.expect(t, !ok, "non-numeric timeout rejected")

	// Unknown option
	_, ok = _cancel_parse_args([]string{"--bogus"})
	testing.expect(t, !ok, "unknown option rejected")
}
