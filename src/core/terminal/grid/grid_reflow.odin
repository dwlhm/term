package terminal_grid

import "base:runtime"
import cell "../cell"
import damage "../damage"

_Logical_Line :: struct {
	cells:         [dynamic]cell.Semantic_Cell,
	direct_colors: [dynamic]cell.Direct_Color,
	wrapped:       bool,
	is_prompt:     bool,
	has_cursor:    bool,
	cursor_offset: int,
}

_Reflow_Row :: struct {
	cells:         [dynamic]cell.Semantic_Cell,
	direct_colors: [dynamic]cell.Direct_Color,
	wrap:          bool,
	is_prompt:     bool,
}

_make_reflow_row :: proc(cols: int, allocator: runtime.Allocator) -> _Reflow_Row {
	rr: _Reflow_Row
	rr.cells = make([dynamic]cell.Semantic_Cell, cols, cols, allocator)
	rr.direct_colors = make([dynamic]cell.Direct_Color, cols, cols, allocator)
	for i in 0..<cols {
		rr.cells[i] = cell.CELL_DEFAULT
		rr.direct_colors[i] = {}
	}
	rr.wrap = false
	rr.is_prompt = false
	return rr
}

_row_has_prompt_symbol :: proc(row: ^Row) -> bool {
	if row == nil do return false
	for c in 0..<len(row.cells) {
		ch := row.cells[c].char
		if ch == 0 || ch == ' ' do continue
		switch ch {
		case 0x256D, 0x2570, 0x250C, 0x2514: // '╭', '╰', '┌', '└'
			return true
		case 0x276F, 0x203A, 0x279C:         // '❯', '›', '➜'
			return true
		case '$', '#', '%':
			return true
		}
		break
	}
	return false
}

_is_active_prompt_region :: proc(g: ^Grid, r: int, cur_r: int) -> bool {
	if r < cur_r - 3 || r > cur_r do return false
	for scan := max(0, cur_r - 3); scan <= cur_r; scan += 1 {
		phys := grid_physical_row(g, scan)
		if g.rows[phys].is_prompt || _row_has_prompt_symbol(&g.rows[phys]) {
			return true
		}
	}
	return false
}

grid_resize_reflow :: proc(
	g: ^Grid,
	d: ^damage.Damage_Tracker,
	new_rows, new_cols: int,
	cursor_row: ^int = nil,
	cursor_col: ^int = nil,
	cursor_pending_wrap: ^bool = nil,
) {
	if g == nil do return
	target_rows := max(1, new_rows)
	target_cols := max(1, new_cols)
	if target_rows == g.row_count && target_cols == g.col_count do return

	old := g^
	if old.row_count <= 0 || old.col_count <= 0 || len(old.rows) == 0 {
		grid_init(g, target_rows, target_cols, old.allocator)
		if d != nil {
			damage.damage_destroy(d)
			damage.damage_init(d, target_rows, target_cols, g.allocator)
			damage.damage_mark_all(d, 1)
		}
		return
	}

	cur_r := clamp(cursor_row^, 0, old.row_count - 1) if cursor_row != nil else 0
	cur_c := clamp(cursor_col^, 0, old.col_count - 1) if cursor_col != nil else 0
	is_wrap := cursor_pending_wrap^ if cursor_pending_wrap != nil else false

	// 1. Find max active row with content or cursor in old visible grid
	last_active_row := 0
	for r in 0..<old.row_count {
		phys := grid_physical_row(&old, r)
		row := &old.rows[phys]
		has_content := false
		for c in 0..<old.col_count {
			cv := row.cells[c]
			dc := row.direct_colors[c]
			if (cv.char != 0 && cv.char != ' ') || cv.style != {} || dc.has_bg || dc.has_fg {
				has_content = true
				break
			}
		}
		if has_content {
			last_active_row = max(last_active_row, r)
		}
	}

	max_active_row := clamp(max(last_active_row, cur_r), 0, old.row_count - 1)
	for max_active_row < old.row_count - 1 {
		phys := grid_physical_row(&old, max_active_row)
		if old.rows[phys].wrap {
			max_active_row += 1
		} else {
			break
		}
	}

	// 2. Extract logical lines across scrollback (-history_count..<0) and visible (0..=max_active_row)
	logical_lines := make([dynamic]_Logical_Line, context.temp_allocator)

	r := -old.history_count
	for r <= max_active_row {
		ll: _Logical_Line
		ll.cells = make([dynamic]cell.Semantic_Cell, context.temp_allocator)
		ll.direct_colors = make([dynamic]cell.Direct_Color, context.temp_allocator)
		ll.has_cursor = false
		ll.cursor_offset = 0
		ll.wrapped = false
		ll.is_prompt = false

		phys := grid_physical_row(&old, r)
		row := &old.rows[phys]

		is_prompt_line := row.is_prompt || _row_has_prompt_symbol(row) || _is_active_prompt_region(&old, r, cur_r)

		if is_prompt_line {
			ll.is_prompt = true
			if r == cur_r {
				ll.has_cursor = true
				xenl := 1 if is_wrap else 0
				ll.cursor_offset = cur_c + xenl
			}
			last_col := -1
			for c in 0..<old.col_count {
				cv := row.cells[c]
				dc := row.direct_colors[c]
				if (cv.char != 0 && cv.char != ' ') || cv.style != {} || dc.has_bg || dc.has_fg {
					last_col = c
				}
			}
			take_cols := last_col + 1 if last_col >= 0 else 0
			if r == cur_r {
				take_cols = max(take_cols, cur_c)
			}
			if take_cols < old.col_count && take_cols > 0 && .Wide_Lead in row.cells[take_cols - 1].flags {
				take_cols += 1
			}
			for c in 0..<take_cols {
				append(&ll.cells, row.cells[c])
				append(&ll.direct_colors, row.direct_colors[c])
			}
			ll.wrapped = false
			r += 1
			append(&logical_lines, ll)
			continue
		}

		for r <= max_active_row {
			row_phys := grid_physical_row(&old, r)
			cur_row := &old.rows[row_phys]
			if cur_row.is_prompt || _row_has_prompt_symbol(cur_row) || _is_active_prompt_region(&old, r, cur_r) {
				break
			}

			if r == cur_r {
				ll.has_cursor = true
				xenl := 1 if is_wrap else 0
				ll.cursor_offset = len(ll.cells) + cur_c + xenl
			}

			if cur_row.wrap {
				// Wrapped row: take cells up to old.col_count
				take_cols := old.col_count
				for take_cols > 0 && cur_row.cells[take_cols - 1] == cell.CELL_DEFAULT && (r != cur_r || take_cols > cur_c) {
					take_cols -= 1
				}
				for c in 0..<take_cols {
					append(&ll.cells, cur_row.cells[c])
					append(&ll.direct_colors, cur_row.direct_colors[c])
				}
				r += 1
				if r > max_active_row {
					ll.wrapped = true
					break
				}
			} else {
				// Hard break row: take up to last non-empty cell
				last_col := -1
				for c in 0..<old.col_count {
					cv := cur_row.cells[c]
					dc := cur_row.direct_colors[c]
					if (cv.char != 0 && cv.char != ' ') || cv.style != {} || dc.has_bg || dc.has_fg {
						last_col = c
					}
				}
				take_cols := last_col + 1 if last_col >= 0 else 0
				if r == cur_r {
					take_cols = max(take_cols, cur_c)
				}
				if take_cols < old.col_count && take_cols > 0 && .Wide_Lead in cur_row.cells[take_cols - 1].flags {
					take_cols += 1
				}
				for c in 0..<take_cols {
					append(&ll.cells, cur_row.cells[c])
					append(&ll.direct_colors, cur_row.direct_colors[c])
				}
				ll.wrapped = false
				r += 1
				break
			}
		}
		append(&logical_lines, ll)
	}

	// 3. Reflow extracted logical lines into rows of width target_cols
	reflowed_rows := make([dynamic]_Reflow_Row, context.temp_allocator)
	new_cursor_row := 0
	new_cursor_col := 0
	new_cursor_pending_wrap := false
	cursor_found := false

	for &ll in logical_lines {
		if ll.is_prompt {
			curr := _make_reflow_row(target_cols, context.temp_allocator)
			curr.is_prompt = true
			curr.wrap = false

			limit := min(len(ll.cells), target_cols)
			col := 0
			ci := 0
			for ci < limit {
				c_val := ll.cells[ci]
				is_wide := .Wide_Lead in c_val.flags

				if is_wide && col == target_cols - 1 {
					curr.cells[col] = cell.CELL_DEFAULT
					break
				}

				if is_wide && ci + 1 < limit && .Wide_Continuation in ll.cells[ci + 1].flags {
					curr.cells[col] = c_val
					curr.direct_colors[col] = ll.direct_colors[ci]
					curr.cells[col + 1] = ll.cells[ci + 1]
					curr.direct_colors[col + 1] = ll.direct_colors[ci + 1]
					col += 2
					ci += 2
				} else {
					curr.cells[col] = c_val
					curr.direct_colors[col] = ll.direct_colors[ci]
					col += 1
					ci += 1
				}
			}

			if ll.has_cursor && !cursor_found {
				new_cursor_row = len(reflowed_rows)
				new_cursor_col = clamp(ll.cursor_offset, 0, target_cols - 1)
				new_cursor_pending_wrap = false
				cursor_found = true
			}

			append(&reflowed_rows, curr)
			continue
		}

		curr := _make_reflow_row(target_cols, context.temp_allocator)
		curr.is_prompt = false
		col := 0
		ci := 0
		n_cells := len(ll.cells)

		if n_cells == 0 {
			if ll.has_cursor && !cursor_found {
				new_cursor_row = len(reflowed_rows)
				new_cursor_col = 0
				cursor_found = true
			}
			append(&reflowed_rows, curr)
			continue
		}

		for ci < n_cells {
			c_val := ll.cells[ci]
			is_wide := .Wide_Lead in c_val.flags

			// Wide char boundary: cannot fit on last column of row
			if is_wide && col == target_cols - 1 && target_cols > 1 {
				curr.wrap = true
				append(&reflowed_rows, curr)
				curr = _make_reflow_row(target_cols, context.temp_allocator)
				curr.is_prompt = false
				col = 0
				if ll.has_cursor && !cursor_found && ll.cursor_offset == ci {
					new_cursor_row = len(reflowed_rows)
					new_cursor_col = 0
					cursor_found = true
				}
			}

			if ll.has_cursor && !cursor_found && ll.cursor_offset == ci {
				new_cursor_row = len(reflowed_rows)
				new_cursor_col = col
				cursor_found = true
			}

			if is_wide && ci + 1 < n_cells && .Wide_Continuation in ll.cells[ci + 1].flags {
				curr.cells[col] = c_val
				curr.direct_colors[col] = ll.direct_colors[ci]
				if col + 1 < target_cols {
					curr.cells[col + 1] = ll.cells[ci + 1]
					curr.direct_colors[col + 1] = ll.direct_colors[ci + 1]
				}
				if ll.has_cursor && !cursor_found && ll.cursor_offset == ci + 1 {
					new_cursor_row = len(reflowed_rows)
					new_cursor_col = col + 1
					cursor_found = true
				}
				col += 2
				ci += 2
			} else {
				curr.cells[col] = c_val
				curr.direct_colors[col] = ll.direct_colors[ci]
				col += 1
				ci += 1
			}

			if col >= target_cols {
				if ci < n_cells {
					curr.wrap = true
					append(&reflowed_rows, curr)
					curr = _make_reflow_row(target_cols, context.temp_allocator)
					curr.is_prompt = false
					col = 0
				}
			}
		}

		if ll.has_cursor && !cursor_found {
			extra := ll.cursor_offset - n_cells
			for col + extra > target_cols {
				curr.wrap = true
				append(&reflowed_rows, curr)
				curr = _make_reflow_row(target_cols, context.temp_allocator)
				curr.is_prompt = false
				extra -= (target_cols - col)
				col = 0
			}
			if col + extra == target_cols {
				new_cursor_row = len(reflowed_rows)
				new_cursor_col = target_cols - 1
				new_cursor_pending_wrap = true
				cursor_found = true
			} else {
				new_cursor_row = len(reflowed_rows)
				new_cursor_col = col + extra
				new_cursor_pending_wrap = false
				cursor_found = true
			}
		}

		curr.wrap = ll.wrapped
		append(&reflowed_rows, curr)
	}

	// 4. Initialize target Grid with new capacity and copy reflowed rows
	grid_init(g, target_rows, target_cols, old.allocator)
	total_rows := len(reflowed_rows)
	max_hist := g.capacity - target_rows

	if total_rows > target_rows {
		overflow := total_rows - target_rows
		g.history_count = min(max_hist, overflow)
		start_idx := total_rows - (target_rows + g.history_count)

		for i in 0..<g.history_count {
			src_r := &reflowed_rows[start_idx + i]
			hist_logical_r := i - g.history_count
			phys := grid_physical_row(g, hist_logical_r)
			copy(g.rows[phys].cells, src_r.cells[:target_cols])
			copy(g.rows[phys].direct_colors, src_r.direct_colors[:target_cols])
			g.rows[phys].generation = 1
			g.rows[phys].wrap = src_r.wrap
			g.rows[phys].is_prompt = src_r.is_prompt
		}

		for i in 0..<target_rows {
			src_r := &reflowed_rows[overflow + i]
			phys := grid_physical_row(g, i)
			copy(g.rows[phys].cells, src_r.cells[:target_cols])
			copy(g.rows[phys].direct_colors, src_r.direct_colors[:target_cols])
			g.rows[phys].generation = 1
			g.rows[phys].wrap = src_r.wrap
			g.rows[phys].is_prompt = src_r.is_prompt
		}
		new_cursor_row -= overflow
		new_cursor_row = clamp(new_cursor_row, 0, target_rows - 1)
	} else {
		g.history_count = 0
		for i in 0..<total_rows {
			src_r := &reflowed_rows[i]
			phys := grid_physical_row(g, i)
			copy(g.rows[phys].cells, src_r.cells[:target_cols])
			copy(g.rows[phys].direct_colors, src_r.direct_colors[:target_cols])
			g.rows[phys].generation = 1
			g.rows[phys].wrap = src_r.wrap
			g.rows[phys].is_prompt = src_r.is_prompt
		}
		new_cursor_row = clamp(new_cursor_row, 0, target_rows - 1)
	}

	if cursor_row != nil do cursor_row^ = new_cursor_row
	if cursor_col != nil do cursor_col^ = clamp(new_cursor_col, 0, target_cols - 1)
	if cursor_pending_wrap != nil do cursor_pending_wrap^ = new_cursor_pending_wrap

	// 5. Cleanup old grid
	grid_destroy(&old)

	// 6. Reset damage tracker to new dimensions and mark all
	if d != nil {
		damage.damage_destroy(d)
		damage.damage_init(d, target_rows, target_cols, g.allocator)
		damage.damage_mark_all(d, 1)
	}
}
