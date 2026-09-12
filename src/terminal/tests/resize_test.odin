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
	term.grid.rows[0].wrapped = true
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
	term.grid.rows[0].wrapped = true
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

	for i in 0..<100 {
		tg.terminal_put_char(&term, rune('A' + (i % 26)))
	}
	tg.terminal_move_cursor(&term, 0, 0)
	testing.expect(t, term.grid.rows[0].wrapped, "row 0 naturally wrapped after 100 chars")
	testing.expect(t, !term.grid.rows[1].wrapped, "row 1 not wrapped")

	// Resize to 50 cols -> wraps into 2 rows of 50
	tg.terminal_resize(&term, 24, 50)
	testing.expect(t, term.grid.col_count == 50, "col_count is 50")
	testing.expect(t, term.grid.rows[0].wrapped, "row 0 wrapped is true after shrink to 50")
	testing.expect(t, !term.grid.rows[1].wrapped, "row 1 wrapped is false")

	for i in 0..<50 {
		cell := tg.grid_get_cell(&term.grid, 0, i)
		testing.expect(t, cell.content == tg.Content_Handle('A' + (i % 26)), "row 0 character matches")
	}
	for i in 0..<50 {
		cell := tg.grid_get_cell(&term.grid, 1, i)
		testing.expect(t, cell.content == tg.Content_Handle('A' + ((50 + i) % 26)), "row 1 character matches")
	}

	// Resize back to 80 cols -> unwraps back to 80 on row 0, 20 on row 1
	tg.terminal_resize(&term, 24, 80)
	testing.expect(t, term.grid.col_count == 80, "col_count is 80")
	testing.expect(t, term.grid.rows[0].wrapped, "row 0 wrapped is true after unwrap")
	testing.expect(t, !term.grid.rows[1].wrapped, "row 1 wrapped is false")

	for i in 0..<80 {
		cell := tg.grid_get_cell(&term.grid, 0, i)
		testing.expect(t, cell.content == tg.Content_Handle('A' + (i % 26)), "row 0 character matches")
	}
	for i in 0..<20 {
		cell := tg.grid_get_cell(&term.grid, 1, i)
		testing.expect(t, cell.content == tg.Content_Handle('A' + ((80 + i) % 26)), "row 1 character matches")
	}
	for i in 20..<80 {
		cell := tg.grid_get_cell(&term.grid, 1, i)
		testing.expect(t, cell == tg.CELL_DEFAULT, "row 1 tail is blank")
	}
	for i in 0..<80 {
		cell := tg.grid_get_cell(&term.grid, 2, i)
		testing.expect(t, cell == tg.CELL_DEFAULT, "row 2 is completely empty")
	}
}

@(test)
test_resize_reflow_cursor_tracking :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Write 100 characters on line 0 (soft-wraps to row 1 cols 0..19)
	for i in 0..<100 {
		tg.terminal_put_char(&term, rune('a' + (i % 26)))
	}
	// Move to next line and write prompt "$ "
	tg.terminal_newline(&term)
	tg.terminal_put_char(&term, '$')
	tg.terminal_put_char(&term, ' ')

	testing.expect(t, term.cursor.row == 2, "cursor row is 2 initially")
	testing.expect(t, term.cursor.col == 2, "cursor col is 2 initially")

	// Resize to 40 cols: 100 chars soft-wrap into 3 rows (40, 40, 20: rows 0, 1, 2)
	// prompt moves down to row 3
	tg.terminal_resize(&term, 24, 40)
	testing.expect(t, term.cursor.row == 3, "cursor row moved down to 3 after wrap")
	testing.expect(t, term.cursor.col == 2, "cursor col preserved at 2")
	testing.expect(t, tg.grid_get_cell(&term.grid, 3, 0).content == '$', "prompt '$' moved to row 3")
	testing.expect(t, tg.grid_get_cell(&term.grid, 3, 1).content == ' ', "prompt ' ' moved to row 3")

	// Resize back to 80 cols: 100 chars unwrap back to 2 rows (80, 20: rows 0, 1)
	// prompt moves back up to row 2
	tg.terminal_resize(&term, 24, 80)
	testing.expect(t, term.cursor.row == 2, "cursor row moved back up to 2 after unwrap")
	testing.expect(t, term.cursor.col == 2, "cursor col preserved at 2")
	testing.expect(t, tg.grid_get_cell(&term.grid, 2, 0).content == '$', "prompt '$' restored to row 2")
	testing.expect(t, tg.grid_get_cell(&term.grid, 2, 1).content == ' ', "prompt ' ' restored to row 2")
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
	term.grid.rows[0].wrapped = true
	tg.terminal_resize(&term, 24, 10)
	testing.expect(t, term.grid.rows[0].wrapped, "row 0 wrapped again")
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 9) == tg.CELL_DEFAULT, "col 9 padded default again")
	lead_rewrap := tg.grid_get_cell(&term.grid, 1, 0)
	cont_rewrap := tg.grid_get_cell(&term.grid, 1, 1)
	testing.expect(t, lead_rewrap.content == 0x4E2D && lead_rewrap.width == 2, "wide lead re-wrapped to row 1")
	testing.expect(t, cont_rewrap.flags == .Wide_Continuation, "wide continuation re-wrapped to row 1")
	testing.expect(t, term.cursor.row == 1 && term.cursor.col == 2, "cursor back to row 1 col 2")
}

@(test)
test_scrollback_preserved_on_resize :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	row_cells := make([]tg.Semantic_Cell, 80)
	defer delete(row_cells)
	for i in 0..<80 {
		row_cells[i] = tg.Semantic_Cell{
			content = tg.Content_Handle('A' + (i % 26)),
			style   = 0,
			width   = 1,
			flags   = .None,
		}
	}

	for _ in 0..<5 {
		tg.scrollback_push(&term.scrollback, row_cells, &term.grapheme_store)
	}
	testing.expect(t, len(term.scrollback.rows) == 5, "5 rows initially in scrollback")

	tg.terminal_resize(&term, 30, 60)
	testing.expect(t, term.scrollback.col_count == 60, "scrollback col_count is 60")
	testing.expect(t, len(term.scrollback.rows) > 0, "scrollback rows preserved after shrink")
	testing.expect(t, tg.terminal_view_max_offset(&term) > 0, "view max offset positive after shrink")
	testing.expect(t, term.scrollback.rows[0].cells[0].content == 'A', "scrollback content intact after shrink")

	tg.terminal_resize(&term, 24, 100)
	testing.expect(t, term.scrollback.col_count == 100, "scrollback col_count is 100")
	testing.expect(t, len(term.scrollback.rows) > 0, "scrollback rows preserved after grow")
	testing.expect(t, tg.terminal_view_max_offset(&term) > 0, "view max offset positive after grow")
	testing.expect(t, term.scrollback.rows[0].cells[0].content == 'A', "scrollback content intact after grow")
}

@(test)
test_resize_command_output_reflows_without_truncation :: proc(t: ^testing.T) {
	// 90-char line in 100 cols -> wraps to 2 rows at 50 cols -> unwraps to 1 row at 100 cols
	{
		term: tg.Terminal
		tg.terminal_init(&term, 24, 100)
		defer tg.terminal_destroy(&term)

		for i in 0..<90 {
			tg.terminal_put_char(&term, rune('A' + (i % 26)))
		}
		tg.terminal_newline(&term)

		testing.expect(t, !term.grid.rows[0].wrapped, "row 0 not wrapped initially")

		// Resize to 50 cols -> wraps into 2 rows
		tg.terminal_resize(&term, 24, 50)
		testing.expect(t, term.grid.col_count == 50, "col_count is 50")
		testing.expect(t, term.grid.rows[0].wrapped, "row 0 wrapped is true after shrink to 50")
		testing.expect(t, !term.grid.rows[1].wrapped, "row 1 wrapped is false")

		for i in 0..<50 {
			cell := tg.grid_get_cell(&term.grid, 0, i)
			testing.expect(t, cell.content == tg.Content_Handle('A' + (i % 26)), "row 0 character matches")
		}
		for i in 0..<40 {
			cell := tg.grid_get_cell(&term.grid, 1, i)
			testing.expect(t, cell.content == tg.Content_Handle('A' + ((50 + i) % 26)), "row 1 character matches")
		}

		// Resize to 100 cols -> unwraps back to 1 row. All 90 characters survive!
		tg.terminal_resize(&term, 24, 100)
		testing.expect(t, term.grid.col_count == 100, "col_count is 100")
		testing.expect(t, !term.grid.rows[0].wrapped, "row 0 unwrapped back to 1 row")

		for i in 0..<90 {
			cell := tg.grid_get_cell(&term.grid, 0, i)
			testing.expect(t, cell.content == tg.Content_Handle('A' + (i % 26)), "unwrapped character matches")
		}
		for i in 90..<100 {
			cell := tg.grid_get_cell(&term.grid, 0, i)
			testing.expect(t, cell == tg.CELL_DEFAULT, "row 0 tail is blank")
		}
		for i in 0..<100 {
			cell := tg.grid_get_cell(&term.grid, 1, i)
			testing.expect(t, cell == tg.CELL_DEFAULT, "row 1 is completely empty after unwrap")
		}
	}

	// 70-char line in 80 cols -> wraps to 2 rows at 50 cols -> unwraps back to 1 row at 80 cols
	{
		term: tg.Terminal
		tg.terminal_init(&term, 24, 80)
		defer tg.terminal_destroy(&term)

		for i in 0..<70 {
			tg.terminal_put_char(&term, rune('A' + (i % 26)))
		}
		tg.terminal_newline(&term)

		testing.expect(t, !term.grid.rows[0].wrapped, "row 0 not wrapped initially")

		// Resize to 50 cols -> wraps into 2 rows
		tg.terminal_resize(&term, 24, 50)
		testing.expect(t, term.grid.col_count == 50, "col_count is 50")
		testing.expect(t, term.grid.rows[0].wrapped, "row 0 wrapped is true after shrink to 50")
		testing.expect(t, !term.grid.rows[1].wrapped, "row 1 wrapped is false")

		for i in 0..<50 {
			cell := tg.grid_get_cell(&term.grid, 0, i)
			testing.expect(t, cell.content == tg.Content_Handle('A' + (i % 26)), "row 0 character matches")
		}
		for i in 0..<20 {
			cell := tg.grid_get_cell(&term.grid, 1, i)
			testing.expect(t, cell.content == tg.Content_Handle('A' + ((50 + i) % 26)), "row 1 character matches")
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
}

@(test)
test_resize_prompt_rprompt_elastic_gap :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Left prompt: 10 chars
	for i in 0..<10 {
		tg.terminal_put_char(&term, rune('0' + i))
	}
	// Space gap: 60 spaces
	for _ in 0..<60 {
		tg.terminal_put_char(&term, ' ')
	}
	// RPROMPT: 10 chars
	for i in 0..<10 {
		tg.terminal_put_char(&term, rune('a' + i))
	}

	// Move cursor back to end of left prompt
	tg.terminal_move_cursor(&term, 0, 10)
	testing.expect(t, term.cursor.row == 0 && term.cursor.col == 10, "cursor at end of left prompt")

	// Resize to 70 cols: gap compresses by 80 - 70 = 10 spaces, line stays on 1 row!
	tg.terminal_resize(&term, 24, 70)

	testing.expect(t, term.grid.col_count == 70, "col_count is 70")
	testing.expect(t, !term.grid.rows[0].wrapped, "row 0 stays on 1 row and is not wrapped")
	testing.expect(t, term.cursor.row == 0, "cursor row stays on row 0")
	testing.expect(t, term.cursor.col == 10, "cursor col preserved at 10")

	// Verify left prompt intact
	for i in 0..<10 {
		cell := tg.grid_get_cell(&term.grid, 0, i)
		testing.expect(t, cell.content == tg.Content_Handle('0' + i), "left prompt intact")
	}
	// Verify RPROMPT intact at right edge (cols 60..69)
	for i in 0..<10 {
		cell := tg.grid_get_cell(&term.grid, 0, 60 + i)
		testing.expect(t, cell.content == tg.Content_Handle('a' + i), "rprompt intact at right edge")
	}
	// Verify row 1 is empty
	for i in 0..<70 {
		cell := tg.grid_get_cell(&term.grid, 1, i)
		testing.expect(t, cell == tg.CELL_DEFAULT, "row 1 is empty default")
	}
}


@(test)
test_resize_trailing_whitespace_trimmed :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Write 10 chars of text followed by 40 unstyled spaces
	for i in 0..<10 {
		tg.terminal_put_char(&term, rune('a' + i))
	}
	for i in 0..<40 {
		tg.terminal_put_char(&term, ' ')
	}
	tg.terminal_newline(&term)

	testing.expect(t, !term.grid.rows[0].wrapped, "row 0 not wrapped initially")

	// Resize to 30 columns: 10 text + 40 spaces (50 total) would wrap into 2 rows if not trimmed.
	// Trailing whitespace trimming ensures row 0 only has 10 active cells, fitting on 1 row of 30.
	tg.terminal_resize(&term, 24, 30)

	testing.expect(t, term.grid.col_count == 30, "col_count is 30")
	testing.expect(t, !term.grid.rows[0].wrapped, "row 0 wrapped is false")
	for i in 0..<10 {
		cell := tg.grid_get_cell(&term.grid, 0, i)
		testing.expect(t, cell.content == tg.Content_Handle('a' + i), "text content preserved on row 0")
	}
	for i in 10..<30 {
		cell := tg.grid_get_cell(&term.grid, 0, i)
		testing.expect(t, cell == tg.CELL_DEFAULT, "trailing columns are empty CELL_DEFAULT")
	}
	// Verify row 1 is completely empty (did not receive wrapped spaces)
	for i in 0..<30 {
		cell := tg.grid_get_cell(&term.grid, 1, i)
		testing.expect(t, cell == tg.CELL_DEFAULT, "row 1 is empty, spaces were trimmed")
	}
}

@(test)
test_resize_dual_engine_command_output_reflow :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Step 1: Prompt line with OSC 133
	tg.terminal_osc_133_prompt_start(&term)
	for c in "user@box:~$ " {
		tg.terminal_put_char(&term, c)
	}
	tg.terminal_osc_133_prompt_end(&term)

	// Step 2: Command starts and outputs 90 characters
	tg.terminal_osc_133_command_start(&term)
	tg.terminal_newline(&term)

	for i in 0..<90 {
		tg.terminal_put_char(&term, rune('0' + (i % 10)))
	}
	tg.terminal_osc_133_command_end(&term)

	testing.expect(t, term.grid.rows[0].is_prompt, "row 0 is prompt")
	testing.expect(t, !term.grid.rows[1].is_prompt, "row 1 is command output")
	testing.expect(t, !term.grid.rows[2].is_prompt, "row 2 is command output continuation")
	testing.expect(t, term.grid.rows[1].wrapped, "row 1 wrapped at 80 cols")

	// Step 3: Resize down to 50 columns -> Output reflows 2-way without truncation
	tg.terminal_resize(&term, 24, 50)
	testing.expect(t, term.grid.col_count == 50, "cols is now 50")
	testing.expect(t, term.grid.rows[0].is_prompt, "row 0 remains prompt")
	testing.expect(t, !term.grid.rows[0].wrapped, "row 0 prompt does not wrap")
	testing.expect(t, term.grid.rows[1].wrapped, "row 1 wrapped at 50 cols")

	// Verify all 90 chars across rows 1 and 2
	for i in 0..<50 {
		cell := tg.grid_get_cell(&term.grid, 1, i)
		testing.expect(t, cell.content == tg.Content_Handle('0' + (i % 10)), "row 1 char match at 50 cols")
	}
	for i in 0..<40 {
		cell := tg.grid_get_cell(&term.grid, 2, i)
		testing.expect(t, cell.content == tg.Content_Handle('0' + ((50 + i) % 10)), "row 2 char match at 50 cols")
	}

	// Step 4: Resize up to 100 columns -> Output completely unwraps back to 1 row
	tg.terminal_resize(&term, 24, 100)
	testing.expect(t, term.grid.col_count == 100, "cols is now 100")
	testing.expect(t, !term.grid.rows[1].wrapped, "row 1 is unwrapped on 100 cols")

	for i in 0..<90 {
		cell := tg.grid_get_cell(&term.grid, 1, i)
		testing.expect(t, cell.content == tg.Content_Handle('0' + (i % 10)), "unwrapped char match at 100 cols")
	}
	// Row 2 must now be empty
	for i in 0..<100 {
		cell := tg.grid_get_cell(&term.grid, 2, i)
		testing.expect(t, cell == tg.CELL_DEFAULT, "row 2 is empty after unwrap")
	}
}

@(test)
test_resize_dual_engine_multiline_prompt_preservation :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Multiline prompt (e.g. Powerlevel10k 2-line prompt):
	// Line 0: Left prompt (10 chars), 50 spaces gap, RPROMPT (10 chars) = 70 chars in 80 cols
	tg.terminal_osc_133_prompt_start(&term)
	for i in 0..<10 {
		tg.terminal_put_char(&term, rune('0' + i))
	}
	for _ in 0..<50 {
		tg.terminal_put_char(&term, ' ')
	}
	for i in 0..<10 {
		tg.terminal_put_char(&term, rune('a' + i))
	}

	// Line 1: cursor prompt symbol
	tg.terminal_newline(&term)
	tg.terminal_put_char(&term, '>')
	tg.terminal_put_char(&term, ' ')
	tg.terminal_osc_133_prompt_end(&term)

	testing.expect(t, term.has_osc_133, "has_osc_133 is true")
	testing.expect(t, term.grid.rows[0].is_prompt, "row 0 is prompt")
	testing.expect(t, term.grid.rows[1].is_prompt, "row 1 is prompt")
	testing.expect(t, term.cursor.row == 1 && term.cursor.col == 2, "cursor at row 1, col 2")

	// Resize to 60 columns:
	// Row 0 gap compresses from 50 spaces to 30 spaces so it stays on 1 row!
	// Row 1 stays on 1 row! Prompt height remains exactly 2 rows!
	tg.terminal_resize(&term, 24, 60)

	testing.expect(t, term.grid.col_count == 60, "cols is 60")
	testing.expect(t, !term.grid.rows[0].wrapped, "row 0 stays 1 physical row")
	testing.expect(t, !term.grid.rows[1].wrapped, "row 1 stays 1 physical row")
	testing.expect(t, term.grid.rows[0].is_prompt, "row 0 is still prompt")
	testing.expect(t, term.grid.rows[1].is_prompt, "row 1 is still prompt")
	testing.expect(t, term.cursor.row == 1 && term.cursor.col == 2, "cursor preserved at row 1, col 2")

	// Row 2 is completely empty default
	for i in 0..<60 {
		cell := tg.grid_get_cell(&term.grid, 2, i)
		testing.expect(t, cell == tg.CELL_DEFAULT, "row 2 is empty, no prompt explosion")
	}
}

@(test)
test_resize_dual_engine_scrollback_preservation :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 10, 80)
	defer tg.terminal_destroy(&term)

	// Write 14 lines of content: rows 0..9 filled, 5 rows pushed into scrollback
	for i in 0..<14 {
		tg.terminal_put_char(&term, rune('A' + i))
		tg.terminal_newline(&term)
	}

	testing.expect(t, len(term.scrollback.rows) == 5, "5 rows in scrollback")
	testing.expect(t, term.scrollback.col_count == 80, "scrollback col_count is 80")

	// Resize to 50 cols: scrollback must not be cleared!
	tg.terminal_resize(&term, 10, 50)
	testing.expect(t, len(term.scrollback.rows) == 5, "5 rows preserved after resize to 50 cols")
	testing.expect(t, term.scrollback.col_count == 50, "scrollback col_count adapted to 50")
	testing.expect(t, term.scrollback.rows[0].cells[0].content == tg.Content_Handle('A'), "oldest row content intact")

	// Resize to 100 cols: scrollback still preserved!
	tg.terminal_resize(&term, 10, 100)
	testing.expect(t, len(term.scrollback.rows) == 5, "5 rows preserved after resize to 100 cols")
	testing.expect(t, term.scrollback.col_count == 100, "scrollback col_count adapted to 100")
	testing.expect(t, term.scrollback.rows[0].cells[0].content == tg.Content_Handle('A'), "oldest row content intact")
}

