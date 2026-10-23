package terminal_tests

// Regression tests for the remaining ECMA-48 / DEC control functions that TUI
// toolkits rely on: tab stops, REP, DECSTR, DECRQM and synchronized output.

import "core:testing"
import term "../"

@test
test_tab_stops_default_and_custom :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 4, 40)
	defer term.terminal_destroy(&terminal)

	term.terminal_feed_string(&terminal, "\tX")
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 8).char, 'X')

	// HTS at column index 3 makes it the next stop after column 0.
	term.terminal_feed_string(&terminal, "\x1b[2;4H\x1bH\r\tZ")
	testing.expect_value(t, term.terminal_get_cell(&terminal, 1, 3).char, 'Z')

	// TBC clears that stop again, so the next tab lands on column 8.
	term.terminal_feed_string(&terminal, "\x1b[3;4H\x1b[0g\r\tW")
	testing.expect_value(t, term.terminal_get_cell(&terminal, 2, 8).char, 'W')
}

@test
test_tab_clear_all_and_forward_backward_tabulation :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 4, 40)
	defer term.terminal_destroy(&terminal)

	// With every stop cleared, TAB moves to the last column.
	term.terminal_feed_string(&terminal, "\x1b[3g\tQ")
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 39).char, 'Q')

	// CHT/CBT against a single reprogrammed stop at column index 9.
	term.terminal_feed_string(&terminal, "\x1b[2;10H\x1bH\r\x1b[IZ")
	testing.expect_value(t, term.terminal_get_cell(&terminal, 1, 9).char, 'Z')

	term.terminal_feed_string(&terminal, "\x1b[2;20H\x1b[ZY")
	testing.expect_value(t, term.terminal_get_cell(&terminal, 1, 9).char, 'Y')
}

@test
test_repeat_preceding_character :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 4, 40)
	defer term.terminal_destroy(&terminal)

	term.terminal_feed_string(&terminal, "A\x1b[4b")
	for c in 0..<5 {
		testing.expect_value(t, term.terminal_get_cell(&terminal, 0, c).char, 'A')
	}
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 5).char, ' ')
}

@test
test_soft_reset_decstr :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 6, 40)
	defer term.terminal_destroy(&terminal)

	term.terminal_feed_string(&terminal, "\x1b[1;31m\x1b[2;4r\x1b[3;5H\x1b[?1h\x1b[?2004h")
	term.terminal_feed_string(&terminal, "\x1b[!p")

	testing.expect_value(t, terminal.parser.cursor.row, 0)
	testing.expect_value(t, terminal.parser.cursor.col, 0)
	testing.expect_value(t, terminal.parser.scroll_top, 0)
	testing.expect_value(t, terminal.parser.scroll_bottom, 5)
	testing.expect(t, !terminal.parser.cursor_key_mode, "DECSTR must clear application cursor keys")
	testing.expect(t, !terminal.parser.bracketed_paste, "DECSTR must clear bracketed paste")
	testing.expect_value(t, term.terminal_cursor_active_fg(&terminal), 7)

	// Content survives a soft reset: it is not a RIS.
	row := term.terminal_get_row(&terminal, 0)
	testing.expect(t, row != nil)
}

@test
test_decrqm_mode_reports :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 4, 40)
	defer term.terminal_destroy(&terminal)

	term.terminal_feed_string(&terminal, "\x1b[?25$p")
	buf: [64]u8
	n := term.terminal_drain_response(&terminal, buf[:])
	testing.expect_value(t, string(buf[:n]), "\x1b[?25;1$y")

	term.terminal_feed_string(&terminal, "\x1b[?25l\x1b[?25$p")
	n = term.terminal_drain_response(&terminal, buf[:])
	testing.expect_value(t, string(buf[:n]), "\x1b[?25;2$y")

	term.terminal_feed_string(&terminal, "\x1b[?9999$p")
	n = term.terminal_drain_response(&terminal, buf[:])
	testing.expect_value(t, string(buf[:n]), "\x1b[?9999;0$y")

	term.terminal_feed_string(&terminal, "\x1b[?2026h\x1b[?2026$p")
	n = term.terminal_drain_response(&terminal, buf[:])
	testing.expect_value(t, string(buf[:n]), "\x1b[?2026;1$y")

	term.terminal_feed_string(&terminal, "\x1b[?6$p")
	n = term.terminal_drain_response(&terminal, buf[:])
	testing.expect_value(t, string(buf[:n]), "\x1b[?6;2$y")

	term.terminal_feed_string(&terminal, "\x1b[?7$p")
	n = term.terminal_drain_response(&terminal, buf[:])
	testing.expect_value(t, string(buf[:n]), "\x1b[?7;1$y")
}

@test
test_origin_mode_decom :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 10, 40)
	defer term.terminal_destroy(&terminal)

	// Set scroll margins to rows 3..6 (1-indexed: 3..6 -> 0-indexed: 2..5)
	term.terminal_feed_string(&terminal, "\x1b[3;6r")
	testing.expect_value(t, terminal.parser.scroll_top, 2)
	testing.expect_value(t, terminal.parser.scroll_bottom, 5)

	// In normal mode (DECOM off), \x1b[1;1H is absolute row 0
	term.terminal_feed_string(&terminal, "\x1b[1;1H")
	r, c := term.terminal_cursor_pos(&terminal)
	testing.expect_value(t, r, 0)
	testing.expect_value(t, c, 0)

	// Turn on Origin Mode (\x1b[?6h): cursor moves to top margin (row 2)
	term.terminal_feed_string(&terminal, "\x1b[?6h")
	testing.expect(t, term.terminal_origin_mode(&terminal), "origin mode must be set")
	r, c = term.terminal_cursor_pos(&terminal)
	testing.expect_value(t, r, 2)
	testing.expect_value(t, c, 0)

	// With DECOM on, \x1b[1;1H addresses row 1 of the margin (row 2)
	term.terminal_feed_string(&terminal, "\x1b[1;5H")
	r, c = term.terminal_cursor_pos(&terminal)
	testing.expect_value(t, r, 2)
	testing.expect_value(t, c, 4)

	// \x1b[2;1H addresses row 2 of the margin (row 3)
	term.terminal_feed_string(&terminal, "\x1b[2;1H")
	r, c = term.terminal_cursor_pos(&terminal)
	testing.expect_value(t, r, 3)
	testing.expect_value(t, c, 0)

	// Out-of-bounds row (e.g. 10) clamps to bottom margin (row 5)
	term.terminal_feed_string(&terminal, "\x1b[20;1H")
	r, c = term.terminal_cursor_pos(&terminal)
	testing.expect_value(t, r, 5)

	// Turn off Origin Mode (\x1b[?6l): cursor resets to (0,0)
	term.terminal_feed_string(&terminal, "\x1b[?6l")
	testing.expect(t, !term.terminal_origin_mode(&terminal), "origin mode must be reset")
	r, c = term.terminal_cursor_pos(&terminal)
	testing.expect_value(t, r, 0)
	testing.expect_value(t, c, 0)
}

@test
test_autowrap_mode_decawm :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 4, 5)
	defer term.terminal_destroy(&terminal)

	testing.expect(t, term.terminal_autowrap(&terminal), "autowrap must be enabled by default")

	// 1. With autowrap enabled: typing 6 characters into a 5-column grid wraps to row 1
	term.terminal_feed_string(&terminal, "ABCDEF")
	cell0 := term.terminal_get_cell(&terminal, 0, 4)
	cell1 := term.terminal_get_cell(&terminal, 1, 0)
	testing.expect_value(t, cell0.char, 'E')
	testing.expect_value(t, cell1.char, 'F')

	// Reset grid
	term.terminal_feed_string(&terminal, "\x1bc")

	// 2. Disable autowrap (\x1b[?7l)
	term.terminal_feed_string(&terminal, "\x1b[?7l")
	testing.expect(t, !term.terminal_autowrap(&terminal), "autowrap must be disabled")

	// Typing 6 characters overwrites the 5th column with the subsequent chars
	term.terminal_feed_string(&terminal, "1234567")
	c4 := term.terminal_get_cell(&terminal, 0, 4)
	c_next := term.terminal_get_cell(&terminal, 1, 0)
	testing.expect_value(t, c4.char, '7')
	testing.expect_value(t, c_next.char, ' ') // Row 1 remains empty!

	// Save and restore cursor restores autowrap
	term.terminal_feed_string(&terminal, "\x1b[?7h\x1b7\x1b[?7l\x1b8")
	testing.expect(t, term.terminal_autowrap(&terminal), "DECRC must restore autowrap state")
}

@test
test_synchronized_output_flag :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 4, 40)
	defer term.terminal_destroy(&terminal)

	testing.expect(t, !term.terminal_sync_output(&terminal), "synchronized output is off by default")
	term.terminal_feed_string(&terminal, "\x1b[?2026h")
	testing.expect(t, term.terminal_sync_output(&terminal), "?2026h must request a synchronized update")
	term.terminal_feed_string(&terminal, "\x1b[?2026l")
	testing.expect(t, !term.terminal_sync_output(&terminal), "?2026l must release the hold")
}
