package terminal_tests

// Regression tests for ISO-2022 character set designation (DEC Special Graphics).
//
// `ESC ( 0` + ASCII letters is how ncurses, dialog and tmux draw boxes. The
// designator used to be swallowed, so `lqqqk` was displayed literally instead of
// "┌───┐".

import "core:testing"
import term "../"
import parser "../parser"

_charset_row :: proc(terminal: ^term.Terminal, row: int, cols: int) -> [32]rune {
	res: [32]rune
	for c in 0..<min(cols, 32) {
		res[c] = term.terminal_get_cell(terminal, row, c).char
	}
	return res
}

@test
test_dec_special_graphics_table :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 4, 40)
	defer term.terminal_destroy(&terminal)

	// Feed the whole 0x5F..0x7E range through the G0 graphics set in one run so
	// the bulk ASCII scanner must honour the active charset.
	term.terminal_feed_string(&terminal, "\x1b(0_`abcdefghijklmnopqrstuvwxyz{|}~")
	row := _charset_row(&terminal, 0, 32)

	expected := [32]rune{
		0x00A0, 0x25C6, 0x2592, 0x2409, 0x240C, 0x240D, 0x240A, 0x00B0,
		0x00B1, 0x2424, 0x240B, 0x2518, 0x2510, 0x250C, 0x2514, 0x253C,
		0x23BA, 0x23BB, 0x2500, 0x23BC, 0x23BD, 0x251C, 0x2524, 0x2534,
		0x252C, 0x2502, 0x2264, 0x2265, 0x03C0, 0x2260, 0x00A3, 0x00B7,
	}
	for i in 0..<32 {
		testing.expect_value(t, row[i], expected[i])
	}
}

@test
test_dec_special_graphics_box_drawing :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 4, 40)
	defer term.terminal_destroy(&terminal)

	term.terminal_feed_string(&terminal, "\x1b(0lqqqk\x1b(Bplain")
	row := _charset_row(&terminal, 0, 10)
	testing.expect_value(t, row[0], '┌')
	testing.expect_value(t, row[1], '─')
	testing.expect_value(t, row[4], '┐')
	testing.expect_value(t, row[5], 'p')
	testing.expect_value(t, row[9], 'n')
}

@test
test_charset_shift_out_and_shift_in :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 4, 40)
	defer term.terminal_destroy(&terminal)

	// G1 designator + SO locks G1 into GL; SI restores G0 (ASCII).
	term.terminal_feed_string(&terminal, "\x1b)0\x0ex\x0fz")
	row := _charset_row(&terminal, 0, 4)
	testing.expect_value(t, row[0], '│')
	testing.expect_value(t, row[1], 'z')
}

@test
test_charset_uk_designator :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 4, 40)
	defer term.terminal_destroy(&terminal)

	term.terminal_feed_string(&terminal, "\x1b(A#\x1b(B#")
	row := _charset_row(&terminal, 0, 3)
	testing.expect_value(t, row[0], '£')
	testing.expect_value(t, row[1], '#')
}

@test
test_charset_null_designator_discards :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 4, 40)
	defer term.terminal_destroy(&terminal)

	term.terminal_feed_string(&terminal, "\x1b(Uabc\x1b(BZ")
	// 'U' maps every GL byte to nothing; the cell stays blank until 'Z'.
	row := _charset_row(&terminal, 0, 2)
	testing.expect_value(t, row[0], 'Z')
}

@test
test_single_shift_applies_to_one_character :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 4, 40)
	defer term.terminal_destroy(&terminal)

	// G2 = DEC graphics, SS2 maps exactly one byte, then GL returns to ASCII.
	term.terminal_feed_string(&terminal, "\x1b*0\x1bNqq")
	row := _charset_row(&terminal, 0, 3)
	testing.expect_value(t, row[0], '─')
	testing.expect_value(t, row[1], 'q')
}

@test
test_index_and_next_line :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 4, 40)
	defer term.terminal_destroy(&terminal)

	// IND keeps the column, NEL resets it.
	term.terminal_feed_string(&terminal, "ab\x1bDcd\x1bEef")
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 0).char, 'a')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 1, 2).char, 'c')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 1, 3).char, 'd')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 2, 0).char, 'e')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 2, 1).char, 'f')
}

@test
test_ris_resets_character_sets :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 4, 40)
	defer term.terminal_destroy(&terminal)

	term.terminal_feed_string(&terminal, "\x1b(0\x1bca")
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 0).char, 'a')
	testing.expect_value(t, terminal.parser.charsets[0], parser.CHARSET_ASCII)
}
