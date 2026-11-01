package core_terminal

import "core:bytes"

// _relay_advance steps the relay's sequence scanner by one byte and reports
// whether that byte ended the sequence. It mirrors where the parser leaves
// Ground and returns to it (including aborts), so the relay and the Terminal
// always agree on sequence boundaries.
_relay_advance :: proc(r: ^Relay, b: u8) -> (done: bool) {
	if b == 0x18 || b == 0x1A do return true // CAN/SUB abort any sequence
	switch r.state {
	case .Ground:
		return true
	case .Escape:
		return _relay_advance_escape(r, b)
	case .Charset:
		return true
	case .Csi_Entry:
		switch b {
		case '?', '>', '<', '=', '0' ..= '9', ';', ':', 0x20 ..= 0x2F:
			r.state = .Csi
			return false
		}
		return true
	case .Csi:
		switch b {
		case '0' ..= '9', ';', ':', 0x20 ..= 0x2F:
			return false
		}
		return true
	case .Osc:
		if b == 0x1B do r.state = .Osc_Esc
		return b == 0x07
	case .Osc_Esc:
		return true
	case .Dcs, .Apc:
		if b == 0x1B do r.state = .Dcs_Esc if r.state == .Dcs else .Apc_Esc
		return b == 0x07
	case .Dcs_Esc, .Apc_Esc:
		return b != 0x1B
	}
	return true
}

_relay_advance_escape :: proc(r: ^Relay, b: u8) -> bool {
	switch b {
	case '[':
		r.state = .Csi_Entry
	case ']':
		r.state = .Osc
	case 'P', '^', 'X':
		r.state = .Dcs
	case '_':
		r.state = .Apc
	case '(', ')', '*', '+', '-', '.', '/':
		r.state = .Charset
	case:
		return true
	}
	return false
}

// _relay_is_query reports whether a complete sequence is one the Terminal may
// answer: CSI with final byte in `cnpqtu` (DA, DSR, DECRQM, XTVERSION, XTWINOPS,
// kitty keyboard query), DECRQCRA (`CSI … * y`), an OSC containing `?`, or a
// DCS `$q` (DECRQSS) / `+q` (XTGETTCAP).
_relay_is_query :: proc(seq: []u8) -> bool {
	if len(seq) < 3 do return false
	body := seq[2:]
	switch seq[1] {
	case '[':
		final := seq[len(seq) - 1]
		switch final {
		case 'c', 'n', 'p', 'q', 't', 'u':
			return true
		case 'y':
			return bytes.index_byte(body, '*') >= 0
		}
	case ']':
		return bytes.index_byte(body, '?') >= 0
	case 'P':
		return bytes.has_prefix(body, {'$', 'q'}) || bytes.has_prefix(body, {'+', 'q'})
	}
	return false
}
