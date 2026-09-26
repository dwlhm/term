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

	for _ in 0..<40 {
		tg.scrollback_push(&term.scrollback, row_cells, &term.grapheme_store)
	}
	testing.expect(t, tg.scrollback_len(&term.scrollback) == 40, "40 rows initially in scrollback")

	tg.terminal_resize(&term, 30, 60)
	testing.expect(t, term.scrollback.col_count == 60, "scrollback col_count is 60")
	testing.expect(t, tg.scrollback_len(&term.scrollback) > 0, "scrollback rows preserved after shrink")
	testing.expect(t, tg.terminal_view_max_offset(&term) > 0, "view max offset positive after shrink")
	testing.expect(t, tg.scrollback_get(&term.scrollback, 0)^.cells[0].content == 'A', "scrollback content intact after shrink")

	tg.terminal_resize(&term, 24, 100)
	testing.expect(t, term.scrollback.col_count == 100, "scrollback col_count is 100")
	testing.expect(t, tg.scrollback_len(&term.scrollback) > 0, "scrollback rows preserved after grow")
	testing.expect(t, tg.terminal_view_max_offset(&term) > 0, "view max offset positive after grow")
	testing.expect(t, tg.scrollback_get(&term.scrollback, 0)^.cells[0].content == 'A', "scrollback content intact after grow")
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

	// Standard VT reflow shrink to 70 cols:
	// 80 cols wraps into 2 rows: row 0 gets 70 cols (wrapped = true), row 1 gets 10 cols (wrapped = false)
	tg.terminal_resize(&term, 24, 70)

	testing.expect(t, term.grid.col_count == 70, "col_count is 70")
	testing.expect(t, term.grid.rows[0].wrapped, "row 0 wrapped is true after shrink to 70")
	testing.expect(t, !term.grid.rows[1].wrapped, "row 1 wrapped is false")
	testing.expect(t, term.cursor.row == 0, "cursor row stays on row 0")
	testing.expect(t, term.cursor.col == 10, "cursor col preserved at 10")

	// Verify row 0 has left prompt (10 chars) + 60 spaces = 70 cols total, preserving 100% of spaces
	for i in 0..<10 {
		cell := tg.grid_get_cell(&term.grid, 0, i)
		testing.expect(t, cell.content == tg.Content_Handle('0' + i), "left prompt intact on row 0")
	}
	for i in 10..<70 {
		cell := tg.grid_get_cell(&term.grid, 0, i)
		testing.expect(t, cell.content == ' ', "space gap intact on row 0")
	}

	// Verify row 1 has extra 10 cols (RPROMPT 'a'..'j') at cols 0..9, zero deletion/compression
	for i in 0..<10 {
		cell := tg.grid_get_cell(&term.grid, 1, i)
		testing.expect(t, cell.content == tg.Content_Handle('a' + i), "rprompt wrapped intact to row 1")
	}
	// Rest of row 1 is blank
	for i in 10..<70 {
		cell := tg.grid_get_cell(&term.grid, 1, i)
		testing.expect(t, cell == tg.CELL_DEFAULT, "row 1 tail is empty default")
	}

	// Expanding back to 80 cols unwraps the line back to a single row
	tg.terminal_resize(&term, 24, 80)

	testing.expect(t, term.grid.col_count == 80, "col_count is 80")
	testing.expect(t, !term.grid.rows[0].wrapped, "row 0 wrapped is false after unwrap")
	testing.expect(t, !term.grid.rows[1].wrapped, "row 1 wrapped is false")
	testing.expect(t, term.cursor.row == 0, "cursor row stays on row 0 after unwrap")
	testing.expect(t, term.cursor.col == 10, "cursor col preserved at 10 after unwrap")

	// Verify row 0 restored completely
	for i in 0..<10 {
		cell := tg.grid_get_cell(&term.grid, 0, i)
		testing.expect(t, cell.content == tg.Content_Handle('0' + i), "left prompt intact on row 0 after unwrap")
	}
	for i in 10..<70 {
		cell := tg.grid_get_cell(&term.grid, 0, i)
		testing.expect(t, cell.content == ' ', "space gap intact on row 0 after unwrap")
	}
	for i in 0..<10 {
		cell := tg.grid_get_cell(&term.grid, 0, 70 + i)
		testing.expect(t, cell.content == tg.Content_Handle('a' + i), "rprompt unwrapped intact at cols 70..79 on row 0")
	}

	// Verify row 1 is completely empty after unwrap
	for i in 0..<80 {
		cell := tg.grid_get_cell(&term.grid, 1, i)
		testing.expect(t, cell == tg.CELL_DEFAULT, "row 1 is empty default after unwrap")
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
	// Multiline prompt preserves height: row 0 and row 1 remain 1 physical row each without wrapping.
	tg.terminal_resize(&term, 24, 60)

	testing.expect(t, term.grid.col_count == 60, "cols is 60")
	testing.expect(t, !term.grid.rows[0].wrapped, "row 0 prompt must not wrap")
	testing.expect(t, !term.grid.rows[1].wrapped, "row 1 prompt must not wrap")
	testing.expect(t, term.grid.rows[0].is_prompt, "row 0 is still prompt")
	testing.expect(t, term.grid.rows[1].is_prompt, "row 1 is still prompt")
	testing.expect(t, term.cursor.row == 1 && term.cursor.col == 2, "cursor preserved at row 1, col 2")

	// Resize back to 80 columns:
	tg.terminal_resize(&term, 24, 80)
	testing.expect(t, term.grid.col_count == 80, "cols restored to 80")
	testing.expect(t, !term.grid.rows[0].wrapped, "row 0 unwrapped back to single row")
	testing.expect(t, !term.grid.rows[1].wrapped, "row 1 unwrapped back to single row")
	testing.expect(t, term.cursor.row == 1 && term.cursor.col == 2, "cursor restored to row 1, col 2")
	for i in 0..<80 {
		cell := tg.grid_get_cell(&term.grid, 2, i)
		testing.expect(t, cell == tg.CELL_DEFAULT, "row 2 is empty after unwrap")
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

	testing.expect(t, tg.scrollback_len(&term.scrollback) == 5, "5 rows in scrollback")
	testing.expect(t, term.scrollback.col_count == 80, "scrollback col_count is 80")

	// Resize to 50 cols: scrollback must not be cleared!
	tg.terminal_resize(&term, 10, 50)
	testing.expect(t, tg.scrollback_len(&term.scrollback) == 5, "5 rows preserved after resize to 50 cols")
	testing.expect(t, term.scrollback.col_count == 50, "scrollback col_count adapted to 50")
	testing.expect(t, tg.scrollback_get(&term.scrollback, 0)^.cells[0].content == tg.Content_Handle('A'), "oldest row content intact")

	// Resize to 100 cols: scrollback still preserved!
	tg.terminal_resize(&term, 10, 100)
	testing.expect(t, tg.scrollback_len(&term.scrollback) == 5, "5 rows preserved after resize to 100 cols")
	testing.expect(t, term.scrollback.col_count == 100, "scrollback col_count adapted to 100")
	testing.expect(t, tg.scrollback_get(&term.scrollback, 0)^.cells[0].content == tg.Content_Handle('A'), "oldest row content intact")
}

@(test)
test_resize_prompt_rprompt_elastic_gap_styled :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Left prompt: 10 chars with style 1
	for i in 0..<10 {
		tg.grid_set_cell(&term.grid, 0, i, tg.Semantic_Cell{content = tg.Content_Handle('0' + i), style = 1, width = 1})
	}
	// Space gap: 60 spaces with style 2 (simulating styled background/foreground in p10k)
	for i in 10..<70 {
		tg.grid_set_cell(&term.grid, 0, i, tg.Semantic_Cell{content = ' ', style = 2, width = 1})
	}
	// RPROMPT: 10 chars with style 3
	for i in 0..<10 {
		tg.grid_set_cell(&term.grid, 0, 70 + i, tg.Semantic_Cell{content = tg.Content_Handle('a' + i), style = 3, width = 1})
	}

	// Move cursor back to end of left prompt
	tg.terminal_move_cursor(&term, 0, 10)
	testing.expect(t, term.cursor.row == 0 && term.cursor.col == 10, "cursor at end of left prompt")

	// Standard VT reflow shrink to 70 cols:
	// 80 cols wraps into 2 rows: row 0 gets 70 cols (wrapped = true), row 1 gets 10 cols (wrapped = false)
	tg.terminal_resize(&term, 24, 70)

	testing.expect(t, term.grid.col_count == 70, "col_count is 70")
	testing.expect(t, term.grid.rows[0].wrapped, "row 0 wrapped is true after shrink to 70")
	testing.expect(t, !term.grid.rows[1].wrapped, "row 1 wrapped is false")
	testing.expect(t, term.cursor.row == 0, "cursor row stays on row 0")
	testing.expect(t, term.cursor.col == 10, "cursor col preserved at 10")

	// Verify row 0 has left prompt (10 chars with style 1) + 60 spaces with style 2, zero deletion
	for i in 0..<10 {
		cell := tg.grid_get_cell(&term.grid, 0, i)
		testing.expect(t, cell.content == tg.Content_Handle('0' + i) && cell.style == 1, "styled left prompt intact on row 0")
	}
	for i in 10..<70 {
		cell := tg.grid_get_cell(&term.grid, 0, i)
		testing.expect(t, cell.content == ' ' && cell.style == 2, "styled space gap intact on row 0")
	}

	// Verify row 1 has extra 10 cols (RPROMPT 'a'..'j' with style 3) at cols 0..9
	for i in 0..<10 {
		cell := tg.grid_get_cell(&term.grid, 1, i)
		testing.expect(t, cell.content == tg.Content_Handle('a' + i) && cell.style == 3, "styled rprompt wrapped intact to row 1")
	}
	// Rest of row 1 is blank default
	for i in 10..<70 {
		cell := tg.grid_get_cell(&term.grid, 1, i)
		testing.expect(t, cell == tg.CELL_DEFAULT, "row 1 tail is empty default")
	}

	// Expanding back to 80 cols unwraps the line back to a single row
	tg.terminal_resize(&term, 24, 80)

	testing.expect(t, term.grid.col_count == 80, "col_count is 80")
	testing.expect(t, !term.grid.rows[0].wrapped, "row 0 wrapped is false after unwrap")
	testing.expect(t, !term.grid.rows[1].wrapped, "row 1 wrapped is false")
	testing.expect(t, term.cursor.row == 0, "cursor row stays on row 0 after unwrap")
	testing.expect(t, term.cursor.col == 10, "cursor col preserved at 10 after unwrap")

	// Verify row 0 restored completely with all styles preserved
	for i in 0..<10 {
		cell := tg.grid_get_cell(&term.grid, 0, i)
		testing.expect(t, cell.content == tg.Content_Handle('0' + i) && cell.style == 1, "styled left prompt restored on row 0")
	}
	for i in 10..<70 {
		cell := tg.grid_get_cell(&term.grid, 0, i)
		testing.expect(t, cell.content == ' ' && cell.style == 2, "styled space gap restored on row 0")
	}
	for i in 0..<10 {
		cell := tg.grid_get_cell(&term.grid, 0, 70 + i)
		testing.expect(t, cell.content == tg.Content_Handle('a' + i) && cell.style == 3, "styled rprompt restored at cols 70..79 on row 0")
	}

	// Verify row 1 is empty default after unwrap
	for i in 0..<80 {
		cell := tg.grid_get_cell(&term.grid, 1, i)
		testing.expect(t, cell == tg.CELL_DEFAULT, "row 1 is empty default after unwrap")
	}
}

@(test)
test_resize_grow_pulls_from_scrollback :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 10, 80)
	defer tg.terminal_destroy(&term)

	for i in 0..<15 {
		if i > 0 {
			tg.terminal_newline(&term)
		}
		tg.terminal_put_char(&term, rune('A' + i))
	}

	testing.expect(t, term.scrollback.count == 5, "5 rows pushed to scrollback")
	testing.expect(t, term.cursor.row == 9, "cursor row at 9 before resize")

	tg.terminal_resize(&term, 15, 80)

	testing.expect(t, term.grid.row_count == 15, "row_count should be 15")
	testing.expect(t, term.scrollback.count == 0, "scrollback count should be 0")
	testing.expect(t, term.cursor.row == 14, "cursor row should be shifted down by 5 to 14")

	for i in 0..<15 {
		cell := tg.grid_get_cell(&term.grid, i, 0)
		testing.expect(t, cell.content == tg.Content_Handle('A' + i), "row content matches in order")
	}
}

@(test)
test_resize_shrink_and_grow_reversible :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 10, 80)
	defer tg.terminal_destroy(&term)

	for r in 0..<10 {
		tg.terminal_move_cursor(&term, r, 0)
		tg.terminal_put_char(&term, rune('A' + r))
	}

	tg.terminal_resize(&term, 6, 80)

	testing.expect(t, term.grid.row_count == 6, "grid rows shrunk to 6")
	testing.expect(t, term.scrollback.count == 4, "4 rows overflowed to scrollback")

	tg.terminal_resize(&term, 10, 80)

	testing.expect(t, term.grid.row_count == 10, "grid rows restored to 10")
	testing.expect(t, term.scrollback.count == 0, "scrollback restored to 0")

	for r in 0..<10 {
		cell := tg.grid_get_cell(&term.grid, r, 0)
		testing.expect(t, cell.content == tg.Content_Handle('A' + r), "row content restored identically")
	}
}

@(test)
test_resize_grow_does_not_pull_scrollback_if_screen_not_full :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 10, 80)
	defer tg.terminal_destroy(&term)

	// Write 15 lines (5 lines pushed to scrollback)
	for i in 0..<15 {
		if i > 0 {
			tg.terminal_newline(&term)
		}
		tg.terminal_put_char(&term, rune('A' + i))
	}

	testing.expect(t, term.scrollback.count == 5, "scrollback count at 5 before resize")

	tg.terminal_clear(&term)
	tg.terminal_move_cursor(&term, 0, 0)
	tg.terminal_put_char(&term, '1')
	tg.terminal_move_cursor(&term, 1, 0)
	tg.terminal_put_char(&term, '2')
	tg.terminal_move_cursor(&term, 2, 0)
	tg.terminal_put_char(&term, '3')
	tg.terminal_move_cursor(&term, 2, 1)

	testing.expect(t, term.cursor.row == 2, "cursor row at 2 before resize")

	// Resize terminal to 15 rows, 80 cols
	tg.terminal_resize(&term, 15, 80)

	// Verify that term.scrollback.count == 5 (no rows pulled from scrollback!)
	testing.expect(t, term.scrollback.count == 5, "scrollback count must remain 5, no rows pulled")
	testing.expect(t, term.cursor.row == 2, "cursor row must stay at 2")

	// Verify rows 0, 1, 2 retain their content
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 0).content == tg.Content_Handle('1'), "row 0 retained")
	testing.expect(t, tg.grid_get_cell(&term.grid, 1, 0).content == tg.Content_Handle('2'), "row 1 retained")
	testing.expect(t, tg.grid_get_cell(&term.grid, 2, 0).content == tg.Content_Handle('3'), "row 2 retained")

	// Rows 3..14 are empty
	for r in 3..<15 {
		testing.expect(t, tg.grid_get_cell(&term.grid, r, 0) == tg.CELL_DEFAULT, "rows 3..14 are empty")
	}
}

@(test)
test_resize_seam_coalescence :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 5, 20)
	defer tg.terminal_destroy(&term)

	for i in 0..<4 {
		tg.terminal_move_cursor(&term, i, 0)
		for ch in "Row" {
			tg.terminal_put_char(&term, ch)
		}
		tg.terminal_put_char(&term, rune('0' + i))
	}

	tg.terminal_move_cursor(&term, 4, 0)
	long_str := "ABCDEFGHIJKLMNOPQRSTUVWXYZ1234"
	for ch in long_str {
		tg.terminal_put_char(&term, ch)
	}

	// In a 5-row terminal, writing 30 chars wrapped: "ABCDEFGHIJKLMNOPQRST" is at row 3 (wrapped=true),
	// and "UVWXYZ1234" is at row 4.
	// We scroll up 4 times so "ABCDEFGHIJKLMNOPQRST" moves into scrollback as the newest row,
	// and "UVWXYZ1234" is at row 0 of the active grid.
	tg.terminal_scroll_up(&term, 4)

	testing.expect(t, term.scrollback.count > 0, "scrollback has pushed rows")
	newest_sb := tg.scrollback_get(&term.scrollback, term.scrollback.count - 1)
	testing.expect(t, newest_sb != nil && newest_sb.wrapped, "newest scrollback row must be wrapped")

	// Resize width to 40 columns and height to 10 rows.
	// Seam coalescence reunites "ABCDEFGHIJKLMNOPQRST" from scrollback and "UVWXYZ1234"
	// from grid row 0 into ONE single logical line.
	tg.terminal_resize(&term, 10, 40)

	found_reunited := false
	for r in 0..<term.grid.row_count {
		match := true
		for c in 0..<len(long_str) {
			cell := tg.grid_get_cell(&term.grid, r, c)
			if cell.content != tg.Content_Handle(long_str[c]) {
				match = false
				break
			}
		}
		if match {
			found_reunited = true
			phys := tg._grid_physical_row(&term.grid, r)
			testing.expect(t, !term.grid.rows[phys].wrapped, "reunited line must not be wrapped on 40 cols")
			break
		}
	}
	testing.expect(t, found_reunited, "reunited line must be present contiguously on one row without splits")
}

@(test)
test_resize_prompt_truncation_without_wrapping :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	left_str := "~/project"
	for ch in left_str {
		tg.terminal_put_char(&term, ch)
	}
	for _ in 0..<50 {
		tg.terminal_put_char(&term, ' ')
	}
	right_str := "git:(main)"
	for ch in right_str {
		tg.terminal_put_char(&term, ch)
	}

	phys := tg._grid_physical_row(&term.grid, 0)
	term.grid.rows[phys].is_prompt = true
	term.cursor.row = 0
	term.cursor.col = len(left_str)

	// Resize from 80 cols down to 60 cols
	tg.terminal_resize(&term, 24, 60)

	testing.expect(t, term.grid.col_count == 60, "cols should be 60")
	phys_after := tg._grid_physical_row(&term.grid, 0)
	testing.expect(t, !term.grid.rows[phys_after].wrapped, "row 0 prompt must not wrap")
	testing.expect(t, term.cursor.row == 0, "cursor row remains 0")
	for c in 0..<60 {
		cell := tg.grid_get_cell(&term.grid, 1, c)
		testing.expect(t, cell == tg.CELL_DEFAULT, "row 1 should remain default/empty, row count remains 1")
	}
}

@(test)
test_resize_multiline_prompt_preserves_height :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Line 1:
	left_str := "my-project"
	for ch in left_str {
		tg.terminal_put_char(&term, ch)
	}
	for _ in 0..<50 {
		tg.terminal_put_char(&term, ' ')
	}
	right_str := "[main]"
	for ch in right_str {
		tg.terminal_put_char(&term, ch)
	}
	phys0 := tg._grid_physical_row(&term.grid, 0)
	term.grid.rows[phys0].is_prompt = true

	// Line 2:
	tg.terminal_newline(&term)
	tg.terminal_put_char(&term, '>')
	tg.terminal_put_char(&term, ' ')
	phys1 := tg._grid_physical_row(&term.grid, 1)
	term.grid.rows[phys1].is_prompt = true

	testing.expect(t, term.cursor.row == 1 && term.cursor.col == 2, "cursor initially at row 1, col 2")

	// Multi-step resize: 80 -> 60 -> 40 -> 80
	resize_steps := []int{60, 40, 80}
	for target_cols in resize_steps {
		tg.terminal_resize(&term, 24, target_cols)
		testing.expect(t, term.grid.col_count == target_cols, "cols must match target")
		testing.expect(t, term.cursor.row == 1, "cursor row remains stable at 1")

		p0 := tg._grid_physical_row(&term.grid, 0)
		p1 := tg._grid_physical_row(&term.grid, 1)
		testing.expect(t, !term.grid.rows[p0].wrapped, "line 1 (row 0) must not wrap")
		testing.expect(t, !term.grid.rows[p1].wrapped, "line 2 (row 1) must not wrap")
		testing.expect(t, term.grid.rows[p0].is_prompt, "row 0 remains prompt")
		testing.expect(t, term.grid.rows[p1].is_prompt, "row 1 remains prompt")

		// Verify row 2 is empty default
		for c in 0..<target_cols {
			cell := tg.grid_get_cell(&term.grid, 2, c)
			testing.expect(t, cell == tg.CELL_DEFAULT, "row 2 must be empty default")
		}
	}
}

@(test)
test_resize_command_output_above_p10k_not_truncated :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Step 1: Simulate "ls -l" command output on line 0 (65 characters long)
	cmd_output := "-rw-r--r--  1 user staff  1024 Sep 27 03:00 very_long_filename_xyz.txt"
	for ch in cmd_output {
		tg.terminal_put_char(&term, ch)
	}

	// Move to next line for 2-line p10k prompt
	tg.terminal_newline(&term)

	// Line 1: p10k frame top row (starts with ╭ = 0x256D)
	p10k_top := "╭─ ~/project"
	for ch in p10k_top {
		tg.terminal_put_char(&term, ch)
	}
	for _ in 0..<40 {
		tg.terminal_put_char(&term, ' ')
	}
	p10k_top_r := "git:(main)"
	for ch in p10k_top_r {
		tg.terminal_put_char(&term, ch)
	}

	// Line 2: p10k frame bottom row (starts with ╰ = 0x2570) with cursor
	tg.terminal_newline(&term)
	p10k_bottom := "╰─$ "
	for ch in p10k_bottom {
		tg.terminal_put_char(&term, ch)
	}

	testing.expect(t, term.cursor.row == 2 && term.cursor.col == 4, "cursor at prompt line 2")

	// Resize from 80 cols down to 50 cols
	tg.terminal_resize(&term, 24, 50)
	testing.expect(t, term.grid.col_count == 50, "cols resized to 50")

	// Verify command output reflows into 2 rows (50 + 15 chars) without truncation:
	p_out0 := tg._grid_physical_row(&term.grid, 0)
	p_out1 := tg._grid_physical_row(&term.grid, 1)
	testing.expect(t, term.grid.rows[p_out0].wrapped, "command output wrapped across cols")
	testing.expect(t, !term.grid.rows[p_out1].wrapped, "command output continuation row not wrapped")

	for i in 0..<50 {
		cell := tg.grid_get_cell(&term.grid, 0, i)
		testing.expect(t, cell.content == tg.Content_Handle(rune(cmd_output[i])), "first 50 chars on row 0")
	}
	for i in 0..<15 {
		cell := tg.grid_get_cell(&term.grid, 1, i)
		testing.expect(t, cell.content == tg.Content_Handle(rune(cmd_output[50 + i])), "remaining 15 chars on row 1")
	}

	// Verify p10k top row (row 2) does not wrap and remains exactly 1 row:
	p_p10k0 := tg._grid_physical_row(&term.grid, 2)
	testing.expect(t, !term.grid.rows[p_p10k0].wrapped, "p10k top frame row must not wrap")
	testing.expect(t, term.grid.rows[p_p10k0].is_prompt, "p10k top frame row marked prompt")

	// Verify p10k bottom row (row 3) does not wrap and cursor is at row 3:
	p_p10k1 := tg._grid_physical_row(&term.grid, 3)
	testing.expect(t, !term.grid.rows[p_p10k1].wrapped, "p10k bottom frame row must not wrap")
	testing.expect(t, term.grid.rows[p_p10k1].is_prompt, "p10k bottom frame row marked prompt")
	testing.expect(t, term.cursor.row == 3, "cursor row remains stable at bottom prompt row 3")

	// Verify row 4 is empty default (no ghost rows)
	for c in 0..<50 {
		cell := tg.grid_get_cell(&term.grid, 4, c)
		testing.expect(t, cell == tg.CELL_DEFAULT, "row 4 must be empty default without ghost rows")
	}
}

@(test)
test_resize_width_shrink_then_grow_preserves_bottom_anchor :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 10, 80)
	defer tg.terminal_destroy(&term)

	for r in 0..<10 {
		tg.terminal_move_cursor(&term, r, 0)
		ch := rune('A' + r)
		for c in 0..<35 {
			tg.terminal_put_char(&term, ch)
		}
	}

	testing.expect(t, term.cursor.row == 9, "cursor initially at row 9")
	testing.expect(t, term.scrollback.count == 0, "scrollback initially empty")

	tg.terminal_resize(&term, 10, 20)

	testing.expect(t, term.cursor.row == 9, "cursor row remains clamped at bottom row 9")
	testing.expect(t, term.scrollback.count > 0, "overflow rows pushed to scrollback")

	tg.terminal_resize(&term, 10, 80)

	testing.expect(t, term.scrollback.count == 0, "all rows pulled back from scrollback")
	testing.expect(t, term.cursor.row == 9, "cursor row remains at bottom row 9 after unwrap")
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 0).content == 'A', "row 0 contains 'A'")
	testing.expect(t, tg.grid_get_cell(&term.grid, 9, 0).content == 'J', "row 9 contains 'J'")
}

