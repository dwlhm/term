package termgrid_test

import "core:testing"
import termgrid "../"

@(test)
test_resize_in_alt_screen_preserves_primary :: proc(t: ^testing.T) {
	term: termgrid.Terminal
	termgrid.terminal_init(&term, 24, 80)
	defer termgrid.terminal_destroy(&term)

	// Write primary screen content
	msg1 := "Primary Shell Content Row 0"
	for ch, i in msg1 {
		termgrid.terminal_put_char(&term, ch)
	}
	termgrid.terminal_newline(&term)
	msg2 := "Primary Shell Content Row 1"
	for ch, i in msg2 {
		termgrid.terminal_put_char(&term, ch)
	}

	// Switch to alt screen (e.g. neovim / htop)
	termgrid.terminal_enter_alt_screen(&term)
	testing.expect(t, term.is_alt_screen, "must be in alt screen")

	// Write alt screen content
	alt_msg := "Editor Running on Alt Screen"
	for ch, i in alt_msg {
		termgrid.terminal_put_char(&term, ch)
	}

	// Verify scrollback is clean before resize
	testing.expect_value(t, term.scrollback.count, 0)

	// Resize while in alt screen
	termgrid.terminal_resize(&term, 30, 100)
	testing.expect_value(t, term.grid.row_count, 30)
	testing.expect_value(t, term.grid.col_count, 100)

	// Crucial invariant: Alt screen lines MUST NOT pollute scrollback
	testing.expect_value(t, term.scrollback.count, 0)

	// Switch back to primary screen (quitting editor)
	termgrid.terminal_leave_alt_screen(&term)
	testing.expect(t, !term.is_alt_screen, "must be back in primary screen")
	testing.expect_value(t, term.grid.row_count, 30)
	testing.expect_value(t, term.grid.col_count, 100)

	// Verify primary screen content was preserved and not wiped by resize
	cell0 := termgrid.terminal_get_cell(&term, 0, 0)
	testing.expect(t, cell0.content == 'P', "Row 0 col 0 must still be 'P'")
	cell1 := termgrid.terminal_get_cell(&term, 1, 0)
	testing.expect(t, cell1.content == 'P', "Row 1 col 0 must still be 'P'")
}

@(test)
test_cursor_restore_clamping_after_shrink :: proc(t: ^testing.T) {
	term: termgrid.Terminal
	termgrid.terminal_init(&term, 40, 80)
	defer termgrid.terminal_destroy(&term)

	// Move cursor deep towards bottom right
	term.cursor.row = 35
	term.cursor.col = 75
	termgrid.terminal_save_cursor(&term)

	// Shrink terminal to 20 rows, 50 cols
	termgrid.terminal_resize(&term, 20, 50)

	// Restore cursor
	termgrid.terminal_restore_cursor(&term)

	// Cursor must be clamped within active grid bounds
	testing.expect(t, term.cursor.row < term.grid.row_count, "cursor row must be within grid rows")
	testing.expect(t, term.cursor.col < term.grid.col_count, "cursor col must be within grid cols")
	testing.expect_value(t, term.cursor.row, 19)
	testing.expect_value(t, term.cursor.col, 49)
}
