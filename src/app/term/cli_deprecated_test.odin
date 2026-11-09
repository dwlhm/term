package term

// Deprecated verbs migration tests (spec 14, X1–X4).

import "core:testing"

@(test)
test_X1_observe_deprecated :: proc(t: ^testing.T) {
	handled, code := app_cli_agent([]string{"observe", "1"})
	testing.expect(t, handled)
	testing.expect_value(t, code, 1)
}

@(test)
test_X2_watch_wait_deprecated :: proc(t: ^testing.T) {
	h1, c1 := app_cli_agent([]string{"watch", "1"})
	testing.expect(t, h1)
	testing.expect_value(t, c1, 1)

	h2, c2 := app_cli_agent([]string{"wait", "1"})
	testing.expect(t, h2)
	testing.expect_value(t, c2, 1)
}

@(test)
test_X3_run_deprecated :: proc(t: ^testing.T) {
	handled, code := app_cli_agent([]string{"run", "1", "ls"})
	testing.expect(t, handled)
	testing.expect_value(t, code, 1)
}

@(test)
test_X4_requests_deprecated :: proc(t: ^testing.T) {
	verbs := []string{"tell", "result", "next", "progress", "answer"}
	for v in verbs {
		handled, code := app_cli_agent([]string{v, "1"})
		testing.expectf(t, handled, "handled %s", v)
		testing.expect_value(t, code, 1)
	}
}

@(test)
test_X4_new_endpoint_deprecated :: proc(t: ^testing.T) {
	handled, code := app_cli_agent([]string{"new", "--endpoint", "virt"})
	testing.expect(t, handled)
	testing.expect_value(t, code, 1)
}
