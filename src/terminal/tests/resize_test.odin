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

	// Live grapheme handles: one at col 0, one at col 14.
	kept := tg.grapheme_store_append(&term.grapheme_store, 'B', 0x301)
	tg.grid_set_cell(&term.grid, 0, 0, tg.Semantic_Cell{content = kept, style = 0, width = 1, flags = .None})
	tail := tg.grapheme_store_append(&term.grapheme_store, 'C', 0x302)
	tg.grid_set_cell(&term.grid, 0, 14, tg.Semantic_Cell{content = tail, style = 0, width = 1, flags = .None})
	testing.expect(t, term.grapheme_store.live_count == 2, "two live grapheme clusters")

	tg.terminal_move_cursor(&term, 0, 14)
	tg.terminal_resize(&term, 10, 10)

	testing.expect(t, term.grid.row_count == 10, "row_count should be 10")
	testing.expect(t, term.grid.col_count == 10, "col_count should be 10")
	testing.expect(t, term.grid.rows[0].wrapped, "row 0 wrapped into row 1")
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 0).content == kept, "kept handle survives on row 0")
	testing.expect(t, tg.grid_get_cell(&term.grid, 1, 4).content == tail, "tail handle wraps to row 1 and survives")
	testing.expect(t, term.grapheme_store.live_count == 2, "both live grapheme handles survive on wrapped lines")
	testing.expect(t, term.cursor.row == 1 && term.cursor.col == 4, "cursor tracks to wrapped position (1, 4)")
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
	testing.expect(t, orphan == tg.CELL_DEFAULT, "orphan lead blanked to CELL_DEFAULT on row 0")
	testing.expect(t, term.grid.rows[0].wrapped, "row 0 marked wrapped")
	testing.expect(t, term.grapheme_store.live_count == 1, "wrapped wide handle survives")
	lead := tg.grid_get_cell(&term.grid, 0, 0)
	cont := tg.grid_get_cell(&term.grid, 0, 1)
	testing.expect(t, lead.content == 0x4E2D && lead.width == 2, "intact pair lead survives")
	testing.expect(t, cont.flags == .Wide_Continuation, "intact pair continuation survives")
	wrapped_lead := tg.grid_get_cell(&term.grid, 1, 0)
	wrapped_cont := tg.grid_get_cell(&term.grid, 1, 1)
	testing.expect(t, wrapped_lead.content == h && wrapped_lead.width == 2, "wide pair wraps intact to next row")
	testing.expect(t, wrapped_cont.flags == .Wide_Continuation, "wrapped continuation intact")
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

@(test)
test_resize_reflow_wrap_and_unwrap_roundtrip :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	for i in 0..<70 {
		tg.terminal_put_char(&term, rune('A' + (i % 26)))
	}
	testing.expect(t, !term.grid.rows[0].wrapped, "row 0 not wrapped initially")

	// Resize to 50 cols -> wraps into 2 rows
	tg.terminal_resize(&term, 24, 50)
	testing.expect(t, term.grid.col_count == 50, "col_count is 50")
	testing.expect(t, term.grid.rows[0].wrapped, "row 0 wrapped is true after shrink")
	testing.expect(t, !term.grid.rows[1].wrapped, "row 1 wrapped is false")

	for i in 0..<50 {
		cell := tg.grid_get_cell(&term.grid, 0, i)
		testing.expect(t, cell.content == tg.Content_Handle('A' + (i % 26)), "row 0 character matches")
	}
	for i in 0..<20 {
		cell := tg.grid_get_cell(&term.grid, 1, i)
		testing.expect(t, cell.content == tg.Content_Handle('A' + ((50 + i) % 26)), "row 1 character matches")
	}
	for i in 20..<50 {
		cell := tg.grid_get_cell(&term.grid, 1, i)
		testing.expect(t, cell == tg.CELL_DEFAULT, "row 1 tail is blank")
	}

	// Resize back to 80 cols -> unwraps back to 1 row
	tg.terminal_resize(&term, 24, 80)
	testing.expect(t, term.grid.col_count == 80, "col_count is 80")
	testing.expect(t, !term.grid.rows[0].wrapped, "row 0 wrapped is false after unwrap")

	for i in 0..<70 {
		cell := tg.grid_get_cell(&term.grid, 0, i)
		testing.expect(t, cell.content == tg.Content_Handle('A' + (i % 26)), "unwrapped character matches")
	}
	for i in 70..<80 {
		cell := tg.grid_get_cell(&term.grid, 0, i)
		testing.expect(t, cell == tg.CELL_DEFAULT, "row 0 tail is blank")
	}
	for i in 0..<80 {
		cell := tg.grid_get_cell(&term.grid, 1, i)
		testing.expect(t, cell == tg.CELL_DEFAULT, "row 1 is completely empty after unwrap")
	}
}

@(test)
test_resize_reflow_cursor_tracking :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Write 70 characters on line 0
	for i in 0..<70 {
		tg.terminal_put_char(&term, rune('a' + (i % 26)))
	}
	// Move to next line and write prompt "$ "
	tg.terminal_newline(&term)
	tg.terminal_put_char(&term, '$')
	tg.terminal_put_char(&term, ' ')

	testing.expect(t, term.cursor.row == 1, "cursor row is 1 initially")
	testing.expect(t, term.cursor.col == 2, "cursor col is 2 initially")

	// Resize to 50 cols: line 0 wraps into 2 rows (row 0 and row 1)
	// prompt moves down to row 2
	tg.terminal_resize(&term, 24, 50)
	testing.expect(t, term.cursor.row == 2, "cursor row moved down to 2 after wrap")
	testing.expect(t, term.cursor.col == 2, "cursor col preserved at 2")
	testing.expect(t, tg.grid_get_cell(&term.grid, 2, 0).content == '$', "prompt '$' moved to row 2")
	testing.expect(t, tg.grid_get_cell(&term.grid, 2, 1).content == ' ', "prompt ' ' moved to row 2")

	// Resize back to 80 cols: line 0 unwraps to 1 row
	// prompt moves back up to row 1
	tg.terminal_resize(&term, 24, 80)
	testing.expect(t, term.cursor.row == 1, "cursor row moved back up to 1 after unwrap")
	testing.expect(t, term.cursor.col == 2, "cursor col preserved at 2")
	testing.expect(t, tg.grid_get_cell(&term.grid, 1, 0).content == '$', "prompt '$' restored to row 1")
	testing.expect(t, tg.grid_get_cell(&term.grid, 1, 1).content == ' ', "prompt ' ' restored to row 1")
}

@(test)
test_resize_reflow_wide_char_edge :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 10)
	defer tg.terminal_destroy(&term)

	// Fill 9 columns (0..8) with ASCII
	for i in 0..<9 {
		tg.terminal_put_char(&term, rune('A' + i))
	}
	testing.expect(t, term.cursor.row == 0 && term.cursor.col == 9, "cursor at col 9 before wide char")

	// Put wide rune at col 9: cannot fit in 1 column, so pads col 9 and wraps to next row cols 0..1
	tg.terminal_put_wide(&term, 0x4E2D) // '中'
	testing.expect(t, term.grid.rows[0].wrapped, "row 0 marked wrapped")
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 9) == tg.CELL_DEFAULT, "col 9 is padded default")
	lead_before := tg.grid_get_cell(&term.grid, 1, 0)
	cont_before := tg.grid_get_cell(&term.grid, 1, 1)
	testing.expect(t, lead_before.content == 0x4E2D && lead_before.width == 2, "wide lead on row 1")
	testing.expect(t, cont_before.flags == .Wide_Continuation, "wide continuation on row 1")
	testing.expect(t, term.cursor.row == 1 && term.cursor.col == 2, "cursor on row 1 at col 2")

	// Resize to 20 cols: unwrap combines row 0 and row 1, wide pad at col 9 is skipped,
	// wide rune follows ASCII immediately on row 0
	tg.terminal_resize(&term, 24, 20)
	testing.expect(t, !term.grid.rows[0].wrapped, "row 0 not wrapped after expand")
	for i in 0..<9 {
		testing.expect(t, tg.grid_get_cell(&term.grid, 0, i).content == tg.Content_Handle('A' + i), "ASCII on row 0")
	}
	lead_after := tg.grid_get_cell(&term.grid, 0, 9)
	cont_after := tg.grid_get_cell(&term.grid, 0, 10)
	testing.expect(t, lead_after.content == 0x4E2D && lead_after.width == 2, "wide lead restored to row 0 cols 9..10")
	testing.expect(t, cont_after.flags == .Wide_Continuation, "wide continuation on row 0 col 10")
	testing.expect(t, term.cursor.row == 0 && term.cursor.col == 11, "cursor moved to row 0 col 11")

	// Resize back to 10 cols: wide rune wraps at col 9 boundary back to row 1 cols 0..1
	tg.terminal_resize(&term, 24, 10)
	testing.expect(t, term.grid.rows[0].wrapped, "row 0 wrapped again")
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 9) == tg.CELL_DEFAULT, "col 9 padded default again")
	lead_rewrap := tg.grid_get_cell(&term.grid, 1, 0)
	cont_rewrap := tg.grid_get_cell(&term.grid, 1, 1)
	testing.expect(t, lead_rewrap.content == 0x4E2D && lead_rewrap.width == 2, "wide lead re-wrapped to row 1")
	testing.expect(t, cont_rewrap.flags == .Wide_Continuation, "wide continuation re-wrapped to row 1")
	testing.expect(t, term.cursor.row == 1 && term.cursor.col == 2, "cursor back to row 1 col 2")
}
