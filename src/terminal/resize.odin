package termgrid

import "base:runtime"

_Logical_Line :: struct {
	cells:         [dynamic]Semantic_Cell,
	wrapped:       bool,
	has_cursor:    bool,
	cursor_offset: int,
	is_prompt:     bool,
}

_reflow_make_row :: proc(cols: int, allocator: runtime.Allocator) -> Row {
	r: Row
	row_init(&r, cols, allocator)
	return r
}

// terminal_resize changes the grid dimensions with bidirectional logical line reflow.
// When columns shrink, text wraps down without being truncated or lost;
// when columns expand back, text unwraps back to its original layout.
// Live grapheme handles survive on wrapped lines.
terminal_resize :: proc(t: ^Terminal, new_rows: int, new_cols: int, allocator := context.allocator) {
	// a. Handle degenerate dims (<= 0) and same dims early out
	if new_rows <= 0 || new_cols <= 0 {
		return
	}
	if new_rows == t.grid.row_count && new_cols == t.grid.col_count {
		return
	}

	old_rows := t.grid.row_count
	old_cols := t.grid.col_count

	// b. Extract logical lines from old grid:
	// Identify rows from 0 up to max_active_row (where max_active_row = max(last_row_with_content, t.cursor.row))
	last_row_with_content := 0
	for r in 0..<old_rows {
		phys := _grid_physical_row(&t.grid, r)
		for c in 0..<old_cols {
			cell := t.grid.rows[phys].cells[c]
			if cell.content != 0 || cell.style != 0 {
				last_row_with_content = max(last_row_with_content, r)
				break
			}
		}
	}

	max_active_row := clamp(max(last_row_with_content, t.cursor.row), 0, old_rows - 1)
	for max_active_row < old_rows - 1 {
		phys := _grid_physical_row(&t.grid, max_active_row)
		if t.grid.rows[phys].wrapped {
			max_active_row += 1
		} else {
			break
		}
	}

	logical_lines := make([dynamic]_Logical_Line, allocator)
	defer {
		for &ll in logical_lines {
			delete(ll.cells)
		}
		delete(logical_lines)
	}

	r := 0
	for r <= max_active_row {
		ll: _Logical_Line
		ll.cells = make([dynamic]Semantic_Cell, allocator)
		ll.has_cursor = false
		ll.cursor_offset = 0
		ll.wrapped = false
		ll.is_prompt = false

		for {
			phys := _grid_physical_row(&t.grid, r)
			row_wrapped := t.grid.rows[phys].wrapped
			if t.grid.rows[phys].is_prompt {
				ll.is_prompt = true
			}

			if r == t.cursor.row {
				ll.has_cursor = true
				ll.cursor_offset = len(ll.cells) + t.cursor.col
			}

			if row_wrapped {
				take_cols := old_cols
				if r + 1 < old_rows {
					next_phys := _grid_physical_row(&t.grid, r + 1)
					next_first := t.grid.rows[next_phys].cells[0]
					if _cell_is_lead(next_first) && t.grid.rows[phys].cells[old_cols - 1] == CELL_DEFAULT {
						take_cols = old_cols - 1
						if r == t.cursor.row && t.cursor.col >= take_cols {
							ll.cursor_offset = len(ll.cells) + take_cols
						}
					}
				}
				for c in 0..<take_cols {
					append(&ll.cells, t.grid.rows[phys].cells[c])
				}
				r += 1
				if r > max_active_row {
					ll.wrapped = true
					break
				}
			} else {
				last_active_col := -1
				for c in 0..<old_cols {
					cell := t.grid.rows[phys].cells[c]
					if (cell.content != 0 && cell.content != ' ') || cell.style != 0 {
						last_active_col = c
					}
				}
				take_cols := 0
				if last_active_col >= 0 {
					take_cols = last_active_col + 1
				}
				if r == t.cursor.row {
					take_cols = max(take_cols, t.cursor.col)
				}
				if take_cols < old_cols && take_cols > 0 && _cell_is_lead(t.grid.rows[phys].cells[take_cols - 1]) {
					take_cols += 1
				}
				for c in 0..<take_cols {
					append(&ll.cells, t.grid.rows[phys].cells[c])
				}
				ll.wrapped = false
				r += 1
				break
			}
		}
		append(&logical_lines, ll)
	}

	// c. Allocate new_backing of capacity _next_pow2(new_rows), each row initialized with new_cols cells
	new_cap := _next_pow2(new_rows)
	new_backing := make([]Row, new_cap, allocator)
	for i in 0..<new_cap {
		row_init(&new_backing[i], new_cols, allocator)
	}

	// Active prompt elastic space gap compression:
	// If new_cols < old_cols, active prompt lines containing an elastic space gap leading to RPROMPT
	// (e.g. >= 6 consecutive unstyled spaces with text at both ends) are compressed by (old_cols - new_cols)
	// so that the line stays on 1 physical row instead of wrapping, preserving prompt vertical stability.
	if new_cols < old_cols {
		for line_idx in 0..<len(logical_lines) {
			ll := &logical_lines[line_idx]
			if ll.wrapped {
				continue
			}
			if t.has_osc_133 && !ll.is_prompt {
				continue
			}
			if len(ll.cells) <= new_cols || old_cols < 30 {
				continue
			}

			// Find first text cell
			first_text := -1
			for i in 0..<len(ll.cells) {
				cell := ll.cells[i]
				if (cell.content != 0 && cell.content != ' ') || cell.style != 0 {
					first_text = i
					break
				}
			}
			if first_text < 0 {
				continue
			}

			// Find last text cell
			last_text := -1
			for i := len(ll.cells) - 1; i >= 0; i -= 1 {
				cell := ll.cells[i]
				if (cell.content != 0 && cell.content != ' ') || cell.style != 0 {
					last_text = i
					break
				}
			}
			if last_text <= first_text {
				continue
			}
			if !t.has_osc_133 && last_text < old_cols - 25 {
				continue
			}

			// Find the longest run of unstyled spaces between first_text and last_text
			best_gap_start := -1
			best_gap_len := 0
			cur_gap_start := -1
			cur_gap_len := 0

			for i in (first_text + 1)..=last_text {
				is_space := false
				if i < last_text {
					cell := ll.cells[i]
					if (cell.content == 0 || cell.content == ' ') && cell.style == 0 {
						is_space = true
					}
				}
				if is_space {
					if cur_gap_start == -1 {
						cur_gap_start = i
						cur_gap_len = 1
					} else {
						cur_gap_len += 1
					}
				} else {
					if cur_gap_len > best_gap_len {
						best_gap_len = cur_gap_len
						best_gap_start = cur_gap_start
					}
					cur_gap_start = -1
					cur_gap_len = 0
				}
			}

			should_compress := false
			if t.has_osc_133 {
				should_compress = ll.is_prompt && best_gap_len >= 6
			} else {
				should_compress = best_gap_len >= 6
			}

			cursor_ok := !ll.has_cursor || ll.cursor_offset <= best_gap_start + 1
			if should_compress && cursor_ok {
				if !t.has_osc_133 {
					ll.is_prompt = true
				}
				diff := old_cols - new_cols
				compress := min(diff, best_gap_len)
				if compress > 0 {
					remove_start := best_gap_start + best_gap_len - compress
					remove_end := best_gap_start + best_gap_len
					copy(ll.cells[remove_start:], ll.cells[remove_end:])
					resize(&ll.cells, len(ll.cells) - compress)

					if ll.has_cursor && ll.cursor_offset > remove_start {
						ll.cursor_offset = max(remove_start, ll.cursor_offset - compress)
					}
				}
			}
		}
	}

	// d. Reflow extracted logical lines into rows
	reflowed_rows := make([dynamic]Row, allocator)
	defer delete(reflowed_rows)

	new_cursor_row := 0
	new_cursor_col := 0
	cursor_found := false

	for &ll in logical_lines {
		if ll.is_prompt {
			current_row := _reflow_make_row(new_cols, allocator)
			current_row.is_prompt = true
			current_row.wrapped = false

			limit := min(len(ll.cells), new_cols)
			col := 0
			ci := 0
			for ci < limit {
				cell := ll.cells[ci]
				is_lead := _cell_is_lead(cell)
				if is_lead && col == new_cols - 1 {
					current_row.cells[col] = CELL_DEFAULT
					break
				}
				if is_lead && ci + 1 < limit && _cell_is_continuation(ll.cells[ci + 1]) {
					current_row.cells[col] = cell
					current_row.cells[col + 1] = ll.cells[ci + 1]
					col += 2
					ci += 2
				} else {
					current_row.cells[col] = cell
					col += 1
					ci += 1
				}
			}

			if t.grapheme_store.live_count > 0 && len(ll.cells) > limit {
				for i in limit..<len(ll.cells) {
					grapheme_store_release(&t.grapheme_store, ll.cells[i].content)
				}
			}

			if ll.has_cursor && !cursor_found {
				new_cursor_row = len(reflowed_rows)
				new_cursor_col = clamp(ll.cursor_offset, 0, new_cols - 1)
				cursor_found = true
			}

			append(&reflowed_rows, current_row)
			continue
		}

		current_row := _reflow_make_row(new_cols, allocator)
		col := 0
		ci := 0
		n_cells := len(ll.cells)

		for ci < n_cells {
			cell := ll.cells[ci]
			is_lead := _cell_is_lead(cell)

			// Wide character boundary rule:
			// if column is new_cols - 1 and the next cell to place is a wide character lead (width == 2),
			// place CELL_DEFAULT at new_cols - 1, mark this row wrapped = true, and start the wide character at column 0 of the next row.
			if is_lead && col == new_cols - 1 && new_cols > 1 {
				current_row.cells[col] = CELL_DEFAULT
				current_row.wrapped = true
				append(&reflowed_rows, current_row)
				current_row = _reflow_make_row(new_cols, allocator)
				col = 0
				if ll.has_cursor && !cursor_found && ll.cursor_offset == ci {
					new_cursor_row = len(reflowed_rows)
					new_cursor_col = 0
					cursor_found = true
				}
				if ll.has_cursor && !cursor_found && ll.cursor_offset == ci + 1 {
					new_cursor_row = len(reflowed_rows)
					new_cursor_col = 1
					cursor_found = true
				}
			}

			if ll.has_cursor && !cursor_found && ll.cursor_offset == ci {
				new_cursor_row = len(reflowed_rows)
				new_cursor_col = col
				cursor_found = true
			}

			if is_lead && ci + 1 < n_cells && _cell_is_continuation(ll.cells[ci + 1]) {
				cont := ll.cells[ci + 1]
				current_row.cells[col] = cell
				current_row.cells[col + 1] = cont

				if ll.has_cursor && !cursor_found && ll.cursor_offset == ci + 1 {
					new_cursor_row = len(reflowed_rows)
					new_cursor_col = col + 1
					cursor_found = true
				}

				col += 2
				ci += 2
			} else {
				current_row.cells[col] = cell
				col += 1
				ci += 1
			}

			if col >= new_cols {
				if ci < n_cells {
					current_row.wrapped = true
					append(&reflowed_rows, current_row)
					current_row = _reflow_make_row(new_cols, allocator)
					col = 0
				}
			}
		}

		if ll.has_cursor && !cursor_found {
			extra := ll.cursor_offset - n_cells
			for col + extra >= new_cols {
				current_row.wrapped = true
				append(&reflowed_rows, current_row)
				current_row = _reflow_make_row(new_cols, allocator)
				extra -= (new_cols - col)
				col = 0
			}
			new_cursor_row = len(reflowed_rows)
			new_cursor_col = col + extra
			cursor_found = true
		}

		current_row.wrapped = ll.wrapped
		append(&reflowed_rows, current_row)
	}

	// Scrollback resize if cols changed
	if new_cols != t.scrollback.col_count {
		scrollback_resize(&t.scrollback, new_cols, &t.grapheme_store, allocator)
	}

	// e. If total reflowed rows exceed new_rows:
	// Shift the rows so that the bottom rows (including cursor) are visible in new_backing[0..<new_rows].
	// If scrollback has room, push the top overflow rows to scrollback, or release their grapheme handles if evicted.
	// Adjust cursor row accordingly.
	total_rows := len(reflowed_rows)
	if total_rows > new_rows {
		overflow := total_rows - new_rows
		for i in 0..<overflow {
			if t.scrollback.max_lines > 0 {
				scrollback_push(&t.scrollback, reflowed_rows[i].cells, &t.grapheme_store, allocator)
			} else {
				if t.grapheme_store.live_count != 0 {
					for c in 0..<len(reflowed_rows[i].cells) {
						grapheme_store_release(&t.grapheme_store, reflowed_rows[i].cells[c].content)
					}
				}
			}
			row_destroy(&reflowed_rows[i], allocator)
		}
		for i in 0..<new_rows {
			row_destroy(&new_backing[i], allocator)
			new_backing[i] = reflowed_rows[overflow + i]
		}
		new_cursor_row -= overflow
	} else {
		for i in 0..<total_rows {
			row_destroy(&new_backing[i], allocator)
			new_backing[i] = reflowed_rows[i]
		}
	}

	// f. Set t.grid.rows = new_backing, ...
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

	// g. Clamp t.cursor.row to [0, new_rows-1] and t.cursor.col to [0, new_cols-1]
	t.cursor.row = clamp(new_cursor_row, 0, new_rows - 1)
	t.cursor.col = clamp(new_cursor_col, 0, new_cols - 1)

	// h. Destroy old rows slice and re-init damage with damage_mark_all
	damage_destroy(&t.damage, allocator)
	damage_init(&t.damage, new_rows, new_cols, allocator)
	gens := make([]u32, new_rows, allocator)
	for i in 0..<new_rows {
		gens[i] = t.grid.rows[i].generation
	}
	damage_mark_all(&t.damage, gens)
	delete(gens, allocator)

	// i. Reset scroll region to full grid and bump render_epoch
	terminal_reset_scroll_region(t)
	t.render_epoch += 1

	// Keep alternate buffer in sync with window dimensions
	_grid_resize_clean(t, new_rows, new_cols, allocator)
}

_grid_resize_clean :: proc(t: ^Terminal, new_rows, new_cols: int, allocator: runtime.Allocator = context.allocator) {
	g := &t.alt_grid
	if t.grapheme_store.live_count > 0 {
		for i in 0..<len(g.rows) {
			for c in 0..<len(g.rows[i].cells) {
				grapheme_store_release(&t.grapheme_store, g.rows[i].cells[c].content)
			}
		}
	}
	for i in 0..<len(g.rows) {
		row_destroy(&g.rows[i], allocator)
	}
	if g.rows != nil {
		delete(g.rows)
	}
	new_cap := _next_pow2(new_rows)
	g.row_count = new_rows
	g.col_count = new_cols
	g.capacity = new_cap
	g.mask = new_cap - 1
	g.origin = 0
	g.rows = make([]Row, new_cap, allocator)
	for i in 0..<new_cap {
		row_init(&g.rows[i], new_cols, allocator)
	}
}
