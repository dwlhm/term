package termgrid_test

import "core:testing"
import tg "../"

// _scrollback_marker_row builds a scratch row of cols cells tagged with
// marker in col 0 for FIFO assertions. The caller owns the buffer;
// scrollback_push copies it.
_scrollback_marker_row :: proc(marker: rune, cols: int, allocator := context.allocator) -> []tg.Semantic_Cell {
	cells := make([]tg.Semantic_Cell, cols, allocator)
	for i in 0..<cols {
		cells[i] = tg.CELL_DEFAULT
	}
	cells[0] = tg.Semantic_Cell{content = tg.Content_Handle(marker), style = 0, width = 1, flags = .None}
	return cells
}

@(test)
test_scrollback_fifo_order :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 3, 4)
	defer tg.terminal_destroy(&term)

	for r in 0..<3 {
		cell := tg.Semantic_Cell{content = tg.Content_Handle('A' + r), style = 0, width = 1, flags = .None}
		tg.grid_set_cell(&term.grid, r, 0, cell)
	}

	tg.terminal_scroll_up(&term, 1)
	tg.terminal_scroll_up(&term, 1)

	testing.expect(t, tg.scrollback_len(&term.scrollback) == 2, "two full-grid scrolls should push two rows")
	testing.expect(t, tg.scrollback_get(&term.scrollback, 0)^.cells[0].content == tg.Content_Handle('A'), "oldest pushed row first")
	testing.expect(t, tg.scrollback_get(&term.scrollback, 1)^.cells[0].content == tg.Content_Handle('B'), "newest pushed row last")
	// Push copies: mutating the grid afterwards must not touch scrollback.
	tg.grid_set_cell(&term.grid, 0, 0, tg.Semantic_Cell{content = 'Z', style = 0, width = 1, flags = .None})
	testing.expect(t, tg.scrollback_get(&term.scrollback, 1)^.cells[0].content == tg.Content_Handle('B'), "scrollback must hold a copy")
}

@(test)
test_scrollback_cap_evicts_oldest :: proc(t: ^testing.T) {
	s: tg.Scrollback
	st: tg.Grapheme_Store
	tg.grapheme_store_init(&st)
	tg.scrollback_init(&s, 4, 3)
	defer tg.scrollback_destroy(&s, &st)

	for i in 0..<5 {
		cells := _scrollback_marker_row('0' + rune(i), 4)
		tg.scrollback_push(&s, cells, &st)
		delete(cells)
	}

	testing.expect(t, tg.scrollback_len(&s) == 3, "len must stay at max_lines")
	testing.expect(t, tg.scrollback_get(&s, 0)^.cells[0].content == tg.Content_Handle('2'), "oldest rows evicted first")
	testing.expect(t, tg.scrollback_get(&s, 1)^.cells[0].content == tg.Content_Handle('3'), "middle row preserved")
	testing.expect(t, tg.scrollback_get(&s, 2)^.cells[0].content == tg.Content_Handle('4'), "newest row appended")
}

@(test)
test_scrollback_evict_releases_handles :: proc(t: ^testing.T) {
	s: tg.Scrollback
	st: tg.Grapheme_Store
	tg.grapheme_store_init(&st)
	tg.scrollback_init(&s, 4, 2)
	defer tg.scrollback_destroy(&s, &st)

	h := tg.grapheme_store_append(&st, 'B', 0x301)
	cells := _scrollback_marker_row('x', 4)
	cells[1] = tg.Semantic_Cell{content = h, style = 0, width = 1, flags = .None}
	tg.scrollback_push(&s, cells, &st)
	delete(cells)
	testing.expect(t, st.live_count == 1, "pushed handle stays live in scrollback")

	plain := _scrollback_marker_row('y', 4)
	tg.scrollback_push(&s, plain, &st)
	delete(plain)
	testing.expect(t, st.live_count == 1, "under cap nothing is released")

	third := _scrollback_marker_row('z', 4)
	tg.scrollback_push(&s, third, &st)
	delete(third)
	testing.expect(t, tg.scrollback_len(&s) == 2, "len stays at cap")
	testing.expect(t, st.live_count == 0, "evicted row's handle must be released")
}

@(test)
test_scrollback_region_scroll_never_pushes :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 5, 4)
	defer tg.terminal_destroy(&term)

	for r in 0..<5 {
		cell := tg.Semantic_Cell{content = tg.Content_Handle('A' + r), style = 0, width = 1, flags = .None}
		tg.grid_set_cell(&term.grid, r, 0, cell)
	}

	testing.expect(t, tg.terminal_set_scroll_region(&term, 1, 3), "region {1,3} must be accepted")
	tg.terminal_scroll_up(&term, 1)
	testing.expect(t, tg.scrollback_len(&term.scrollback) == 0, "partial region scroll must never push")

	tg.terminal_reset_scroll_region(&term)
	tg.terminal_scroll_up(&term, 1)
	testing.expect(t, tg.scrollback_len(&term.scrollback) == 1, "full-grid scroll must push")
}

@(test)
test_scrollback_resize_col_change_preserves :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 4, 4)
	defer tg.terminal_destroy(&term)

	h := tg.grapheme_store_append(&term.grapheme_store, 'C', 0x302)
	tg.grid_set_cell(&term.grid, 0, 1, tg.Semantic_Cell{content = h, style = 0, width = 1, flags = .None})
	tg.terminal_scroll_up(&term, 1)
	tg.terminal_scroll_up(&term, 1)
	testing.expect(t, tg.scrollback_len(&term.scrollback) == 2, "two rows should be stored")
	testing.expect(t, term.grapheme_store.live_count == 1, "scrolled handle stays live in scrollback")

	tg.terminal_resize(&term, 4, 8)
	testing.expect(t, tg.scrollback_len(&term.scrollback) == 2, "col change must preserve scrollback")
	testing.expect(t, term.scrollback.col_count == 8, "col_count must re-sync to new cols")
	testing.expect(t, term.grapheme_store.live_count == 1, "preserved rows keep handles live")

	// Same-cols resize preserves history.
	tg.terminal_scroll_up(&term, 1)
	testing.expect(t, tg.scrollback_len(&term.scrollback) == 3, "scroll after resize pushes again")
	tg.terminal_move_cursor(&term, 3, 0)
	tg.terminal_resize(&term, 6, 8)
	testing.expect(t, tg.scrollback_len(&term.scrollback) == 1, "same-cols resize pulls 2 rows on grow from 4 to 6, 1 remains")
	testing.expect(t, term.scrollback.col_count == 8, "col_count unchanged")
}

@(test)
test_scrollback_destroy_frees_live_rows :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 3, 4)

	h := tg.grapheme_store_append(&term.grapheme_store, 'D', 0x303)
	tg.grid_set_cell(&term.grid, 0, 2, tg.Semantic_Cell{content = h, style = 0, width = 1, flags = .None})
	tg.terminal_scroll_up(&term, 1)
	testing.expect(t, tg.scrollback_len(&term.scrollback) == 1, "one row should be stored")

	tg.terminal_destroy(&term)
	testing.expect(t, tg.scrollback_len(&term.scrollback) == 0, "destroy must empty the list")
	testing.expect(t, term.grapheme_store.live_count == 0, "destroy must release live handles")
}

@(test)
test_scrollback_resize_preserves_wide_boundary :: proc(t: ^testing.T) {
	s: tg.Scrollback
	st: tg.Grapheme_Store
	tg.grapheme_store_init(&st)
	tg.scrollback_init(&s, 6, 5)
	defer tg.scrollback_destroy(&s, &st)

	// Push a line: "ABCD" + Wide CJK (2 cells) = 6 cells
	row_cells := make([]tg.Semantic_Cell, 6)
	defer delete(row_cells)
	row_cells[0] = tg.Semantic_Cell{content = 'A', width = 1}
	row_cells[1] = tg.Semantic_Cell{content = 'B', width = 1}
	row_cells[2] = tg.Semantic_Cell{content = 'C', width = 1}
	row_cells[3] = tg.Semantic_Cell{content = 'D', width = 1}
	// Wide lead at col 4, continuation at col 5
	row_cells[4] = tg.Semantic_Cell{content = 0x4E2D, width = 2}
	row_cells[5] = tg.Semantic_Cell{content = 0x4E2D, width = 0, flags = .Wide_Continuation}

	tg.scrollback_push(&s, row_cells, &st)
	testing.expect_value(t, tg.scrollback_len(&s), 1)

	// Resize scrollback to 5 columns.
	// In a 5-column line: "ABCD" takes cols 0..3.
	// Col 4 cannot fit the wide character pair!
	// Col 4 must be blank (CELL_DEFAULT), and the wide pair must wrap to next row at cols 0..1!
	tg.scrollback_resize(&s, 5, &st)
	testing.expect_value(t, tg.scrollback_len(&s), 2)

	r0 := tg.scrollback_get(&s, 0)
	testing.expect(t, r0.cells[0].content == 'A', "r0 col 0 must be 'A'")
	testing.expect(t, r0.cells[3].content == 'D', "r0 col 3 must be 'D'")
	testing.expect(t, r0.cells[4].content == 0, "r0 col 4 must be blanked CELL_DEFAULT")

	r1 := tg.scrollback_get(&s, 1)
	testing.expect(t, r1.cells[0].content == 0x4E2D, "r1 col 0 must have wide lead")
	testing.expect(t, r1.cells[1].flags == .Wide_Continuation, "r1 col 1 must have wide continuation")
}

@(test)
test_scrollback_resize_lossless_roundtrip :: proc(t: ^testing.T) {
	s: tg.Scrollback
	st: tg.Grapheme_Store
	tg.grapheme_store_init(&st)
	tg.scrollback_init(&s, 80, 10)
	defer tg.scrollback_destroy(&s, &st)

	row_cells := make([]tg.Semantic_Cell, 80)
	defer delete(row_cells)
	for i in 0..<80 {
		row_cells[i] = tg.CELL_DEFAULT
	}
	for i in 0..<60 {
		row_cells[i] = tg.Semantic_Cell{content = tg.Content_Handle('A' + (i % 26)), width = 1}
	}
	tg.scrollback_push(&s, row_cells, &st, false)
	testing.expect_value(t, tg.scrollback_len(&s), 1)

	tg.scrollback_resize(&s, 20, &st)
	testing.expect_value(t, tg.scrollback_len(&s), 3)

	r0 := tg.scrollback_get(&s, 0)
	r1 := tg.scrollback_get(&s, 1)
	r2 := tg.scrollback_get(&s, 2)
	testing.expect(t, r0.wrapped == true, "row 0 should be wrapped")
	testing.expect(t, r1.wrapped == true, "row 1 should be wrapped")
	testing.expect(t, r2.wrapped == false, "row 2 should not be wrapped")

	tg.scrollback_resize(&s, 80, &st)
	testing.expect_value(t, tg.scrollback_len(&s), 1)

	res := tg.scrollback_get(&s, 0)
	testing.expect(t, res.wrapped == false, "res row should not be wrapped")
	for i in 0..<60 {
		testing.expect(t, res.cells[i].content == tg.Content_Handle('A' + (i % 26)), "all 60 chars preserved in order")
	}
	for i in 60..<80 {
		testing.expect(t, res.cells[i] == tg.CELL_DEFAULT, "cells past 60 are blank")
	}
}

