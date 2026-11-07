package terminal_tests

// Behavioral unit tests for the OSC 7501 Program Status Protocol.

import "core:encoding/base64"
import "core:fmt"
import "core:testing"
import extension "../extension"
import term "../"
import parser "../parser"

@test
test_osc_7501_state_and_properties :: proc(t: ^testing.T) {
	msg := "Compiling packages (45/120)"
	b64_msg := base64.encode(transmute([]u8)msg, base64.ENC_TABLE, context.temp_allocator)

	// Format: state=working:app=cargo:kind=compile:title=term:msg=<b64>
	payload := fmt.tprintf("state=working:app=cargo:kind=compile:title=term-build:msg=%s", b64_msg)
	status, ok := extension.osc_7501_parse(payload)

	testing.expect(t, ok, "OSC 7501 payload must parse successfully")
	testing.expect_value(t, status.state, extension.Program_State.Working)
	testing.expect_value(t, extension.program_status_app(&status), "cargo")
	testing.expect_value(t, extension.program_status_title(&status), "term-build")
	testing.expect_value(t, extension.program_status_msg(&status), msg)
}

@test
test_osc_7501_blocked_state_plain_msg :: proc(t: ^testing.T) {
	payload := "state=blocked:app=claude:kind=auth:msg=Password required for sudo"
	status, ok := extension.osc_7501_parse(payload)

	testing.expect(t, ok)
	testing.expect_value(t, status.state, extension.Program_State.Blocked)
	testing.expect_value(t, extension.program_status_app(&status), "claude")
	testing.expect_value(t, extension.program_status_msg(&status), "Password required for sudo")
}

@test
test_osc_7501_clear_and_done_states :: proc(t: ^testing.T) {
	status_done, ok_done := extension.osc_7501_parse("state=done")
	testing.expect(t, ok_done)
	testing.expect_value(t, status_done.state, extension.Program_State.Done)

	status_clear, ok_clear := extension.osc_7501_parse("state=clear")
	testing.expect(t, ok_clear)
	testing.expect_value(t, status_clear.state, extension.Program_State.Clear)

	_, ok_bad := extension.osc_7501_parse("app=missing_state")
	testing.expect(t, !ok_bad, "payload without state must be rejected")
}

@test
test_osc_7501_probe_is_answered :: proc(t: ^testing.T) {
	// claude-code asks OSC 7501 ; ? and reports its state only after a reply
	// whose data starts with "?".
	terminal: term.Terminal
	term.terminal_init(&terminal, 6, 40)
	defer term.terminal_destroy(&terminal)
	term.terminal_feed_string(&terminal, "\x1b]7501;?\x1b\\")
	buf: [64]u8
	n := parser.parser_drain_response(&terminal.parser, buf[:])
	testing.expect_value(t, string(buf[:n]), "\x1b]7501;?1\x1b\\")
	term.terminal_feed_string(&terminal, "\x1b]7501;state=idle:app=x\x1b\\")
	testing.expect_value(t, parser.parser_drain_response(&terminal.parser, buf[:]), 0) // a report is not a query
}
