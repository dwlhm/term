package termgrid_test

import "core:testing"
import tg "../"

// xenl (deferred wrap) tests: printing to the last column must NOT move the
// cursor to the next line. The cursor stays at the last column with
// pending_wrap set; the line advance happens when the next character is
// printed. This matches xterm/ghostty/kitty and is required for fish shell
// autosuggestion rendering (save/move/print/restore cycles).

_xenl_fill_to_last_col :: proc(term: ^tg.Terminal) {
	// Fill row 0 cols 0..79; cursor ends at (0,79) with pending_wrap set.
	for _ in 0..<term.grid.col_count {
		tg.terminal_put_char(term, 'A')
	}
}

@(test)
test_xenl_last_col_defers_wrap :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	_xenl_fill_to_last_col(&term)

	cur := tg.terminal_get_cursor(&term)
	testing.expect(t, cur.row == 0 && cur.col == 79, "cursor must stay at last column")
	testing.expect(t, term.cursor.pending_wrap, "pending_wrap must be set")
	testing.expect(t, !term.grid.rows[0].wrapped, "row must not be marked wrapped yet")

	// Next character triggers the deferred advance.
	tg.terminal_put_char(&term, 'B')
	cur = tg.terminal_get_cursor(&term)
	testing.expect(t, cur.row == 1 && cur.col == 1, "cursor must advance to next line")
	testing.expect(t, term.grid.rows[0].wrapped, "row must be marked wrapped after advance")
	testing.expect(t, tg.grid_get_cell(&term.grid, 1, 0).content == 'B', "char must land on next line")
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 79).content == 'A', "last col content preserved")
	testing.expect(t, !term.cursor.pending_wrap, "pending_wrap cleared after advance")
}

@(test)
test_xenl_movement_cancels_pending :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	_xenl_fill_to_last_col(&term)
	tg.terminal_cursor_left(&term, 1)
	testing.expect(t, !term.cursor.pending_wrap, "cursor left must cancel pending wrap")
	testing.expect(t, term.cursor.col == 78, "cursor must move left normally")

	_xenl_fill_to_last_col(&term)
	tg.terminal_cursor_up(&term, 0)
	testing.expect(t, !term.cursor.pending_wrap, "cursor up must cancel pending wrap")

	_xenl_fill_to_last_col(&term)
	tg.terminal_move_cursor(&term, 3, 3)
	testing.expect(t, !term.cursor.pending_wrap, "CUP must cancel pending wrap")
	testing.expect(t, term.cursor.row == 3 && term.cursor.col == 3, "CUP must position exactly")
}

@(test)
test_xenl_backspace_cancels_pending :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	_xenl_fill_to_last_col(&term)
	tg.terminal_backspace(&term)
	testing.expect(t, !term.cursor.pending_wrap, "backspace must cancel pending wrap")
	testing.expect(t, term.cursor.col == 78, "backspace must move to col 78")
	testing.expect(
		t,
		tg.grid_get_cell(&term.grid, 0, 79).content == 'A',
		"backspace must not touch grid content",
	)
}

@(test)
test_xenl_newline_clears_pending :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	_xenl_fill_to_last_col(&term)
	tg.terminal_newline(&term)
	testing.expect(t, !term.cursor.pending_wrap, "newline must clear pending wrap")
	testing.expect(t, term.cursor.row == 1 && term.cursor.col == 0, "newline must home next line")
}

// Mirrors the fish autosuggestion cycle: save cursor, move to end of line,
// print the dim suggestion up to the last column, restore cursor, then type
// the next character. The typed character must land at the saved position,
// not on the row below.
@(test)
test_xenl_fish_autosuggestion_cycle :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// User typed "hello", cursor at (0,5).
	tg.terminal_put_string(&term, "hello")
	tg.terminal_save_cursor(&term)

	// Fish renders the suggestion: move to end, print 75 chars to last col.
	tg.terminal_move_cursor(&term, 0, 5)
	for _ in 0..<75 {
		tg.terminal_put_char(&term, 's')
	}
	testing.expect(t, term.cursor.pending_wrap, "suggestion fill must set pending wrap")

	// Fish restores the cursor to the typing position.
	tg.terminal_restore_cursor(&term)
	cur := tg.terminal_get_cursor(&term)
	testing.expect(t, cur.row == 0 && cur.col == 5, "restore must return to typing position")
	testing.expect(t, !term.cursor.pending_wrap, "restore must cancel pending wrap")

	// User types the next character: must land at (0,5), cursor to (0,6).
	tg.terminal_put_char(&term, 'X')
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 5).content == 'X', "typed char must land at saved pos")
	cur = tg.terminal_get_cursor(&term)
	testing.expect(t, cur.row == 0 && cur.col == 6, "cursor must advance normally, not jump lines")
}

@(test)
test_xenl_restore_marks_damage :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	tg.terminal_move_cursor(&term, 2, 5)
	tg.terminal_save_cursor(&term)
	tg.terminal_move_cursor(&term, 0, 0)
	tg.damage_clear(&term.damage)

	tg.terminal_restore_cursor(&term)
	testing.expect(t, term.damage.dirty_rows[0].span_count > 0 || term.damage.dirty_rows[0].full,
		"old cursor cell must be marked dirty")
	testing.expect(t, term.damage.dirty_rows[2].span_count > 0 || term.damage.dirty_rows[2].full,
		"restored cursor cell must be marked dirty")
}

@(test)
test_xenl_bottom_row_pending_scrolls :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 4, 10)
	defer tg.terminal_destroy(&term)

	// Fill the bottom row to the last column.
	tg.terminal_move_cursor(&term, 3, 0)
	for _ in 0..<10 {
		tg.terminal_put_char(&term, 'z')
	}
	testing.expect(t, term.cursor.pending_wrap, "pending wrap set at bottom-right")

	// Next char: deferred advance scrolls, cursor stays bottom row col 1.
	tg.terminal_put_char(&term, 'q')
	cur := tg.terminal_get_cursor(&term)
	testing.expect(t, cur.row == 3 && cur.col == 1, "bottom wrap must scroll and stay pinned")
	testing.expect(t, len(term.damage.scroll_ops) == 1, "bottom wrap must record a scroll op")
}
