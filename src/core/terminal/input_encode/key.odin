package input_encode

// Key events -> the VT bytes a program expects, for the modes it asked for
// (DECCKM, Kitty keyboard flags). Pure and allocation-free: the window maps its
// platform keys onto Key_Event, the session core encodes automation keys with
// the same code.

import "core:fmt"

ENCODED_MAX :: 32

Encoded :: struct {
	bytes: [ENCODED_MAX]u8,
	len:   int,
}

Key :: enum u8 {
	None,
	Char, // a character key: Key_Event.char holds its unshifted ASCII value
	Enter,
	Tab,
	Backspace,
	Escape,
	Insert,
	Delete,
	Home,
	End,
	Page_Up,
	Page_Down,
	Up,
	Down,
	Left,
	Right,
	F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,
	Caps_Lock,
	Scroll_Lock,
	Num_Lock,
	Print_Screen,
	Pause,
	Context_Menu,
}

Mod :: enum u8 {
	Shift,
	Alt,
	Ctrl,
	Super,
}
Mods :: bit_set[Mod; u8]

Key_Event_Kind :: enum u8 {
	Press   = 1,
	Repeat  = 2,
	Release = 3,
}

Key_Event :: struct {
	key:  Key,
	char: rune, // Key.Char only: lowercase letter, digit, punctuation or ' '
	mods: Mods,
	kind: Key_Event_Kind,
}

Key_Modes :: struct {
	app_cursor:  bool, // DECCKM: unmodified arrows as SS3
	kitty_flags: u8,   // CSI > flags u
}

// encode_key renders ev for a program in modes. ok = false: the key has no
// byte form here (a plain character is text input, a release without Kitty
// event reporting is silent).
encode_key :: proc(ev: Key_Event, modes: Key_Modes) -> (res: Encoded, ok: bool) {
	flags := modes.kitty_flags
	if ev.kind == .Release && (flags & KITTY_KBD_EVENT_TYPES == 0 || !kitty_should_encode(ev, flags)) {
		return {}, false
	}
	if flags != 0 && kitty_should_encode(ev, flags) {
		if r, kitty_ok := _encode_kitty(ev, flags); kitty_ok do return r, true
	}

	shift, alt, ctrl, super := .Shift in ev.mods, .Alt in ev.mods, .Ctrl in ev.mods, .Super in ev.mods
	if super && !ctrl && !alt {
		if r, super_ok := _encode_super(ev, shift); super_ok do return r, true
	}
	if super do return {}, false
	if alt && !ctrl {
		if r, alt_ok := _encode_alt(ev, shift); alt_ok do return r, true
	}
	if ctrl && !alt {
		if r, ctrl_ok := _encode_ctrl(ev); ctrl_ok do return r, true
	}

	xmod := 1 + (1 if shift else 0) + (2 if alt else 0) + (4 if ctrl else 0)
	if r, arrow_ok := _encode_arrow(ev.key, xmod, modes.app_cursor); arrow_ok do return r, true
	if r, edit_ok := _encode_edit(ev.key, xmod, shift); edit_ok do return r, true
	if r, nav_ok := _encode_nav(ev.key, xmod); nav_ok do return r, true
	return _encode_fn(ev.key)
}

// key_is_printable: the platform also delivers this key as text input.
key_is_printable :: proc(ev: Key_Event) -> bool {
	return ev.key == .Char && ev.char >= 0x20 && ev.char <= 0x7E
}

@(private = "file")
_set :: proc(s: string) -> (res: Encoded, ok: bool) {
	copy(res.bytes[:], s)
	res.len = min(len(s), ENCODED_MAX)
	return res, true
}

@(private = "file")
_fmt :: proc(format: string, args: ..any) -> (res: Encoded, ok: bool) {
	res.len = len(fmt.bprintf(res.bytes[:], format, ..args))
	return res, true
}

// _encode_super: macOS line editing on Cmd (kill line, start/end of line).
@(private = "file")
_encode_super :: proc(ev: Key_Event, shift: bool) -> (res: Encoded, ok: bool) {
	#partial switch ev.key {
	case .Backspace, .Delete: return _set("\x15")
	case .Left:  if !shift do return _set("\x01")
	case .Right: if !shift do return _set("\x05")
	}
	return {}, false
}

@(private = "file")
_encode_alt :: proc(ev: Key_Event, shift: bool) -> (res: Encoded, ok: bool) {
	#partial switch ev.key {
	case .Backspace, .Delete: return _set("\x1b\x7f")
	case .Enter:              return _set("\x1b\r")
	case .Char:
		c := ev.char
		switch c {
		case 'a'..='z':
			if shift do c -= 'a' - 'A'
		case '0'..='9':
		case:
			return {}, false
		}
		res.bytes[0], res.bytes[1], res.len = 0x1b, u8(c), 2
		return res, true
	}
	return {}, false
}

@(private = "file")
_encode_ctrl :: proc(ev: Key_Event) -> (res: Encoded, ok: bool) {
	#partial switch ev.key {
	case .Backspace, .Delete: return _set("\x17") // ^W unix-word-rubout
	case .Char:
		switch ev.char {
		case 'a'..='z':
			res.bytes[0], res.len = u8(ev.char - 'a' + 1), 1
			return res, true
		case ' ':  return _set("\x00")
		case '[':  return _set("\x1b")
		case '\\': return _set("\x1c")
		case ']':  return _set("\x1d")
		}
	}
	return {}, false
}

@(private = "file")
_encode_arrow :: proc(key: Key, xmod: int, app_cursor: bool) -> (res: Encoded, ok: bool) {
	final: u8
	#partial switch key {
	case .Up:    final = 'A'
	case .Down:  final = 'B'
	case .Right: final = 'C'
	case .Left:  final = 'D'
	case:        return {}, false
	}
	if xmod > 1 do return _fmt("\x1b[1;%d%c", xmod, rune(final))
	res.bytes[0], res.bytes[1], res.bytes[2], res.len = 0x1b, 'O' if app_cursor else '[', final, 3
	return res, true
}

@(private = "file")
_encode_tilde :: proc(n, xmod: int) -> (res: Encoded, ok: bool) {
	if xmod > 1 do return _fmt("\x1b[%d;%d~", n, xmod)
	return _fmt("\x1b[%d~", n)
}

@(private = "file")
_encode_edit :: proc(key: Key, xmod: int, shift: bool) -> (res: Encoded, ok: bool) {
	#partial switch key {
	case .Enter:     return _set("\r")
	case .Backspace: return _set("\x7f")
	case .Tab:       return _set("\x1b[Z" if shift else "\t")
	case .Escape:    return _set("\x1b")
	case .Insert:    return _encode_tilde(2, xmod)
	case .Delete:    return _encode_tilde(3, xmod)
	}
	return {}, false
}

@(private = "file")
_encode_nav :: proc(key: Key, xmod: int) -> (res: Encoded, ok: bool) {
	#partial switch key {
	case .Home:
		if xmod > 1 do return _fmt("\x1b[1;%dH", xmod)
		return _set("\x1b[H")
	case .End:
		if xmod > 1 do return _fmt("\x1b[1;%dF", xmod)
		return _set("\x1b[F")
	case .Page_Up:   return _encode_tilde(5, xmod)
	case .Page_Down: return _encode_tilde(6, xmod)
	}
	return {}, false
}

@(private = "file")
_encode_fn :: proc(key: Key) -> (res: Encoded, ok: bool) {
	#partial switch key {
	case .F1:  return _set("\x1bOP")
	case .F2:  return _set("\x1bOQ")
	case .F3:  return _set("\x1bOR")
	case .F4:  return _set("\x1bOS")
	case .F5:  return _set("\x1b[15~")
	case .F6:  return _set("\x1b[17~")
	case .F7:  return _set("\x1b[18~")
	case .F8:  return _set("\x1b[19~")
	case .F9:  return _set("\x1b[20~")
	case .F10: return _set("\x1b[21~")
	case .F11: return _set("\x1b[23~")
	case .F12: return _set("\x1b[24~")
	}
	return {}, false
}
