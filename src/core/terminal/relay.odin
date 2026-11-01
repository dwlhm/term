package core_terminal

import "core:bytes"
import parser "parser"

// Relay sits between a program and its viewers: every byte reaches the core's
// Terminal, and the viewer stream drops the queries that Terminal already
// answered (so the program never gets two replies). Escape sequences are held
// until complete; longer ones pass through unexamined.
RELAY_CSI_MAX    :: 64
RELAY_STRING_MAX :: 512

Relay_State :: enum u8 {
	Ground,
	Escape,
	Charset,
	Csi_Entry,
	Csi,
	Osc,
	Osc_Esc,
	Dcs,
	Dcs_Esc,
	Apc,
	Apc_Esc,
}

Relay :: struct {
	hold:        [RELAY_STRING_MAX]u8,
	hold_len:    int,
	state:       Relay_State,
	// passthrough: the sequence outgrew `hold` (or is an APC) and is being
	// forwarded unexamined until it ends.
	passthrough: bool,
}

relay_feed :: proc(r: ^Relay, t: ^Terminal, input: []u8, viewer_out: ^[dynamic]u8, replies_out: ^[dynamic]u8) {
	if r == nil || t == nil do return
	i := 0
	for i < len(input) {
		switch {
		case r.state == .Ground:
			i += _relay_ground(r, t, input[i:], viewer_out)
		case r.passthrough:
			i += _relay_passthrough(r, t, input[i:], viewer_out, replies_out)
		case:
			_relay_hold_byte(r, t, input[i], viewer_out, replies_out)
			i += 1
		}
	}
}

// relay_flush writes a held, incomplete sequence into the Terminal (e.g. before
// a snapshot), so the Terminal has seen every byte the program wrote.
relay_flush :: proc(r: ^Relay, t: ^Terminal) {
	if r == nil || t == nil do return
	if r.state != .Ground && !r.passthrough do terminal_feed_bytes(t, r.hold[:r.hold_len])
	r.hold_len, r.state, r.passthrough = 0, .Ground, false
}

// _relay_ground forwards plain bytes up to the next ESC, or starts holding at it.
_relay_ground :: proc(r: ^Relay, t: ^Terminal, input: []u8, viewer_out: ^[dynamic]u8) -> int {
	if input[0] == 0x1B {
		r.hold[0], r.hold_len, r.state = 0x1B, 1, .Escape
		return 1
	}
	n := bytes.index_byte(input, 0x1B)
	if n < 0 do n = len(input)
	terminal_feed_bytes(t, input[:n])
	append(viewer_out, ..input[:n])
	return n
}

_relay_hold_byte :: proc(r: ^Relay, t: ^Terminal, b: u8, viewer_out, replies_out: ^[dynamic]u8) {
	r.hold[r.hold_len] = b
	r.hold_len += 1
	if _relay_advance(r, b) {
		_relay_finish_held(r, t, viewer_out, replies_out)
		return
	}
	limit := RELAY_CSI_MAX if r.state == .Csi_Entry || r.state == .Csi else RELAY_STRING_MAX
	if r.state == .Apc || r.hold_len >= limit {
		// Too long to examine (or an APC, never a candidate): forward what is
		// held and stream the rest.
		terminal_feed_bytes(t, r.hold[:r.hold_len])
		append(viewer_out, ..r.hold[:r.hold_len])
		r.hold_len, r.passthrough = 0, true
	}
}

_relay_passthrough :: proc(r: ^Relay, t: ^Terminal, input: []u8, viewer_out, replies_out: ^[dynamic]u8) -> int {
	is_apc := r.state == .Apc || r.state == .Apc_Esc
	n := 0
	done := false
	for n < len(input) && !done {
		done = _relay_advance(r, input[n])
		n += 1
	}
	terminal_feed_bytes(t, input[:n])
	append(viewer_out, ..input[:n])
	if !done do return n
	// Kitty graphics replies belong to the viewer, which answers them itself.
	_relay_drain(t, replies_out, keep = !is_apc)
	r.state, r.passthrough = .Ground, false
	return n
}

// _relay_finish_held writes a complete sequence into the Terminal and forwards
// it to the viewer unless it is a query the Terminal answered.
_relay_finish_held :: proc(r: ^Relay, t: ^Terminal, viewer_out, replies_out: ^[dynamic]u8) {
	seq := r.hold[:r.hold_len]
	is_apc := len(seq) > 1 && seq[1] == '_'
	// Start from an empty response buffer so growth is attributable to `seq`
	// and a full buffer can never truncate its reply.
	_relay_drain(t, replies_out, keep = true)
	terminal_feed_bytes(t, seq)
	answered := t.parser.response_len > 0
	if !answered || !_relay_is_query(seq) do append(viewer_out, ..seq)
	_relay_drain(t, replies_out, keep = !is_apc)
	r.hold_len, r.state = 0, .Ground
}

// _relay_drain empties the Terminal's response buffer into `replies_out`
// (or discards it), minus in-band resize reports (`CSI 48;…t`): the viewer
// owns the pixel geometry and reports it itself.
_relay_drain :: proc(t: ^Terminal, replies_out: ^[dynamic]u8, keep: bool) {
	buf: [parser.MAX_RESPONSE_BUFFER]u8
	for {
		n := terminal_drain_response(t, buf[:])
		if n == 0 do return
		if keep do _relay_append_replies(replies_out, buf[:n])
	}
}

_relay_append_replies :: proc(replies_out: ^[dynamic]u8, data: []u8) {
	i := 0
	for i < len(data) {
		if bytes.has_prefix(data[i:], {0x1B, '[', '4', '8', ';'}) {
			end := bytes.index_byte(data[i:], 't')
			if end >= 0 {
				i += end + 1
				continue
			}
		}
		append(replies_out, data[i])
		i += 1
	}
}
