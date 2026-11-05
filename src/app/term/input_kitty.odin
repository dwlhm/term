package term

// Kitty Keyboard Protocol encoding (https://sw.kovidgoyal.net/kitty/keyboard-protocol/).
//
// Clients opt in progressively with `CSI > flags u`; the terminal must then stop
// emitting ambiguous legacy byte sequences for the affected keys. Flags supported
// here: disambiguate (1), report event types (2) and report all keys as escape
// codes (8). Alternate keys (4) and associated text (16) are accepted but not
// generated, which the protocol explicitly allows.

import "core:fmt"
import "vendor:sdl3"

KITTY_KBD_DISAMBIGUATE :: u8(1)
KITTY_KBD_EVENT_TYPES  :: u8(2)
KITTY_KBD_ALT_KEYS     :: u8(4)
KITTY_KBD_ALL_KEYS     :: u8(8)
KITTY_KBD_TEXT         :: u8(16)

INPUT_EVENT_PRESS   :: u8(1)
INPUT_EVENT_REPEAT  :: u8(2)
INPUT_EVENT_RELEASE :: u8(3)

// Functional key codes defined by the protocol (the private-use range).
@(rodata)
_KITTY_FUNCTIONAL_CODES := [?]struct {
	key:  sdl3.Keycode,
	code: int,
}{
	{sdl3.K_INSERT, 57348},
	{sdl3.K_DELETE, 57349},
	{sdl3.K_LEFT, 57350},
	{sdl3.K_RIGHT, 57351},
	{sdl3.K_UP, 57352},
	{sdl3.K_DOWN, 57353},
	{sdl3.K_PAGEUP, 57354},
	{sdl3.K_PAGEDOWN, 57355},
	{sdl3.K_HOME, 57356},
	{sdl3.K_END, 57357},
	{sdl3.K_CAPSLOCK, 57358},
	{sdl3.K_SCROLLLOCK, 57359},
	{sdl3.K_NUMLOCKCLEAR, 57360},
	{sdl3.K_PRINTSCREEN, 57361},
	{sdl3.K_PAUSE, 57362},
	{sdl3.K_APPLICATION, 57363},
	{sdl3.K_F1, 57364},
	{sdl3.K_F2, 57365},
	{sdl3.K_F3, 57366},
	{sdl3.K_F4, 57367},
	{sdl3.K_F5, 57368},
	{sdl3.K_F6, 57369},
	{sdl3.K_F7, 57370},
	{sdl3.K_F8, 57371},
	{sdl3.K_F9, 57372},
	{sdl3.K_F10, 57373},
	{sdl3.K_F11, 57374},
	{sdl3.K_F12, 57375},
}

_kitty_modifiers :: proc(mod: sdl3.Keymod) -> int {
	result := 1
	if (mod & sdl3.KMOD_SHIFT) != sdl3.KMOD_NONE do result += 1
	if (mod & sdl3.KMOD_ALT) != sdl3.KMOD_NONE do result += 2
	if (mod & sdl3.KMOD_CTRL) != sdl3.KMOD_NONE do result += 4
	if (mod & sdl3.KMOD_GUI) != sdl3.KMOD_NONE do result += 8
	return result
}

// _kitty_key_code maps a keypress onto the protocol's key code: an ASCII
// codepoint for printable keys (lowercase, unshifted) or a functional code.
_kitty_key_code :: proc(key: sdl3.Keycode) -> (code: int, ok: bool) {
	for entry in _KITTY_FUNCTIONAL_CODES {
		if key == entry.key do return entry.code, true
	}

	switch key {
	case sdl3.K_RETURN, sdl3.K_KP_ENTER: return 13, true
	case sdl3.K_TAB:                     return 9, true
	case sdl3.K_BACKSPACE:               return 127, true
	case sdl3.K_ESCAPE:                  return 27, true
	case sdl3.K_SPACE:                   return 32, true
	}

	raw := int(key)
	if raw >= int(sdl3.K_A) && raw <= int(sdl3.K_Z) {
		return raw - int(sdl3.K_A) + int('a'), true
	}
	if raw >= int(sdl3.K_0) && raw <= int(sdl3.K_9) do return raw, true
	if raw >= 0x21 && raw <= 0x7E do return raw, true // punctuation keys share ASCII values
	return 0, false
}

// input_kitty_should_encode reports whether an ambiguous key must be expressed as
// a CSI u sequence instead of its legacy bytes.
_kitty_should_encode :: proc(key: sdl3.Keycode, mod: sdl3.Keymod, flags: u8) -> bool {
	// Functional keys with an unambiguous legacy encoding must always use it:
	// kitty's own encoder keeps them in the legacy form (CSI 1;mods A,
	// CSI 2;mods ~, SS3 P, …) and consumers such as yazi only parse that form.
	if _kitty_legacy_functional_key(key) do return false
	if flags & KITTY_KBD_ALL_KEYS != 0 do return true
	if flags & KITTY_KBD_DISAMBIGUATE == 0 do return false
	if key == sdl3.K_ESCAPE do return true

	mods := _kitty_modifiers(mod)
	if mods == 1 do return false
	// Only keys that would otherwise be ambiguous need the enhanced encoding.
	switch key {
	case sdl3.K_RETURN, sdl3.K_KP_ENTER, sdl3.K_TAB, sdl3.K_BACKSPACE, sdl3.K_SPACE:
		return true
	}

	// Under disambiguate mode (flag 1), printable keys with Shift alone produce
	// plain text (e.g. Shift+; -> ':' or Shift+a -> 'A') and are not ambiguous.
	is_other_mod := (mod & (sdl3.KMOD_CTRL | sdl3.KMOD_ALT | sdl3.KMOD_GUI)) != sdl3.KMOD_NONE
	if !is_other_mod && _key_is_printable(key) && key != sdl3.K_SPACE {
		return false
	}

	return _kitty_code_ok(key)
}

_kitty_code_ok :: proc(key: sdl3.Keycode) -> bool {
	_, ok := _kitty_key_code(key)
	return ok
}

// _kitty_legacy_functional_key reports keys that already have an unambiguous
// legacy escape sequence. They must never be upgraded to CSI u: the enhanced
// form is optional for them and breaks apps that only parse the legacy form.
_kitty_legacy_functional_key :: proc(key: sdl3.Keycode) -> bool {
	switch key {
	case sdl3.K_UP, sdl3.K_DOWN, sdl3.K_LEFT, sdl3.K_RIGHT,
	     sdl3.K_HOME, sdl3.K_END,
	     sdl3.K_INSERT, sdl3.K_DELETE,
	     sdl3.K_PAGEUP, sdl3.K_PAGEDOWN,
	     sdl3.K_F1, sdl3.K_F2, sdl3.K_F3, sdl3.K_F4, sdl3.K_F5, sdl3.K_F6,
	     sdl3.K_F7, sdl3.K_F8, sdl3.K_F9, sdl3.K_F10, sdl3.K_F11, sdl3.K_F12:
		return true
	}
	return false
}

// _key_is_printable reports whether SDL also delivers a TEXT_INPUT event for
// this key (plain or Option-composed characters). Ctrl/GUI suppress text input.
_key_is_printable :: proc(key: sdl3.Keycode) -> bool {
	if key == sdl3.K_SPACE do return true
	raw := int(key)
	if raw >= int(sdl3.K_A) && raw <= int(sdl3.K_Z) do return true
	if raw >= int(sdl3.K_0) && raw <= int(sdl3.K_9) do return true
	if raw >= 0x21 && raw <= 0x7E do return true
	return false
}

// input_encode_key_kitty renders a keypress as `CSI code ; mods : event u`.
input_encode_key_kitty :: proc(
	key: sdl3.Keycode,
	mod: sdl3.Keymod,
	flags: u8,
	event: u8,
) -> (res: Input_Encode_Result, ok: bool) {
	code, has_code := _kitty_key_code(key)
	if !has_code do return {}, false

	mods := _kitty_modifiers(mod)
	report_event := flags & KITTY_KBD_EVENT_TYPES != 0

	text: string
	switch {
	case report_event && mods > 1:
		text = fmt.bprintf(res.bytes[:], "\x1b[%d;%d:%du", code, mods, event)
	case report_event:
		text = fmt.bprintf(res.bytes[:], "\x1b[%d;1:%du", code, event)
	case mods > 1:
		text = fmt.bprintf(res.bytes[:], "\x1b[%d;%du", code, mods)
	case:
		text = fmt.bprintf(res.bytes[:], "\x1b[%du", code)
	}
	res.len = len(text)
	return res, true
}
