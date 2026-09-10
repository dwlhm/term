package termgrid

import "base:runtime"

// Grid represents the terminal grid with ring buffer row storage.
// Capacity is always a power of 2 for fast modulo.
Grid :: struct {
	rows:        []Row,       // length = capacity (power of 2)
	row_count:   int,         // logical number of rows (visible area)
	col_count:   int,         // number of columns
	capacity:    int,         // power of 2, >= row_count
	origin:      int,         // ring buffer origin (physical index of logical row 0)
	mask:        int,         // capacity - 1 (for fast modulo)
	style_table: Style_Table,
}

// _next_pow2 returns the smallest power of 2 >= n.
_next_pow2 :: proc(n: int) -> int {
	if n <= 1 {
		return 1
	}
	p: int = 1
	for p < n {
		p <<= 1
	}
	return p
}

// grid_init initializes a grid with the specified dimensions.
// Capacity is rounded up to the next power of 2.
grid_init :: proc(g: ^Grid, rows, cols: int, allocator: runtime.Allocator = context.allocator) {
	g.row_count = rows
	g.col_count = cols
	g.capacity = _next_pow2(rows)
	g.mask = g.capacity - 1
	g.origin = 0

	g.rows = make([]Row, g.capacity, allocator)
	for i in 0..<g.capacity {
		row_init(&g.rows[i], cols, allocator)
	}

	style_table_init(&g.style_table)
}

// grid_destroy frees all rows and the style table.
grid_destroy :: proc(g: ^Grid, allocator: runtime.Allocator = context.allocator) {
	for i in 0..<len(g.rows) {
		row_destroy(&g.rows[i], allocator)
	}
	if g.rows != nil {
		delete(g.rows)
		g.rows = nil
	}
	g.row_count = 0
	g.col_count = 0
	g.capacity = 0
	g.origin = 0
	g.mask = 0
}

// _grid_physical_row converts a logical row index to a physical index.
_grid_physical_row :: proc(g: ^Grid, logical_row: int) -> int {
	return (g.origin + logical_row) & g.mask
}

// grid_get_cell retrieves a cell at the specified logical position.
// Returns CELL_DEFAULT if row/col is out of bounds.
grid_get_cell :: proc(g: ^Grid, row, col: int) -> Semantic_Cell {
	if row < 0 || row >= g.row_count || col < 0 || col >= g.col_count {
		return CELL_DEFAULT
	}
	phys := _grid_physical_row(g, row)
	return g.rows[phys].cells[col]
}

// grid_set_cell sets a cell at the specified logical position.
// Returns false if row/col is out of bounds.
grid_set_cell :: proc(g: ^Grid, row, col: int, cell: Semantic_Cell) -> bool {
	if row < 0 || row >= g.row_count || col < 0 || col >= g.col_count {
		return false
	}
	phys := _grid_physical_row(g, row)
	return row_set_cell(&g.rows[phys], col, cell)
}

// grid_clear resets all cells to CELL_DEFAULT and marks all rows dirty.
grid_clear :: proc(g: ^Grid) {
	for i in 0..<len(g.rows) {
		row_clear(&g.rows[i])
	}
	g.origin = 0
}

// grid_scroll_up scrolls the grid up by n rows (ring buffer rotation).
// Returns the number of rows actually scrolled (may be clamped).
grid_scroll_up :: proc(g: ^Grid, n: int) -> int {
	if g.row_count == 0 {
		return 0
	}
	if n <= 0 {
		return 0
	}
	actual := n
	if actual > g.row_count {
		actual = g.row_count
	}

	// Rotate origin forward
	g.origin = (g.origin + actual) & g.mask

	// Clear the bottom n rows (logical rows [row_count-n, row_count-1])
	for i in 0..<actual {
		logical_row := g.row_count - actual + i
		phys := _grid_physical_row(g, logical_row)
		row_clear(&g.rows[phys])
	}

	return actual
}

// grid_scroll_down scrolls the grid down by n rows (ring buffer rotation).
// Returns the number of rows actually scrolled (may be clamped).
grid_scroll_down :: proc(g: ^Grid, n: int) -> int {
	if g.row_count == 0 {
		return 0
	}
	if n <= 0 {
		return 0
	}
	actual := n
	if actual > g.row_count {
		actual = g.row_count
	}

	// Rotate origin backward
	g.origin = (g.origin - actual + g.capacity) & g.mask

	// Clear the top n rows (logical rows [0, n-1])
	for i in 0..<actual {
		phys := _grid_physical_row(g, i)
		row_clear(&g.rows[phys])
	}

	return actual
}
