package terminal_tests

import "core:testing"
import term "../"
import cell "../cell"

@test
test_terminal_resize_reflow_narrow :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 5, 20)
	defer term.terminal_destroy(&terminal)

	// Feed 20 characters on row 0
	term.terminal_feed_string(&terminal, "0123456789abcdefghij")

	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 0).char, '0')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 19).char, 'j')

	// Resize to 10 columns: line must wrap to 2 rows
	term.terminal_resize(&terminal, 5, 10)
	testing.expect_value(t, terminal.cols, 10)

	// Row 0 should have "0123456789" and wrap == true
	row0 := term.terminal_get_row(&terminal, 0)
	testing.expect(t, row0 != nil, "Row 0 is nil")
	testing.expect(t, row0.wrap, "Row 0 should be marked wrapped")
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 0).char, '0')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 9).char, '9')

	// Row 1 should have "abcdefghij" and wrap == false
	row1 := term.terminal_get_row(&terminal, 1)
	testing.expect(t, row1 != nil, "Row 1 is nil")
	testing.expect(t, !row1.wrap, "Row 1 should not be marked wrapped")
	testing.expect_value(t, term.terminal_get_cell(&terminal, 1, 0).char, 'a')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 1, 9).char, 'j')
}

@test
test_terminal_resize_reflow_widen :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 5, 10)
	defer term.terminal_destroy(&terminal)

	// Feed 20 characters on 10-col grid (wraps to 2 rows automatically)
	term.terminal_feed_string(&terminal, "0123456789abcdefghij")

	// Resize to 20 columns: the two wrapped rows must unwrap back into row 0
	term.terminal_resize(&terminal, 5, 20)
	testing.expect_value(t, terminal.cols, 20)

	row0 := term.terminal_get_row(&terminal, 0)
	testing.expect(t, row0 != nil, "Row 0 is nil")
	testing.expect(t, !row0.wrap, "Row 0 should not be marked wrapped after unwrap")
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 0).char, '0')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 9).char, '9')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 10).char, 'a')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 19).char, 'j')
}

@test
test_terminal_resize_wide_character_boundary :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 5, 10)
	defer term.terminal_destroy(&terminal)

	// Place 3 narrow characters + 1 wide kanji '日' (U+65E5, width 2)
	term.terminal_feed_string(&terminal, "abc\u65E5")

	// Resize to 4 columns: 'a', 'b', 'c' occupy 0, 1, 2.
	// Col 3 cannot fit '日' (requires 2 cells)! So col 3 is padded, row 0 wraps,
	// and '日' starts at col 0 on row 1!
	term.terminal_resize(&terminal, 5, 4)

	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 0).char, 'a')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 1).char, 'b')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 2).char, 'c')
	row0 := term.terminal_get_row(&terminal, 0)
	testing.expect(t, row0 != nil && row0.wrap, "Row 0 should wrap due to wide char overflow")

	testing.expect_value(t, term.terminal_get_cell(&terminal, 1, 0).char, rune(0x65E5))
	testing.expect(t, .Wide_Lead in term.terminal_get_cell(&terminal, 1, 0).flags, "Wide lead expected at (1,0)")
	testing.expect(t, .Wide_Continuation in term.terminal_get_cell(&terminal, 1, 1).flags, "Wide continuation expected at (1,1)")
}

@test
test_terminal_resize_preserves_scrollback :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 3, 10)
	defer term.terminal_destroy(&terminal)

	// Scroll lines into scrollback by writing 5 lines
	term.terminal_feed_string(&terminal, "line1\nline2\nline3\nline4\nline5")

	testing.expect(t, terminal.grid.history_count > 0, "Expected non-zero history_count")

	// Resize window
	term.terminal_resize(&terminal, 4, 15)
	testing.expect(t, terminal.grid.history_count > 0, "History count must be preserved across resize")

	// Verify content in history
	h_row := term.terminal_get_row(&terminal, -terminal.grid.history_count)
	testing.expect(t, h_row != nil, "History row is accessible")
	testing.expect_value(t, h_row.cells[0].char, 'l')
}

@test
test_terminal_resize_cursor_tracking :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 5, 20)
	defer term.terminal_destroy(&terminal)

	term.terminal_feed_string(&terminal, "0123456789ABCDEFGHIJ")
	testing.expect_value(t, terminal.parser.cursor.row, 0)

	// Resize to 10 cols: row 0 gets 10 chars, row 1 gets 10 chars, cursor should move to row 1
	term.terminal_resize(&terminal, 5, 10)
	testing.expect_value(t, terminal.parser.cursor.row, 1)
	testing.expect_value(t, terminal.parser.cursor.col, 9)
}

@test
test_terminal_resize_prompt_protection :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 5, 40)
	defer term.terminal_destroy(&terminal)

	// Simulate a multi-line prompt
	// Line 0: "╭─ ~/project"
	// Line 1: "╰─> "
	term.terminal_feed_string(&terminal, "\u256D\u2500 ~/project\r\n\u2570\u2500> ")

	// Resize from 40 to 30 columns
	term.terminal_resize(&terminal, 5, 30)

	// Prompt lines must remain on separate rows and NOT merge!
	row0 := term.terminal_get_row(&terminal, 0)
	row1 := term.terminal_get_row(&terminal, 1)

	testing.expect(t, row0 != nil, "Row 0 is nil")
	testing.expect(t, row1 != nil, "Row 1 is nil")
	testing.expect_value(t, row0.cells[0].char, rune(0x256D)) // '╭'
	testing.expect_value(t, row1.cells[0].char, rune(0x2570)) // '╰'
	testing.expect(t, !row0.wrap, "Prompt line 0 must not be wrapped")
	testing.expect(t, !row1.wrap, "Prompt line 1 must not be wrapped")
}

