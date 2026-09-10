package input

import "core:unicode/utf8"

// Input encode (Langkah 8): key/mouse -> bytes VT, normal mode only.
// No app-cursor, no bracketed paste, no mouse reporting.

// INPUT_ENCODE_MAX is the largest sequence input_encode can emit.
// Callers size their buffer to at least this many bytes. The longest
// encodings are the modified arrows (ESC [ 1 ; m X = 6 bytes) and
// Alt + 4-byte rune (ESC + 4 = 5 bytes); both fit with margin.
INPUT_ENCODE_MAX :: 8

// Input_Key_Kind names the key carried by an Input_Event.
Input_Key_Kind :: enum u8 {
	Printable,
	Enter,
	Backspace,
	Tab,
	Escape,
	Arrow_Up,
	Arrow_Down,
	Arrow_Left,
	Arrow_Right,
	Home,
	End,
	PgUp,
	PgDn,
	Ctrl,
	Alt_Mod,
}

// Input_Event is one decoded key press plus held modifiers.
// kind selects the key; rune carries the codepoint for Printable,
// the Ctrl target letter for Ctrl, and the base key for Alt_Mod.
// ctrl/alt/shift report held modifiers: on arrows they select the
// xterm modifier parameter, on Printable+ctrl they select the
// control-code mapping. alt/shift on other kinds are ignored.
Input_Event :: struct {
	kind:  Input_Key_Kind,
	rune:  rune,
	ctrl:  bool,
	alt:   bool,
	shift: bool,
}

// _MOD_SHIFT/_MOD_ALT/_MOD_CTRL are the xterm modifier bit weights.
// The CSI parameter is 1 + (shift?1:0) + (alt?2:0) + (ctrl?4:0),
// giving Shift=2, Alt=3, Shift+Alt=4, Ctrl=5, Shift+Ctrl=6,
// Alt+Ctrl=7, Shift+Alt+Ctrl=8.
_MOD_SHIFT :: 1
_MOD_ALT :: 2
_MOD_CTRL :: 4

// input_encode writes the VT byte sequence for ev into out and
// returns the bytes written (0 < n <= INPUT_ENCODE_MAX).
//
// All-or-nothing: when out is smaller than the full sequence the
// result is 0 and out is left untouched. Empty out and unknown
// kinds also return 0.
//
// Encodings (normal mode only):
//   Printable -> UTF-8 bytes of rune
//   Enter -> 0x0D, Backspace -> 0x7F, Tab -> 0x09, Escape -> 0x1B
//   arrows -> ESC [ X, or ESC [ 1 ; m X with modifiers per xterm
//   Home -> ESC [ H, End -> ESC [ F, PgUp -> ESC [ 5 ~, PgDn -> ESC [ 6 ~
//   Ctrl (+ ctrl flag + letter) -> 0x01-0x1A; Ctrl+Space -> 0x00;
//     Ctrl+@ -> 0x00, Ctrl+[ -> 0x1B, Ctrl+\ -> 0x1C, Ctrl+] -> 0x1D,
//     Ctrl+^ -> 0x1E, Ctrl+_/?// -> 0x1F (xterm: Ctrl+/ emits 0x1F)
//   Alt_Mod -> ESC prefix + key bytes (Alt+x -> ESC x, Alt+Enter -> ESC CR)
input_encode :: proc(ev: Input_Event, out: []u8) -> int {
	if len(out) == 0 {
		return 0
	}
	#partial switch ev.kind {
	case .Printable:
		if ev.ctrl {
			return _encode_ctrl(ev.rune, out)
		}
		if ev.rune < 0 || ev.rune > utf8.MAX_RUNE {
			return 0
		}
		buf, n := utf8.encode_rune(ev.rune)
		if n <= 0 || n > len(out) {
			return 0
		}
		copy(out, buf[:n])
		return n
	case .Enter:
		return _encode_byte(0x0D, out)
	case .Backspace:
		return _encode_byte(0x7F, out)
	case .Tab:
		return _encode_byte(0x09, out)
	case .Escape:
		return _encode_byte(0x1B, out)
	case .Arrow_Up:
		return _encode_arrow('A', ev, out)
	case .Arrow_Down:
		return _encode_arrow('B', ev, out)
	case .Arrow_Right:
		return _encode_arrow('C', ev, out)
	case .Arrow_Left:
		return _encode_arrow('D', ev, out)
	case .Home:
		return _encode_csi3('H', out)
	case .End:
		return _encode_csi3('F', out)
	case .PgUp:
		return _encode_csi4('5', '~', out)
	case .PgDn:
		return _encode_csi4('6', '~', out)
	case .Ctrl:
		return _encode_ctrl(ev.rune, out)
	case .Alt_Mod:
		return _encode_alt(ev, out)
	case:
		return 0
	}
}

// _encode_byte writes one fixed byte. 1-byte out always suffices.
_encode_byte :: proc(b: u8, out: []u8) -> int {
	if len(out) < 1 {
		return 0
	}
	out[0] = b
	return 1
}

// _encode_csi3 writes ESC [ X (arrows unmodified, Home, End).
_encode_csi3 :: proc(final: u8, out: []u8) -> int {
	if len(out) < 3 {
		return 0
	}
	out[0] = 0x1B
	out[1] = '['
	out[2] = final
	return 3
}

// _encode_csi4 writes ESC [ p ~ (PgUp/PgDn).
_encode_csi4 :: proc(param: u8, final: u8, out: []u8) -> int {
	if len(out) < 4 {
		return 0
	}
	out[0] = 0x1B
	out[1] = '['
	out[2] = param
	out[3] = final
	return 4
}

// _encode_arrow writes ESC [ X unmodified, else ESC [ 1 ; m X
// with the full xterm modifier table (m = 2..8).
_encode_arrow :: proc(final: u8, ev: Input_Event, out: []u8) -> int {
	m := 1
	if ev.shift {
		m += _MOD_SHIFT
	}
	if ev.alt {
		m += _MOD_ALT
	}
	if ev.ctrl {
		m += _MOD_CTRL
	}
	if m == 1 {
		return _encode_csi3(final, out)
	}
	if len(out) < 6 {
		return 0
	}
	out[0] = 0x1B
	out[1] = '['
	out[2] = '1'
	out[3] = ';'
	out[4] = '0' + u8(m)
	out[5] = final
	return 6
}

// _encode_ctrl maps a letter to its control code: a-z/A-Z -> 0x01-0x1A,
// Space/@ -> 0x00, [ -> 0x1B, \ -> 0x1C, ] -> 0x1D, ^ -> 0x1E,
// _/?// -> 0x1F. Anything else -> 0 (unknown).
_encode_ctrl :: proc(r: rune, out: []u8) -> int {
	b: u8
	switch {
	case r >= 'a' && r <= 'z':
		b = u8(r - 'a' + 1)
	case r >= 'A' && r <= 'Z':
		b = u8(r - 'A' + 1)
	case r == ' ' || r == '@':
		b = 0x00
	case r == '[':
		b = 0x1B
	case r == '\\':
		b = 0x1C
	case r == ']':
		b = 0x1D
	case r == '^':
		b = 0x1E
	case r == '_' || r == '?' || r == '/':
		b = 0x1F
	case:
		return 0
	}
	return _encode_byte(b, out)
}

// _encode_alt writes ESC followed by the base key bytes: CR for
// Enter (rune '\r'/'\n'), the control code when ctrl is held, else
// the UTF-8 bytes of rune. A zero rune is unknown -> 0.
_encode_alt :: proc(ev: Input_Event, out: []u8) -> int {
	inner: [INPUT_ENCODE_MAX]u8
	n := 0
	switch {
	case ev.rune == '\r' || ev.rune == '\n':
		inner[0] = 0x0D
		n = 1
	case ev.ctrl:
		n = _encode_ctrl(ev.rune, inner[:])
	case ev.rune != 0 && ev.rune <= utf8.MAX_RUNE && ev.rune >= 0:
		ebuf, w := utf8.encode_rune(ev.rune)
		copy(inner[:], ebuf[:w])
		n = w
	}
	if n <= 0 || 1 + n > len(out) {
		return 0
	}
	out[0] = 0x1B
	copy(out[1:], inner[:n])
	return 1 + n
}
