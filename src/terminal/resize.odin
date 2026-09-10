package termgrid

// terminal_resize changes the grid dimensions, preserving top-left content.
// New cells are CELL_DEFAULT; cells truncated on the right/bottom have their
// grapheme handles released. A wide pair split by the new right edge has its
// orphan lead blanked to CELL_DEFAULT (handle released). The cursor is
// clamped into the new bounds, the scroll region resets to the full grid,
// and all rows are marked dirty. Same dims is a cheap no-op; degenerate
// (<= 0) dims leave the terminal unchanged. The old backing is freed only
// after the new backing is fully allocated, so a failed allocation leaves
// the old dims intact.
terminal_resize :: proc(t: ^Terminal, new_rows: int, new_cols: int, allocator := context.allocator) {
	if new_rows <= 0 || new_cols <= 0 {
		return
	}
	if new_rows == t.grid.row_count && new_cols == t.grid.col_count {
		return
	}

	old_rows := t.grid.row_count
	old_cols := t.grid.col_count

	// Allocate the new backing first; t is untouched until it succeeds.
	new_cap := _next_pow2(new_rows)
	new_backing := make([]Row, new_cap, allocator)
	for i in 0..<new_cap {
		row_init(&new_backing[i], new_cols, allocator)
	}

	copy_rows := min(old_rows, new_rows)
	copy_cols := min(old_cols, new_cols)

	// Copy the top-left rectangle, preserving row generations.
	for r in 0..<copy_rows {
		old_phys := _grid_physical_row(&t.grid, r)
		new_backing[r].generation = t.grid.rows[old_phys].generation
		for c in 0..<copy_cols {
			new_backing[r].cells[c] = t.grid.rows[old_phys].cells[c]
		}
	}

	// Release handles of discarded cells (right/bottom truncation).
	if t.grapheme_store.live_count != 0 {
		for r in 0..<copy_rows {
			old_phys := _grid_physical_row(&t.grid, r)
			for c in copy_cols..<old_cols {
				grapheme_store_release(&t.grapheme_store, t.grid.rows[old_phys].cells[c].content)
			}
		}
		for r in copy_rows..<old_rows {
			old_phys := _grid_physical_row(&t.grid, r)
			for c in 0..<old_cols {
				grapheme_store_release(&t.grapheme_store, t.grid.rows[old_phys].cells[c].content)
			}
		}
	}

	// Repair a wide pair split by the new right edge: a lead stranded at
	// the last kept column lost its continuation to truncation.
	if new_cols < old_cols {
		for r in 0..<copy_rows {
			if _row_cell_is_lead(&new_backing[r], new_cols - 1) {
				grapheme_store_release(&t.grapheme_store, new_backing[r].cells[new_cols - 1].content)
				new_backing[r].cells[new_cols - 1] = CELL_DEFAULT
			}
		}
	}

	// Install the new backing; the old one is freed only now.
	for i in 0..<len(t.grid.rows) {
		row_destroy(&t.grid.rows[i], allocator)
	}
	delete(t.grid.rows)
	t.grid.rows = new_backing
	t.grid.row_count = new_rows
	t.grid.col_count = new_cols
	t.grid.capacity = new_cap
	t.grid.mask = new_cap - 1
	t.grid.origin = 0

	// Full damage over the new grid.
	damage_destroy(&t.damage, allocator)
	damage_init(&t.damage, new_rows, new_cols, allocator)
	gens := make([]u32, new_rows, context.allocator)
	for i in 0..<new_rows {
		gens[i] = t.grid.rows[i].generation
	}
	damage_mark_all(&t.damage, gens)
	delete(gens)

	// Scrollback rows are fixed-width: a col change invalidates every
	// stored row, so clear (releasing its grapheme handles) and re-sync
	// the width. Same-cols resize preserves scrollback history.
	if new_cols != t.scrollback.col_count {
		scrollback_clear(&t.scrollback, &t.grapheme_store, allocator)
		t.scrollback.col_count = new_cols
	}

	// Clamp the cursor and reset the scroll region to the full grid.
	cursor_move(&t.cursor, t.cursor.row, t.cursor.col, new_rows, new_cols)
	terminal_reset_scroll_region(t)
}
