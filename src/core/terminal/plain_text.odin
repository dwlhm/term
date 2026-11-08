package core_terminal

// Plain text of a Terminal: selections, `term session read`. EGC clusters are
// resolved, wide continuations skipped, an empty cell is a space.

import "core:strings"
import cell "cell"
import egc "egc"
import grid "grid"

terminal_cell_append_utf8 :: proc(b: ^strings.Builder, pool: ^egc.Egc_Pool, c: cell.Semantic_Cell) {
	if .Wide_Continuation in c.flags do return
	if .Has_Egc in c.flags && pool != nil {
		if runes := egc.egc_pool_get(pool, int(c.char - egc.EGC_INDEX_BASE)); runes != nil {
			for rn in runes do strings.write_rune(b, rn)
			return
		}
	}
	strings.write_rune(b, c.char if c.char != 0 else ' ')
}

// terminal_row_last_content_col is the rightmost non-blank column (-1: blank row).
terminal_row_last_content_col :: proc(row: ^grid.Row) -> int {
	if row == nil do return -1
	for i := len(row.cells) - 1; i >= 0; i -= 1 {
		ch := row.cells[i].char
		if ch != 0 && ch != ' ' do return i
	}
	return -1
}

// terminal_text appends up to `history` scrollback lines and the active screen:
// soft-wrapped rows joined, trailing blanks and trailing empty lines dropped.
terminal_text :: proc(t: ^Terminal, b: ^strings.Builder, history: int) {
	terminal_text_rows(t, &t.grid, b, -min(history, t.grid.history_count), t.grid.row_count)
}

// terminal_text_rows appends rows [from, to) of g the same way. end_col clips
// the last row [from, to) when >= 0.
terminal_text_rows :: proc(t: ^Terminal, g: ^grid.Grid, b: ^strings.Builder, from, to: int, end_col: int = -1) {
	start := len(b.buf)
	keep := start // end of the last line with content
	for r in from ..< to {
		row := grid.grid_get_row(g, r)
		if row == nil do continue
		last := terminal_row_last_content_col(row)
		if r == to - 1 && end_col >= 0 do last = min(last, end_col - 1)
		for c in 0 ..= last do terminal_cell_append_utf8(b, &t.egc_pool, row.cells[c])
		if last >= 0 do keep = len(b.buf)
		if !row.wrap || r == to - 1 do strings.write_byte(b, '\n')
	}
	resize(&b.buf, keep)
	if keep > start do strings.write_byte(b, '\n')
}
