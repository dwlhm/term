package terminal_grid

import cell "../cell"
import damage "../damage"

// _rect_sanitize_boundary clears the orphaned half of a wide character when a
// rectangular operation splits a 2-cell glyph at column `col` (the first column
// modified or read at a left/right edge).
@(private = "package")
_rect_sanitize_boundary :: proc(g: ^Grid, d: ^damage.Damage_Tracker, row, col: int) {
	if g == nil || row < 0 || row >= g.row_count || col <= 0 || col >= g.col_count do return
	c := grid_get_cell(g, row, col)
	if .Wide_Continuation in c.flags {
		grid_set_cell(g, d, row, col - 1, cell.CELL_DEFAULT)
		grid_set_cell(g, d, row, col, cell.CELL_DEFAULT)
	}
}

// _rect_sanitize_cell converts a half-severed wide glyph at the edge of a
// copied span (`i == 0` continuation or `i == width - 1` lead) into a space
// preserving its colours so no orphan half-glyph lands in the destination.
@(private = "file")
_rect_sanitize_cell :: proc(c: cell.Semantic_Cell, is_first, is_last: bool) -> cell.Semantic_Cell {
	if (is_first && .Wide_Continuation in c.flags) || (is_last && .Wide_Lead in c.flags) {
		res := c
		res.char = ' '
		res.flags -= {.Wide_Lead, .Wide_Continuation, .Has_Egc}
		return res
	}
	return c
}

// _rect_copy_row_span copies cells `[src_l..=src_r]` from `src_row` into
// `dst_row` starting at `dst_l`, handling horizontal overlap safely.
@(private = "file")
_rect_copy_row_span :: proc(
	g: ^Grid,
	d: ^damage.Damage_Tracker,
	src_row, dst_row: int,
	src_l, dst_l, width: int,
) {
	if width <= 0 do return
	_rect_sanitize_boundary(g, d, dst_row, dst_l)
	_rect_sanitize_boundary(g, d, dst_row, dst_l + width)

	if src_row == dst_row && dst_l > src_l && dst_l < src_l + width {
		for i := width - 1; i >= 0; i -= 1 {
			c := _rect_sanitize_cell(grid_get_cell(g, src_row, src_l + i), i == 0, i == width - 1)
			dc := grid_get_direct_color(g, src_row, src_l + i)
			grid_set_cell(g, d, dst_row, dst_l + i, c, dc)
		}
		return
	}
	for i in 0 ..< width {
		c := _rect_sanitize_cell(grid_get_cell(g, src_row, src_l + i), i == 0, i == width - 1)
		dc := grid_get_direct_color(g, src_row, src_l + i)
		grid_set_cell(g, d, dst_row, dst_l + i, c, dc)
	}
}

// grid_scroll_rect_up scrolls the sub-rectangle `[top..=bottom, left..=right]`
// up by `n` rows. Delegates to `grid_scroll_up` when the horizontal span covers
// the full grid width.
grid_scroll_rect_up :: proc(
	g: ^Grid,
	d: ^damage.Damage_Tracker,
	top, bottom, left, right: int,
	n: int,
	fill: cell.Semantic_Cell = cell.CELL_DEFAULT,
	dc: cell.Direct_Color = {},
) -> int {
	if g == nil || g.row_count == 0 || n <= 0 do return 0
	l := max(0, left)
	r := min(g.col_count - 1, right)
	if l == 0 && r == g.col_count - 1 {
		return grid_scroll_up(g, d, top, bottom, n, fill, dc)
	}
	t := max(0, top)
	b := min(g.row_count - 1, bottom)
	if t >= b || l > r do return 0

	actual := min(n, b - t + 1)
	width := r - l + 1
	for row in t ..< (b - actual + 1) {
		_rect_copy_row_span(g, d, row + actual, row, l, l, width)
	}
	for row in (b - actual + 1) ..= b {
		grid_clear_line(g, d, row, l, r + 1, fill, dc)
	}
	return actual
}

// grid_scroll_rect_down scrolls the sub-rectangle `[top..=bottom, left..=right]`
// down by `n` rows. Delegates to `grid_scroll_down` when full-width.
grid_scroll_rect_down :: proc(
	g: ^Grid,
	d: ^damage.Damage_Tracker,
	top, bottom, left, right: int,
	n: int,
	fill: cell.Semantic_Cell = cell.CELL_DEFAULT,
	dc: cell.Direct_Color = {},
) -> int {
	if g == nil || g.row_count == 0 || n <= 0 do return 0
	l := max(0, left)
	r := min(g.col_count - 1, right)
	if l == 0 && r == g.col_count - 1 {
		return grid_scroll_down(g, d, top, bottom, n, fill, dc)
	}
	t := max(0, top)
	b := min(g.row_count - 1, bottom)
	if t >= b || l > r do return 0

	actual := min(n, b - t + 1)
	width := r - l + 1
	for row := b; row >= t + actual; row -= 1 {
		_rect_copy_row_span(g, d, row - actual, row, l, l, width)
	}
	for row in t ..< (t + actual) {
		grid_clear_line(g, d, row, l, r + 1, fill, dc)
	}
	return actual
}

// grid_copy_rect copies `[src_top..=src_bottom, src_left..=src_right]` to
// `(dst_top, dst_left)`, clipping to grid dimensions and handling overlap.
grid_copy_rect :: proc(
	g: ^Grid,
	d: ^damage.Damage_Tracker,
	src_top, src_left, src_bottom, src_right: int,
	dst_top, dst_left: int,
) {
	if g == nil || src_top > src_bottom || src_left > src_right do return
	if dst_top >= g.row_count || dst_left >= g.col_count do return
	if dst_top < 0 || dst_left < 0 do return

	height := min(src_bottom - src_top + 1, g.row_count - dst_top)
	width := min(src_right - src_left + 1, g.col_count - dst_left)
	if height <= 0 || width <= 0 do return

	if dst_top > src_top {
		for r := height - 1; r >= 0; r -= 1 {
			_rect_copy_row_span(g, d, src_top + r, dst_top + r, src_left, dst_left, width)
		}
	} else {
		for r in 0 ..< height {
			_rect_copy_row_span(g, d, src_top + r, dst_top + r, src_left, dst_left, width)
		}
	}
}

// grid_fill_rect fills `[top..=bottom, left..=right]` with `fill` and `dc`,
// sanitizing wide-character boundaries at the rectangle edges.
grid_fill_rect :: proc(
	g: ^Grid,
	d: ^damage.Damage_Tracker,
	top, left, bottom, right: int,
	fill: cell.Semantic_Cell,
	dc: cell.Direct_Color = {},
) {
	if g == nil || top > bottom || left > right do return
	t := clamp(top, 0, g.row_count - 1)
	b := clamp(bottom, 0, g.row_count - 1)
	l := clamp(left, 0, g.col_count - 1)
	r := clamp(right, 0, g.col_count - 1)
	for row in t ..= b {
		grid_clear_line(g, d, row, l, r + 1, fill, dc)
	}
}

// grid_selective_erase_rect implements DECSERA (`CSI Pt;Pl;Pb;Pr ${`): replaces
// characters in `[top..=bottom, left..=right]` with spaces while preserving
// existing cell colours and visual style attributes.
grid_selective_erase_rect :: proc(
	g: ^Grid,
	d: ^damage.Damage_Tracker,
	top, left, bottom, right: int,
) {
	if g == nil || top > bottom || left > right do return
	t := clamp(top, 0, g.row_count - 1)
	b := clamp(bottom, 0, g.row_count - 1)
	l := clamp(left, 0, g.col_count - 1)
	r := clamp(right, 0, g.col_count - 1)
	for row in t ..= b {
		_rect_sanitize_boundary(g, d, row, l)
		_rect_sanitize_boundary(g, d, row, r + 1)
		for col in l ..= r {
			c := grid_get_cell(g, row, col)
			dc := grid_get_direct_color(g, row, col)
			c.char = ' '
			c.flags -= {.Wide_Lead, .Wide_Continuation, .Has_Egc}
			grid_set_cell(g, d, row, col, c, dc)
		}
	}
}
