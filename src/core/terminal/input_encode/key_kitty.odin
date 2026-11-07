package input_encode

// Kitty Keyboard Protocol encoding (https://sw.kovidgoyal.net/kitty/keyboard-protocol/).
//
// Clients opt in progressively with `CSI > flags u`; the terminal must then stop
// emitting ambiguous legacy byte sequences for the affected keys. Flags supported
// here: disambiguate (1), report event types (2) and report all keys as escape
// codes (8). Alternate keys (4) and associated text (16) are accepted but not
// generated, which the protocol explicitly allows.

import "core:fmt"

KITTY_KBD_DISAMBIGUATE :: u8(1)
KITTY_KBD_EVENT_TYPES  :: u8(2)
KITTY_KBD_ALT_KEYS     :: u8(4)
KITTY_KBD_ALL_KEYS     :: u8(8)
KITTY_KBD_TEXT         :: u8(16)

// Functional key codes defined by the protocol (the private-use range).
@(rodata)
_KITTY_FUNCTIONAL_CODES := [Key]int {
	.None = 0, .Char = 0, .Enter = 0, .Tab = 0, .Backspace = 0, .Escape = 0,
	.Insert = 57348, .Delete = 57349,
	.Left = 57350, .Right = 57351, .Up = 57352, .Down = 57353,
	.Page_Up = 57354, .Page_Down = 57355, .Home = 57356, .End = 57357,
	.Caps_Lock = 57358, .Scroll_Lock = 57359, .Num_Lock = 57360,
	.Print_Screen = 57361, .Pause = 57362, .Context_Menu = 57363,
	.F1 = 57364, .F2 = 57365, .F3 = 57366, .F4 = 57367, .F5 = 57368, .F6 = 57369,
	.F7 = 57370, .F8 = 57371, .F9 = 57372, .F10 = 57373, .F11 = 57374, .F12 = 57375,
}

@(private = "file")
_kitty_modifiers :: proc(mods: Mods) -> int {
	result := 1
	if .Shift in mods do result += 1
	if .Alt in mods do result += 2
	if .Ctrl in mods do result += 4
	if .Super in mods do result += 8
	return result
}

// _kitty_key_code: an ASCII codepoint for character keys (lowercase,
// unshifted) or the protocol's functional code.
@(private = "file")
_kitty_key_code :: proc(ev: Key_Event) -> (code: int, ok: bool) {
	#partial switch ev.key {
	case .Enter:     return 13, true
	case .Tab:       return 9, true
	case .Backspace: return 127, true
	case .Escape:    return 27, true
	case .Char:      return int(ev.char), ev.char >= 0x20 && ev.char <= 0x7E
	}
	code = _KITTY_FUNCTIONAL_CODES[ev.key]
	return code, code != 0
}

// kitty_should_encode reports whether a key must be expressed as a CSI u
// sequence instead of its legacy bytes. It also decides whether a release is
// reported at all: legacy bytes have no event field.
kitty_should_encode :: proc(ev: Key_Event, flags: u8) -> bool {
	// Functional keys with an unambiguous legacy encoding must always use it:
	// kitty's own encoder keeps them in the legacy form (CSI 1;mods A,
	// CSI 2;mods ~, SS3 P, …) and consumers such as yazi only parse that form.
	if _kitty_legacy_functional_key(ev.key) do return false
	if flags & KITTY_KBD_ALL_KEYS != 0 do return true
	if flags & KITTY_KBD_DISAMBIGUATE == 0 do return false
	if ev.key == .Escape do return true
	if ev.mods == {} do return false

	// Only keys that would otherwise be ambiguous need the enhanced encoding.
	#partial switch ev.key {
	case .Enter, .Tab, .Backspace: return true
	}
	if ev.key == .Char && ev.char == ' ' do return true

	// Under disambiguate mode (flag 1), printable keys with Shift alone produce
	// plain text (e.g. Shift+; -> ':' or Shift+a -> 'A') and are not ambiguous.
	if ev.mods & {.Ctrl, .Alt, .Super} == {} && key_is_printable(ev) do return false

	_, ok := _kitty_key_code(ev)
	return ok
}

// _kitty_legacy_functional_key reports keys that already have an unambiguous
// legacy escape sequence. They must never be upgraded to CSI u: the enhanced
// form is optional for them and breaks apps that only parse the legacy form.
@(private = "file")
_kitty_legacy_functional_key :: proc(key: Key) -> bool {
	#partial switch key {
	case .Up, .Down, .Left, .Right, .Home, .End, .Insert, .Delete, .Page_Up, .Page_Down,
	     .F1, .F2, .F3, .F4, .F5, .F6, .F7, .F8, .F9, .F10, .F11, .F12:
		return true
	}
	return false
}

// _encode_kitty renders a keypress as `CSI code ; mods : event u`.
_encode_kitty :: proc(ev: Key_Event, flags: u8) -> (res: Encoded, ok: bool) {
	code, has_code := _kitty_key_code(ev)
	if !has_code do return {}, false

	mods := _kitty_modifiers(ev.mods)
	event := int(ev.kind)
	text: string
	switch {
	case flags & KITTY_KBD_EVENT_TYPES != 0:
		text = fmt.bprintf(res.bytes[:], "\x1b[%d;%d:%du", code, mods, event)
	case mods > 1:
		text = fmt.bprintf(res.bytes[:], "\x1b[%d;%du", code, mods)
	case:
		text = fmt.bprintf(res.bytes[:], "\x1b[%du", code)
	}
	res.len = len(text)
	return res, true
}
