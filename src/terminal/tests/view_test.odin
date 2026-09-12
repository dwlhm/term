package termgrid_test

import "core:testing"
import tg "../"

_view_marker_row :: proc(marker: rune, cols: int) -> []tg.Semantic_Cell {
	cells := make([]tg.Semantic_Cell, cols)
	for i in 0..<cols {
		cells[i] = tg.CELL_DEFAULT
	}
	cells[0] = tg.Semantic_Cell{content = tg.Content_Handle(marker), width = 1}
	return cells
}

@(test)
test_view_empty_history_and_mapping :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 3, 4)
	defer tg.terminal_destroy(&term)

	view := tg.Terminal_View{}
	tg.terminal_view_set_offset(&view, &term, 99)
	testing.expect(t, view.scrollback_offset == 0, "empty history must clamp offset to zero")
	testing.expect(t, tg.terminal_view_get_cell(&term, &view, 0, 0) == tg.CELL_DEFAULT, "empty history must map to live grid")
	testing.expect(t, tg.terminal_view_max_offset(&term) == 0, "empty history max offset must be zero")
}

@(test)
test_view_history_mapping_and_clamp :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 2, 3)
	defer tg.terminal_destroy(&term)
	term.scrollback.max_lines = 3

	for marker in 'A'..='D' {
		cells := _view_marker_row(marker, 3)
		tg.scrollback_push(&term.scrollback, cells, &term.grapheme_store)
		delete(cells)
	}
	term.grid.rows[term.grid.origin].cells[0].content = 'L'

	view := tg.Terminal_View{}
	testing.expect(t, tg.terminal_view_get_cell(&term, &view, 0, 0).content == 'L', "zero offset must show the live grid")
	tg.terminal_view_set_offset(&view, &term, 1)
	testing.expect(t, view.scrollback_offset == 1, "offset inside history must be retained")
	testing.expect(t, tg.terminal_view_get_cell(&term, &view, 0, 0).content == 'D', "offset one must show the newest retained history row")
	testing.expect(t, tg.terminal_view_get_cell(&term, &view, 1, 0).content == 'L', "offset one must retain the live tail")

	tg.terminal_view_set_offset(&view, &term, 99)
	testing.expect(t, view.scrollback_offset == 3, "offset must clamp at max history")
	testing.expect(t, tg.terminal_view_get_cell(&term, &view, 0, 0).content == 'B', "max offset must show oldest retained history")
}

@(test)
test_view_wide_normalization_and_selection :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 2, 5)
	defer tg.terminal_destroy(&term)
	tg.terminal_put_char(&term, 0x4E2D)
	tg.terminal_put_char(&term, 'x')

	start := tg.Terminal_Point{row = 0, col = 1}
	normal := tg.terminal_view_normalize_point(&term, start)
	testing.expect(t, normal.col == 0, "wide continuation selection point must normalize to lead")

	view := tg.Terminal_View{selection = tg.Terminal_Selection{
		active = true,
		anchor = tg.Terminal_Point{row = 0, col = 1},
		focus = tg.Terminal_Point{row = 0, col = 2},
	}}
	testing.expect(t, tg.terminal_view_selection_contains(&term, &view, tg.Terminal_Point{row = 0, col = 0}), "normalized wide lead must be selected")
	testing.expect(t, tg.terminal_view_selection_contains(&term, &view, tg.Terminal_Point{row = 0, col = 2}), "selection endpoint must be selected")
}

@(test)
test_view_selection_copy_trims_and_resolves_graphemes :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 2, 6)
	defer tg.terminal_destroy(&term)

	h := tg.grapheme_store_append(&term.grapheme_store, 'e', 0x301)
	tg.grid_set_cell(&term.grid, 0, 0, tg.Semantic_Cell{content = h, width = 1})
	tg.grid_set_cell(&term.grid, 0, 1, tg.Semantic_Cell{content = ' ', width = 1})
	tg.grid_set_cell(&term.grid, 1, 0, tg.Semantic_Cell{content = 'B', width = 1})

	view := tg.Terminal_View{selection = tg.Terminal_Selection{
		active = true,
		anchor = tg.Terminal_Point{row = 0, col = 0},
		focus = tg.Terminal_Point{row = 1, col = 2},
	}}
	got := tg.terminal_view_copy(&term, &view)
	defer delete(got)
	testing.expect(t, got == "é\nB", "copy must resolve marks, trim trailing blanks, and preserve breaks")
}

@(test)
test_view_inactive_selection_copy_is_empty :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 1, 1)
	defer tg.terminal_destroy(&term)

	view := tg.Terminal_View{}
	got := tg.terminal_view_copy(&term, &view)
	testing.expect(t, len(got) == 0, "inactive selection must copy empty text")
	delete(got)
}
