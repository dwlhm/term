package feature_session_tests

// Behavioral unit tests for Session Telemetry, Monitor & Detached Registry.

import "core:testing"
import "core:unicode/utf8"
import term "../../../core/terminal"
import extension "../../../core/terminal/extension"
import session "../"

@test
test_session_is_running_job_osc7501 :: proc(t: ^testing.T) {
	sess: session.Terminal_Session
	term.terminal_init(&sess.term, 24, 80)
	defer term.terminal_destroy(&sess.term)

	testing.expect(t, !session.session_is_running_job(&sess), "initially not running job")

	// Set OSC 7501 state = working
	sess.program_status.state = .Working
	testing.expect(t, session.session_is_running_job(&sess), "state=working must be recognized as active job")

	// Set OSC 7501 state = blocked
	sess.program_status.state = .Blocked
	testing.expect(t, session.session_is_running_job(&sess), "state=blocked must be recognized as active job")

	// Set OSC 7501 state = done
	sess.program_status.state = .Done
	testing.expect(t, !session.session_is_running_job(&sess), "state=done is not an active job")
}

@test
test_session_is_running_job_osc133 :: proc(t: ^testing.T) {
	sess: session.Terminal_Session
	term.terminal_init(&sess.term, 24, 80)
	defer term.terminal_destroy(&sess.term)

	// Shell integration OSC 133;C (command running)
	sess.command_running = true
	sess.in_prompt = false
	testing.expect(t, session.session_is_running_job(&sess), "OSC 133 command_running must be recognized")

	// Prompt idle (133;A)
	sess.command_running = false
	sess.in_prompt = true
	testing.expect(t, !session.session_is_running_job(&sess), "idle prompt must not be an active job")
}

@test
test_session_peek_last_line_resolves_egc_as_valid_utf8 :: proc(t: ^testing.T) {
	sess: session.Terminal_Session
	term.terminal_init(&sess.term, 4, 40)
	defer term.terminal_destroy(&sess.term)

	// VS16 cluster (EGC pool index ≥ U+110000) followed by a wide emoji (continuation cell).
	term.terminal_feed_string(&sess.term, "⏺️ ok 😀!")
	buf: [256]u8
	line := session.session_peek_last_line(&sess, buf[:])
	testing.expect(t, utf8.valid_string(line), "peeked line must be valid UTF-8 (NSString rejects invalid input)")
	testing.expect_value(t, line, "⏺️ ok 😀!")
}
