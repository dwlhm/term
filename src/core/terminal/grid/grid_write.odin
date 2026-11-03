package terminal_grid

import cell "../cell"
import damage "../damage"

// grid_write_ascii writes a run of printable ASCII at (row, col) with one
// attribute template, clipped to the row. It is equivalent to sanitizing wide
// pairs and calling grid_set_cell for every byte, but looks the row up once and
// marks the changed cells as a single damage span.
grid_write_ascii :: proc(
	g: ^Grid,
	d: ^damage.Damage_Tracker,
	row, col: int,
	text: []u8,
	template: cell.Semantic_Cell,
	dc: cell.Direct_Color,
) -> int {
	if g == nil || row < 0 || row >= g.row_count || col < 0 || col >= g.col_count do return 0
	n := min(len(text), g.col_count - col)
	if n <= 0 do return 0
	end := col + n
	r := &g.rows[grid_physical_row(g, row)]

	// A wide pair cut by either edge of the run loses its other half; pairs
	// inside the run are overwritten anyway.
	cut_right := end < g.col_count && .Wide_Lead in r.cells[end - 1].flags
	if col > 0 && .Wide_Continuation in r.cells[col].flags {
		grid_set_cell(g, d, row, col - 1, cell.CELL_DEFAULT)
	}
	if cut_right do grid_set_cell(g, d, row, end, cell.CELL_DEFAULT)

	tracks := .Has_Direct_Color in template.flags || .Has_Hyperlink in template.flags || .Has_Underline_Decor in template.flags
	stored_dc := dc if tracks else {}
	first, last := -1, -1
	for b, k in text[:n] {
		x := col + k
		c := template
		c.char = rune(b)
		if transmute(u64)r.cells[x] != transmute(u64)c || (tracks && r.direct_colors[x] != dc) {
			r.cells[x] = c
			r.direct_colors[x] = stored_dc
			if first < 0 do first = x
			last = x
		}
	}
	if first >= 0 {
		r.generation += 1
		if d != nil do damage.damage_mark_span(d, row, first, last + 1, r.generation)
	}
	return n
}
