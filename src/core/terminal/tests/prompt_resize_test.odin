package terminal_tests

import "core:testing"
import term "../"

@test
test_terminal_resize_rprompt_wrapped_no_duplication :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 5, 40)
	defer term.terminal_destroy(&terminal)

	// Feed 40-char prompt line with OSC 133 semantic markers
	// Line 0: "╭─ ~/term               at 12:00:00" (40 cols)
	term.terminal_feed_string(&terminal, "\x1b]133;A\x07\u256D\u2500 ~/term               at 12:00:00")
	// Feed wrap to next line: newline moves to row 1
	term.terminal_feed_string(&terminal, "\r\n\u2570\u2500\u276F \x1b]133;B\x07")

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

		// Reprint prompt cleanly with OSC 133 markers
		term.terminal_feed_string(&terminal, "\x1b]133;A\x07\u256D\u2500 ~/term\r\n\u2570\u2500\u276F \x1b]133;B\x07")
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
test_terminal_resize_osc133_narrow_wrapped_prompt_preserves_history :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 10, 56)
	defer term.terminal_destroy(&terminal)

	// 1. Execute printf command under OSC 133 lifecycle (133;A -> 133;B -> 133;C -> output -> 133;D)
	term.terminal_feed_string(
		&terminal,
		"\x1b]133;A\x07\u276F \x1b]133;B\x07printf '\\e[3mSynthetic Italic\\e[0m \\e[4:3;58:2::255:80:80mCurly Red\\e[0m \\e[9mStrike\\e[0m\\n'\r\n\x1b]133;C\x07",
	)
	term.terminal_feed_string(
		&terminal,
		"\x1b[3mSynthetic Italic\x1b[0m \x1b[4:3;58:2::255:80:80mCurly Red\x1b[0m \x1b[9mStrike\x1b[0m\r\n\x1b]133;D;0\x07",
	)

	// 2. Active Powerlevel10k prompt at 56 cols (blank line + 34-col header + input line -> VD = 2)
	term.terminal_feed_string(
		&terminal,
		"\x1b]133;A\x07\r\n\u256D\u2500 \uF179 \uF07C ~/p/term on \uF1D3 \uF126 main !20 ?3\r\n\u2570\u2500\u276F \x1b]133;B\x07",
	)
	testing.expect_value(t, terminal.parser.cursor.row, 5)

	// 3. Narrow rapidly to 20 cols (< 34 cols minimum p10k banner width) and simulate Zsh SIGWINCH redraw
	term.terminal_resize(&terminal, 10, 20)
	// Zsh moves up 2 rows (old VD = 2), clears below, and redraws 34-col banner which wraps across 2 rows (new VD = 3)
	term.terminal_feed_string(
		&terminal,
		"\r\r\x1b[2A\x1b[J\x1b]133;A\x07\r\n\u256D\u2500 \uF179 \uF07C ~/p/term on \uF1D3 \uF126 main !20 ?3\r\n\u2570\u2500\u276F \x1b]133;B\x07",
	)

	// 4. Widen back to 56 cols and simulate Zsh SIGWINCH redraw (moves up 3 rows for old VD = 3, clears below)
	term.terminal_resize(&terminal, 10, 56)
	term.terminal_feed_string(
		&terminal,
		"\r\r\x1b[3A\x1b[J\x1b]133;A\x07\r\n\u256D\u2500 \uF179 \uF07C ~/p/term on \uF1D3 \uF126 main !20 ?3\r\n\u2570\u2500\u276F \x1b]133;B\x07",
	)

	// Verify command and styled output rows were never overwritten or lost
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 0).char, rune(0x276F))
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 2).char, 'p')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 2, 0).char, 'S')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 2, 17).char, 'C')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 2, 27).char, 'S')
}

// Rows below the cursor while a prompt is active (prompt at the top after
// `clear`, output further down) are outside the prompt block [prompt start,
// cursor row]: reflow must consume them like any other row instead of
// stalling on them (the old guard looped forever, allocating).
@test
test_terminal_resize_rows_below_active_prompt :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 7, 15)
	defer term.terminal_destroy(&terminal)

	term.terminal_feed_string(&terminal, "\r\n\r\nbelow\x1b[H$ ls")
	testing.expect_value(t, terminal.parser.cursor.row, 0)

	term.terminal_resize(&terminal, 9, 14)
	testing.expect_value(t, terminal.parser.cursor.row, 0)
	testing.expect_value(t, terminal.parser.cursor.col, 4)
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 0).char, '$')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 2, 0).char, 'b')

	term.terminal_resize(&terminal, 6, 30)
	testing.expect_value(t, term.terminal_get_cell(&terminal, 2, 0).char, 'b')
}
