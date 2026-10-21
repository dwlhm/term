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
	phys_rows:     int,
	truncate:      bool,
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

_copy_row_into :: proc(
	g: ^Grid,
	logical_r: int,
	cells: []cell.Semantic_Cell,
	colors: []cell.Direct_Color,
	wrap: bool,
	is_prompt: bool,
) {
	phys := grid_physical_row(g, logical_r)
	target_cols := g.col_count
	c_len := min(target_cols, len(cells))
	copy(g.rows[phys].cells[:c_len], cells[:c_len])
	for c := c_len; c < target_cols; c += 1 {
		g.rows[phys].cells[c] = cell.CELL_DEFAULT
	}
	if len(colors) > 0 {
		clr_len := min(target_cols, len(colors))
		copy(g.rows[phys].direct_colors[:clr_len], colors[:clr_len])
		for c := clr_len; c < target_cols; c += 1 {
			g.rows[phys].direct_colors[c] = {}
		}
	} else {
		for c in 0..<target_cols {
			g.rows[phys].direct_colors[c] = {}
		}
	}
	if c_len == target_cols && target_cols > 0 && .Wide_Lead in g.rows[phys].cells[target_cols - 1].flags {
		g.rows[phys].cells[target_cols - 1] = cell.CELL_DEFAULT
		g.rows[phys].direct_colors[target_cols - 1] = {}
	}
	g.rows[phys].generation = 1
	g.rows[phys].wrap = wrap
	g.rows[phys].is_prompt = is_prompt
}

_destroy_logical_lines :: proc(lines: [dynamic]_Logical_Line) {
	for &ll in lines {
		delete(ll.cells)
		delete(ll.direct_colors)
	}
	delete(lines)
}

_destroy_reflow_rows :: proc(rows: [dynamic]_Reflow_Row) {
	for &rr in rows {
		delete(rr.cells)
		delete(rr.direct_colors)
	}
	delete(rows)
}

_row_content_len :: proc(row: ^Row) -> int {
	if row == nil do return 0
	last_col := -1
	n := len(row.cells)
	has_dc := len(row.direct_colors) == n
	for c := n - 1; c >= 0; c -= 1 {
		cv := row.cells[c]
		dc := row.direct_colors[c] if has_dc else cell.Direct_Color{}
		if (cv.char != 0 && cv.char != ' ') || cv.style != {} || dc.has_bg || dc.has_fg {
			last_col = c
			break
		}
	}
	if last_col < 0 do return 0
	len_res := last_col + 1
	if len_res < n && .Wide_Lead in row.cells[last_col].flags {
		len_res += 1
	}
	return len_res
}

_row_logical_len :: proc(g: ^Grid, r: int) -> int {
	phys := grid_physical_row(g, r)
	row := &g.rows[phys]
	if !row.wrap do return _row_content_len(row)
	n := len(row.cells)
	if n > 0 && row.cells[n - 1] == cell.CELL_DEFAULT && r + 1 < g.row_count {
		next_phys := grid_physical_row(g, r + 1)
		next := &g.rows[next_phys]
		if len(next.cells) > 0 && .Wide_Lead in next.cells[0].flags do return n - 1
	}
	return n
}

_is_prompt_start_row :: proc(row: ^Row, is_continuation: bool, is_cursor_row: bool) -> bool {
	if row == nil || is_continuation do return false
	if row.is_prompt do return true

	n := len(row.cells)
	for c in 0..<n {
		ch := row.cells[c].char
		if ch == 0 || ch == ' ' do continue

		// Multi-line prompt frame corners and bars: '╭', '╰', '┌', '└', '─', '│'
		switch ch {
		case 0x256D, 0x2570, 0x250C, 0x2514, 0x2500, 0x2502:
			return true
		// Powerline symbols and git branch icons
		case 0xE0A0, 0xE0B0, 0xE0B1, 0xE0B2, 0xE0B3:
			return true
		// Prompt markers: '❯', '›', '➜', '▶', '»', '→'
		case 0x276F, 0x203A, 0x279C, 0x25B6, 0x00BB, 0x2192:
			return true
		case '$', '#', '%':
			if c + 1 < n && (row.cells[c + 1].char == ' ' || row.cells[c + 1].char == 0) {
				return true
			}
		}
	}
	return false
}

_detect_active_prompt_start :: proc(g: ^Grid, cur_r: int) -> int {
	if g == nil || cur_r < 0 || cur_r >= g.row_count do return -1

	cur_phys := grid_physical_row(g, cur_r)
	cur_row := &g.rows[cur_phys]
	if cur_row == nil do return -1

	has_cur_prompt := cur_row.is_prompt || _is_prompt_start_row(cur_row, false, true)
	prompt_start := cur_r if has_cur_prompt else -1

	// Scan up to 4 rows above cursor to find prompt start frame ('╭' or '┌') or row.is_prompt
	for r := cur_r - 1; r >= max(0, cur_r - 4); r -= 1 {
		phys := grid_physical_row(g, r)
		row := &g.rows[phys]
		if row == nil do break

		// Empty row cannot be part of contiguous prompt frame
		if _row_content_len(row) == 0 do break

		// Check first non-space character
		first_ch: rune = 0
		first_col := -1
		for c in 0..<len(row.cells) {
			ch := row.cells[c].char
			if ch == 0 || ch == ' ' do continue
			first_ch = ch
			first_col = c
			break
		}

		if first_ch == 0x256D || first_ch == 0x250C { // '╭', '┌'
			prompt_start = r
			break
		}

		if row.is_prompt {
			prompt_start = r
			continue
		}

		// Continuation line of multi-line frame: must start with '│' (0x2502) or be indented (first_col > 0)
		if first_ch == 0x2502 || first_col > 0 {
			continue
		}

		// Hit a line starting at col 0 with non-frame character: cannot be part of prompt frame!
		break
	}

	return prompt_start
}

_extract_logical_lines :: proc(
	old: ^Grid,
	start_r, end_r: int,
	cur_r, cur_c: int,
	is_wrap: bool,
	seam_cells: []cell.Semantic_Cell = nil,
	seam_colors: []cell.Direct_Color = nil,
	seam_has_prompt: bool = false,
	prompt_start_r: int = -1,
	allocator: runtime.Allocator = context.allocator,
) -> [dynamic]_Logical_Line {
	logical_lines := make([dynamic]_Logical_Line, allocator)
	r := start_r
	is_continuation := false

	for r <= end_r {
		ll: _Logical_Line
		ll.cells = make([dynamic]cell.Semantic_Cell, allocator)
		ll.direct_colors = make([dynamic]cell.Direct_Color, allocator)
		ll.has_cursor = false
		ll.cursor_offset = 0
		ll.wrapped = false
		ll.is_prompt = false
		ll.phys_rows = 0
		ll.truncate = false

		if r == 0 && len(seam_cells) > 0 {
			append(&ll.cells, ..seam_cells)
			if len(seam_colors) > 0 {
				append(&ll.direct_colors, ..seam_colors)
			}
			if seam_has_prompt {
				ll.is_prompt = true
			}
			ll.phys_rows += 1
			is_continuation = true
		}

		row_phys := grid_physical_row(old, r)
		cur_row := &old.rows[row_phys]

		// Prompt boundary protection: all rows within active prompt block are isolated individually
		// with truncate so that vertical distance to cursor never expands, regardless of prior wrap flags.
		if prompt_start_r >= 0 && r >= prompt_start_r && r <= cur_r {
			ll.phys_rows = 1
			ll.is_prompt = true
			ll.truncate = true
			ll.wrapped = false

			if r == cur_r {
				ll.has_cursor = true
				ll.cursor_offset = cur_c
			}

			c_len := _row_content_len(cur_row)
			take_cols := max(c_len, cur_c + 1) if (r == cur_r) else c_len
			take_cols = clamp(take_cols, 0, old.col_count)

			for c in 0..<take_cols {
				append(&ll.cells, cur_row.cells[c])
				clr := cur_row.direct_colors[c] if c < len(cur_row.direct_colors) else cell.Direct_Color{}
				append(&ll.direct_colors, clr)
			}

			append(&logical_lines, ll)
			r += 1
			is_continuation = false
			continue
		}

		phys := grid_physical_row(old, r)
		first_row := &old.rows[phys]
		is_p := _is_prompt_start_row(first_row, is_continuation, r == cur_r)
		if is_p {
			ll.is_prompt = true
		}

		for r <= end_r {
			// Do not wrap into active prompt block
			if prompt_start_r >= 0 && r >= prompt_start_r {
				break
			}

			row_phys := grid_physical_row(old, r)
			cur_row := &old.rows[row_phys]
			ll.phys_rows += 1

			if cur_row.is_prompt {
				ll.is_prompt = true
			}

			if r == cur_r {
				ll.has_cursor = true
				xenl := 1 if is_wrap else 0
				ll.cursor_offset = len(ll.cells) + cur_c + xenl
			}

			content_len := _row_logical_len(old, r)
			take_cols := max(content_len, cur_c + 1) if (r == cur_r) else content_len
			take_cols = clamp(take_cols, 0, old.col_count)

			if cur_row.wrap {
				for c in 0..<take_cols {
					append(&ll.cells, cur_row.cells[c])
					clr := cur_row.direct_colors[c] if c < len(cur_row.direct_colors) else cell.Direct_Color{}
					append(&ll.direct_colors, clr)
				}
				r += 1
				is_continuation = true
				if r > end_r {
					ll.wrapped = true
					break
				}
				if prompt_start_r >= 0 && r >= prompt_start_r {
					ll.wrapped = false
					is_continuation = false
					break
				}
				next_phys := grid_physical_row(old, r)
				next_row := &old.rows[next_phys]
				if next_row.is_prompt {
					ll.wrapped = false
					is_continuation = false
					break
				}
			} else {
				for c in 0..<take_cols {
					append(&ll.cells, cur_row.cells[c])
					clr := cur_row.direct_colors[c] if c < len(cur_row.direct_colors) else cell.Direct_Color{}
					append(&ll.direct_colors, clr)
				}
				ll.wrapped = false
				r += 1
				is_continuation = false
				break
			}
		}
		append(&logical_lines, ll)
	}
	return logical_lines
}

_reflow_logical_lines :: proc(
	logical_lines: []_Logical_Line,
	target_cols: int,
	cursor_row: ^int,
	cursor_col: ^int,
	cursor_pending_wrap: ^bool,
	cursor_found: ^bool,
	allocator: runtime.Allocator = context.allocator,
) -> [dynamic]_Reflow_Row {
	reflowed := make([dynamic]_Reflow_Row, allocator)
	for &ll in logical_lines {
		// Truncate branch for active prompt block lines that were 1 physical row before resize:
		// Preserves exact 1-row height so vertical distance (VD) to cursor does not expand when shrinking.
		if ll.truncate {
			curr := _make_reflow_row(target_cols, allocator)
			curr.is_prompt = true

			limit := min(len(ll.cells), target_cols)
			if limit > 0 && .Wide_Lead in ll.cells[limit - 1].flags do limit -= 1
			for i in 0..<limit {
				curr.cells[i] = ll.cells[i]
				if i < len(ll.direct_colors) do curr.direct_colors[i] = ll.direct_colors[i]
			}
			if ll.has_cursor && !cursor_found^ {
				cursor_row^ = len(reflowed)
				cursor_col^ = clamp(ll.cursor_offset, 0, target_cols - 1)
				cursor_pending_wrap^ = false
				cursor_found^ = true
			}
			append(&reflowed, curr)
			continue
		}

		curr := _make_reflow_row(target_cols, allocator)
		curr.is_prompt = ll.is_prompt
		col := 0
		ci := 0
		n_cells := len(ll.cells)

		if n_cells == 0 {
			if ll.has_cursor && !cursor_found^ {
				cursor_row^ = len(reflowed)
				cursor_col^ = 0
				cursor_pending_wrap^ = false
				cursor_found^ = true
			}
			append(&reflowed, curr)
			continue
		}

		for ci < n_cells {
			c_val := ll.cells[ci]
			is_wide := .Wide_Lead in c_val.flags

			// Wide char boundary: cannot fit in 1-column grid, write blank and wrap
			if is_wide && target_cols == 1 {
				curr.cells[0] = cell.CELL_DEFAULT
				if ll.has_cursor && !cursor_found^ && (ll.cursor_offset == ci || ll.cursor_offset == ci + 1) {
					cursor_row^ = len(reflowed)
					cursor_col^ = 0
					cursor_pending_wrap^ = false
					cursor_found^ = true
				}
				ci += 2 if (ci + 1 < n_cells && .Wide_Continuation in ll.cells[ci + 1].flags) else 1
				if ci < n_cells {
					curr.wrap = true
					append(&reflowed, curr)
					curr = _make_reflow_row(target_cols, allocator)
					curr.is_prompt = false
					col = 0
				}
				continue
			}

			// If wide char overflows right margin at target_cols - 1: wrap to next row
			if is_wide && col == target_cols - 1 && target_cols > 1 {
				curr.wrap = true
				append(&reflowed, curr)
				curr = _make_reflow_row(target_cols, allocator)
				curr.is_prompt = false
				col = 0
				if ll.has_cursor && !cursor_found^ && ll.cursor_offset == ci {
					cursor_row^ = len(reflowed)
					cursor_col^ = 0
					cursor_pending_wrap^ = false
					cursor_found^ = true
				}
			}

			if ll.has_cursor && !cursor_found^ && ll.cursor_offset == ci {
				cursor_row^ = len(reflowed)
				cursor_col^ = col
				cursor_pending_wrap^ = false
				cursor_found^ = true
			}

			if is_wide && ci + 1 < n_cells && .Wide_Continuation in ll.cells[ci + 1].flags {
				curr.cells[col] = c_val
				if ci < len(ll.direct_colors) do curr.direct_colors[col] = ll.direct_colors[ci]
				if col + 1 < target_cols {
					curr.cells[col + 1] = ll.cells[ci + 1]
					if ci + 1 < len(ll.direct_colors) do curr.direct_colors[col + 1] = ll.direct_colors[ci + 1]
				}
				if ll.has_cursor && !cursor_found^ && ll.cursor_offset == ci + 1 {
					cursor_row^ = len(reflowed)
					cursor_col^ = col + 1
					cursor_pending_wrap^ = false
					cursor_found^ = true
				}
				col += 2
				ci += 2
			} else {
				curr.cells[col] = c_val
				if ci < len(ll.direct_colors) do curr.direct_colors[col] = ll.direct_colors[ci]
				col += 1
				ci += 1
			}

			if col >= target_cols {
				if ci < n_cells {
					curr.wrap = true
					append(&reflowed, curr)
					curr = _make_reflow_row(target_cols, allocator)
					curr.is_prompt = false
					col = 0
				}
			}
		}

		if ll.has_cursor && !cursor_found^ {
			extra := max(0, ll.cursor_offset - n_cells)
			for col + extra > target_cols {
				curr.wrap = true
				append(&reflowed, curr)
				curr = _make_reflow_row(target_cols, allocator)
				curr.is_prompt = false
				extra -= (target_cols - col)
				col = 0
			}
			cursor_row^ = len(reflowed)
			cursor_col^ = clamp(col + extra, 0, target_cols - 1)
			cursor_pending_wrap^ = (col + extra >= target_cols)
			cursor_found^ = true
		}

		curr.wrap = ll.wrapped
		append(&reflowed, curr)
	}
	return reflowed
}

grid_resize_reflow :: proc(
	g: ^Grid,
	d: ^damage.Damage_Tracker,
	new_rows, new_cols: int,
	cursor_row: ^int = nil,
	cursor_col: ^int = nil,
	cursor_pending_wrap: ^bool = nil,
	displacement: ^int = nil,
) {
	if g == nil do return
	target_rows := max(1, new_rows)
	target_cols := max(1, new_cols)
	if target_rows == g.row_count && target_cols == g.col_count do return

	old := g^
	if old.row_count <= 0 || old.col_count <= 0 || len(old.rows) == 0 {
		alloc := old.allocator
		grid_destroy(&old)
		grid_init(g, target_rows, target_cols, alloc)
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

	// Find max active row with content or cursor in old visible grid
	last_active_row := 0
	for r in 0..<old.row_count {
		phys := grid_physical_row(&old, r)
		row := &old.rows[phys]
		if _row_content_len(row) > 0 {
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
	num_vis_old := max_active_row + 1

	// Fast path: width did not change, only height changed!
	if target_cols == old.col_count {
		grid_init(g, target_rows, target_cols, old.allocator)
		max_hist := max(0, g.capacity - target_rows)

		new_cur_r := cur_r
		if cur_r >= target_rows {
			shift := cur_r - (target_rows - 1)
			added_hist := min(shift, old.row_count)
			g.history_count = min(max_hist, old.history_count + added_hist)

			n_add := min(added_hist, g.history_count)
			skip_add := added_hist - n_add
			keep := g.history_count - n_add

			// Keep newest old history rows if keep > 0
			if keep > 0 {
				skip := old.history_count - keep
				for i in 0..<keep {
					src_phys := grid_physical_row(&old, (skip + i) - old.history_count)
					dst_row := &old.rows[src_phys]
					_copy_row_into(g, i - g.history_count, dst_row.cells, dst_row.direct_colors, dst_row.wrap, dst_row.is_prompt)
				}
			}

			// Add shifted visible rows into newest history
			for i in 0..<n_add {
				src_phys := grid_physical_row(&old, skip_add + i)
				dst_row := &old.rows[src_phys]
				_copy_row_into(g, -n_add + i, dst_row.cells, dst_row.direct_colors, dst_row.wrap, dst_row.is_prompt)
			}

			vis_to_copy := min(old.row_count - shift, target_rows)
			for i in 0..<vis_to_copy {
				src_phys := grid_physical_row(&old, shift + i)
				dst_row := &old.rows[src_phys]
				_copy_row_into(g, i, dst_row.cells, dst_row.direct_colors, dst_row.wrap, dst_row.is_prompt)
			}
			new_cur_r = target_rows - 1
		} else {
			delta_rows := max(0, target_rows - old.row_count)
			free_rows := max(0, target_rows - num_vis_old)
			pull := min(old.history_count, min(delta_rows, free_rows))

			rem_hist := old.history_count - pull
			g.history_count = min(max_hist, rem_hist)
			for i in 0..<g.history_count {
				src_phys := grid_physical_row(&old, (i - g.history_count) - pull)
				dst_row := &old.rows[src_phys]
				_copy_row_into(g, i - g.history_count, dst_row.cells, dst_row.direct_colors, dst_row.wrap, dst_row.is_prompt)
			}

			for i in 0..<pull {
				src_phys := grid_physical_row(&old, -pull + i)
				dst_row := &old.rows[src_phys]
				_copy_row_into(g, i, dst_row.cells, dst_row.direct_colors, dst_row.wrap, dst_row.is_prompt)
			}

			vis_to_copy := min(old.row_count, target_rows - pull)
			for i in 0..<vis_to_copy {
				src_phys := grid_physical_row(&old, i)
				dst_row := &old.rows[src_phys]
				_copy_row_into(g, pull + i, dst_row.cells, dst_row.direct_colors, dst_row.wrap, dst_row.is_prompt)
			}
			new_cur_r = clamp(cur_r + pull, 0, target_rows - 1)
		}

		if cursor_row != nil do cursor_row^ = new_cur_r
		if cursor_col != nil do cursor_col^ = cur_c

		grid_destroy(&old)
		if d != nil {
			damage.damage_destroy(d)
			damage.damage_init(d, target_rows, target_cols, g.allocator)
			damage.damage_mark_all(d, 1)
		}
		return
	}

	// General path: width changed, reflow visible lines + seam + any history pulled into viewport.
	scratch_alloc := old.allocator

	// 1. Seam coalescence across history/visible boundary
	// If the newest row(s) in history have wrap == true, they continue into row 0.
	seam_cells := make([dynamic]cell.Semantic_Cell, scratch_alloc)
	seam_colors := make([dynamic]cell.Direct_Color, scratch_alloc)
	defer delete(seam_cells)
	defer delete(seam_colors)

	seam_has_prompt := false
	hist_end := -1
	for hist_end >= -old.history_count {
		phys := grid_physical_row(&old, hist_end)
		if old.rows[phys].wrap {
			hist_end -= 1
		} else {
			break
		}
	}
	if hist_end < -1 {
		for r_seam := hist_end + 1; r_seam <= -1; r_seam += 1 {
			phys := grid_physical_row(&old, r_seam)
			r_row := &old.rows[phys]
			if r_row.is_prompt {
				seam_has_prompt = true
			}
			c_len := _row_logical_len(&old, r_seam)
			for c in 0..<c_len {
				append(&seam_cells, r_row.cells[c])
				clr := r_row.direct_colors[c] if c < len(r_row.direct_colors) else cell.Direct_Color{}
				append(&seam_colors, clr)
			}
		}
	}

	// 2. Reflow scrollback history rows (-old.history_count ..= hist_end)
	hist_reflowed: [dynamic]_Reflow_Row
	defer _destroy_reflow_rows(hist_reflowed)
	if hist_end >= -old.history_count {
		dummy_cr, dummy_cc := -999, -999
		dummy_wrap, dummy_found := false, true
		hist_lines := _extract_logical_lines(&old, -old.history_count, hist_end, -999, -999, false, nil, nil, false, -1, scratch_alloc)
		hist_reflowed = _reflow_logical_lines(hist_lines[:], target_cols, &dummy_cr, &dummy_cc, &dummy_wrap, &dummy_found, scratch_alloc)
		_destroy_logical_lines(hist_lines)
	}
	n_hist := len(hist_reflowed)

	// 3. Detect active prompt start row and extract VISIBLE lines (0..=max_active_row)
	prompt_start_r := _detect_active_prompt_start(&old, cur_r)
	vis_lines := _extract_logical_lines(&old, 0, max_active_row, cur_r, cur_c, is_wrap, seam_cells[:], seam_colors[:], seam_has_prompt, prompt_start_r, scratch_alloc)
	defer _destroy_logical_lines(vis_lines)

	new_cursor_row := 0
	new_cursor_col := 0
	new_cursor_pending_wrap := false
	cursor_found := false

	vis_reflowed := _reflow_logical_lines(vis_lines[:], target_cols, &new_cursor_row, &new_cursor_col, &new_cursor_pending_wrap, &cursor_found, scratch_alloc)
	defer _destroy_reflow_rows(vis_reflowed)

	// 4. Initialize target Grid with new capacity
	grid_init(g, target_rows, target_cols, old.allocator)
	max_hist := max(0, g.capacity - target_rows)
	num_vis := len(vis_reflowed)

	disp := 0
	if num_vis <= target_rows {
		delta_rows := max(0, target_rows - old.row_count)
		free_rows := target_rows - num_vis
		max_pull := min(delta_rows, free_rows)
		actual_pull := min(n_hist, max_pull)
		disp = actual_pull

		// Copy pulled history rows into top of visible viewport (0..<actual_pull)
		for i in 0..<actual_pull {
			src_r := &hist_reflowed[(n_hist - actual_pull) + i]
			_copy_row_into(g, i, src_r.cells[:], src_r.direct_colors[:], src_r.wrap, src_r.is_prompt)
		}

		// Copy visible rows after pulled history (actual_pull..<actual_pull + num_vis)
		for i in 0..<num_vis {
			src_r := &vis_reflowed[i]
			_copy_row_into(g, actual_pull + i, src_r.cells[:], src_r.direct_colors[:], src_r.wrap, src_r.is_prompt)
		}

		// Remaining reflowed history rows stay in history (-g.history_count..<0)
		rem_hist := n_hist - actual_pull
		g.history_count = min(max_hist, rem_hist)
		keep_hist := g.history_count
		start_idx := rem_hist - keep_hist
		for i in 0..<keep_hist {
			src_r := &hist_reflowed[start_idx + i]
			_copy_row_into(g, i - keep_hist, src_r.cells[:], src_r.direct_colors[:], src_r.wrap, src_r.is_prompt)
		}

		new_cursor_row = clamp(new_cursor_row + actual_pull, 0, target_rows - 1)
	} else {
		// Visible lines overflow target_rows.
		// Limit overflow to new_cursor_row so cursor line is NEVER pushed into history.
		overflow := min(num_vis - target_rows, new_cursor_row)
		disp = -overflow
		for i in 0..<target_rows {
			src_r := &vis_reflowed[overflow + i]
			_copy_row_into(g, i, src_r.cells[:], src_r.direct_colors[:], src_r.wrap, src_r.is_prompt)
		}
		new_cursor_row -= overflow
		new_cursor_row = clamp(new_cursor_row, 0, target_rows - 1)

		// Total history = all reflowed history rows + overflow rows from visible
		total_hist := n_hist + overflow
		g.history_count = min(max_hist, total_hist)

		// We need the newest g.history_count rows out of (hist_reflowed followed by vis_reflowed[0..<overflow]).
		keep_overflow := min(overflow, g.history_count)
		keep_hist := g.history_count - keep_overflow

		// Copy keep_hist from end of hist_reflowed into (-g.history_count .. -keep_overflow)
		if keep_hist > 0 {
			hist_start := n_hist - keep_hist
			for i in 0..<keep_hist {
				src_r := &hist_reflowed[hist_start + i]
				_copy_row_into(g, i - g.history_count, src_r.cells[:], src_r.direct_colors[:], src_r.wrap, src_r.is_prompt)
			}
		}

		// Copy keep_overflow from vis_reflowed into (-keep_overflow .. 0)
		for i in 0..<keep_overflow {
			src_r := &vis_reflowed[(overflow - keep_overflow) + i]
			_copy_row_into(g, -keep_overflow + i, src_r.cells[:], src_r.direct_colors[:], src_r.wrap, src_r.is_prompt)
		}
	}

	if displacement != nil do displacement^ = disp

	if cursor_row != nil do cursor_row^ = new_cursor_row
	if cursor_col != nil do cursor_col^ = clamp(new_cursor_col, 0, target_cols - 1)
	if cursor_pending_wrap != nil do cursor_pending_wrap^ = new_cursor_pending_wrap

	grid_destroy(&old)
	if d != nil {
		damage.damage_destroy(d)
		damage.damage_init(d, target_rows, target_cols, g.allocator)
		damage.damage_mark_all(d, 1)
	}
}
