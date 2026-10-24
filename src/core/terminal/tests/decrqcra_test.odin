package terminal_tests

import "core:testing"
import term "../"

// DECRQCRA (`CSI Pid ; Pp ; Pt ; Pl ; Pb ; Pr * y`) answers with
// `DCS Pid ! ~ <hex> ST`, returning the 16-bit sum of character codes in the rectangle.

_expect_checksum :: proc(t: ^testing.T, terminal: ^term.Terminal, request, want: string) {
	term.terminal_feed_string(terminal, request)
	resp: [64]u8
	n := term.terminal_drain_response(terminal, resp[:])
	testing.expect_value(t, string(resp[:n]), want)
}

@test
test_decrqcra_blank_cell :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	_expect_checksum(t, &terminal, "\x1b[1;;1;1;1;1*y", "\x1bP1!~0020\x1b\\")
}

@test
test_decrqcra_echoes_request_id :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	_expect_checksum(t, &terminal, "\x1b[42;;2;2;2;2*y", "\x1bP42!~0020\x1b\\")
}

@test
test_decrqcra_sums_character_codes :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	term.terminal_feed_string(&terminal, "ABC")
	// 'A' + 'B' + 'C' = 0x41 + 0x42 + 0x43 = 0xC6
	_expect_checksum(t, &terminal, "\x1b[1;;1;1;1;3*y", "\x1bP1!~00C6\x1b\\")
	// Single cell, 1-based coordinates: column 2 holds 'B'.
	_expect_checksum(t, &terminal, "\x1b[2;;1;2;1;2*y", "\x1bP2!~0042\x1b\\")
}

@test
test_decrqcra_clips_oversized_rect :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 4, 10)
	defer term.terminal_destroy(&terminal)

	// 4x10 blank cells: 40 * 0x20 = 0x500, clipped to page dimensions.
	_expect_checksum(t, &terminal, "\x1b[1;;1;1;999;999*y", "\x1bP1!~0500\x1b\\")
	// Rectangle completely outside the page boundaries sums nothing.
	_expect_checksum(t, &terminal, "\x1b[2;;50;50;60;60*y", "\x1bP2!~0000\x1b\\")
}

@test
test_decrqcra_respects_origin_mode :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	// 'X' at row 5, column 1, then make rows 5..7 the origin and query (1,1).
	term.terminal_feed_string(&terminal, "\x1b[5;1HX\x1b[5;7r\x1b[?6h")
	_expect_checksum(t, &terminal, "\x1b[1;;1;1;1;1*y", "\x1bP1!~0058\x1b\\")

	// With origin mode disabled, the same rectangle addresses real row 1 (blank).
	term.terminal_feed_string(&terminal, "\x1b[?6l")
	_expect_checksum(t, &terminal, "\x1b[2;;1;1;1;1*y", "\x1bP2!~0020\x1b\\")
}

@test
test_decrqcra_wide_glyph_counts_once :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	// U+4E16 is double-width: the lead cell carries the code point, continuation contributes 0.
	term.terminal_feed_string(&terminal, "\x1b[1;1H\u4E16")
	_expect_checksum(t, &terminal, "\x1b[1;;1;1;1;1*y", "\x1bP1!~4E16\x1b\\")
	_expect_checksum(t, &terminal, "\x1b[2;;1;2;1;2*y", "\x1bP2!~0000\x1b\\")
}

@test
test_decrqcra_cluster_uses_base_code_point :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	// "e" + U+0301 COMBINING ACUTE ACCENT forms one cluster whose base is 'e'.
	term.terminal_feed_string(&terminal, "\x1b[1;1He\u0301")
	_expect_checksum(t, &terminal, "\x1b[1;;1;1;1;1*y", "\x1bP1!~0065\x1b\\")
}

@test
test_decrqcra_ignores_non_checksum_intermediate :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	// `CSI Ps $ y` is not DECRQCRA; it must stay silent instead of answering.
	_expect_checksum(t, &terminal, "\x1b[1;1;1;1;1$y", "")
}
