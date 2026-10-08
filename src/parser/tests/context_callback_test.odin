package parser_test

import "core:testing"
import "core:thread"
import p "../../parser"
import tg "../../terminal"

_CONTEXT_QUERY_COUNT :: 64
_CONTEXT_CAPTURE_CAP :: 4096

_Context_Capture :: struct {
	bytes: [_CONTEXT_CAPTURE_CAP]u8,
	len: int,
}

_Context_Fixture :: struct {
	parser: p.Parser,
	term: tg.Terminal,
	response, clipboard: _Context_Capture,
	query: string,
}

_context_capture :: proc(user_data: rawptr, data: []u8) {
	capture := (^_Context_Capture)(user_data)
	capture.len += copy(capture.bytes[capture.len:], data)
}

_context_fixture_init :: proc(f: ^_Context_Fixture, row, col: int, query: string) {
	p.parser_init(&f.parser)
	tg.terminal_init(&f.term, 8, 12)
	tg.terminal_move_cursor(&f.term, row, col)
	f.query = query
	f.parser.response_context_cb = _context_capture
	f.parser.response_user_data = &f.response
	f.parser.clipboard_context_cb = _context_capture
	f.parser.clipboard_user_data = &f.clipboard
}

_context_queries :: proc(f: ^_Context_Fixture) {
	for _ in 0..<_CONTEXT_QUERY_COUNT {
		p.parse_chunk(&f.parser, &f.term, transmute([]u8)f.query)
	}
}

_context_worker :: proc(worker: ^thread.Thread) {
	_context_queries((^_Context_Fixture)(worker.data))
}

_context_initializer :: proc(worker: ^thread.Thread) {
	parser: p.Parser
	for _ in 0..<_CONTEXT_QUERY_COUNT {
		p.parser_init(&parser)
	}
}

_context_expect :: proc(t: ^testing.T, f: ^_Context_Fixture, reply, clipboard: string, count: int) {
	testing.expect(t, f.response.len == len(reply) * count)
	for i in 0..<count {
		start := i * len(reply)
		testing.expect(t, string(f.response.bytes[start:start + len(reply)]) == reply, "reply must belong to its querying terminal")
	}
	testing.expect(t, f.clipboard.len == len(clipboard) * count)
	for i in 0..<count {
		start := i * len(clipboard)
		testing.expect(t, string(f.clipboard.bytes[start:start + len(clipboard)]) == clipboard, "OSC 52 must reach its own clipboard sink")
	}
}

@(test)
test_context_callbacks_alternating_and_concurrent_origins :: proc(t: ^testing.T) {
	left, right := new(_Context_Fixture), new(_Context_Fixture)
	defer free(left)
	defer free(right)
	_context_fixture_init(left, 0, 1, "\x1b[6n\x1b]52;c;YQ==\x07")
	_context_fixture_init(right, 2, 3, "\x1b[6n\x1b]52;c;Yg==\x07")
	defer tg.terminal_destroy(&left.term)
	defer tg.terminal_destroy(&right.term)
	// Querying workers own independent states while new parsers initialize.
	p.parse_chunk(&left.parser, &left.term, transmute([]u8)left.query)
	p.parse_chunk(&right.parser, &right.term, transmute([]u8)right.query)
	p.parse_chunk(&left.parser, &left.term, transmute([]u8)left.query)
	_context_expect(t, left, "\x1b[1;2R", "a", 2)
	_context_expect(t, right, "\x1b[3;4R", "b", 1)
	left.response, left.clipboard = {}, {}
	right.response, right.clipboard = {}, {}
	first := thread.create(_context_worker)
	second := thread.create(_context_worker)
	initializer := thread.create(_context_initializer)
	first.data = left
	second.data = right
	thread.start(first)
	thread.start(second)
	thread.start(initializer)
	thread.join(first)
	thread.join(second)
	thread.join(initializer)
	thread.destroy(first)
	thread.destroy(second)
	thread.destroy(initializer)
	_context_expect(t, left, "\x1b[1;2R", "a", _CONTEXT_QUERY_COUNT)
	_context_expect(t, right, "\x1b[3;4R", "b", _CONTEXT_QUERY_COUNT)
}

@(test)
test_context_callbacks_take_precedence_and_reset :: proc(t: ^testing.T) {
	fixture := new(_Context_Fixture)
	defer free(fixture)
	_context_fixture_init(fixture, 0, 0, "")
	defer tg.terminal_destroy(&fixture.term)
	_proto_reset()
	fixture.parser.response_cb = _proto_cb_response
	fixture.parser.clipboard_cb = _fx_cb_clipboard
	p.parser_emit_response(&fixture.parser, transmute([]u8)string("response"))
	p.parser_emit_clipboard(&fixture.parser, transmute([]u8)string("clipboard"))
	testing.expect(t, string(fixture.response.bytes[:fixture.response.len]) == "response")
	testing.expect(t, string(fixture.clipboard.bytes[:fixture.clipboard.len]) == "clipboard")
	testing.expect(t, len(_proto_response()) == 0)
	p.parser_init(&fixture.parser)
	testing.expect(t, !p.parser_has_response_sink(&fixture.parser) && !p.parser_has_clipboard_sink(&fixture.parser))
	testing.expect(t, fixture.parser.response_user_data == nil && fixture.parser.clipboard_user_data == nil)
}
