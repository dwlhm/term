package termgrid_test

import "core:testing"
import tg "../"

@(test)
test_terminal_erase_display_entire :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Fill grid with content on first, second, and last rows.
	tg.terminal_put_string(&term, "Hello, World!")
	tg.terminal_newline(&term)
	tg.terminal_put_string(&term, "Second line here")
	cell := tg.Semantic_Cell{content = 'Z', style = 0, width = 1, flags = .None}
	testing.expect(t, tg.grid_set_cell(&term.grid, 23, 79, cell), "setup cell write should succeed")

	// Drain pre-erase damage so post-erase damage is purely from the erase.
	journal := tg.terminal_take_damage(&term)
	tg.damage_journal_destroy(&journal)

	// Park cursor mid-grid; VT ED must not move it.
	tg.terminal_move_cursor(&term, 5, 10)
	before := tg.terminal_get_cursor(&term)

	tg.terminal_erase_display(&term, .Entire)

	// ALL cells must be blank.
	failed := false
	for r in 0..<term.grid.row_count {
		for c in 0..<term.grid.col_count {
			got := tg.terminal_get_cell(&term, r, c)
			if got != tg.CELL_DEFAULT {
				failed = true
			}
		}
	}
	testing.expect(t, !failed, "every cell should be CELL_DEFAULT after ED 2")

	// Full damage expected.
	journal2 := tg.terminal_take_damage(&term)
	defer tg.damage_journal_destroy(&journal2)
	for r in 0..<term.grid.row_count {
		testing.expect(t, journal2.dirty_rows[r].full, "every row should be full damage after ED 2")
	}

	// Cursor unmoved.
	after := tg.terminal_get_cursor(&term)
	testing.expect(t, after.row == before.row && after.col == before.col, "ED must not move cursor")
}
