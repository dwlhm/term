package termgrid_test

import "core:testing"
import tg "../"

@(test)
test_resize_grow_preserves_content :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	tg.terminal_move_cursor(&term, 0, 0)
	tg.terminal_put_char(&term, 'A')
	tg.terminal_move_cursor(&term, 23, 78)
	tg.terminal_put_char(&term, 'Z')
	tg.terminal_move_cursor(&term, 5, 10)
	tg.damage_clear(&term.damage)

	tg.terminal_resize(&term, 30, 100)

	testing.expect(t, term.grid.row_count == 30, "row_count should be 30")
	testing.expect(t, term.grid.col_count == 100, "col_count should be 100")
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 0).content == 'A', "top-left content kept")
	testing.expect(t, tg.grid_get_cell(&term.grid, 23, 78).content == 'Z', "old bottom-right kept")
	blank := tg.grid_get_cell(&term.grid, 29, 99)
	testing.expect(t, blank == tg.CELL_DEFAULT, "new cells should be CELL_DEFAULT")
	edge := tg.grid_get_cell(&term.grid, 0, 80)
	testing.expect(t, edge == tg.CELL_DEFAULT, "grown columns should be CELL_DEFAULT")
	testing.expect(t, term.cursor.row == 5 && term.cursor.col == 10, "cursor in bounds stays put")
	testing.expect(t, len(term.damage.dirty_rows) == 30, "damage should cover new rows")
	for i in 0..<30 {
		testing.expect(t, term.damage.dirty_rows[i].full, "every row should be fully dirty")
	}
}

@(test)
test_resize_shrink_truncates_and_clamps_cursor :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	tg.terminal_move_cursor(&term, 0, 0)
	tg.terminal_put_char(&term, 'A')
	tg.terminal_move_cursor(&term, 23, 78)
	tg.terminal_put_char(&term, 'Z')

	// Pool handle in the kept area, one in the truncated tail.
	kept := tg.grapheme_store_append(&term.grapheme_store, 'B', 0x301)
	tg.grid_set_cell(&term.grid, 0, 0, tg.Semantic_Cell{content = kept, style = 0, width = 1, flags = .None})
	tail := tg.grapheme_store_append(&term.grapheme_store, 'C', 0x302)
	tg.grid_set_cell(&term.grid, 0, 79, tg.Semantic_Cell{content = tail, style = 0, width = 1, flags = .None})
	testing.expect(t, term.grapheme_store.live_count == 2, "two live grapheme clusters")

	tg.terminal_move_cursor(&term, 23, 79)
	tg.terminal_resize(&term, 10, 10)

	testing.expect(t, term.grid.row_count == 10, "row_count should be 10")
	testing.expect(t, term.grid.col_count == 10, "col_count should be 10")
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 0).content == kept, "kept handle survives")
	testing.expect(t, term.cursor.row == 9 && term.cursor.col == 9, "cursor clamped to (9,9)")
	testing.expect(t, term.grapheme_store.live_count == 1, "truncated handle released")
	testing.expect(t, len(term.damage.dirty_rows) == 10, "damage should cover new rows")
	for i in 0..<10 {
		testing.expect(t, term.damage.dirty_rows[i].full, "every row should be fully dirty")
	}
}

@(test)
test_resize_same_dims_noop :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 10, 20)
	defer tg.terminal_destroy(&term)

	tg.terminal_move_cursor(&term, 3, 4)
	tg.terminal_put_char(&term, 'Q')
	tg.damage_clear(&term.damage)

	tg.terminal_resize(&term, 10, 20)

	testing.expect(t, term.grid.row_count == 10 && term.grid.col_count == 20, "dims unchanged")
	testing.expect(t, tg.grid_get_cell(&term.grid, 3, 4).content == 'Q', "content unchanged")
	testing.expect(t, !term.damage.dirty_rows[3].full, "no-op must not mark damage")
}

@(test)
test_resize_degenerate_safe :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	tg.terminal_move_cursor(&term, 5, 5)
	tg.terminal_put_char(&term, 'D')

	tg.terminal_resize(&term, 0, 80)
	tg.terminal_resize(&term, -1, 80)
	tg.terminal_resize(&term, 24, 0)
	tg.terminal_resize(&term, 24, -3)
	tg.terminal_resize(&term, 0, 0)

	testing.expect(t, term.grid.row_count == 24 && term.grid.col_count == 80, "dims unchanged")
	testing.expect(t, term.cursor.row == 5 && term.cursor.col == 6, "cursor unchanged")
	testing.expect(t, tg.grid_get_cell(&term.grid, 5, 5).content == 'D', "content unchanged")
}

@(test)
test_resize_wide_split_repair :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 5, 10)
	defer tg.terminal_destroy(&term)

	// Intact pair at cols 0..1.
	tg.terminal_move_cursor(&term, 0, 0)
	tg.terminal_put_wide(&term, 0x4E2D)
	// Pair straddling the future edge: lead with a pool handle at col 8.
	h := tg.grapheme_store_append(&term.grapheme_store, 0x4E2D, 0x301)
	tg.grid_set_cell(&term.grid, 0, 8, tg.Semantic_Cell{content = h, style = 0, width = 2, flags = .None})
	tg.grid_set_cell(
		&term.grid,
		0,
		9,
		tg.Semantic_Cell{content = 0, style = 0, width = 1, flags = .Wide_Continuation},
	)
	testing.expect(t, term.grapheme_store.live_count == 1, "one live cluster before resize")

	tg.terminal_resize(&term, 5, 9)

	testing.expect(t, term.grid.col_count == 9, "col_count should be 9")
	orphan := tg.grid_get_cell(&term.grid, 0, 8)
	testing.expect(t, orphan == tg.CELL_DEFAULT, "orphan lead blanked to CELL_DEFAULT")
	testing.expect(t, term.grapheme_store.live_count == 0, "orphan handle released")
	lead := tg.grid_get_cell(&term.grid, 0, 0)
	cont := tg.grid_get_cell(&term.grid, 0, 1)
	testing.expect(t, lead.content == 0x4E2D && lead.width == 2, "intact pair lead survives")
	testing.expect(t, cont.flags == .Wide_Continuation, "intact pair continuation survives")
}

@(test)
test_resize_scroll_region_reset :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	ok := tg.terminal_set_scroll_region(&term, 5, 15)
	testing.expect(t, ok, "narrowed scroll region should apply")

	tg.terminal_resize(&term, 30, 100)
	testing.expect(t, term.scroll_top == 0, "scroll_top resets to 0")
	testing.expect(t, term.scroll_bottom == 29, "scroll_bottom resets to new_rows-1")

	ok = tg.terminal_set_scroll_region(&term, 2, 20)
	testing.expect(t, ok, "narrowed scroll region should apply again")
	tg.terminal_resize(&term, 10, 10)
	testing.expect(t, term.scroll_top == 0, "scroll_top resets to 0 on shrink")
	testing.expect(t, term.scroll_bottom == 9, "scroll_bottom resets to new_rows-1 on shrink")
}
