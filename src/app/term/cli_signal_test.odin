package term

// CLI pre-validation tests for `term session signal` (spec 4.5, G2, G3).

import "core:testing"

@(test)
test_G2_signal_names_and_numbers_accepted :: proc(t: ^testing.T) {
	// G2: TERM, SIGTERM, term, 9, 2, 15 all accepted
	cases := []struct {
		input: string,
		sig:   i32,
	}{
		{"TERM", 15},
		{"SIGTERM", 15},
		{"term", 15},
		{"INT", 2},
		{"sigint", 2},
		{"HUP", 1},
		{"KILL", 9},
		{"9", 9},
		{"2", 2},
		{"15", 15},
	}
	for c in cases {
		sig, ok := app_cli_parse_signal(c.input)
		testing.expect(t, ok, "valid signal accepted")
		testing.expect_value(t, sig, c.sig)
	}
}

@(test)
test_G3_signal_unknown_rejected :: proc(t: ^testing.T) {
	// G3: BOGUS, 0, 99 rejected
	bad := []string{"BOGUS", "0", "99", "-1", "NOSIG"}
	for b in bad {
		_, ok := app_cli_parse_signal(b)
		testing.expect(t, !ok, "invalid signal rejected")
	}
}
