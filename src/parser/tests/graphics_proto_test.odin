package parser_test

import "core:testing"
import tg "../../terminal"
import p "../../parser"

// --- Kitty Graphics Protocol (APC) Capture Tests ---
//
// The APC transport is ESC _ G <control>;<payload> ST. The parser accumulates
// everything after ESC _ into a reused fixed buffer, so the graphics callback
// must copy the control/payload slices into stable package-scoped buffers
// before the next sequence overwrites them.

_APC_MAX_CALLS :: 8

// Thread-local capture buffers: Odin runs package tests on multiple threads,
// so shared globals would race between tests running concurrently.
@(thread_local)
_apc_ctl_log: [_APC_MAX_CALLS][256]u8
@(thread_local)
_apc_ctl_log_len: [_APC_MAX_CALLS]int
@(thread_local)
_apc_pl_log: [_APC_MAX_CALLS][256]u8
@(thread_local)
_apc_pl_log_len: [_APC_MAX_CALLS]int
@(thread_local)
_apc_calls: int

_apc_capture_cb :: proc(user_data: rawptr, t: ^tg.Terminal, control: []u8, payload: []u8) {
	_ = user_data
	_ = t
	if _apc_calls >= _APC_MAX_CALLS { return }
	idx := _apc_calls
	n := min(len(control), len(_apc_ctl_log[idx]))
	copy(_apc_ctl_log[idx][:n], control[:n])
	_apc_ctl_log_len[idx] = n
	m := min(len(payload), len(_apc_pl_log[idx]))
	copy(_apc_pl_log[idx][:m], payload[:m])
	_apc_pl_log_len[idx] = m
	_apc_calls += 1
}

_apc_reset :: proc() {
	for i in 0..<_APC_MAX_CALLS {
		_apc_ctl_log_len[i] = 0
		_apc_pl_log_len[i] = 0
	}
	_apc_calls = 0
}

_apc_control :: proc(idx: int) -> []u8 {
	return _apc_ctl_log[idx][:_apc_ctl_log_len[idx]]
}

_apc_payload :: proc(idx: int) -> []u8 {
	return _apc_pl_log[idx][:_apc_pl_log_len[idx]]
}

@(test)
test_apc_kgp_basic_split :: proc(t: ^testing.T) {
	_apc_reset()
	parser: p.Parser
	p.parser_init(&parser)
	parser.graphics_cb = _apc_capture_cb

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	seq := "\x1b_G a=T,f=100,s=1,v=1;PHB5bGVz\x1b\\"
	p.parse_chunk(&parser, &term, transmute([]u8)seq)

	testing.expect(t, _apc_calls == 1, "exactly one graphics callback expected")
	want_control := "a=T,f=100,s=1,v=1"
	want_payload := "PHB5bGVz"
	_proto_bytes_eq(t, _apc_control(0), transmute([]u8)want_control, "control must drop the G identifier and space")
	_proto_bytes_eq(t, _apc_payload(0), transmute([]u8)want_payload, "payload must follow the first ';'")
}

@(test)
test_apc_kgp_no_space_after_g :: proc(t: ^testing.T) {
	_apc_reset()
	parser: p.Parser
	p.parser_init(&parser)
	parser.graphics_cb = _apc_capture_cb

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Same as the basic case but with no space between 'G' and the control.
	seq := "\x1b_Ga=T,f=100,s=1,v=1;PHB5bGVz\x1b\\"
	p.parse_chunk(&parser, &term, transmute([]u8)seq)

	testing.expect(t, _apc_calls == 1, "exactly one graphics callback expected")
	want_control := "a=T,f=100,s=1,v=1"
	want_payload := "PHB5bGVz"
	_proto_bytes_eq(t, _apc_control(0), transmute([]u8)want_control, "optional space absence must be tolerated")
	_proto_bytes_eq(t, _apc_payload(0), transmute([]u8)want_payload, "payload must follow the first ';'")
}

@(test)
test_apc_kgp_no_semicolon :: proc(t: ^testing.T) {
	_apc_reset()
	parser: p.Parser
	p.parser_init(&parser)
	parser.graphics_cb = _apc_capture_cb

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	seq := "\x1b_G a=q\x1b\\"
	p.parse_chunk(&parser, &term, transmute([]u8)seq)

	testing.expect(t, _apc_calls == 1, "exactly one graphics callback expected")
	want_control := "a=q"
	_proto_bytes_eq(t, _apc_control(0), transmute([]u8)want_control, "control must be the whole body when no ';'")
	testing.expect(t, len(_apc_payload(0)) == 0, "payload must be empty when no ';'")
}

@(test)
test_apc_kgp_bel_terminator :: proc(t: ^testing.T) {
	_apc_reset()
	parser: p.Parser
	p.parser_init(&parser)
	parser.graphics_cb = _apc_capture_cb

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	seq := "\x1b_G a=T,f=100,s=1,v=1;PHB5bGVz\x07"
	p.parse_chunk(&parser, &term, transmute([]u8)seq)

	testing.expect(t, _apc_calls == 1, "exactly one graphics callback expected")
	want_control := "a=T,f=100,s=1,v=1"
	want_payload := "PHB5bGVz"
	_proto_bytes_eq(t, _apc_control(0), transmute([]u8)want_control, "BEL-terminated APC must deliver the same control")
	_proto_bytes_eq(t, _apc_payload(0), transmute([]u8)want_payload, "BEL-terminated APC must deliver the same payload")
}

@(test)
test_apc_kgp_st_terminator :: proc(t: ^testing.T) {
	_apc_reset()
	parser: p.Parser
	p.parser_init(&parser)
	parser.graphics_cb = _apc_capture_cb

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Single-byte C1 String Terminator (0x9C).
	seq := "\x1b_G a=T,f=100,s=1,v=1;PHB5bGVz\x9c"
	p.parse_chunk(&parser, &term, transmute([]u8)seq)

	testing.expect(t, _apc_calls == 1, "exactly one graphics callback expected")
	want_control := "a=T,f=100,s=1,v=1"
	want_payload := "PHB5bGVz"
	_proto_bytes_eq(t, _apc_control(0), transmute([]u8)want_control, "ST-terminated APC must deliver the same control")
	_proto_bytes_eq(t, _apc_payload(0), transmute([]u8)want_payload, "ST-terminated APC must deliver the same payload")
}

@(test)
test_apc_kgp_consecutive_sequences :: proc(t: ^testing.T) {
	_apc_reset()
	parser: p.Parser
	p.parser_init(&parser)
	parser.graphics_cb = _apc_capture_cb

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	seq := "\x1b_G a=T,f=100,s=1,v=1;PHB5bGVz\x1b\\\x1b_G a=q\x1b\\"
	p.parse_chunk(&parser, &term, transmute([]u8)seq)

	testing.expect(t, _apc_calls == 2, "two consecutive APCs must fire two callbacks")
	want_control0 := "a=T,f=100,s=1,v=1"
	want_payload0 := "PHB5bGVz"
	want_control1 := "a=q"
	_proto_bytes_eq(t, _apc_control(0), transmute([]u8)want_control0, "first APC control must be delivered first")
	_proto_bytes_eq(t, _apc_payload(0), transmute([]u8)want_payload0, "first APC payload must be delivered first")
	_proto_bytes_eq(t, _apc_control(1), transmute([]u8)want_control1, "second APC control must be delivered second")
	testing.expect(t, len(_apc_payload(1)) == 0, "second APC must have an empty payload")
}

@(test)
test_apc_non_kgp_identifier_ignored :: proc(t: ^testing.T) {
	_apc_reset()
	parser: p.Parser
	p.parser_init(&parser)
	parser.graphics_cb = _apc_capture_cb

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	seq := "\x1b_X foo;bar\x1b\\"
	p.parse_chunk(&parser, &term, transmute([]u8)seq)

	testing.expect(t, _apc_calls == 0, "non-KGP APC identifier must not invoke the graphics callback")
}

@(test)
test_apc_empty_body_ignored :: proc(t: ^testing.T) {
	_apc_reset()
	parser: p.Parser
	p.parser_init(&parser)
	parser.graphics_cb = _apc_capture_cb

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	seq := "\x1b_\x1b\\"
	p.parse_chunk(&parser, &term, transmute([]u8)seq)

	testing.expect(t, _apc_calls == 0, "empty APC must not invoke the graphics callback")
}

@(test)
test_apc_osc52_regression :: proc(t: ^testing.T) {
	_fx_reset()
	parser: p.Parser
	p.parser_init(&parser)
	parser.clipboard_cb = _fx_cb_clipboard

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// OSC 52 clipboard write: base64 "aGk=" decodes to "hi".
	p.parse_chunk(&parser, &term, []u8{0x1B, ']', '5', '2', ';', 'c', ';', 'a', 'G', 'k', '=', 0x07})
	_fx_bytes_eq(t, _fx_clipboard(), []u8{'h', 'i'}, "OSC 52 clipboard write must still fire after APC support")
}
