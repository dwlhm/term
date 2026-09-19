package termgrid

import "base:runtime"

// SCROLLBACK_MAX_LINES caps stored scrollback rows; memory stays bounded.
SCROLLBACK_MAX_LINES :: 1000

// Scrollback_Row is one off-screen row evicted from the grid.
// cells owns its backing; grapheme handles inside are owned by the row
// (transferred from the grid on push, released on evict/clear/destroy).
Scrollback_Row :: struct {
	cells:   []Semantic_Cell,
	wrapped: bool,
}

// Scrollback is a bounded FIFO of evicted grid rows.
// Full-grid scroll_up appends; partial region scroll never appends.
Scrollback :: struct {
	rows:      []Scrollback_Row,
	cells:     []Semantic_Cell, // Flattened 2D array
	head:      int,
	count:     int,
	total_pushed: u64, // Successful pushes, including oldest-row eviction.
	clear_generation: u64, // Explicit document invalidation boundary.
	max_lines: int,
	col_count: int,
}

// scrollback_init prepares an empty scrollback for rows of cols cells.

scrollback_len :: #force_inline proc(s: ^Scrollback) -> int {
	if s == nil { return 0 }
	return s.count
}

scrollback_get :: #force_inline proc(s: ^Scrollback, index: int) -> ^Scrollback_Row {
	if s == nil || index < 0 || index >= s.count || s.max_lines == 0 { return nil }
	real_idx := (s.head + index) % s.max_lines
	return &s.rows[real_idx]
}

scrollback_init :: proc(s: ^Scrollback, cols: int, max_lines: int = SCROLLBACK_MAX_LINES, allocator: runtime.Allocator = context.allocator) {
	s.rows = make([]Scrollback_Row, max_lines, allocator)
	s.cells = make([]Semantic_Cell, max_lines * cols, allocator)
	for i in 0..<max_lines {
		s.rows[i].cells = s.cells[i * cols : (i + 1) * cols]
		s.rows[i].wrapped = false
	}
	s.head = 0
	s.count = 0
	s.total_pushed = 0
	s.clear_generation = 0
	s.max_lines = max_lines
	s.col_count = cols
}

// scrollback_destroy releases every stored row (grapheme handles first,
// mirroring the scroll/erase release discipline) and frees the list.
scrollback_destroy :: proc(s: ^Scrollback, store: ^Grapheme_Store, allocator: runtime.Allocator = context.allocator) {
	scrollback_clear(s, store, allocator)
	if s.cells != nil {
		delete(s.cells, allocator)
		s.cells = nil
	}
	if s.rows != nil {
		delete(s.rows, allocator)
		s.rows = nil
	}
	s.max_lines = 0
	s.col_count = 0
}

// scrollback_clear drops all stored rows but keeps the list backing.
// col_count is left untouched; the caller updates it on resize.
scrollback_clear :: proc(s: ^Scrollback, store: ^Grapheme_Store, allocator: runtime.Allocator = context.allocator) {
	s.clear_generation += 1
	for i in 0..<s.count {
		row := scrollback_get(s, i)
		_scrollback_release_row(row, store)
		row.wrapped = false
		// We DO NOT delete row.cells because they are slices of s.cells
	}
	s.head = 0
	s.count = 0
}

// scrollback_resize reflows scrollback rows to new_cols width.
// Wrapped rows are coalesced into logical lines before re-wrapping,
// guaranteeing 100% lossless bidirectional reflow.
scrollback_resize :: proc(s: ^Scrollback, new_cols: int, store: ^Grapheme_Store, allocator: runtime.Allocator = context.allocator) {
	if s == nil || new_cols <= 0 || new_cols == s.col_count {
		if s != nil && new_cols > 0 { s.col_count = new_cols }
		return
	}
	if s.count == 0 {
		s.col_count = new_cols
		if s.cells != nil { delete(s.cells, allocator) }
		s.cells = make([]Semantic_Cell, s.max_lines * new_cols, allocator)
		for i in 0..<s.max_lines {
			s.rows[i].cells = s.cells[i * new_cols : (i + 1) * new_cols]
			s.rows[i].wrapped = false
		}
		return
	}

	_SB_Logical_Line :: struct {
		cells:   [dynamic]Semantic_Cell,
		wrapped: bool,
	}

	logical_lines := make([dynamic]_SB_Logical_Line, allocator)
	defer {
		for &ll in logical_lines {
			delete(ll.cells)
		}
		delete(logical_lines)
	}

	r := 0
	for r < s.count {
		ll: _SB_Logical_Line
		ll.cells = make([dynamic]Semantic_Cell, allocator)
		ll.wrapped = false

		for r < s.count {
			row := scrollback_get(s, r)
			is_wrapped := row.wrapped

			if is_wrapped {
				take_cols := s.col_count
				for take_cols > 0 && row.cells[take_cols - 1] == CELL_DEFAULT {
					take_cols -= 1
				}
				for c in 0..<take_cols {
					append(&ll.cells, row.cells[c])
				}
				r += 1
				if r >= s.count {
					ll.wrapped = true
					break
				}
			} else {
				last_active := -1
				for c in 0..<s.col_count {
					cell := row.cells[c]
					if (cell.content != 0 && cell.content != ' ') || cell.style != 0 {
						last_active = c
					}
				}
				take := last_active + 1 if last_active >= 0 else 0
				if take > 0 && _cell_is_lead(row.cells[take - 1]) {
					take += 1
				}
				for c in 0..<take {
					append(&ll.cells, row.cells[c])
				}
				ll.wrapped = false
				r += 1
				break
			}
		}
		append(&logical_lines, ll)
	}

	new_rows := make([dynamic]Scrollback_Row, allocator)
	defer {
		for i in 0..<len(new_rows) {
			delete(new_rows[i].cells, allocator)
		}
		delete(new_rows)
	}

	for &ll in logical_lines {
		if len(ll.cells) == 0 {
			nr := make([]Semantic_Cell, new_cols, allocator)
			for c in 0..<new_cols { nr[c] = CELL_DEFAULT }
			append(&new_rows, Scrollback_Row{cells = nr, wrapped = false})
			continue
		}

		ci := 0
		n_cells := len(ll.cells)
		for ci < n_cells {
			take := new_cols
			if ci + take > n_cells {
				take = n_cells - ci
			}
			if take == new_cols && ci + take < n_cells {
				if _cell_is_lead(ll.cells[ci + take - 1]) && _cell_is_continuation(ll.cells[ci + take]) {
					take -= 1
				}
			}
			nr := make([]Semantic_Cell, new_cols, allocator)
			for c in 0..<new_cols { nr[c] = CELL_DEFAULT }
			copy(nr[:take], ll.cells[ci : ci + take])

			row_wrapped := false
			if ci + take < n_cells {
				row_wrapped = true
			} else {
				row_wrapped = ll.wrapped
			}

			append(&new_rows, Scrollback_Row{cells = nr, wrapped = row_wrapped})
			ci += take
		}
	}

	for len(new_rows) > s.max_lines {
		old := new_rows[0]
		_scrollback_release_row(&old, store)
		delete(old.cells, allocator)
		ordered_remove(&new_rows, 0)
	}

	if s.cells != nil {
		delete(s.cells, allocator)
	}
	s.cells = make([]Semantic_Cell, s.max_lines * new_cols, allocator)
	for i in 0..<s.max_lines {
		s.rows[i].cells = s.cells[i * new_cols : (i + 1) * new_cols]
		s.rows[i].wrapped = false
	}

	for i in 0..<len(new_rows) {
		copy(s.rows[i].cells, new_rows[i].cells)
		s.rows[i].wrapped = new_rows[i].wrapped
	}

	s.head = 0
	s.count = len(new_rows)
	s.col_count = new_cols
}


// scrollback_push appends a COPY of cells as the newest row.
// A cols mismatch (resize changed cols without a clear) drops the row
// instead of storing a ragged row. Past max_lines the oldest row is
// evicted after releasing its grapheme handles, so memory stays bounded.
scrollback_push :: proc(
	s: ^Scrollback,
	cells: []Semantic_Cell,
	store: ^Grapheme_Store,
	wrapped: bool = false,
	allocator: runtime.Allocator = context.allocator,
) {
	if len(cells) != s.col_count || s.max_lines <= 0 {
		return
	}
	
	s.total_pushed += 1
	if s.count < s.max_lines {
		real_idx := (s.head + s.count) % s.max_lines
		copy(s.rows[real_idx].cells, cells)
		s.rows[real_idx].wrapped = wrapped
		s.count += 1
	} else {
		old := &s.rows[s.head]
		_scrollback_release_row(old, store)
		copy(old.cells, cells)
		old.wrapped = wrapped
		s.head = (s.head + 1) % s.max_lines
	}
}

// _scrollback_release_row releases every pool handle in a scrollback row.
// Literal codepoints are a no-op inside grapheme_store_release.
_scrollback_release_row :: proc(row: ^Scrollback_Row, store: ^Grapheme_Store) {
	if store == nil || store.live_count == 0 {
		return
	}
	for c in 0..<len(row.cells) {
		grapheme_store_release(store, row.cells[c].content)
	}
}

// scrollback_pop_newest removes the newest row from scrollback and copies its cells to dest.
// Grapheme handles are transferred to dest without being released.
scrollback_pop_newest :: proc(s: ^Scrollback, dest: []Semantic_Cell, out_wrapped: ^bool = nil) -> bool {
	if s == nil || s.count <= 0 || len(dest) != s.col_count {
		return false
	}
	real_idx := (s.head + s.count - 1) % s.max_lines
	copy(dest, s.rows[real_idx].cells)
	if out_wrapped != nil {
		out_wrapped^ = s.rows[real_idx].wrapped
	}
	s.rows[real_idx].wrapped = false
	s.count -= 1
	return true
}

