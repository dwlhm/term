package termgrid

import "base:runtime"

_Logical_Line :: struct {
	cells:         [dynamic]Semantic_Cell,
	colors:        [dynamic]Direct_Color_Channel,
	wrapped:       bool,
	has_cursor:    bool,
	cursor_offset: int,
	is_prompt:     bool,
}

_reflow_make_row :: proc(cols: int, allocator: runtime.Allocator) -> Row {
	r: Row
	r.cells = make([]Semantic_Cell, cols, allocator)
	r.ext.colors = make([]Direct_Color_Channel, cols, allocator)
	row_init(&r, cols)
	return r
}

_row_has_prompt_frame :: proc(row: ^Row) -> bool {
	if row == nil do return false
	for c in 0..<len(row.cells) {
		ch := row.cells[c].content
		if ch == 0 || ch == ' ' do continue
		if ch == 0x256D || ch == 0x2570 || ch == 0x250C || ch == 0x2514 {
			return true
		}
		break
	}
	return false
}

_has_active_prompt_frame :: proc(t: ^Terminal) -> bool {
	if t == nil do return false
	start_r := max(0, t.cursor.row - 2)
	for cr := start_r; cr <= t.cursor.row; cr += 1 {
		p := _grid_physical_row(&t.grid, cr)
		if _row_has_prompt_frame(&t.grid.rows[p]) {
			return true
		}
	}
	return false
}

_terminal_resize_primary :: proc(t: ^Terminal, new_rows: int, new_cols: int, allocator: runtime.Allocator = context.allocator) {
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

	// Seam coalescence across scrollback and grid boundary:
	// If the newest row in scrollback is wrapped, pop all consecutive wrapped rows
	// belonging to that logical line and prepend them to row 0's logical line.
	seam_rows := make([dynamic][]Semantic_Cell, context.temp_allocator)

	for t.scrollback.count > 0 {
		newest := scrollback_get(&t.scrollback, t.scrollback.count - 1)
		if newest == nil || !newest.wrapped {
			break
		}
		row_buf := make([]Semantic_Cell, old_cols, context.temp_allocator)
		row_wrapped := false
		if scrollback_pop_newest(&t.scrollback, row_buf, &row_wrapped) {
			append(&seam_rows, row_buf)
		} else {
			break
		}
	}

	logical_lines := make([dynamic]_Logical_Line, context.temp_allocator)

	r := 0
	for r <= max_active_row {
		ll: _Logical_Line
		ll.cells = make([dynamic]Semantic_Cell, context.temp_allocator)
		ll.colors = make([dynamic]Direct_Color_Channel, context.temp_allocator)
		ll.has_cursor = false
		ll.cursor_offset = 0
		ll.wrapped = false
		ll.is_prompt = false

		if r == 0 && len(seam_rows) > 0 {
			// seam_rows[0] is newest popped, seam_rows[len - 1] is oldest
			for s_idx := len(seam_rows) - 1; s_idx >= 0; s_idx -= 1 {
				s_row := seam_rows[s_idx]
				take_cols := old_cols
				for take_cols > 0 && s_row[take_cols - 1] == CELL_DEFAULT {
					take_cols -= 1
				}
				for c in 0..<take_cols {
					append(&ll.cells, s_row[c])
					append(&ll.colors, Direct_Color_Channel{})
				}
			}
		}

		for {
			phys := _grid_physical_row(&t.grid, r)
			row_wrapped := t.grid.rows[phys].wrapped
			if t.grid.rows[phys].is_prompt {
				ll.is_prompt = true
			} else if r == t.cursor.row {
				if _has_active_prompt_frame(t) {
					ll.is_prompt = true
				}
			} else if r < t.cursor.row && r >= t.cursor.row - 2 {
				if _row_has_prompt_frame(&t.grid.rows[phys]) {
					ll.is_prompt = true
				}
			}
			if r == t.cursor.row {
				ll.has_cursor = true
				xenl_adj := 1 if t.cursor.pending_wrap else 0
				ll.cursor_offset = len(ll.cells) + t.cursor.col + xenl_adj
			}

			if row_wrapped {
				take_cols := old_cols
				// If the wrapped row has trailing unwritten CELL_DEFAULT cells (e.g. from wide-char right margin or previous padding), do not absorb them:
				for take_cols > 0 && t.grid.rows[phys].cells[take_cols - 1] == CELL_DEFAULT {
					take_cols -= 1
				}
				// Ensure at least take_cols covers up to cursor if cursor is on this row
				if r == t.cursor.row {
					take_cols = max(take_cols, t.cursor.col)
				}
				for c in 0..<take_cols {
					append(&ll.cells, t.grid.rows[phys].cells[c])
					col_clr := t.grid.rows[phys].ext.colors[c] if (len(t.grid.rows[phys].ext.colors) > c) else Direct_Color_Channel{}
					append(&ll.colors, col_clr)
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
					col_clr := t.grid.rows[phys].ext.colors[c] if (len(t.grid.rows[phys].ext.colors) > c) else Direct_Color_Channel{}
					append(&ll.colors, col_clr)
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
	new_cells := make([]Semantic_Cell, new_cap * new_cols, allocator)
	new_ext_colors := make([]Direct_Color_Channel, new_cap * new_cols, allocator)
	for i in 0..<new_cap {
		new_backing[i].cells = new_cells[i * new_cols : (i + 1) * new_cols]
		new_backing[i].ext.channels = {}
		new_backing[i].ext.colors = new_ext_colors[i * new_cols : (i + 1) * new_cols]
		for c in 0..<new_cols {
			new_backing[i].cells[c] = CELL_DEFAULT
			new_backing[i].ext.colors[c] = {}
		}
		new_backing[i].generation = 0
		new_backing[i].wrapped = false
		new_backing[i].is_prompt = false
	}


	// d. Reflow extracted logical lines into rows
	reflowed_rows := make([dynamic]Row, context.temp_allocator)

	new_cursor_row := 0
	new_cursor_col := 0
	cursor_pending_wrap := false
	cursor_found := false

	for &ll in logical_lines {
		if ll.is_prompt {
			current_row := _reflow_make_row(new_cols, context.temp_allocator)
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
					if u8(cell.flags) & u8(Cell_Flags.Direct_Color) != 0 && ci < len(ll.colors) {
						current_row.ext.channels |= {.Direct_Color}
						if col < len(current_row.ext.colors) {
							current_row.ext.colors[col] = ll.colors[ci]
						}
						if ci + 1 < len(ll.colors) && col + 1 < len(current_row.ext.colors) {
							current_row.ext.colors[col + 1] = ll.colors[ci + 1]
						}
					}
					col += 2
					ci += 2
				} else {
					current_row.cells[col] = cell
					if u8(cell.flags) & u8(Cell_Flags.Direct_Color) != 0 && ci < len(ll.colors) {
						current_row.ext.channels |= {.Direct_Color}
						if col < len(current_row.ext.colors) {
							current_row.ext.colors[col] = ll.colors[ci]
						}
					}
					col += 1
					ci += 1
				}
			}

			if ll.has_cursor && !cursor_found {
				new_cursor_row = len(reflowed_rows)
				if ll.cursor_offset >= new_cols {
					new_cursor_col = new_cols - 1
					cursor_pending_wrap = true
				} else {
					new_cursor_col = clamp(ll.cursor_offset, 0, new_cols - 1)
					cursor_pending_wrap = false
				}
				cursor_found = true
			}

			append(&reflowed_rows, current_row)
			continue
		}

		current_row := _reflow_make_row(new_cols, context.temp_allocator)
		current_row.is_prompt = ll.is_prompt
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
				current_row = _reflow_make_row(new_cols, context.temp_allocator)
				current_row.is_prompt = ll.is_prompt
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
				if u8(cell.flags) & u8(Cell_Flags.Direct_Color) != 0 && ci < len(ll.colors) {
					current_row.ext.channels |= {.Direct_Color}
					if col < len(current_row.ext.colors) {
						current_row.ext.colors[col] = ll.colors[ci]
					}
					if ci + 1 < len(ll.colors) && col + 1 < len(current_row.ext.colors) {
						current_row.ext.colors[col + 1] = ll.colors[ci + 1]
					}
				}

				if ll.has_cursor && !cursor_found && ll.cursor_offset == ci + 1 {
					new_cursor_row = len(reflowed_rows)
					new_cursor_col = col + 1
					cursor_found = true
				}

				col += 2
				ci += 2
			} else {
				current_row.cells[col] = cell
				if u8(cell.flags) & u8(Cell_Flags.Direct_Color) != 0 && ci < len(ll.colors) {
					current_row.ext.channels |= {.Direct_Color}
					if col < len(current_row.ext.colors) {
						current_row.ext.colors[col] = ll.colors[ci]
					}
				}
				col += 1
				ci += 1
			}

			if col >= new_cols {
				if ci < n_cells {
					current_row.wrapped = true
					append(&reflowed_rows, current_row)
					current_row = _reflow_make_row(new_cols, context.temp_allocator)
					current_row.is_prompt = ll.is_prompt
					col = 0
				}
			}
		}

		if ll.has_cursor && !cursor_found {
			extra := ll.cursor_offset - n_cells
			for col + extra > new_cols {
				current_row.wrapped = true
				append(&reflowed_rows, current_row)
				current_row = _reflow_make_row(new_cols, context.temp_allocator)
				current_row.is_prompt = ll.is_prompt
				extra -= (new_cols - col)
				col = 0
			}
			if col + extra == new_cols {
				new_cursor_row = len(reflowed_rows)
				new_cursor_col = new_cols - 1
				cursor_pending_wrap = true
				cursor_found = true
			} else {
				new_cursor_row = len(reflowed_rows)
				new_cursor_col = col + extra
				cursor_pending_wrap = false
				cursor_found = true
			}
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
				scrollback_push(&t.scrollback, reflowed_rows[i].cells, &t.grapheme_store, reflowed_rows[i].wrapped, allocator, reflowed_rows[i].ext)
			} else {
				if t.grapheme_store.live_count != 0 {
					for c in 0..<len(reflowed_rows[i].cells) {
						grapheme_store_release(&t.grapheme_store, reflowed_rows[i].cells[c].content)
					}
				}
			}
		}
		for i in 0..<new_rows {
			src_row := &reflowed_rows[overflow + i]
			dest_row := &new_backing[i]
			copy(dest_row.cells, src_row.cells)
			dest_row.generation = src_row.generation
			dest_row.wrapped = src_row.wrapped
			dest_row.is_prompt = src_row.is_prompt
			dest_row.ext.channels = src_row.ext.channels
			if len(dest_row.ext.colors) > 0 && len(src_row.ext.colors) > 0 {
				copy(dest_row.ext.colors, src_row.ext.colors)
			}
		}
		new_cursor_row -= overflow
	} else {
		is_screen_full := max_active_row >= old_rows - 1
		pull_count := min(new_rows - total_rows, t.scrollback.count) if (new_rows > total_rows && is_screen_full) else 0
		shift_down := 0
		if pull_count > 0 && is_screen_full && new_rows > (pull_count + total_rows) {
			shift_down = new_rows - (pull_count + total_rows)
		}
		
		if pull_count > 0 {
			// Pull pull_count newest rows from scrollback into new_backing[shift_down ..< shift_down + pull_count]
			for i := pull_count - 1; i >= 0; i -= 1 {
				row_wrapped := false
				_ = scrollback_pop_newest(&t.scrollback, new_backing[shift_down + i].cells, &row_wrapped)
				new_backing[shift_down + i].generation = 0
				new_backing[shift_down + i].wrapped = row_wrapped
				new_backing[shift_down + i].is_prompt = false
			}
			// Place reflowed_rows at shift_down + pull_count ..< shift_down + pull_count + total_rows
			for i in 0..<total_rows {
				dest_row := &new_backing[shift_down + pull_count + i]
				src_row := &reflowed_rows[i]
				copy(dest_row.cells, src_row.cells)
				dest_row.generation = src_row.generation
				dest_row.wrapped = src_row.wrapped
				dest_row.is_prompt = src_row.is_prompt
				dest_row.ext.channels = src_row.ext.channels
				if len(dest_row.ext.colors) > 0 && len(src_row.ext.colors) > 0 {
					copy(dest_row.ext.colors, src_row.ext.colors)
				}
			}
			new_cursor_row += shift_down + pull_count
		} else {
			for i in 0..<total_rows {
				dest_row := &new_backing[shift_down + i]
				src_row := &reflowed_rows[i]
				copy(dest_row.cells, src_row.cells)
				dest_row.generation = src_row.generation
				dest_row.wrapped = src_row.wrapped
				dest_row.is_prompt = src_row.is_prompt
				dest_row.ext.channels = src_row.ext.channels
				if len(dest_row.ext.colors) > 0 && len(src_row.ext.colors) > 0 {
					copy(dest_row.ext.colors, src_row.ext.colors)
				}
			}
			new_cursor_row += shift_down
		}
	}

	// f. Set t.grid.rows = new_backing, ...
	for i in 0..<len(t.grid.rows) {
	}
	if t.grid.ext_colors != nil {
		delete(t.grid.ext_colors)
	}
	if t.grid.cells != nil {
		delete(t.grid.cells)
	}
	delete(t.grid.rows)
	t.grid.rows = new_backing
	t.grid.cells = new_cells
	t.grid.ext_colors = new_ext_colors
	t.grid.row_count = new_rows
	t.grid.col_count = new_cols
	t.grid.capacity = new_cap
	t.grid.mask = new_cap - 1
	t.grid.origin = 0

	// g. Clamp t.cursor.row to [0, new_rows-1] and t.cursor.col to [0, new_cols-1].
	t.cursor.row = clamp(new_cursor_row, 0, new_rows - 1)
	t.cursor.col = clamp(new_cursor_col, 0, new_cols - 1)
	t.cursor.pending_wrap = cursor_pending_wrap

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

	if t.is_alt_screen {
		// Delta-only: Only resize active alt screen grid directly.
		// Bypasses primary grid reflow & scrollback coalescence during alt-screen mode.
		_grid_resize_alt(&t.grid, new_rows, new_cols, &t.grapheme_store, allocator)
		t.cursor.row = clamp(t.cursor.row, 0, new_rows - 1)
		t.cursor.col = clamp(t.cursor.col, 0, new_cols - 1)
		t.cursor.pending_wrap = false
		t.scroll_top = 0
		t.scroll_bottom = new_rows - 1

		damage_destroy(&t.damage, allocator)
		damage_init(&t.damage, new_rows, new_cols, allocator)
		gens := make([]u32, new_rows, allocator)
		for i in 0..<new_rows {
			gens[i] = t.grid.rows[i].generation
		}
		damage_mark_all(&t.damage, gens)
		delete(gens, allocator)
		t.render_epoch += 1
		return
	}
	_terminal_resize_primary(t, new_rows, new_cols, allocator)
	_grid_resize_clean(t, new_rows, new_cols, allocator)
}

_grid_resize_alt :: proc(g: ^Grid, new_rows, new_cols: int, store: ^Grapheme_Store, allocator: runtime.Allocator = context.allocator) {
	old_rows := g.row_count
	old_cols := g.col_count
	old_rows_slice := g.rows
	old_cells_slice := g.cells
	old_ext_colors_slice := g.ext_colors

	new_cap := _next_pow2(new_rows)
	new_rows_slice := make([]Row, new_cap, allocator)
	new_cells_slice := make([]Semantic_Cell, new_cap * new_cols, allocator)
	new_ext_colors_slice := make([]Direct_Color_Channel, new_cap * new_cols, allocator)

	// Release grapheme handles from cells that will be discarded
	if store != nil && store.live_count > 0 {
		for r in new_rows..<min(old_rows, len(old_rows_slice)) {
			for c in 0..<min(old_cols, len(old_rows_slice[r].cells)) {
				grapheme_store_release(store, old_rows_slice[r].cells[c].content)
			}
		}
		if new_cols < old_cols {
			for r in 0..<min(old_rows, new_rows) {
				if r < len(old_rows_slice) {
					for c in new_cols..<min(old_cols, len(old_rows_slice[r].cells)) {
						grapheme_store_release(store, old_rows_slice[r].cells[c].content)
					}
				}
			}
		}
	}

	copy_rows := min(old_rows, new_rows)
	copy_cols := min(old_cols, new_cols)

	for i in 0..<new_cap {
		new_rows_slice[i].cells = new_cells_slice[i * new_cols : (i + 1) * new_cols]
		new_rows_slice[i].ext.channels = {}
		new_rows_slice[i].ext.colors = new_ext_colors_slice[i * new_cols : (i + 1) * new_cols]
		for c in 0..<new_cols {
			new_rows_slice[i].cells[c] = CELL_DEFAULT
			new_rows_slice[i].ext.colors[c] = {}
		}
		if i < copy_rows && i < len(old_rows_slice) {
			copy(new_rows_slice[i].cells[:copy_cols], old_rows_slice[i].cells[:copy_cols])
			new_rows_slice[i].ext.channels = old_rows_slice[i].ext.channels
			if len(old_rows_slice[i].ext.colors) > 0 {
				copy(new_rows_slice[i].ext.colors[:copy_cols], old_rows_slice[i].ext.colors[:copy_cols])
			}
			new_rows_slice[i].generation = old_rows_slice[i].generation + 1
			new_rows_slice[i].wrapped = old_rows_slice[i].wrapped
			new_rows_slice[i].is_prompt = false
		} else {
			new_rows_slice[i].generation = 0
			new_rows_slice[i].wrapped = false
			new_rows_slice[i].is_prompt = false
		}
	}

	if old_ext_colors_slice != nil {
		delete(old_ext_colors_slice)
	}
	if old_cells_slice != nil {
		delete(old_cells_slice)
	}
	if old_rows_slice != nil {
		delete(old_rows_slice)
	}

	g.rows = new_rows_slice
	g.cells = new_cells_slice
	g.ext_colors = new_ext_colors_slice
	g.row_count = new_rows
	g.col_count = new_cols
	g.capacity = new_cap
	g.mask = new_cap - 1
	g.origin = 0
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
	if g.ext_colors != nil {
		delete(g.ext_colors)
	}
	if g.cells != nil {
		delete(g.cells)
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
	g.cells = make([]Semantic_Cell, new_cap * new_cols, allocator)
	g.ext_colors = make([]Direct_Color_Channel, new_cap * new_cols, allocator)
	for i in 0..<new_cap {
		g.rows[i].cells = g.cells[i * new_cols : (i + 1) * new_cols]
		g.rows[i].ext.channels = {}
		g.rows[i].ext.colors = g.ext_colors[i * new_cols : (i + 1) * new_cols]
		for c in 0..<new_cols {
			g.rows[i].cells[c] = CELL_DEFAULT
			g.rows[i].ext.colors[c] = {}
		}
		g.rows[i].generation = 0
		g.rows[i].wrapped = false
		g.rows[i].is_prompt = false
	}
}
