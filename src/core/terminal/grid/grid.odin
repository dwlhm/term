package terminal_grid

import "core:slice"
import "base:runtime"
import cell "../cell"
import damage "../damage"

Row :: struct {
	cells:         []cell.Semantic_Cell,
	direct_colors: []cell.Direct_Color,
	generation:    u32,
	occ:           u16, // cells at [occ:] are CELL_DEFAULT with no colour (an upper bound)
	is_prompt:     bool,
	wrap:          bool,
}

DEFAULT_SCROLLBACK :: 2048
GRID_MAX_COLS      :: int(max(u16)) // Row.occ is a u16: keeps Row at 40 bytes for region scrolls

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
	history_limit: int, // 0 for the alternate screen: scrolling never becomes scrollback
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

grid_init :: proc(
	g: ^Grid,
	rows, cols: int,
	allocator: runtime.Allocator = context.allocator,
	history: int = DEFAULT_SCROLLBACK,
) {
	if g == nil do return
	g.row_count = max(1, rows)
	g.col_count = clamp(cols, 1, GRID_MAX_COLS)
	g.capacity = _next_pow2(max(g.row_count, 1) + max(0, history))
	g.mask = g.capacity - 1
	g.origin = 0
	g.history_count = 0
	g.history_limit = clamp(history, 0, g.capacity - g.row_count)
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
	g.history_limit = 0
}

grid_get_row :: proc(g: ^Grid, row: int) -> ^Row {
	if g == nil || row < -g.history_count || row >= g.row_count do return nil
	phys := grid_physical_row(g, row)
	if phys < 0 || phys >= len(g.rows) do return nil
	return &g.rows[phys]
}

grid_get_cell :: proc(g: ^Grid, row, col: int) -> cell.Semantic_Cell {
	if g == nil || row < -g.history_count || row >= g.row_count || col < 0 || col >= g.col_count {
		return cell.CELL_DEFAULT
	}
	phys := grid_physical_row(g, row)
	return g.rows[phys].cells[col]
}

grid_get_direct_color :: proc(g: ^Grid, row, col: int) -> cell.Direct_Color {
	if g == nil || row < -g.history_count || row >= g.row_count || col < 0 || col >= g.col_count {
		return {}
	}
	phys := grid_physical_row(g, row)
	return g.rows[phys].direct_colors[col]
}

grid_get_cell_ptr :: proc(g: ^Grid, row, col: int) -> ^cell.Semantic_Cell {
	if g == nil || row < 0 || row >= g.row_count || col < 0 || col >= g.col_count {
		return nil
	}
	phys := grid_physical_row(g, row)
	return &g.rows[phys].cells[col]
}

grid_set_cell :: proc(g: ^Grid, d: ^damage.Damage_Tracker, row, col: int, c: cell.Semantic_Cell, dc: cell.Direct_Color = {}) -> bool {
	if g == nil || row < 0 || row >= g.row_count || col < 0 || col >= g.col_count {
		return false
	}
	phys := grid_physical_row(g, row)
	r := &g.rows[phys]
	tracks_decoration := .Has_Direct_Color in c.flags || .Has_Hyperlink in c.flags || .Has_Underline_Decor in c.flags
	if r.cells[col] != c || (tracks_decoration && r.direct_colors[col] != dc) {
		r.cells[col] = c
		if tracks_decoration {
			r.direct_colors[col] = dc
		} else {
			r.direct_colors[col] = {}
		}
		r.generation += 1
		r.occ = max(r.occ, u16(col + 1))
		if d != nil {
			damage.damage_mark_cell(d, row, col, r.generation)
		}
	}
	return true
}

grid_clear_line :: proc(
	g: ^Grid,
	d: ^damage.Damage_Tracker,
	row: int,
	col_start: int = 0,
	col_end: int = -1,
	fill: cell.Semantic_Cell = cell.CELL_DEFAULT,
	dc: cell.Direct_Color = {},
) {
	if g == nil || row < 0 || row >= g.row_count do return
	phys := grid_physical_row(g, row)
	r := &g.rows[phys]

	c_end := g.col_count if col_end < 0 else min(g.col_count, col_end)
	c_start := max(0, col_start)
	if c_start >= c_end do return

	// Boundary wide-char sanitization
	blank := fill == cell.CELL_DEFAULT && dc == {}
	if c_start > 0 && .Wide_Continuation in r.cells[c_start].flags {
		r.cells[c_start - 1] = fill
		r.direct_colors[c_start - 1] = dc
	}
	if c_end < g.col_count && .Wide_Continuation in r.cells[c_end].flags {
		r.cells[c_end] = fill
		r.direct_colors[c_end] = dc
		if !blank do r.occ = max(r.occ, u16(c_end + 1))
	}

	if blank {
		// Cells at [occ:] are already blank: only the written part is cleared.
		e := max(c_start, min(c_end, int(r.occ)))
		_fill_cells(r.cells[c_start:e], r.direct_colors[c_start:e], fill, dc)
		if c_end >= int(r.occ) do r.occ = min(r.occ, u16(c_start))
	} else {
		_fill_cells(r.cells[c_start:c_end], r.direct_colors[c_start:c_end], fill, dc)
		r.occ = max(r.occ, u16(c_end))
	}
	if c_start == 0 && c_end >= g.col_count {
		r.wrap = false
		r.is_prompt = false
	}
	r.generation += 1
	if d != nil {
		damage.damage_mark_span(d, row, c_start, c_end, r.generation)
	}
}

grid_clear_all :: proc(
	g: ^Grid,
	d: ^damage.Damage_Tracker,
	fill: cell.Semantic_Cell = cell.CELL_DEFAULT,
	dc: cell.Direct_Color = {},
) {
	if g == nil do return
	for r in 0..<g.row_count {
		grid_clear_line(g, d, r, 0, g.col_count, fill, dc)
	}
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
grid_scroll_up :: proc(
	g: ^Grid,
	d: ^damage.Damage_Tracker,
	top, bottom: int,
	n: int,
	fill: cell.Semantic_Cell = cell.CELL_DEFAULT,
	dc: cell.Direct_Color = {},
) -> int {
	if g == nil || g.row_count == 0 || n <= 0 do return 0
	t := max(0, top)
	b := min(g.row_count - 1, bottom)
	if t >= b do return 0

	actual := min(n, b - t + 1)

	// O(1) fast path: full-screen scroll
	if t == 0 && b == g.row_count - 1 {
		g.origin = (g.origin + actual) & g.mask
		g.history_count = min(g.history_count + actual, g.history_limit)
		// Clear bottom exposed rows
		for i in 0..<actual {
			lr := g.row_count - actual + i
			_row_reset(&g.rows[grid_physical_row(g, lr)], fill, dc)
		}
		if d != nil {
			damage.damage_mark_all(d, 1)
		}
		return actual
	}

	// Sub-region scroll (DECSTBM margins): rotate the Row headers (slices into
	// the pools) inside [t, b]; no cell data moves. The vacated rows end up at
	// the bottom of the region and are reset.
	for i in t..<(b - actual + 1) {
		_swap_rows(g, i, i + actual)
	}
	for i in (b - actual + 1)..=b {
		_row_reset(&g.rows[grid_physical_row(g, i)], fill, dc)
	}
	_mark_region(g, d, t, b)

	return actual
}

// grid_scroll_down scrolls content down by n rows.
grid_scroll_down :: proc(
	g: ^Grid,
	d: ^damage.Damage_Tracker,
	top, bottom: int,
	n: int,
	fill: cell.Semantic_Cell = cell.CELL_DEFAULT,
	dc: cell.Direct_Color = {},
) -> int {
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
			_row_reset(&g.rows[grid_physical_row(g, i)], fill, dc)
		}
		if d != nil {
			damage.damage_mark_all(d, 1)
		}
		return actual
	}

	// Sub-region scroll: rotate Row headers downward; vacated rows end up on top.
	for i := b; i >= t + actual; i -= 1 {
		_swap_rows(g, i, i - actual)
	}
	for i in t..<(t + actual) {
		_row_reset(&g.rows[grid_physical_row(g, i)], fill, dc)
	}
	_mark_region(g, d, t, b)

	return actual
}

grid_resize :: proc(
	g: ^Grid,
	d: ^damage.Damage_Tracker,
	new_rows, new_cols: int,
	cursor_row: ^int = nil,
	cursor_col: ^int = nil,
	cursor_pending_wrap: ^bool = nil,
	displacement: ^int = nil,
) {
	grid_resize_reflow(g, d, new_rows, new_cols, cursor_row, cursor_col, cursor_pending_wrap, displacement)
}

@(private = "file")
_swap_rows :: #force_inline proc(g: ^Grid, a, b: int) {
	pa, pb := grid_physical_row(g, a), grid_physical_row(g, b)
	g.rows[pa], g.rows[pb] = g.rows[pb], g.rows[pa]
}

// _row_reset clears a whole row to `fill`, including its line flags. A blank
// fill only touches the cells written since the last reset (`occ`).
@(private = "file")
_row_reset :: #force_inline proc(r: ^Row, fill: cell.Semantic_Cell, dc: cell.Direct_Color) {
	if fill == cell.CELL_DEFAULT && dc == {} {
		_fill_cells(r.cells[:r.occ], r.direct_colors[:r.occ], fill, dc)
		r.occ = 0
	} else {
		_fill_cells(r.cells, r.direct_colors, fill, dc)
		r.occ = u16(len(r.cells))
	}
	r.generation += 1
	r.wrap = false
	r.is_prompt = false
}

// _fill_cells writes each array in its own pass; the common all-default
// colour is a memset. Cells are stored as u64 words: that loop vectorizes
// (the 4-aligned struct loop does not), and slice.fill's doubling memmoves
// cost more than the stores on the short rows most resets clear.
@(private = "file")
_fill_cells :: #force_inline proc(cells: []cell.Semantic_Cell, colors: []cell.Direct_Color, fill: cell.Semantic_Cell, dc: cell.Direct_Color) {
	#assert(size_of(cell.Semantic_Cell) == size_of(u64))
	word := transmute(u64)fill
	for &w in slice.reinterpret([]u64, cells) do w = word
	if dc == {} {
		slice.zero(colors)
	} else {
		for &c in colors do c = dc
	}
}

// _mark_region bumps the generation of every row in [t, b] and marks it dirty.
@(private = "file")
_mark_region :: proc(g: ^Grid, d: ^damage.Damage_Tracker, t, b: int) {
	for i in t..=b {
		r := &g.rows[grid_physical_row(g, i)]
		r.generation += 1
		if d != nil do damage.damage_mark_row(d, i, r.generation)
	}
}
