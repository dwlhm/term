package terminal_tests

import "core:mem"
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

@test
test_terminal_resize_preserves_prompt_and_history_separation :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 5, 40)
	defer term.terminal_destroy(&terminal)

	// Feed 10 lines so earlier lines scroll into scrollback history (6 history rows + 5 visible rows)
	for i in 0..<8 {
		term.terminal_feed_string(&terminal, "scrollback history line\r\n")
	}
	term.terminal_feed_string(&terminal, "drwxr-xr-x src\r\n\u256D\u2500 ~/project\r\n\u2570\u2500> ")

	old_hist := terminal.grid.history_count
	testing.expect_value(t, old_hist, 6)
	testing.expect_value(t, terminal.parser.cursor.row, 4)

	// Resize to 12 rows, 60 cols (height increases by 7, pulling all 6 history rows down into rows 0..5)
	term.terminal_resize(&terminal, 12, 60)

	// Cursor shifts down by 6 pulled history rows (4 + 6 = 10), leaving row 11 empty
	testing.expect_value(t, terminal.parser.cursor.row, 10)
	testing.expect_value(t, terminal.grid.history_count, 0)

	row8 := term.terminal_get_row(&terminal, 8)
	row9 := term.terminal_get_row(&terminal, 9)
	row10 := term.terminal_get_row(&terminal, 10)
	row11 := term.terminal_get_row(&terminal, 11)

	testing.expect(t, row8 != nil && row8.cells[0].char == 'd', "Row 8 should be 'drwxr-xr-x src'")
	testing.expect(t, row9 != nil && row9.cells[0].char == rune(0x256D), "Row 9 should be '╭─ ~/project'")
	testing.expect(t, row10 != nil && row10.cells[0].char == rune(0x2570), "Row 10 should be '╰─>'")
	testing.expect(t, row11 != nil && row11.cells[0].char == ' ', "Row 11 should be empty space")

	// Feed zsh SIGWINCH redraw sequence:
	term.terminal_feed_string(&terminal, "\r\x1b[A\x1b[J\r\n\x1b[A\u256D\u2500 ~/project\r\n\u2570\u2500> ")

	// Prompt must stay in place at rows 9..10 without duplicating or jumping down
	testing.expect_value(t, terminal.parser.cursor.row, 10)
	row9_after := term.terminal_get_row(&terminal, 9)
	row10_after := term.terminal_get_row(&terminal, 10)
	row11_after := term.terminal_get_row(&terminal, 11)
	testing.expect(t, row9_after != nil && row9_after.cells[0].char == rune(0x256D), "Row 9 must remain prompt top")
	testing.expect(t, row10_after != nil && row10_after.cells[0].char == rune(0x2570), "Row 10 must remain prompt bottom")
	testing.expect(t, row11_after != nil && row11_after.cells[0].char == ' ', "Row 11 must still be empty space")
}

@test
test_terminal_resize_vertical_only_fast_path :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 6, 40)
	defer term.terminal_destroy(&terminal)

	// Feed 4 lines, cursor is at row 3
	term.terminal_feed_string(&terminal, "line 0\r\nline 1\r\nline 2\r\nline 3")
	testing.expect_value(t, terminal.parser.cursor.row, 3)

	// Enlarge height: 6 -> 10 rows (cols stays 40, history is 0)
	term.terminal_resize(&terminal, 10, 40)

	// Cursor and content must stay at rows 0..3
	testing.expect_value(t, terminal.parser.cursor.row, 3)
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 0).char, 'l')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 3, 5).char, '3')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 4, 0).char, ' ')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 9, 0).char, ' ')

	// Now shrink height below cursor: 10 -> 3 rows (cursor was at row 3)
	term.terminal_resize(&terminal, 3, 40)

	// Cursor must be clamped to last row (2), pushing "line 0" into history
	testing.expect_value(t, terminal.parser.cursor.row, 2)
	testing.expect_value(t, terminal.grid.history_count, 1)
	testing.expect_value(t, term.terminal_get_cell(&terminal, 2, 5).char, '3')

	// Enlarge height back: 3 -> 6 rows -> "line 0" must be pulled back from history into row 0!
	term.terminal_resize(&terminal, 6, 40)
	testing.expect_value(t, terminal.grid.history_count, 0)
	testing.expect_value(t, terminal.parser.cursor.row, 3)
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 5).char, '0')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 3, 5).char, '3')
}

@test
test_terminal_resize_prompt_wrapped_command :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 5, 20)
	defer term.terminal_destroy(&terminal)

	// Prompt followed by command that wraps across 2 rows (20 cols: "╰─❯ 0123456789ABCDEFG" = 21 chars)
	term.terminal_feed_string(&terminal, "\u2570\u2500\u276F 0123456789ABCDEFG")

	row0 := term.terminal_get_row(&terminal, 0)
	row1 := term.terminal_get_row(&terminal, 1)
	testing.expect(t, row0 != nil && row0.wrap, "Row 0 must wrap")
	testing.expect(t, row1 != nil && !row1.wrap, "Row 1 must be continuation")

	// Widen to 40 columns: must unwrap completely into row 0 without data loss!
	term.terminal_resize(&terminal, 5, 40)

	w_row0 := term.terminal_get_row(&terminal, 0)
	testing.expect(t, w_row0 != nil, "Row 0 is nil")
	testing.expect(t, !w_row0.wrap, "Row 0 should no longer be wrapped after widening")
	// Verify characters 'G' at end of command is preserved
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 0).char, rune(0x2570))
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 20).char, 'G')
}

@test
test_terminal_resize_overflow_preserves_cursor_line :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 10, 40)
	defer term.terminal_destroy(&terminal)

	// Fill screen with cursor at row 2 and completion items at rows 3..7
	term.terminal_feed_string(&terminal, "line 0\r\nline 1\r\nline 2 (cursor here)\r\nmenu item 1\r\nmenu item 2\r\nmenu item 3\r\nmenu item 4\r\nmenu item 5")
	// Move cursor up to row 2
	term.terminal_feed_string(&terminal, "\x1b[5A")
	testing.expect_value(t, terminal.parser.cursor.row, 2)

	// Shrink viewport to 4 rows: cursor line must stay visible, not pushed off to history
	term.terminal_resize(&terminal, 4, 40)

	testing.expect(t, terminal.parser.cursor.row >= 0 && terminal.parser.cursor.row < 4, "Cursor must remain in visible area")
	cur_cell := term.terminal_get_cell(&terminal, terminal.parser.cursor.row, 0)
	testing.expect_value(t, cur_cell.char, 'l') // line 2
}

@test
test_terminal_resize_one_column_wide_char :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 5, 10)
	defer term.terminal_destroy(&terminal)

	// Kanji '日' (width 2)
	term.terminal_feed_string(&terminal, "\u65E5")

	// Resize to 1 column: wide char cannot fit, must safely be replaced without crash or broken continuation
	term.terminal_resize(&terminal, 5, 1)

	c0 := term.terminal_get_cell(&terminal, 0, 0)
	testing.expect(t, !(.Wide_Lead in c0.flags), "Col 0 cannot be wide lead in 1-column grid")
}

@test
test_terminal_resize_seam_coalescence :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 2, 10)
	defer term.terminal_destroy(&terminal)

	// Line 0 wraps onto line 1, then line 1 scrolls into history!
	// "0123456789" (row 0, wraps) + "abcdefghij" (row 1, wraps) + "KLM" (row 2)
	term.terminal_feed_string(&terminal, "0123456789abcdefghijKLM")

	// Now row 0 is in history with wrap == true, continuing into visible row 0
	testing.expect(t, terminal.grid.history_count > 0, "Expected history count > 0")

	// Widen to 30 columns: the wrapped seam line across history and row 0 must coalesce and unwrap!
	term.terminal_resize(&terminal, 5, 30)

	// Row 0 should contain the unwrapped string "0123456789abcdefghijKLM"
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 0).char, '0')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 9).char, '9')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 10).char, 'a')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 19).char, 'j')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 20).char, 'K')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 22).char, 'M')
}

@test
test_terminal_resize_wrapped_row_trailing_space_preserved :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 5, 6)
	defer term.terminal_destroy(&terminal)

	// "hello " has 6 characters, fills row 0 exactly!
	// Next character "world" wraps to row 1.
	term.terminal_feed_string(&terminal, "hello world")

	row0 := term.terminal_get_row(&terminal, 0)
	testing.expect(t, row0 != nil && row0.wrap, "Row 0 must wrap")
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 5).char, ' ')

	// Widen to 20 columns: row 0 must become "hello world" with space at index 5!
	term.terminal_resize(&terminal, 5, 20)

	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 0).char, 'h')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 4).char, 'o')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 5).char, ' ') // The space must NOT be trimmed!
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 6).char, 'w')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 10).char, 'd')
}

@test
test_terminal_resize_prompt_flag_not_duplicated_on_continuation :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 5, 30)
	defer term.terminal_destroy(&terminal)

	// Long prompt line with explicit is_prompt
	term.terminal_feed_string(&terminal, "prompt start text")
	row0 := term.terminal_get_row(&terminal, 0)
	testing.expect(t, row0 != nil, "Row 0 should not be nil")
	row0.is_prompt = true

	// Narrow to 10 cols so prompt line wraps into 2 rows
	term.terminal_resize(&terminal, 5, 10)

	n_row0 := term.terminal_get_row(&terminal, 0)
	n_row1 := term.terminal_get_row(&terminal, 1)
	testing.expect(t, n_row0 != nil && n_row0.is_prompt, "Row 0 must retain is_prompt == true")
	testing.expect(t, n_row1 != nil && !n_row1.is_prompt, "Continuation row 1 must have is_prompt == false")
}

@test
test_terminal_resize_active_prompt_top_line_truncated_not_wrapped :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 5, 60)
	defer term.terminal_destroy(&terminal)

	// Simulate Powerlevel10k 2-line prompt:
	// Row 0: "╭─  ~/project/term on git:main              at 16:05:24" (56 chars)
	// Row 1: "╰─❯ " (cursor here)
	term.terminal_feed_string(&terminal, "\u256D\u2500 \uF179 ~/project/term on git:main              at 16:05:24\r\n\u2570\u2500\u276F ")

	testing.expect_value(t, terminal.parser.cursor.row, 1)

	// Shrink from 60 to 30 columns:
	// Top prompt row was 1 physical row before resize. It must truncate (not wrap into 2 rows),
	// so that distance to cursor stays exactly 1 row!
	term.terminal_resize(&terminal, 5, 30)

	testing.expect_value(t, terminal.parser.cursor.row, 1)
	row0 := term.terminal_get_row(&terminal, 0)
	row1 := term.terminal_get_row(&terminal, 1)
	testing.expect(t, row0 != nil && !row0.wrap, "Active prompt top row must NOT wrap into 2 rows")
	testing.expect(t, row1 != nil, "Row 1 must be active prompt bottom row")
	testing.expect_value(t, row0.cells[0].char, rune(0x256D))
	testing.expect_value(t, row1.cells[0].char, rune(0x2570))
}

@test
test_terminal_resize_box_drawing_in_output_reflows_normally :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 5, 30)
	defer term.terminal_destroy(&terminal)

	// Box drawing in output (not cursor row), e.g. tree output or table:
	term.terminal_feed_string(&terminal, "\u250C\u2500\u2500 Header Box Table \u2500\u2500\u2510\r\noutput line\r\n$ ")

	// Cursor is at row 2 ('$ ')
	testing.expect_value(t, terminal.parser.cursor.row, 2)

	// Shrink from 30 to 10 cols:
	// Row 0 has 24 chars, was output (not prompt block contiguous to cursor line).
	// It should wrap normally instead of being treated as a prompt line!
	term.terminal_resize(&terminal, 10, 10)

	// The box drawing line should wrap across multiple rows
	row0 := term.terminal_get_row(&terminal, 0)
	testing.expect(t, row0 != nil && row0.wrap, "Box drawing line in output should wrap normally when narrowed")
}

@test
test_terminal_resize_history_pull_preserves_blank_rows_below_cursor :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 5, 20)
	defer term.terminal_destroy(&terminal)

	// Push 5 lines into history (total 10 lines on 5-row screen)
	for i in 0..<9 {
		term.terminal_feed_string(&terminal, "hist line\r\n")
	}
	term.terminal_feed_string(&terminal, "active")
	testing.expect_value(t, terminal.grid.history_count, 5)
	testing.expect_value(t, terminal.parser.cursor.row, 4)

	// Move cursor up 2 rows (to row 2) and clear below cursor (\x1b[J) so rows 3..4 are blank
	term.terminal_feed_string(&terminal, "\x1b[2A\x1b[J")
	testing.expect_value(t, terminal.parser.cursor.row, 2)

	// Resize from 5x20 to 7x30 (height increases by 2, while 4 rows are free below row 2):
	// Should pull at most delta_rows = 2 lines from history, preserving the 2 blank rows below cursor!
	term.terminal_resize(&terminal, 7, 30)
	testing.expect_value(t, terminal.grid.history_count, 3)
	testing.expect_value(t, terminal.parser.cursor.row, 4)
}

@test
test_terminal_resize_temp_allocator_self_cleaning :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 5, 20)
	defer term.terminal_destroy(&terminal)

	term.terminal_feed_string(&terminal, "line 1\r\nline 2\r\nline 3\r\nline 4\r\nline 5\r\nline 6\r\n0123456789abcdefghij")

	temp_track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&temp_track, context.temp_allocator)
	defer mem.tracking_allocator_destroy(&temp_track)

	{
		context.temp_allocator = mem.tracking_allocator(&temp_track)
		term.terminal_resize(&terminal, 8, 10)
		term.terminal_resize(&terminal, 10, 30)
	}

	testing.expect_value(t, len(temp_track.allocation_map), 0)
	testing.expect_value(t, temp_track.current_memory_allocated, 0)
}

@test
test_terminal_resize_starship_multiline_prompt_protection :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 5, 60)
	defer term.terminal_destroy(&terminal)

	// Output line followed by 2-line prompt
	term.terminal_feed_string(&terminal, "output row 0\r\n\u256D\u2500 \uF179 ~/project/term on git:main at 12:00:00\r\n\u2570\u2500\u276F ")

	testing.expect_value(t, terminal.parser.cursor.row, 2)

	// Resize down to 25 cols:
	// Output row 0 wraps, but prompt banner and input line must stay exactly 1 row each!
	term.terminal_resize(&terminal, 6, 25)

	testing.expect_value(t, terminal.parser.cursor.row, 2)
	row1 := term.terminal_get_row(&terminal, 1)
	row2 := term.terminal_get_row(&terminal, 2)
	testing.expect(t, row1 != nil && !row1.wrap, "Banner line must not wrap")
	testing.expect(t, row2 != nil && !row2.wrap, "Input line must not wrap")

	// Resize back up to 60 cols
	term.terminal_resize(&terminal, 5, 60)
	testing.expect_value(t, terminal.parser.cursor.row, 2)
}

@test
test_terminal_resize_standard_bash_prompt_protection :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 5, 60)
	defer term.terminal_destroy(&terminal)

	term.terminal_feed_string(&terminal, "first output\r\nuser@hostname:~/project$ ")
	testing.expect_value(t, terminal.parser.cursor.row, 1)

	// Resize down to 15 cols: cursor row with prompt must be protected
	term.terminal_resize(&terminal, 5, 15)
	testing.expect_value(t, terminal.parser.cursor.row, 1)

	// Resize back to 60 cols
	term.terminal_resize(&terminal, 5, 60)
	testing.expect_value(t, terminal.parser.cursor.row, 1)
}

@test
test_terminal_resize_scrollback_history_reflows_on_widen_and_narrow :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 3, 20)
	defer term.terminal_destroy(&terminal)

	// Feed 40 chars that wrap into 2 rows at 20 cols:
	// "0123456789abcdefghij" (20) + "0123456789abcdefghij" (20)
	term.terminal_feed_string(&terminal, "0123456789abcdefghij0123456789abcdefghij\r\n")

	// Feed 4 lines to push the wrapped line deep into scrollback history
	term.terminal_feed_string(&terminal, "line1\r\nline2\r\nline3\r\nline4\r\n")
	testing.expect(t, terminal.grid.history_count >= 2, "Expected history_count >= 2")

	// Widen to 50 columns:
	// The 40-char wrapped line in history must coalesce/unwrap into 1 row!
	term.terminal_resize(&terminal, 3, 50)

	oldest := term.terminal_get_row(&terminal, -terminal.grid.history_count)
	testing.expect(t, oldest != nil, "Oldest history row must exist")
	testing.expect_value(t, oldest.cells[0].char, '0')
	testing.expect_value(t, oldest.cells[19].char, 'j')
	testing.expect_value(t, oldest.cells[20].char, '0')
	testing.expect_value(t, oldest.cells[39].char, 'j')
	testing.expect(t, !oldest.wrap, "Unwrapped row in scrollback must have wrap == false")

	// Narrow to 10 columns:
	// The 40-char line in history must wrap into 4 rows of 10 chars each!
	term.terminal_resize(&terminal, 3, 10)

	r0 := term.terminal_get_row(&terminal, -terminal.grid.history_count)
	r1 := term.terminal_get_row(&terminal, -terminal.grid.history_count + 1)
	r2 := term.terminal_get_row(&terminal, -terminal.grid.history_count + 2)
	r3 := term.terminal_get_row(&terminal, -terminal.grid.history_count + 3)

	testing.expect(t, r0 != nil && r0.wrap, "Row 0 in scrollback must wrap")
	testing.expect(t, r1 != nil && r1.wrap, "Row 1 in scrollback must wrap")
	testing.expect(t, r2 != nil && r2.wrap, "Row 2 in scrollback must wrap")
	testing.expect(t, r3 != nil && !r3.wrap, "Row 3 in scrollback must not wrap")

	testing.expect_value(t, r0.cells[0].char, '0')
	testing.expect_value(t, r1.cells[0].char, 'a')
	testing.expect_value(t, r2.cells[0].char, '0')
	testing.expect_value(t, r3.cells[0].char, 'a')
}

