package termgrid

import "base:runtime"

// Row represents a single row in the terminal grid.
// Each row has a generation counter for damage tracking.
Row :: struct {
	cells:      []Semantic_Cell, // length = grid.col_count
	generation: u32,             // incremented on every mutation
}

// row_init initializes a row with the specified number of columns.
// All cells are set to CELL_DEFAULT, generation = 0.
row_init :: proc(r: ^Row, cols: int, allocator: runtime.Allocator = context.allocator) {
	r.cells = make([]Semantic_Cell, cols, allocator)
	for i in 0..<cols {
		r.cells[i] = CELL_DEFAULT
	}
	r.generation = 0
}

// row_destroy frees the cells array.
row_destroy :: proc(r: ^Row, allocator: runtime.Allocator = context.allocator) {
	if r.cells != nil {
		delete(r.cells)
		r.cells = nil
	}
	r.generation = 0
}

// row_clear resets all cells to CELL_DEFAULT and increments generation.
row_clear :: proc(r: ^Row) {
	for i in 0..<len(r.cells) {
		r.cells[i] = CELL_DEFAULT
	}
	r.generation += 1
}

// row_set_cell sets a cell at the specified column and increments generation.
// Returns false if col is out of bounds.
row_set_cell :: proc(r: ^Row, col: int, cell: Semantic_Cell) -> bool {
	if col < 0 || col >= len(r.cells) {
		return false
	}
	r.cells[col] = cell
	r.generation += 1
	return true
}

// _row_cell_is_continuation reports whether the cell at col is the right
// half of a wide pair. Out of bounds is never a continuation.
_row_cell_is_continuation :: proc(r: ^Row, col: int) -> bool {
	if col < 0 || col >= len(r.cells) {
		return false
	}
	return u8(r.cells[col].flags) & u8(Cell_Flags.Wide_Continuation) != 0
}

// _row_cell_is_lead reports whether the cell at col is a wide lead.
// Out of bounds is never a lead.
_row_cell_is_lead :: proc(r: ^Row, col: int) -> bool {
	if col < 0 || col >= len(r.cells) {
		return false
	}
	return r.cells[col].width == 2 && u8(r.cells[col].flags) & u8(Cell_Flags.Wide_Continuation) == 0
}

// _wide_shift_repair blanks wide halves orphaned by a horizontal shift at
// col of n cells (is_insert: right shift with blank fill; else left shift
// with blank tail). Blanking writes CELL_DEFAULT without releasing handles:
// the caller pre-releases the exact orphan candidates before shifting.
_wide_shift_repair :: proc(r: ^Row, col: int, n: int, is_insert: bool) {
	// Pair straddling the shift point: lead left behind, continuation moved.
	if col > 0 && _row_cell_is_lead(r, col - 1) {
		r.cells[col - 1] = CELL_DEFAULT
	}
	if is_insert {
		// Moved continuation at col+n lost its lead; lead pushed to the
		// last cell lost its continuation to eviction.
		if _row_cell_is_continuation(r, col + n) {
			r.cells[col + n] = CELL_DEFAULT
		}
		if col + n <= len(r.cells) - 1 && _row_cell_is_lead(r, len(r.cells) - 1) {
			r.cells[len(r.cells) - 1] = CELL_DEFAULT
		}
	} else {
		// Shifted-in continuation at col lost its lead; lead before the
		// blank tail lost its continuation.
		if _row_cell_is_continuation(r, col) {
			r.cells[col] = CELL_DEFAULT
		}
		if len(r.cells) - n - 1 >= 0 && _row_cell_is_lead(r, len(r.cells) - n - 1) {
			r.cells[len(r.cells) - n - 1] = CELL_DEFAULT
		}
	}
}

// row_insert_cells shifts cells right by n at col (ICH), fills the gap with
// CELL_DEFAULT, repairs split wide pairs, and bumps generation.
// Evicted tail handles must be pre-released by the caller (no store here).
// OOB col returns false; n <= 0 is a no-op true.
row_insert_cells :: proc(r: ^Row, col: int, n: int) -> bool {
	if col < 0 || col >= len(r.cells) {
		return false
	}
	if n <= 0 {
		return true
	}
	m := n
	if avail := len(r.cells) - col; m > avail {
		m = avail
	}

	i := len(r.cells) - 1
	for i >= col + m {
		r.cells[i] = r.cells[i - m]
		i -= 1
	}
	for i in col..<(col + m) {
		r.cells[i] = CELL_DEFAULT
	}
	_wide_shift_repair(r, col, m, true)
	r.generation += 1
	return true
}

// row_delete_cells shifts cells left by n at col (DCH), fills the tail with
// CELL_DEFAULT, repairs split wide pairs, and bumps generation.
// Deleted-cell handles must be pre-released by the caller (no store here).
// OOB col returns false; n <= 0 is a no-op true.
row_delete_cells :: proc(r: ^Row, col: int, n: int) -> bool {
	if col < 0 || col >= len(r.cells) {
		return false
	}
	if n <= 0 {
		return true
	}
	m := n
	if avail := len(r.cells) - col; m > avail {
		m = avail
	}

	for i in col..<(len(r.cells) - m) {
		r.cells[i] = r.cells[i + m]
	}
	for i in (len(r.cells) - m)..<len(r.cells) {
		r.cells[i] = CELL_DEFAULT
	}
	_wide_shift_repair(r, col, m, false)
	r.generation += 1
	return true
}
