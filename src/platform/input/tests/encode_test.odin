package input_test

import "core:testing"
import input "../"

// _enc encodes ev into a max-size buffer, returning bytes + length.
_enc :: proc(ev: input.Input_Event) -> ([input.INPUT_ENCODE_MAX]u8, int) {
	buf: [input.INPUT_ENCODE_MAX]u8
	n := input.input_encode(ev, buf[:])
	return buf, n
}

// _enc_cap encodes ev into a cap-sized buffer for small-out tests.
_enc_cap :: proc(ev: input.Input_Event, buf: []u8) -> int {
	return input.input_encode(ev, buf)
}

// _expect_bytes compares the first n output bytes against want.
_expect_bytes :: proc(t: ^testing.T, got: [input.INPUT_ENCODE_MAX]u8, n: int, want: []u8, msg: string) {
	testing.expect(t, n == len(want), msg)
	if n != len(want) {
		return
	}
	for b, i in want {
		testing.expect(t, got[i] == b, msg)
	}
}

@(test)
test_encode_printable_ascii :: proc(t: ^testing.T) {
	buf, n := _enc({kind = .Printable, rune = 'A'})
	_expect_bytes(t, buf, n, {0x41}, "printable 'A' must emit one byte 0x41")
}

@(test)
test_encode_printable_multibyte :: proc(t: ^testing.T) {
	// e-acute (U+00E9): 2 bytes C3 A9.
	buf, n := _enc({kind = .Printable, rune = 'é'})
	_expect_bytes(t, buf, n, {0xC3, 0xA9}, "printable U+00E9 must pass through as 2-byte UTF-8")

	// CJK (U+4E2D): 3 bytes E4 B8 AD.
	buf, n = _enc({kind = .Printable, rune = '中'})
	_expect_bytes(t, buf, n, {0xE4, 0xB8, 0xAD}, "printable U+4E2D must pass through as 3-byte UTF-8")

	// Emoji (U+1F600): 4 bytes F0 9F 98 80.
	buf, n = _enc({kind = .Printable, rune = '😀'})
	_expect_bytes(t, buf, n, {0xF0, 0x9F, 0x98, 0x80}, "printable U+1F600 must pass through as 4-byte UTF-8")
}

@(test)
test_encode_fixed_single_bytes :: proc(t: ^testing.T) {
	buf, n := _enc({kind = .Enter})
	_expect_bytes(t, buf, n, {0x0D}, "Enter must emit CR")

	buf, n = _enc({kind = .Backspace})
	_expect_bytes(t, buf, n, {0x7F}, "Backspace must emit DEL")

	buf, n = _enc({kind = .Tab})
	_expect_bytes(t, buf, n, {0x09}, "Tab must emit HT")

	buf, n = _enc({kind = .Escape})
	_expect_bytes(t, buf, n, {0x1B}, "Escape must emit ESC")
}

@(test)
test_encode_arrows_plain :: proc(t: ^testing.T) {
	buf, n := _enc({kind = .Arrow_Up})
	_expect_bytes(t, buf, n, {0x1B, '[', 'A'}, "Up must emit ESC[A")

	buf, n = _enc({kind = .Arrow_Down})
	_expect_bytes(t, buf, n, {0x1B, '[', 'B'}, "Down must emit ESC[B")

	buf, n = _enc({kind = .Arrow_Right})
	_expect_bytes(t, buf, n, {0x1B, '[', 'C'}, "Right must emit ESC[C")

	buf, n = _enc({kind = .Arrow_Left})
	_expect_bytes(t, buf, n, {0x1B, '[', 'D'}, "Left must emit ESC[D")
}

@(test)
test_encode_arrow_up_full_modifier_table :: proc(t: ^testing.T) {
	// Full xterm table on Up: none, S, A, S+A, C, S+C, A+C, S+A+C.
	cases := [8]input.Input_Event{
		{kind = .Arrow_Up},
		{kind = .Arrow_Up, shift = true},
		{kind = .Arrow_Up, alt = true},
		{kind = .Arrow_Up, shift = true, alt = true},
		{kind = .Arrow_Up, ctrl = true},
		{kind = .Arrow_Up, shift = true, ctrl = true},
		{kind = .Arrow_Up, alt = true, ctrl = true},
		{kind = .Arrow_Up, shift = true, alt = true, ctrl = true},
	}
	params := [8]u8{0, '2', '3', '4', '5', '6', '7', '8'}
	for ev, i in cases {
		buf, n := _enc(ev)
		if i == 0 {
			_expect_bytes(t, buf, n, {0x1B, '[', 'A'}, "Up unmodified must emit ESC[A")
			continue
		}
		_expect_bytes(t, buf, n, {0x1B, '[', '1', ';', params[i], 'A'}, "Up modifier row must emit CSI 1;m A")
	}
}

@(test)
test_encode_arrows_modifier_spot :: proc(t: ^testing.T) {
	buf, n := _enc({kind = .Arrow_Down, shift = true})
	_expect_bytes(t, buf, n, {0x1B, '[', '1', ';', '2', 'B'}, "Shift+Down must emit ESC[1;2B")

	buf, n = _enc({kind = .Arrow_Left, ctrl = true})
	_expect_bytes(t, buf, n, {0x1B, '[', '1', ';', '5', 'D'}, "Ctrl+Left must emit ESC[1;5D")

	buf, n = _enc({kind = .Arrow_Right, alt = true})
	_expect_bytes(t, buf, n, {0x1B, '[', '1', ';', '3', 'C'}, "Alt+Right must emit ESC[1;3C")
}

@(test)
test_encode_home_end_pgup_pgdn :: proc(t: ^testing.T) {
	buf, n := _enc({kind = .Home})
	_expect_bytes(t, buf, n, {0x1B, '[', 'H'}, "Home must emit ESC[H")

	buf, n = _enc({kind = .End})
	_expect_bytes(t, buf, n, {0x1B, '[', 'F'}, "End must emit ESC[F")

	buf, n = _enc({kind = .PgUp})
	_expect_bytes(t, buf, n, {0x1B, '[', '5', '~'}, "PgUp must emit ESC[5~")

	buf, n = _enc({kind = .PgDn})
	_expect_bytes(t, buf, n, {0x1B, '[', '6', '~'}, "PgDn must emit ESC[6~")
}

@(test)
test_encode_ctrl_letters :: proc(t: ^testing.T) {
	buf, n := _enc({kind = .Ctrl, rune = 'c'})
	_expect_bytes(t, buf, n, {0x03}, "Ctrl+c must emit 0x03")

	buf, n = _enc({kind = .Ctrl, rune = 'C'})
	_expect_bytes(t, buf, n, {0x03}, "Ctrl+C must emit 0x03")

	buf, n = _enc({kind = .Ctrl, rune = 'a'})
	_expect_bytes(t, buf, n, {0x01}, "Ctrl+a must emit 0x01")

	buf, n = _enc({kind = .Ctrl, rune = 'z'})
	_expect_bytes(t, buf, n, {0x01 + 25}, "Ctrl+z must emit 0x1A")

	buf, n = _enc({kind = .Ctrl, rune = ' '})
	_expect_bytes(t, buf, n, {0x00}, "Ctrl+Space must emit 0x00")

	buf, n = _enc({kind = .Ctrl, rune = '/'})
	_expect_bytes(t, buf, n, {0x1F}, "Ctrl+/ must emit 0x1F")

	// ctrl flag + Printable letter takes the same path.
	buf, n = _enc({kind = .Printable, rune = 'c', ctrl = true})
	_expect_bytes(t, buf, n, {0x03}, "ctrl flag + letter must emit 0x03")
}

@(test)
test_encode_alt_prefix :: proc(t: ^testing.T) {
	buf, n := _enc({kind = .Alt_Mod, rune = 'x'})
	_expect_bytes(t, buf, n, {0x1B, 'x'}, "Alt+x must emit ESC x")

	buf, n = _enc({kind = .Alt_Mod, rune = '\r'})
	_expect_bytes(t, buf, n, {0x1B, 0x0D}, "Alt+Enter must emit ESC CR")
}

@(test)
test_encode_small_out_all_or_nothing :: proc(t: ^testing.T) {
	small: [2]u8
	n := _enc_cap({kind = .Arrow_Up}, small[:])
	testing.expect(t, n == 0, "2-byte out for 3-byte Up must return 0")

	tiny: [1]u8 = {0xAA}
	n = _enc_cap({kind = .Alt_Mod, rune = 'x'}, tiny[:])
	testing.expect(t, n == 0, "1-byte out for 2-byte Alt+x must return 0")
	testing.expect(t, tiny[0] == 0xAA, "failed encode must leave out untouched")

	empty: [0]u8
	n = _enc_cap({kind = .Printable, rune = 'A'}, empty[:])
	testing.expect(t, n == 0, "empty out must return 0")

	// Exact-fit boundary still succeeds.
	exact: [3]u8
	n = _enc_cap({kind = .Arrow_Up}, exact[:])
	testing.expect(t, n == 3, "exact-fit out must succeed")
	testing.expect(t, exact[0] == 0x1B && exact[1] == '[' && exact[2] == 'A', "exact-fit Up must emit ESC[A")
}

@(test)
test_encode_unknown_kind :: proc(t: ^testing.T) {
	buf: [input.INPUT_ENCODE_MAX]u8
	n := input.input_encode({kind = input.Input_Key_Kind(255)}, buf[:])
	testing.expect(t, n == 0, "unknown kind must return 0")
}
