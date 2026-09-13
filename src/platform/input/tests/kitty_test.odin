package input_test

import "core:testing"
import input "../"

// Kitty keyboard protocol encode tests: with disambiguate (flag 1),
// ambiguous keys encode as CSI u while Enter/Tab/Backspace stay legacy.
// Without flags every encoding must match the legacy table exactly.

// _kenc encodes ev with kitty flags into a max-size buffer.
_kenc :: proc(ev: input.Input_Event, flags: u8) -> ([input.INPUT_ENCODE_MAX]u8, int) {
	buf: [input.INPUT_ENCODE_MAX]u8
	n := input.input_encode(ev, buf[:], flags)
	return buf, n
}

@(test)
test_kitty_legacy_default_unchanged :: proc(t: ^testing.T) {
	// No flags (and explicit 0) must reproduce the legacy table exactly.
	buf, n := _kenc({kind = .Escape}, 0)
	_expect_bytes(t, buf, n, {0x1B}, "Escape without flags must emit ESC")

	buf, n = _kenc({kind = .Ctrl, rune = 'c', ctrl = true}, 0)
	_expect_bytes(t, buf, n, {0x03}, "Ctrl+c without flags must emit 0x03")

	buf, n = _kenc({kind = .Alt_Mod, rune = 'x', alt = true}, 0)
	_expect_bytes(t, buf, n, {0x1B, 'x'}, "Alt+x without flags must emit ESC x")

	buf, n = _kenc({kind = .Enter}, 0)
	_expect_bytes(t, buf, n, {0x0D}, "Enter without flags must emit CR")
}

@(test)
test_kitty_escape_disambiguate :: proc(t: ^testing.T) {
	buf, n := _kenc({kind = .Escape}, 1)
	_expect_bytes(t, buf, n, {0x1B, '[', '2', '7', 'u'}, "Escape must emit CSI 27 u")

	buf, n = _kenc({kind = .Escape, shift = true}, 1)
	_expect_bytes(t, buf, n, {0x1B, '[', '2', '7', ';', '2', 'u'}, "Shift+Escape must emit CSI 27;2 u")
}

@(test)
test_kitty_ctrl_letters :: proc(t: ^testing.T) {
	buf, n := _kenc({kind = .Ctrl, rune = 'c', ctrl = true}, 1)
	_expect_bytes(t, buf, n, {0x1B, '[', '9', '9', ';', '5', 'u'}, "Ctrl+c must emit CSI 99;5 u")

	// Uppercase runes collapse to the unshifted (lowercase) codepoint.
	buf, n = _kenc({kind = .Ctrl, rune = 'C', ctrl = true}, 1)
	_expect_bytes(t, buf, n, {0x1B, '[', '9', '9', ';', '5', 'u'}, "Ctrl+C must use lowercase codepoint")

	buf, n = _kenc({kind = .Ctrl, rune = 'c', ctrl = true, shift = true}, 1)
	_expect_bytes(
		t,
		buf,
		n,
		{0x1B, '[', '9', '9', ';', '6', 'u'},
		"Ctrl+Shift+c must emit CSI 99;6 u",
	)
}

@(test)
test_kitty_alt_letters :: proc(t: ^testing.T) {
	buf, n := _kenc({kind = .Alt_Mod, rune = 'x', alt = true}, 1)
	_expect_bytes(t, buf, n, {0x1B, '[', '1', '2', '0', ';', '3', 'u'}, "Alt+x must emit CSI 120;3 u")
}

@(test)
test_kitty_ctrl_space :: proc(t: ^testing.T) {
	buf, n := _kenc({kind = .Ctrl, rune = ' ', ctrl = true}, 0)
	_expect_bytes(t, buf, n, {0x00}, "Ctrl+Space legacy must emit NUL")

	buf, n = _kenc({kind = .Ctrl, rune = ' ', ctrl = true}, 1)
	_expect_bytes(t, buf, n, {0x1B, '[', '3', '2', ';', '5', 'u'}, "Ctrl+Space must emit CSI 32;5 u")
}

@(test)
test_kitty_enter_tab_bs_stay_legacy :: proc(t: ^testing.T) {
	buf, n := _kenc({kind = .Enter}, 1)
	_expect_bytes(t, buf, n, {0x0D}, "Enter must stay CR even when disambiguated")

	buf, n = _kenc({kind = .Tab}, 1)
	_expect_bytes(t, buf, n, {0x09}, "Tab must stay HT even when disambiguated")

	buf, n = _kenc({kind = .Backspace}, 1)
	_expect_bytes(t, buf, n, {0x7F}, "Backspace must stay DEL even when disambiguated")

	buf, n = _kenc({kind = .Alt_Mod, rune = '\r', alt = true}, 1)
	_expect_bytes(t, buf, n, {0x1B, 0x0D}, "Alt+Enter must stay ESC CR")

	buf, n = _kenc({kind = .Alt_Mod, rune = '\x7f', alt = true}, 1)
	_expect_bytes(t, buf, n, {0x1B, 0x7F}, "Alt+Backspace must stay ESC DEL")
}

@(test)
test_kitty_shift_tab :: proc(t: ^testing.T) {
	// Shift+Tab is CSI Z in both legacy and disambiguated modes.
	buf, n := _kenc({kind = .Tab, shift = true}, 0)
	_expect_bytes(t, buf, n, {0x1B, '[', 'Z'}, "Shift+Tab legacy must emit CSI Z")

	buf, n = _kenc({kind = .Tab, shift = true}, 1)
	_expect_bytes(t, buf, n, {0x1B, '[', 'Z'}, "Shift+Tab must stay CSI Z when disambiguated")

	buf, n = _kenc({kind = .Tab}, 1)
	_expect_bytes(t, buf, n, {0x09}, "plain Tab must stay HT")
}

@(test)
test_kitty_gui_as_super :: proc(t: ^testing.T) {
	buf, n := _kenc({kind = .Ctrl, rune = 'x', ctrl = true, gui = true}, 1)
	_expect_bytes(
		t,
		buf,
		n,
		{0x1B, '[', '1', '2', '0', ';', '1', '3', 'u'},
		"Ctrl+Gui+x must emit CSI 120;13 u (super=8)",
	)
}

@(test)
test_kitty_arrows_unchanged :: proc(t: ^testing.T) {
	// Arrows are already unambiguous: identical in both modes.
	buf, n := _kenc({kind = .Arrow_Up}, 1)
	_expect_bytes(t, buf, n, {0x1B, '[', 'A'}, "Up must stay ESC[A")

	buf, n = _kenc({kind = .Arrow_Down, ctrl = true}, 1)
	_expect_bytes(t, buf, n, {0x1B, '[', '1', ';', '5', 'B'}, "Ctrl+Down must stay ESC[1;5B")
}

@(test)
test_kitty_small_out_atomic :: proc(t: ^testing.T) {
	small: [4]u8
	n := input.input_encode({kind = .Ctrl, rune = 'c', ctrl = true}, small[:], 1)
	testing.expect(t, n == 0, "4-byte out for 7-byte CSI u must return 0")

	exact: [7]u8
	n = input.input_encode({kind = .Ctrl, rune = 'c', ctrl = true}, exact[:], 1)
	testing.expect(t, n == 7, "exact-fit CSI u must succeed")
	testing.expect(
		t,
		exact[0] == 0x1B && exact[1] == '[' && exact[6] == 'u',
		"exact-fit CSI u must frame correctly",
	)
}
