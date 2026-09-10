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

	testing.expect(t, len(term.scrollback.rows) == 2, "two full-grid scrolls should push two rows")
	testing.expect(t, term.scrollback.rows[0].cells[0].content == tg.Content_Handle('A'), "oldest pushed row first")
	testing.expect(t, term.scrollback.rows[1].cells[0].content == tg.Content_Handle('B'), "newest pushed row last")
	// Push copies: mutating the grid afterwards must not touch scrollback.
	tg.grid_set_cell(&term.grid, 0, 0, tg.Semantic_Cell{content = 'Z', style = 0, width = 1, flags = .None})
	testing.expect(t, term.scrollback.rows[1].cells[0].content == tg.Content_Handle('B'), "scrollback must hold a copy")
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

	testing.expect(t, len(s.rows) == 3, "len must stay at max_lines")
	testing.expect(t, s.rows[0].cells[0].content == tg.Content_Handle('2'), "oldest rows evicted first")
	testing.expect(t, s.rows[1].cells[0].content == tg.Content_Handle('3'), "middle row preserved")
	testing.expect(t, s.rows[2].cells[0].content == tg.Content_Handle('4'), "newest row appended")
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
	testing.expect(t, len(s.rows) == 2, "len stays at cap")
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
	testing.expect(t, len(term.scrollback.rows) == 0, "partial region scroll must never push")

	tg.terminal_reset_scroll_region(&term)
	tg.terminal_scroll_up(&term, 1)
	testing.expect(t, len(term.scrollback.rows) == 1, "full-grid scroll must push")
}

@(test)
test_scrollback_resize_col_change_clears :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 4, 4)
	defer tg.terminal_destroy(&term)

	h := tg.grapheme_store_append(&term.grapheme_store, 'C', 0x302)
	tg.grid_set_cell(&term.grid, 0, 1, tg.Semantic_Cell{content = h, style = 0, width = 1, flags = .None})
	tg.terminal_scroll_up(&term, 1)
	tg.terminal_scroll_up(&term, 1)
	testing.expect(t, len(term.scrollback.rows) == 2, "two rows should be stored")
	testing.expect(t, term.grapheme_store.live_count == 1, "scrolled handle stays live in scrollback")

	tg.terminal_resize(&term, 4, 8)
	testing.expect(t, len(term.scrollback.rows) == 0, "col change must clear scrollback")
	testing.expect(t, term.scrollback.col_count == 8, "col_count must re-sync to new cols")
	testing.expect(t, term.grapheme_store.live_count == 0, "cleared rows must release handles")

	// Same-cols resize preserves history.
	tg.terminal_scroll_up(&term, 1)
	testing.expect(t, len(term.scrollback.rows) == 1, "scroll after resize pushes again")
	tg.terminal_resize(&term, 6, 8)
	testing.expect(t, len(term.scrollback.rows) == 1, "same-cols resize must preserve scrollback")
	testing.expect(t, term.scrollback.col_count == 8, "col_count unchanged")
}

@(test)
test_scrollback_destroy_frees_live_rows :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 3, 4)

	h := tg.grapheme_store_append(&term.grapheme_store, 'D', 0x303)
	tg.grid_set_cell(&term.grid, 0, 2, tg.Semantic_Cell{content = h, style = 0, width = 1, flags = .None})
	tg.terminal_scroll_up(&term, 1)
	testing.expect(t, len(term.scrollback.rows) == 1, "one row should be stored")

	tg.terminal_destroy(&term)
	testing.expect(t, len(term.scrollback.rows) == 0, "destroy must empty the list")
	testing.expect(t, term.grapheme_store.live_count == 0, "destroy must release live handles")
}
