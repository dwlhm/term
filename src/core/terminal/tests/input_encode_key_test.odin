package terminal_tests

// Key encoding for every mode a program can ask for. The legacy path must stay
// byte-identical when no Kitty flags are set; the flags switch exactly the keys
// they cover to CSI u.

import "core:strings"
import "core:testing"
import ie "../input_encode"

KD :: ie.KITTY_KBD_DISAMBIGUATE
KE :: ie.KITTY_KBD_EVENT_TYPES
KA :: ie.KITTY_KBD_ALL_KEYS

@(private = "file")
_k :: proc(key: ie.Key, mods: ie.Mods = {}, flags: u8 = 0, kind := ie.Key_Event_Kind.Press, app_cursor := false) -> string {
	return _enc({key = key, mods = mods, kind = kind}, flags, app_cursor)
}

@(private = "file")
_c :: proc(char: rune, mods: ie.Mods = {}, flags: u8 = 0, kind := ie.Key_Event_Kind.Press) -> string {
	return _enc({key = .Char, char = char, mods = mods, kind = kind}, flags, false)
}

@(private = "file")
_enc :: proc(ev: ie.Key_Event, flags: u8, app_cursor: bool) -> string {
	res, ok := ie.encode_key(ev, {app_cursor = app_cursor, kitty_flags = flags})
	if !ok do return "<none>"
	return strings.clone(string(res.bytes[:res.len]), context.temp_allocator) // res lives on this stack frame
}

@test
test_key_legacy :: proc(t: ^testing.T) {
	testing.expect_value(t, _c('a', {.Ctrl}), "\x01")
	testing.expect_value(t, _c(' ', {.Ctrl}), "\x00")
	testing.expect_value(t, _c('[', {.Ctrl}), "\x1b")
	testing.expect_value(t, _k(.Enter), "\r")
	testing.expect_value(t, _k(.Tab, {.Shift}), "\x1b[Z")
	testing.expect_value(t, _k(.Up), "\x1b[A")
	testing.expect_value(t, _k(.Up, app_cursor = true), "\x1bOA")
	testing.expect_value(t, _k(.Up, {.Ctrl}, app_cursor = true), "\x1b[1;5A")
	testing.expect_value(t, _k(.Escape), "\x1b")
	testing.expect_value(t, _k(.F1), "\x1bOP")
	testing.expect_value(t, _k(.F12), "\x1b[24~")
	testing.expect_value(t, _k(.Page_Down, {.Shift}), "\x1b[6;2~")
	testing.expect_value(t, _k(.Home, {.Alt}), "\x1b[1;3H")
	// Plain characters are text input, never key bytes.
	testing.expect_value(t, _c('a'), "<none>")
	// No release without Kitty event reporting.
	testing.expect_value(t, _k(.Enter, kind = .Release), "<none>")
}

@test
test_key_super_alt_ctrl_editing :: proc(t: ^testing.T) {
	testing.expect_value(t, _k(.Backspace, {.Super}), "\x15")
	testing.expect_value(t, _k(.Delete, {.Super}), "\x15")
	testing.expect_value(t, _k(.Left, {.Super}), "\x01")
	testing.expect_value(t, _k(.Right, {.Super}), "\x05")
	testing.expect_value(t, _c('c', {.Super}), "<none>")
	testing.expect_value(t, _k(.Backspace, {.Alt}), "\x1b\x7f")
	testing.expect_value(t, _k(.Delete, {.Alt}), "\x1b\x7f")
	testing.expect_value(t, _c('b', {.Alt}), "\x1bb")
	testing.expect_value(t, _c('b', {.Alt, .Shift}), "\x1bB")
	testing.expect_value(t, _c('5', {.Alt}), "\x1b5")
	testing.expect_value(t, _k(.Backspace, {.Ctrl}), "\x17")
	testing.expect_value(t, _k(.Delete, {.Ctrl}), "\x17")
}

@test
test_key_kitty_disambiguate :: proc(t: ^testing.T) {
	testing.expect_value(t, _c('a', {.Ctrl}, KD), "\x1b[97;5u")
	testing.expect_value(t, _c('a', {.Alt}, KD), "\x1b[97;3u")
	testing.expect_value(t, _c('a', {.Ctrl, .Shift}, KD), "\x1b[97;6u")
	testing.expect_value(t, _k(.Escape, {}, KD), "\x1b[27u")
	testing.expect_value(t, _k(.Enter, {.Shift}, KD), "\x1b[13;2u")
	testing.expect_value(t, _k(.Tab, {.Shift}, KD), "\x1b[9;2u")
	testing.expect_value(t, _k(.Backspace, {.Alt}, KD), "\x1b[127;3u")
	testing.expect_value(t, _k(.Left, {.Ctrl}, KD), "\x1b[1;5D")
	testing.expect_value(t, _k(.Enter, {}, KD), "\r")
	testing.expect_value(t, _c('a', {}, KD), "<none>")
	// Shift alone on printable keys is plain text, never CSI u.
	testing.expect_value(t, _c(';', {.Shift}, KD), "<none>")
	testing.expect_value(t, _c('a', {.Shift}, KD), "<none>")
	testing.expect_value(t, _c(' ', {.Shift}, KD), "\x1b[32;2u")
	testing.expect_value(t, _c(';', {.Ctrl}, KD), "\x1b[59;5u")
}

@test
test_key_kitty_all_keys_and_events :: proc(t: ^testing.T) {
	testing.expect_value(t, _c('a', {}, KA), "\x1b[97u")
	testing.expect_value(t, _c(' ', {}, KA), "\x1b[32u")
	testing.expect_value(t, _k(.Up, {}, KA), "\x1b[A")
	testing.expect_value(t, _k(.F5, {}, KA), "\x1b[15~")
	testing.expect_value(t, _c('1', {.Shift}, KA), "\x1b[49;2u")
	testing.expect_value(t, _k(.Enter, {}, KA), "\x1b[13u")
	testing.expect_value(t, _c('a', {}, KA | KE, .Press), "\x1b[97;1:1u")
	testing.expect_value(t, _c('a', {}, KA | KE, .Repeat), "\x1b[97;1:2u")
	testing.expect_value(t, _c('a', {}, KA | KE, .Release), "\x1b[97;1:3u")
	// All keys without event reporting: a release is never sent.
	testing.expect_value(t, _c('a', {}, KA, .Release), "<none>")
	// Legacy functional keys never emit a release event.
	testing.expect_value(t, _k(.Left, {.Ctrl, .Shift}, KA | KE, .Release), "<none>")
	testing.expect_value(t, _k(.Down, {}, KE), "\x1b[B")
	testing.expect_value(t, _k(.Down, {}, KE, .Release), "<none>")
	testing.expect_value(t, _k(.Down, {.Ctrl}, KD | KE), "\x1b[1;5B")
	testing.expect_value(t, _k(.Down, {.Ctrl}, KD | KE, .Release), "<none>")
	testing.expect_value(t, _c('a', {.Ctrl}, KD | KE), "\x1b[97;5:1u")
	testing.expect_value(t, _c('a', {.Ctrl}, KD | KE, .Release), "\x1b[97;5:3u")
}

@test
test_key_kitty_yazi_flags_keep_legacy_functional :: proc(t: ^testing.T) {
	// yazi pushes CSI > 29 u (DISAMBIGUATE | ALT_KEYS | ALL_KEYS | TEXT).
	flags := KD | ie.KITTY_KBD_ALT_KEYS | KA | ie.KITTY_KBD_TEXT
	testing.expect_value(t, _k(.Up, {}, flags), "\x1b[A")
	testing.expect_value(t, _k(.Right, {}, flags), "\x1b[C")
	testing.expect_value(t, _k(.Home, {}, flags), "\x1b[H")
	testing.expect_value(t, _k(.End, {}, flags), "\x1b[F")
	testing.expect_value(t, _k(.Page_Up, {}, flags), "\x1b[5~")
	testing.expect_value(t, _c('a', {}, flags), "\x1b[97u")
	testing.expect_value(t, _k(.Up, {.Ctrl}, flags), "\x1b[1;5A")
	testing.expect_value(t, _k(.Insert, {.Ctrl}, flags), "\x1b[2;5~")
	testing.expect_value(t, _k(.Caps_Lock, {}, flags), "\x1b[57358u")
}
