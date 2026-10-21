package terminal_tests

import "core:testing"
import term "../"

@test
test_terminal_resize_rprompt_wrapped_no_duplication :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 5, 40)
	defer term.terminal_destroy(&terminal)

	// Feed 40-char prompt line that fills all 40 columns completely, triggering pending_wrap
	// Line 0: "╭─ ~/term               at 12:00:00" (40 cols)
	term.terminal_feed_string(&terminal, "\u256D\u2500 ~/term               at 12:00:00")
	// Feed wrap to next line: newline moves to row 1
	term.terminal_feed_string(&terminal, "\r\n\u2570\u2500\u276F ")

	// Manually ensure row 0 had wrap == true (simulating right margin overflow from RPROMPT)
	row0 := term.terminal_get_row(&terminal, 0)
	testing.expect(t, row0 != nil, "Row 0 should exist")
	row0.wrap = true

	testing.expect_value(t, terminal.parser.cursor.row, 1)

	// Rapidly resize through various widths
	widths := [?]int{35, 30, 25, 20, 30, 40}
	for w in widths {
		term.terminal_resize(&terminal, 5, w)

		// Prompt must never wrap or push cursor row down
		testing.expect_value(t, terminal.parser.cursor.row, 1)
		testing.expect_value(t, terminal.grid.history_count, 0)

		r0 := term.terminal_get_row(&terminal, 0)
		r1 := term.terminal_get_row(&terminal, 1)
		testing.expect(t, r0 != nil && !r0.wrap, "Row 0 must stay 1 row and wrap == false")
		testing.expect(t, r1 != nil && !r1.wrap, "Row 1 must stay 1 row and wrap == false")
		testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 0).char, rune(0x256D))
		testing.expect_value(t, term.terminal_get_cell(&terminal, 1, 0).char, rune(0x2570))

		// Simulate Zsh SIGWINCH handling: move up 1 line (\x1b[A), CR (\r), clear to bottom (\x1b[J), and reprint
		term.terminal_feed_string(&terminal, "\x1b[A\r\x1b[J")
		testing.expect_value(t, terminal.parser.cursor.row, 0)

		// Reprint prompt cleanly
		term.terminal_feed_string(&terminal, "\u256D\u2500 ~/term\r\n\u2570\u2500\u276F ")
		testing.expect_value(t, terminal.parser.cursor.row, 1)
		testing.expect_value(t, terminal.grid.history_count, 0)
	}
}

@test
test_terminal_resize_saved_cursor_synchronization :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 6, 20)
	defer term.terminal_destroy(&terminal)

	// Move cursor to (row 2, col 15) and save with DECSC (\x1b7)
	term.terminal_feed_string(&terminal, "\x1b[3;16H\x1b7")
	testing.expect_value(t, terminal.parser.cursor.row, 2)
	testing.expect_value(t, terminal.parser.cursor.col, 15)
	testing.expect_value(t, terminal.parser.cursor.saved_row, 2)
	testing.expect_value(t, terminal.parser.cursor.saved_col, 15)

	// Move cursor away to (0, 0)
	term.terminal_feed_string(&terminal, "\x1b[1;1H")
	testing.expect_value(t, terminal.parser.cursor.row, 0)

	// Narrow columns to 10: saved_col must be clamped to 9
	term.terminal_resize(&terminal, 6, 10)
	testing.expect_value(t, terminal.parser.cursor.saved_col, 9)

	// Restore cursor with DECRC (\x1b8)
	term.terminal_feed_string(&terminal, "\x1b8")
	testing.expect_value(t, terminal.parser.cursor.row, 2)
	testing.expect_value(t, terminal.parser.cursor.col, 9)
}

@test
test_terminal_resize_inflight_overflow_prompt_header_does_not_wrap :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 5, 20)
	defer term.terminal_destroy(&terminal)

	// Feed prompt header of 25 characters into a 20-column terminal (simulating wider in-flight output)
	// Header starts with '╭─' (0x256D)
	term.terminal_feed_string(&terminal, "\u256D\u2500 ~/term on git at 12:00")

	// The prompt header must NOT wrap onto row 1; it must clip at col 19, keeping row 1 empty!
	testing.expect_value(t, terminal.parser.cursor.row, 0)
	testing.expect_value(t, terminal.parser.cursor.col, 19)

	r0 := term.terminal_get_row(&terminal, 0)
	testing.expect(t, r0 != nil && !r0.wrap, "Prompt header must not have wrap == true")

	// Next line is newline + bottom frame
	term.terminal_feed_string(&terminal, "\r\n\u2570\u2500\u276F ")
	testing.expect_value(t, terminal.parser.cursor.row, 1)

	// Shell clears with \x1b[A\r\x1b[J
	term.terminal_feed_string(&terminal, "\x1b[A\r\x1b[J")
	testing.expect_value(t, terminal.parser.cursor.row, 0)

	// Row 0 is now clean
	r0_cleared := term.terminal_get_row(&terminal, 0)
	testing.expect(t, r0_cleared != nil, "Row 0 should exist")
	testing.expect_value(t, r0_cleared.cells[0].char, ' ')
}
