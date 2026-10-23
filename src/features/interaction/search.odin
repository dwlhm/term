package feature_interaction

// In-terminal search over the visible grid and scrollback.
//
// Matching is allocation-free so it can run on every keystroke of the search bar;
// the caller supplies the anchor and direction, and matches wrap around the whole
// buffer exactly once.

import "core:unicode"
import core_terminal "../../core/terminal"

MAX_SEARCH_RUNES :: 128

Search_Match :: struct {
	row:       int, // logical row; negative values live in scrollback
	col_start: int,
	col_end:   int, // inclusive
	found:     bool,
}

_search_decode_needle :: proc(needle: string) -> (runes: [MAX_SEARCH_RUNES]rune, count: int) {
	for r in needle {
		if count >= MAX_SEARCH_RUNES do break
		runes[count] = unicode.to_lower(r)
		count += 1
	}
	return runes, count
}

// _search_cell_rune returns the printable rune stored in a cell (first codepoint
// for grapheme clusters), lowercased for case-insensitive comparison.
_search_cell_rune :: proc(term: ^core_terminal.Terminal, row, col: int) -> (rune, bool) {
	c := core_terminal.terminal_get_cell(term, row, col)
	if .Wide_Continuation in c.flags do return 0, false
	ch := c.char
	if .Has_Egc in c.flags {
		if runes := core_terminal.terminal_get_egc_runes(term, ch); len(runes) > 0 do ch = runes[0]
	}
	if ch == 0 do ch = ' '
	return unicode.to_lower(ch), true
}

_search_row_matches :: proc(
	term: ^core_terminal.Terminal,
	row, col: int,
	needle: []rune,
	cols: int,
) -> bool {
	cursor := col
	for want in needle {
		for cursor < cols {
			if _, ok := _search_cell_rune(term, row, cursor); ok do break
			cursor += 1
		}
		if cursor >= cols do return false
		got, _ := _search_cell_rune(term, row, cursor)
		if got != want do return false
		cursor += 1
	}
	return true
}

// search_find locates the next match at or after (forward) / at or before
// (backward) the anchor, wrapping around the buffer once.
search_find :: proc(
	term: ^core_terminal.Terminal,
	needle: string,
	from_row, from_col: int,
	forward: bool,
) -> Search_Match {
	if term == nil || len(needle) == 0 do return {}
	runes, count := _search_decode_needle(needle)
	if count == 0 do return {}

	cols := term.cols
	top := -term.grid.history_count
	bottom := term.rows - 1
	rows := bottom - top + 1
	if cols <= 0 || rows <= 0 do return {}

	start := clamp(from_row, top, bottom) - top
	for step in 0..<rows {
		row_index := (start + step) % rows if forward else (start - step + rows * 2) % rows
		row := row_index + top

		first_col := 0
		if step == 0 {
			first_col = clamp(from_col, 0, max(0, cols - 1))
		}
		for offset in 0..<cols {
			col := (first_col + offset) % cols if forward else (first_col - offset + cols * 2) % cols
			if _search_row_matches(term, row, col, runes[:count], cols) {
				return Search_Match{row = row, col_start = col, col_end = col + count - 1, found = true}
			}
			if !forward && col == 0 do break
		}
	}
	return {}
}

// search_match_to_cells converts a match into selection cells for highlighting.
search_match_cells :: proc(match: Search_Match) -> (start: Cell_Pos, end: Cell_Pos) {
	return Cell_Pos{row = match.row, col = match.col_start}, Cell_Pos{row = match.row, col = match.col_end}
}

