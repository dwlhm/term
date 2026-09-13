package input

import "core:unicode/utf8"

// Input encode (Phase 8): key/mouse -> bytes VT, normal mode only.
// No app-cursor, no bracketed paste, no mouse reporting.

// INPUT_ENCODE_MAX is the largest sequence input_encode can emit.
// Callers size their buffer to at least this many bytes. The longest
// legacy encodings are the modified arrows (ESC [ 1 ; m X = 6 bytes) and
// Alt + 4-byte rune (ESC + 4 = 5 bytes); kitty CSI u sequences need up to
// 12 bytes (ESC [ ddddd ; ddd u), so the cap leaves margin for those.
INPUT_ENCODE_MAX :: 16

// INPUT_DELETE_CSI_PARAM is the xterm parameter for the Delete key.
INPUT_DELETE_CSI_PARAM :: u8('3')

// Input_Event_Type distinguishes PTY keys from terminal-local events.
Input_Event_Type :: enum u8 {
	Key,
	Pointer,
	Local,
}

// Input_Pointer_Kind identifies one terminal-local pointer transition.
Input_Pointer_Kind :: enum u8 {
	Motion,
	Button_Down,
	Button_Up,
	Wheel,
}

// Input_Local_Action identifies an action handled by the application.
Input_Local_Action :: enum u8 {
	None,
	Copy,
	Paste,
	Zoom_In,
	Zoom_Out,
}

// Input_Pointer_Event carries SDL mouse data without terminal mouse-reporting
// bytes. Coordinates are in window pixels; wheel_integer_* are SDL's whole
// scroll ticks and wheel_* preserve the high-resolution deltas.
Input_Pointer_Event :: struct {
	kind:              Input_Pointer_Kind,
	x, y:              f32,
	dx, dy:            f32,
	button:            u8,
	pressed:           bool,
	primary_down:      bool,
	wheel_x, wheel_y:  f32,
	wheel_integer_x:   i32,
	wheel_integer_y:   i32,
	wheel_flipped:     bool,
	shift:             bool,
}

// Input_Key_Kind names the key carried by a key Input_Event.
Input_Key_Kind :: enum u8 {
	Printable,
	Enter,
	Backspace,
	Delete,
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

// Input_Event is one translated SDL event. Key events retain the original
// key-oriented fields; pointer and local events use pointer/action instead.
// Non-key events are local to the terminal application and encode to zero
// PTY bytes.
Input_Event :: struct {
	event_type: Input_Event_Type,
	kind:       Input_Key_Kind,
	rune:       rune,
	ctrl:       bool,
	alt:        bool,
	shift:      bool,
	gui:        bool,
	pointer:    Input_Pointer_Event,
	action:     Input_Local_Action,
}

// _MOD_SHIFT/_MOD_ALT/_MOD_CTRL are the xterm modifier bit weights.
// The CSI parameter is 1 + (shift?1:0) + (alt?2:0) + (ctrl?4:0),
// giving Shift=2, Alt=3, Shift+Alt=4, Ctrl=5, Shift+Ctrl=6,
// Alt+Ctrl=7, Shift+Alt+Ctrl=8.
_MOD_SHIFT :: 1
_MOD_ALT :: 2
_MOD_CTRL :: 4

// _kitty_mods computes the kitty 1-based modifier value for ev
// (shift=1, alt=2, ctrl=4, super/gui=8). Matches the legacy xterm weights
// for shift/alt/ctrl and extends them with the GUI key as super.
_kitty_mods :: proc(ev: Input_Event) -> int {
	m := 1
	if ev.shift {
		m += 1
	}
	if ev.alt {
		m += 2
	}
	if ev.ctrl {
		m += 4
	}
	if ev.gui {
		m += 8
	}
	return m
}

// _kitty_unshifted maps a rune to its unshifted CSI u codepoint.
// Letters are lowercased per the kitty spec (ctrl+shift+a is CSI 97, never
// CSI 65); other runes pass through unchanged. Returns 0 when invalid.
// Limitation: physical-layout unshifting (e.g. '@' -> '2') needs key
// position info the Input_Event does not carry, so symbols encode as-is.
_kitty_unshifted :: proc(r: rune) -> u32 {
	if r >= 'A' && r <= 'Z' {
		return u32(r + 32)
	}
	if r <= 0 || r > utf8.MAX_RUNE {
		return 0
	}
	return u32(r)
}

// _write_decimal writes v as decimal ASCII into out, returning bytes written
// or 0 when out is too small.
_write_decimal :: proc(out: []u8, v: u32) -> int {
	if v == 0 {
		if len(out) < 1 {
			return 0
		}
		out[0] = '0'
		return 1
	}
	tmp: [10]u8
	tn := 0
	x := v
	for x > 0 {
		tmp[tn] = u8(x % 10) + '0'
		tn += 1
		x /= 10
	}
	if len(out) < tn {
		return 0
	}
	for i in 0..<tn {
		out[i] = tmp[tn - 1 - i]
	}
	return tn
}

// _encode_csi_u writes ESC [ code [;mods] u (kitty keyboard encoding).
// The modifier field is omitted when mods == 1 (no modifiers).
// All-or-nothing: returns 0 and leaves out untouched when it does not fit.
_encode_csi_u :: proc(code: u32, mods: int, out: []u8) -> int {
	tmp: [16]u8
	if len(tmp) < 4 {
		return 0
	}
	tmp[0] = 0x1B
	tmp[1] = '['
	n := 2
	w := _write_decimal(tmp[n:], code)
	if w == 0 {
		return 0
	}
	n += w
	if mods != 1 {
		if n + 1 >= len(tmp) {
			return 0
		}
		tmp[n] = ';'
		n += 1
		w = _write_decimal(tmp[n:], u32(mods))
		if w == 0 {
			return 0
		}
		n += w
	}
	if n >= len(tmp) {
		return 0
	}
	tmp[n] = 'u'
	n += 1
	if n > len(out) {
		return 0
	}
	copy(out, tmp[:n])
	return n
}

// _kitty_disambiguate reports whether the disambiguate enhancement is active.
_kitty_disambiguate :: proc(kitty_flags: u8) -> bool {
	return kitty_flags & 1 != 0
}

// input_encode writes the VT byte sequence for ev into out and
// returns the bytes written (0 < n <= INPUT_ENCODE_MAX).
//
// All-or-nothing: when out is smaller than the full sequence the
// result is 0 and out is left untouched. Empty out and unknown
// kinds also return 0.
//
// kitty_flags carries the terminal's active kitty keyboard enhancement flags
// (default 0 = legacy). With disambiguate (bit 1), ambiguous keys (Escape,
// ctrl/alt ASCII combos) encode as CSI u per the kitty keyboard protocol;
// Enter/Tab/Backspace stay legacy so a crashed program never traps the user.
//
// Encodings (normal mode only):
//   Printable -> UTF-8 bytes of rune
//   Enter -> 0x0D, Backspace -> 0x7F, Tab -> 0x09 (Shift+Tab -> ESC[Z),
//     Escape -> 0x1B
//   arrows -> ESC [ X, or ESC [ 1 ; m X with modifiers per xterm
//   Home -> ESC [ H, End -> ESC [ F, PgUp -> ESC [ 5 ~, PgDn -> ESC [ 6 ~
//   Delete -> ESC [ 3 ~, or ESC [ 3 ; m ~ with modifiers per xterm
//   Ctrl (+ ctrl flag + letter) -> 0x01-0x1A; Ctrl+Space -> 0x00;
//     Ctrl+@ -> 0x00, Ctrl+[ -> 0x1B, Ctrl+\ -> 0x1C, Ctrl+] -> 0x1D,
//     Ctrl+^ -> 0x1E, Ctrl+_/?// -> 0x1F (xterm: Ctrl+/ emits 0x1F)
//   Alt_Mod -> ESC prefix + key bytes (Alt+x -> ESC x, Alt+Enter -> ESC CR)
input_encode :: proc(ev: Input_Event, out: []u8, kitty_flags: u8 = 0, app_cursor: bool = false) -> int {
	if len(out) == 0 {
		return 0
	}
	if ev.event_type != .Key {
		return 0
	}
	disambiguate := _kitty_disambiguate(kitty_flags)
	#partial switch ev.kind {
	case .Printable:
		if ev.ctrl || (disambiguate && ev.alt) {
			if disambiguate {
				code := _kitty_unshifted(ev.rune)
				if code == 0 {
					return 0
				}
				return _encode_csi_u(code, _kitty_mods(ev), out)
			}
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
		if ev.gui {
			return _encode_byte(0x15, out)
		}
		if ev.ctrl {
			return _encode_byte(0x17, out)
		}
		return _encode_byte(0x7F, out)
	case .Delete:
		if ev.gui {
			return _encode_byte(0x0B, out)
		}
		if ev.ctrl {
			if !disambiguate {
				return _encode_alt_rune('d', out)
			}
		}
		return _encode_csi_tilde(INPUT_DELETE_CSI_PARAM, ev, out)
	case .Tab:
		if ev.shift && !ev.ctrl && !ev.alt {
			return _encode_csi3('Z', out)
		}
		return _encode_byte(0x09, out)
	case .Escape:
		if disambiguate {
			return _encode_csi_u(27, _kitty_mods(ev), out)
		}
		return _encode_byte(0x1B, out)
	case .Arrow_Up:
		return _encode_arrow('A', ev, out, app_cursor)
	case .Arrow_Down:
		return _encode_arrow('B', ev, out, app_cursor)
	case .Arrow_Right:
		return _encode_arrow('C', ev, out, app_cursor)
	case .Arrow_Left:
		return _encode_arrow('D', ev, out, app_cursor)
	case .Home:
		return _encode_csi3('H', out)
	case .End:
		return _encode_csi3('F', out)
	case .PgUp:
		return _encode_csi4('5', '~', out)
	case .PgDn:
		return _encode_csi4('6', '~', out)
	case .Ctrl:
		if disambiguate {
			code := _kitty_unshifted(ev.rune)
			if code == 0 {
				return 0
			}
			// The Ctrl kind implies the ctrl bit even when the flag is absent.
			m := _kitty_mods(ev)
			if (m - 1) & 4 == 0 {
				m += 4
			}
			return _encode_csi_u(code, m, out)
		}
		return _encode_ctrl(ev.rune, out)
	case .Alt_Mod:
		// Enter/Tab/Backspace/Escape stay legacy even when disambiguated
		// (kitty exception: the user must always be able to type reset).
		if disambiguate && (ev.alt || ev.ctrl) && ev.rune != '\r' && ev.rune != '\n' && ev.rune != '\x7f' && ev.rune != '\t' && ev.rune != '\x1b' {
			code := _kitty_unshifted(ev.rune)
			if code == 0 {
				return 0
			}
			// The Alt_Mod kind implies the alt bit even when the flag is absent.
			m := _kitty_mods(ev)
			if (m - 1) & 2 == 0 {
				m += 2
			}
			return _encode_csi_u(code, m, out)
		}
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

// _encode_csi_tilde writes ESC [ p ~, adding the xterm modifier parameter
// when Shift, Alt, or Ctrl is held.
_encode_csi_tilde :: proc(param: u8, ev: Input_Event, out: []u8) -> int {
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
		if len(out) < 4 {
			return 0
		}
		out[0] = 0x1B
		out[1] = '['
		out[2] = param
		out[3] = '~'
		return 4
	}
	if len(out) < 6 {
		return 0
	}
	out[0] = 0x1B
	out[1] = '['
	out[2] = param
	out[3] = ';'
	out[4] = '0' + u8(m)
	out[5] = '~'
	return 6
}

// _encode_arrow writes ESC O X in app_cursor mode unmodified, else ESC [ X,
// or ESC [ 1 ; m X with modifiers per xterm (m = 2..8).
_encode_arrow :: proc(final: u8, ev: Input_Event, out: []u8, app_cursor: bool = false) -> int {
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
		if app_cursor {
			if len(out) < 3 {
				return 0
			}
			out[0] = 0x1B
			out[1] = 'O'
			out[2] = final
			return 3
		}
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

_encode_alt_rune :: proc(r: rune, out: []u8) -> int {
	if r <= 0 || r > utf8.MAX_RUNE {
		return 0
	}
	buf, w := utf8.encode_rune(r)
	if w <= 0 || 1 + w > len(out) {
		return 0
	}
	out[0] = 0x1B
	copy(out[1:], buf[:w])
	return 1 + w
}

// mouse_encode_sgr_full encodes a pointer event into SGR 1006 format:
// \e[<btn;col;rowM (press/motion) or \e[<btn;col;rowm (release).
// Button codes per xterm SGR 1006:
// - Left = 0, Middle = 1, Right = 2
// - Motion = +32 (drag motion or motion event)
// - Wheel Up = 64, Wheel Down = 65
// - Shift modifier = +4
mouse_encode_sgr_full :: proc(pointer: Input_Pointer_Event, col, row: int, shift: bool, out: []u8) -> int {
	btn := 0
	final: u8 = 'M'

	switch pointer.kind {
	case .Wheel:
		final = 'M'
		if pointer.wheel_y > 0 || pointer.wheel_integer_y > 0 {
			btn = 64
		} else {
			btn = 65
		}
	case .Button_Down:
		final = 'M'
		switch pointer.button {
		case 1: btn = 0
		case 2: btn = 1
		case 3: btn = 2
		case:   btn = 0
		}
	case .Button_Up:
		final = 'm'
		switch pointer.button {
		case 1: btn = 0
		case 2: btn = 1
		case 3: btn = 2
		case:   btn = 0
		}
	case .Motion:
		final = 'M'
		if pointer.primary_down {
			btn = 32
		} else if pointer.button == 2 {
			btn = 1 + 32
		} else if pointer.button == 3 {
			btn = 2 + 32
		} else {
			btn = 35
		}
	}

	if shift || pointer.shift {
		btn += 4
	}

	tmp: [32]u8
	tmp[0] = 0x1B
	tmp[1] = '['
	tmp[2] = '<'
	n := 3

	w := _write_decimal(tmp[n:], u32(btn))
	if w == 0 do return 0
	n += w

	if n >= len(tmp) do return 0
	tmp[n] = ';'
	n += 1

	c := col
	if c < 1 do c = 1
	w = _write_decimal(tmp[n:], u32(c))
	if w == 0 do return 0
	n += w

	if n >= len(tmp) do return 0
	tmp[n] = ';'
	n += 1

	r := row
	if r < 1 do r = 1
	w = _write_decimal(tmp[n:], u32(r))
	if w == 0 do return 0
	n += w

	if n >= len(tmp) do return 0
	tmp[n] = final
	n += 1

	if n > len(out) do return 0
	copy(out, tmp[:n])
	return n
}

// mouse_encode_sgr_short delegates to mouse_encode_sgr_full using pointer.shift.
mouse_encode_sgr_short :: proc(pointer: Input_Pointer_Event, col, row: int, out: []u8) -> int {
	return mouse_encode_sgr_full(pointer, col, row, pointer.shift, out)
}

// mouse_encode_sgr supports both full and short call forms.
mouse_encode_sgr :: proc{mouse_encode_sgr_full, mouse_encode_sgr_short}

