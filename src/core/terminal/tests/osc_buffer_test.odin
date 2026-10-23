package terminal_tests

// Regression tests for oversized control strings.
//
// OSC and APC payloads used to be stored in fixed 512-byte / silently truncated
// buffers, which cut clipboard transfers (OSC 52) and hyperlinks in half while
// still delivering the fragment to the consumer.

import "core:strings"
import "core:testing"
import term "../"
import parser "../parser"

_osc_capture :: struct {
	id:      int,
	payload: string,
	calls:   int,
	scratch: [dynamic]u8,
}

_osc_capture_proc :: proc(user_data: rawptr, osc_id: int, payload: string, term_ptr: rawptr) -> bool {
	capture := (^_osc_capture)(user_data)
	capture.id = osc_id
	capture.calls += 1
	clear(&capture.scratch)
	append(&capture.scratch, ..transmute([]u8)payload)
	capture.payload = string(capture.scratch[:])
	return true
}

@test
test_osc_payload_not_truncated :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 6, 40)
	defer term.terminal_destroy(&terminal)

	capture: _osc_capture
	defer delete(capture.scratch)
	term.terminal_register_osc(&terminal, 52, _osc_capture_proc, &capture)

	body := strings.repeat("A", 8192, context.temp_allocator)
	sequence := strings.concatenate({"\x1b]52;c;", body, "\x1b\\"}, context.temp_allocator)
	term.terminal_feed_string(&terminal, sequence)

	testing.expect_value(t, capture.calls, 1)
	testing.expect_value(t, capture.id, 52)
	// Payload excludes the "52;" prefix, so "c;" + body.
	testing.expect_value(t, len(capture.payload), len(body) + 2)
	testing.expect(t, strings.has_suffix(capture.payload, body), "the tail of a long OSC payload must survive")
}

@test
test_osc_overflow_is_dropped_whole :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 6, 40)
	defer term.terminal_destroy(&terminal)

	capture: _osc_capture
	defer delete(capture.scratch)
	term.terminal_register_osc(&terminal, 52, _osc_capture_proc, &capture)

	oversized := strings.repeat("B", parser.MAX_OSC_BUFFER + 32, context.temp_allocator)
	sequence := strings.concatenate({"\x1b]52;c;", oversized, "\x1b\\"}, context.temp_allocator)
	term.terminal_feed_string(&terminal, sequence)

	testing.expect_value(t, capture.calls, 0)

	// The parser must recover and deliver the next well-formed sequence.
	term.terminal_feed_string(&terminal, "\x1b]52;c;QUJD\x1b\\")
	testing.expect_value(t, capture.calls, 1)
	testing.expect_value(t, capture.payload, "c;QUJD")
}

@test
test_osc_terminated_by_bel_and_st :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 6, 40)
	defer term.terminal_destroy(&terminal)

	capture: _osc_capture
	defer delete(capture.scratch)
	term.terminal_register_osc(&terminal, 0, _osc_capture_proc, &capture)

	term.terminal_feed_string(&terminal, "\x1b]0;title-bel\x07")
	testing.expect_value(t, capture.calls, 1)
	testing.expect_value(t, capture.payload, "title-bel")

	term.terminal_feed_string(&terminal, "\x1b]0;title-st\x1b\\")
	testing.expect_value(t, capture.calls, 2)
	testing.expect_value(t, capture.payload, "title-st")
}
