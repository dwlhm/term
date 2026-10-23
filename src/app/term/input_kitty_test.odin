package term

// Behavioral tests for the Kitty keyboard protocol input encoding.
//
// The encoder must stay byte-identical to the legacy path when no flags are set,
// and must switch to unambiguous CSI u sequences exactly for the keys the flags
// cover.

import "core:testing"
import "vendor:sdl3"

_encode :: proc(key: sdl3.Keycode, mod: sdl3.Keymod, flags: u8, event: u8 = INPUT_EVENT_PRESS) -> string {
	res, ok := input_encode_key(key, mod, false, flags, event)
	if !ok do return "<none>"
	return string(res.bytes[:res.len])
}

@test
test_input_legacy_encoding_unchanged :: proc(t: ^testing.T) {
	testing.expect_value(t, _encode(sdl3.K_A, sdl3.KMOD_CTRL, 0), "\x01")
	testing.expect_value(t, _encode(sdl3.K_RETURN, sdl3.KMOD_NONE, 0), "\r")
	testing.expect_value(t, _encode(sdl3.K_UP, sdl3.KMOD_NONE, 0), "\x1b[A")
	testing.expect_value(t, _encode(sdl3.K_UP, sdl3.KMOD_CTRL, 0), "\x1b[1;5A")
	testing.expect_value(t, _encode(sdl3.K_ESCAPE, sdl3.KMOD_NONE, 0), "\x1b")
	testing.expect_value(t, _encode(sdl3.K_F1, sdl3.KMOD_NONE, 0), "\x1bOP")
	// Plain letters are produced by TEXT_INPUT, never by the key encoder.
	testing.expect_value(t, _encode(sdl3.K_A, sdl3.KMOD_NONE, 0), "<none>")
}

@test
test_input_disambiguate_ctrl_and_alt :: proc(t: ^testing.T) {
	flags := KITTY_KBD_DISAMBIGUATE
	testing.expect_value(t, _encode(sdl3.K_A, sdl3.KMOD_CTRL, flags), "\x1b[97;5u")
	testing.expect_value(t, _encode(sdl3.K_A, sdl3.KMOD_ALT, flags), "\x1b[97;3u")
	testing.expect_value(t, _encode(sdl3.K_A, sdl3.KMOD_CTRL | sdl3.KMOD_SHIFT, flags), "\x1b[97;6u")
	testing.expect_value(t, _encode(sdl3.K_ESCAPE, sdl3.KMOD_NONE, flags), "\x1b[27u")
	testing.expect_value(t, _encode(sdl3.K_RETURN, sdl3.KMOD_SHIFT, flags), "\x1b[13;2u")
	testing.expect_value(t, _encode(sdl3.K_TAB, sdl3.KMOD_SHIFT, flags), "\x1b[9;2u")
	testing.expect_value(t, _encode(sdl3.K_BACKSPACE, sdl3.KMOD_ALT, flags), "\x1b[127;3u")
	testing.expect_value(t, _encode(sdl3.K_LEFT, sdl3.KMOD_CTRL, flags), "\x1b[1;5D")
	// Unmodified, non-ambiguous keys keep their legacy behaviour.
	testing.expect_value(t, _encode(sdl3.K_RETURN, sdl3.KMOD_NONE, flags), "\r")
	testing.expect_value(t, _encode(sdl3.K_A, sdl3.KMOD_NONE, flags), "<none>")
}

@test
test_input_report_all_keys :: proc(t: ^testing.T) {
	flags := KITTY_KBD_ALL_KEYS
	testing.expect_value(t, _encode(sdl3.K_A, sdl3.KMOD_NONE, flags), "\x1b[97u")
	testing.expect_value(t, _encode(sdl3.K_SPACE, sdl3.KMOD_NONE, flags), "\x1b[32u")
	testing.expect_value(t, _encode(sdl3.K_UP, sdl3.KMOD_NONE, flags), "\x1b[A")
	testing.expect_value(t, _encode(sdl3.K_F5, sdl3.KMOD_NONE, flags), "\x1b[15~")
	testing.expect_value(t, _encode(sdl3.K_1, sdl3.KMOD_SHIFT, flags), "\x1b[49;2u")
	testing.expect_value(t, _encode(sdl3.K_RETURN, sdl3.KMOD_NONE, flags), "\x1b[13u")
}

@test
test_input_event_types :: proc(t: ^testing.T) {
	flags := KITTY_KBD_ALL_KEYS | KITTY_KBD_EVENT_TYPES
	testing.expect_value(t, _encode(sdl3.K_A, sdl3.KMOD_NONE, flags, INPUT_EVENT_PRESS), "\x1b[97;1:1u")
	testing.expect_value(t, _encode(sdl3.K_A, sdl3.KMOD_NONE, flags, INPUT_EVENT_REPEAT), "\x1b[97;1:2u")
	testing.expect_value(t, _encode(sdl3.K_A, sdl3.KMOD_NONE, flags, INPUT_EVENT_RELEASE), "\x1b[97;1:3u")
	// Functional keys keep the legacy form even for release: no CSI u event.
	testing.expect_value(
		t,
		_encode(sdl3.K_LEFT, sdl3.KMOD_CTRL | sdl3.KMOD_SHIFT, flags, INPUT_EVENT_RELEASE),
		"<none>",
	)
}

@test
test_release_never_falls_back_to_legacy :: proc(t: ^testing.T) {
	// Event-type reporting alone must not duplicate legacy keys: a Down arrow is
	// sent as "\x1b[B" on press, so its release must produce nothing at all.
	event_flags := KITTY_KBD_EVENT_TYPES
	testing.expect_value(t, _encode(sdl3.K_DOWN, sdl3.KMOD_NONE, event_flags), "\x1b[B")
	release, ok := input_encode_key(sdl3.K_DOWN, sdl3.KMOD_NONE, false, event_flags, INPUT_EVENT_RELEASE)
	testing.expect(t, !ok, "legacy keys must not emit a release event")
	testing.expect_value(t, release.len, 0)

	// Functional keys stay on their legacy encodings even with the disambiguate
	// flag: a modified arrow uses the xterm form and never emits a release event.
	disambiguate := KITTY_KBD_DISAMBIGUATE | KITTY_KBD_EVENT_TYPES
	release, ok = input_encode_key(sdl3.K_DOWN, sdl3.KMOD_NONE, false, disambiguate, INPUT_EVENT_RELEASE)
	testing.expect(t, !ok, "plain arrows must not emit a release event")
	press, press_ok := input_encode_key(
		sdl3.K_DOWN,
		sdl3.KMOD_CTRL,
		false,
		disambiguate,
		INPUT_EVENT_PRESS,
	)
	testing.expect(t, press_ok)
	testing.expect_value(t, string(press.bytes[:press.len]), "\x1b[1;5B")
	release, ok = input_encode_key(sdl3.K_DOWN, sdl3.KMOD_CTRL, false, disambiguate, INPUT_EVENT_RELEASE)
	testing.expect(t, !ok, "modified legacy functional keys must not emit a release event")

	// Text keys that *are* enhanced do report press and release.
	press, press_ok = input_encode_key(sdl3.K_A, sdl3.KMOD_CTRL, false, disambiguate, INPUT_EVENT_PRESS)
	testing.expect(t, press_ok)
	testing.expect_value(t, string(press.bytes[:press.len]), "\x1b[97;5:1u")
	released, release_ok := input_encode_key(
		sdl3.K_A,
		sdl3.KMOD_CTRL,
		false,
		disambiguate,
		INPUT_EVENT_RELEASE,
	)
	testing.expect(t, release_ok)
	testing.expect_value(t, string(released.bytes[:released.len]), "\x1b[97;5:3u")
}

@test
test_input_yazi_flags_legacy_arrows :: proc(t: ^testing.T) {
	// yazi pushes CSI > 29 u (DISAMBIGUATE | ALT_KEYS | ALL_KEYS | TEXT).
	// Functional keys must stay in their legacy form; text keys become CSI u.
	flags := KITTY_KBD_DISAMBIGUATE | KITTY_KBD_ALT_KEYS | KITTY_KBD_ALL_KEYS | KITTY_KBD_TEXT
	testing.expect_value(t, _encode(sdl3.K_UP, sdl3.KMOD_NONE, flags), "\x1b[A")
	testing.expect_value(t, _encode(sdl3.K_DOWN, sdl3.KMOD_NONE, flags), "\x1b[B")
	testing.expect_value(t, _encode(sdl3.K_LEFT, sdl3.KMOD_NONE, flags), "\x1b[D")
	testing.expect_value(t, _encode(sdl3.K_RIGHT, sdl3.KMOD_NONE, flags), "\x1b[C")
	testing.expect_value(t, _encode(sdl3.K_HOME, sdl3.KMOD_NONE, flags), "\x1b[H")
	testing.expect_value(t, _encode(sdl3.K_END, sdl3.KMOD_NONE, flags), "\x1b[F")
	testing.expect_value(t, _encode(sdl3.K_PAGEUP, sdl3.KMOD_NONE, flags), "\x1b[5~")
	testing.expect_value(t, _encode(sdl3.K_PAGEDOWN, sdl3.KMOD_NONE, flags), "\x1b[6~")
	testing.expect_value(t, _encode(sdl3.K_A, sdl3.KMOD_NONE, flags), "\x1b[97u")
	testing.expect_value(t, _encode(sdl3.K_UP, sdl3.KMOD_CTRL, flags), "\x1b[1;5A")
	testing.expect_value(t, _encode(sdl3.K_HOME, sdl3.KMOD_CTRL, flags), "\x1b[1;5H")
	testing.expect_value(t, _encode(sdl3.K_INSERT, sdl3.KMOD_CTRL, flags), "\x1b[2;5~")
}
