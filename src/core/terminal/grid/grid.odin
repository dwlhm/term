package terminal_grid

import "base:runtime"
import cell "../cell"
import damage "../damage"

Row :: struct {
	cells:         []cell.Semantic_Cell,
	direct_colors: []cell.Direct_Color,
	generation:    u32,
	is_prompt:     bool,
	wrap:          bool,
}

DEFAULT_SCROLLBACK :: 2048

Grid :: struct {
	rows:          []Row,
	cells_pool:    []cell.Semantic_Cell,
	colors_pool:   []cell.Direct_Color,
	row_count:     int,
	col_count:     int,
	capacity:      int,
	mask:          int,
	origin:        int,
	history_count: int,
	allocator:     runtime.Allocator,
}

_next_pow2 :: proc(n: int) -> int {
	if n <= 1 do return 1
	p := 1
	for p < n {
		p <<= 1
	}
	return p
}

grid_physical_row :: proc(g: ^Grid, logical_row: int) -> int {
	if g == nil || g.capacity == 0 do return 0
	idx := (g.origin + logical_row) % g.capacity
	if idx < 0 do idx += g.capacity
	return idx
}

grid_init :: proc(g: ^Grid, rows, cols: int, allocator: runtime.Allocator = context.allocator) {
	if g == nil do return
	g.row_count = max(1, rows)
	g.col_count = max(1, cols)
	g.capacity = _next_pow2(max(g.row_count, 1) + DEFAULT_SCROLLBACK)
	g.mask = g.capacity - 1
	g.origin = 0
	g.history_count = 0
	g.allocator = allocator

	total_cells := g.capacity * g.col_count
	g.cells_pool = make([]cell.Semantic_Cell, total_cells, allocator)
	g.colors_pool = make([]cell.Direct_Color, total_cells, allocator)
	g.rows = make([]Row, g.capacity, allocator)

	for i in 0..<g.capacity {
		offset := i * g.col_count
		g.rows[i] = Row{
			cells         = g.cells_pool[offset : offset + g.col_count],
			direct_colors = g.colors_pool[offset : offset + g.col_count],
			generation    = 1,
			is_prompt     = false,
			wrap          = false,
		}
		for c in 0..<g.col_count {
			g.rows[i].cells[c] = cell.CELL_DEFAULT
		}
	}
}

grid_destroy :: proc(g: ^Grid) {
	if g == nil do return
	if len(g.rows) > 0 {
		delete(g.rows, g.allocator)
		g.rows = nil
	}
	if len(g.cells_pool) > 0 {
		delete(g.cells_pool, g.allocator)
		g.cells_pool = nil
	}
	if len(g.colors_pool) > 0 {
		delete(g.colors_pool, g.allocator)
		g.colors_pool = nil
	}
	g.row_count = 0
	g.col_count = 0
	g.capacity = 0
	g.origin = 0
	g.history_count = 0
}

grid_get_cell :: proc(g: ^Grid, row, col: int) -> cell.Semantic_Cell {
	if g == nil || row < -g.history_count || row >= g.row_count || col < 0 || col >= g.col_count {
		return cell.CELL_DEFAULT
	}
	phys := grid_physical_row(g, row)
	return g.rows[phys].cells[col]
}

grid_get_cell_ptr :: proc(g: ^Grid, row, col: int) -> ^cell.Semantic_Cell {
	if g == nil || row < 0 || row >= g.row_count || col < 0 || col >= g.col_count {
		return nil
	}
	phys := grid_physical_row(g, row)
	return &g.rows[phys].cells[col]
}

grid_set_cell :: proc(g: ^Grid, d: ^damage.Damage_Tracker, row, col: int, c: cell.Semantic_Cell) -> bool {
	if g == nil || row < 0 || row >= g.row_count || col < 0 || col >= g.col_count {
		return false
	}
	phys := grid_physical_row(g, row)
	r := &g.rows[phys]
	if r.cells[col] != c {
		r.cells[col] = c
		r.generation += 1
		if d != nil {
			damage.damage_mark_cell(d, row, col, r.generation)
		}
	}
	return true
}

grid_clear_line :: proc(g: ^Grid, d: ^damage.Damage_Tracker, row: int, col_start: int = 0, col_end: int = -1) {
	if g == nil || row < 0 || row >= g.row_count do return
	phys := grid_physical_row(g, row)
	r := &g.rows[phys]

	c_end := g.col_count if col_end < 0 else min(g.col_count, col_end)
	c_start := max(0, col_start)
	if c_start >= c_end do return

	for c in c_start..<c_end {
		r.cells[c] = cell.CELL_DEFAULT
	}
	r.generation += 1
	if d != nil {
		damage.damage_mark_span(d, row, c_start, c_end, r.generation)
	}
}

grid_clear_all :: proc(g: ^Grid, d: ^damage.Damage_Tracker) {
	if g == nil do return
	for r in 0..<g.row_count {
		grid_clear_line(g, d, r, 0, g.col_count)
	}
	g.origin = 0
	if d != nil {
		damage.damage_mark_all(d, 1)
	}
}

grid_clear_history :: proc(g: ^Grid) {
	if g == nil do return
	g.history_count = 0
}

// grid_scroll_up scrolls content up by n rows.
// If scrolling the entire grid (0 to row_count-1), it executes in O(1) via ring buffer origin shift.
grid_scroll_up :: proc(g: ^Grid, d: ^damage.Damage_Tracker, top, bottom: int, n: int) -> int {
	if g == nil || g.row_count == 0 || n <= 0 do return 0
	t := max(0, top)
	b := min(g.row_count - 1, bottom)
	if t >= b do return 0

	actual := min(n, b - t + 1)

	// O(1) fast path: full-screen scroll
	if t == 0 && b == g.row_count - 1 {
		g.origin = (g.origin + actual) & g.mask
		g.history_count = min(g.history_count + actual, g.capacity - g.row_count)
		// Clear bottom exposed rows
		for i in 0..<actual {
			lr := g.row_count - actual + i
			phys := grid_physical_row(g, lr)
			r := &g.rows[phys]
			for c in 0..<g.col_count {
				r.cells[c] = cell.CELL_DEFAULT
			}
			r.generation += 1
			r.wrap = false
			r.is_prompt = false
		}
		if d != nil {
			damage.damage_mark_all(d, 1)
		}
		return actual
	}

	// Sub-region scroll (DECSTBM margins): copy row pointers in subregion
	for i in t..<(b - actual + 1) {
		src_phys := grid_physical_row(g, i + actual)
		dst_phys := grid_physical_row(g, i)
		copy(g.rows[dst_phys].cells, g.rows[src_phys].cells)
		g.rows[dst_phys].generation += 1
		g.rows[dst_phys].wrap = g.rows[src_phys].wrap
		g.rows[dst_phys].is_prompt = g.rows[src_phys].is_prompt
		if d != nil {
			damage.damage_mark_row(d, i, g.rows[dst_phys].generation)
		}
	}
	for i in (b - actual + 1)..=b {
		phys := grid_physical_row(g, i)
		r := &g.rows[phys]
		for c in 0..<g.col_count {
			r.cells[c] = cell.CELL_DEFAULT
		}
		r.generation += 1
		r.wrap = false
		r.is_prompt = false
		if d != nil {
			damage.damage_mark_row(d, i, r.generation)
		}
	}

	return actual
}

// grid_scroll_down scrolls content down by n rows.
grid_scroll_down :: proc(g: ^Grid, d: ^damage.Damage_Tracker, top, bottom: int, n: int) -> int {
	if g == nil || g.row_count == 0 || n <= 0 do return 0
	t := max(0, top)
	b := min(g.row_count - 1, bottom)
	if t >= b do return 0

	actual := min(n, b - t + 1)

	// O(1) fast path: full-screen scroll
	if t == 0 && b == g.row_count - 1 {
		g.origin = (g.origin - actual + g.capacity) & g.mask
		// Clear top exposed rows
		for i in 0..<actual {
			phys := grid_physical_row(g, i)
			r := &g.rows[phys]
			for c in 0..<g.col_count {
				r.cells[c] = cell.CELL_DEFAULT
			}
			r.generation += 1
			r.wrap = false
			r.is_prompt = false
		}
		if d != nil {
			damage.damage_mark_all(d, 1)
		}
		return actual
	}

	// Sub-region scroll: copy downward from bottom to top
	for i := b; i >= t + actual; i -= 1 {
		src_phys := grid_physical_row(g, i - actual)
		dst_phys := grid_physical_row(g, i)
		copy(g.rows[dst_phys].cells, g.rows[src_phys].cells)
		g.rows[dst_phys].generation += 1
		g.rows[dst_phys].wrap = g.rows[src_phys].wrap
		g.rows[dst_phys].is_prompt = g.rows[src_phys].is_prompt
		if d != nil {
			damage.damage_mark_row(d, i, g.rows[dst_phys].generation)
		}
	}
	for i in t..<(t + actual) {
		phys := grid_physical_row(g, i)
		r := &g.rows[phys]
		for c in 0..<g.col_count {
			r.cells[c] = cell.CELL_DEFAULT
		}
		r.generation += 1
		r.wrap = false
		r.is_prompt = false
		if d != nil {
			damage.damage_mark_row(d, i, r.generation)
		}
	}

	return actual
}

grid_resize :: proc(g: ^Grid, d: ^damage.Damage_Tracker, new_rows, new_cols: int) {
	if g == nil || (new_rows == g.row_count && new_cols == g.col_count) do return

	old := g^
	grid_init(g, new_rows, new_cols, old.allocator)

	// Copy existing visible cells up to min dimensions
	min_r := min(old.row_count, new_rows)
	min_c := min(old.col_count, new_cols)
	for r in 0..<min_r {
		old_phys := grid_physical_row(&old, r)
		new_phys := grid_physical_row(g, r)
		copy(g.rows[new_phys].cells[:min_c], old.rows[old_phys].cells[:min_c])
		g.rows[new_phys].generation = 1
	}

	grid_destroy(&old)

	if d != nil {
		damage.damage_destroy(d)
		damage.damage_init(d, new_rows, new_cols, g.allocator)
		damage.damage_mark_all(d, 1)
	}
}
