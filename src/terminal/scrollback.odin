package termgrid

import "base:runtime"

// SCROLLBACK_MAX_LINES caps stored scrollback rows; memory stays bounded.
SCROLLBACK_MAX_LINES :: 1000

// Scrollback_Row is one off-screen row evicted from the grid.
// cells owns its backing; grapheme handles inside are owned by the row
// (transferred from the grid on push, released on evict/clear/destroy).
Scrollback_Row :: struct {
	cells: []Semantic_Cell,
}

// Scrollback is a bounded FIFO of evicted grid rows.
// Full-grid scroll_up appends; partial region scroll never appends.
Scrollback :: struct {
	rows:      [dynamic]Scrollback_Row,
	max_lines: int,
	col_count: int,
}

// scrollback_init prepares an empty scrollback for rows of cols cells.
scrollback_init :: proc(s: ^Scrollback, cols: int, max_lines: int = SCROLLBACK_MAX_LINES, allocator: runtime.Allocator = context.allocator) {
	s.rows = make([dynamic]Scrollback_Row, allocator)
	s.max_lines = max_lines
	s.col_count = cols
}

// scrollback_destroy releases every stored row (grapheme handles first,
// mirroring the scroll/erase release discipline) and frees the list.
scrollback_destroy :: proc(s: ^Scrollback, store: ^Grapheme_Store, allocator: runtime.Allocator = context.allocator) {
	scrollback_clear(s, store, allocator)
	if s.rows != nil {
		delete(s.rows)
		s.rows = nil
	}
	s.max_lines = 0
	s.col_count = 0
}

// scrollback_clear drops all stored rows but keeps the list backing.
// col_count is left untouched; the caller updates it on resize.
scrollback_clear :: proc(s: ^Scrollback, store: ^Grapheme_Store, allocator: runtime.Allocator = context.allocator) {
	for &row in s.rows {
		_scrollback_release_row(&row, store)
		if row.cells != nil {
			delete(row.cells, allocator)
			row.cells = nil
		}
	}
	clear(&s.rows)
}

// scrollback_resize reflows scrollback rows to new_cols width.
// Existing rows have their active cells wrapped or padded into new_cols rows.
// Keeps memory bounded to max_lines, evicting oldest rows if needed.
scrollback_resize :: proc(s: ^Scrollback, new_cols: int, store: ^Grapheme_Store, allocator: runtime.Allocator = context.allocator) {
	if s == nil || new_cols <= 0 || new_cols == s.col_count {
		if s != nil && new_cols > 0 { s.col_count = new_cols }
		return
	}
	if len(s.rows) == 0 {
		s.col_count = new_cols
		return
	}

	new_rows := make([dynamic]Scrollback_Row, allocator)

	for &old_row in s.rows {
		old_cells := old_row.cells
		// Find last active column in old_cells
		last_active := -1
		for c in 0..<len(old_cells) {
			cell := old_cells[c]
			if (cell.content != 0 && cell.content != ' ') || cell.style != 0 {
				last_active = c
			}
		}
		active_len := last_active >= 0 ? last_active + 1 : 0

		if active_len == 0 {
			// Empty row: store 1 empty row of new_cols
			empty_row := make([]Semantic_Cell, new_cols, allocator)
			for k in 0..<new_cols { empty_row[k] = CELL_DEFAULT }
			append(&new_rows, Scrollback_Row{cells = empty_row})
		} else {
			ci := 0
			for ci < active_len {
				take := min(active_len - ci, new_cols)
				chunk := make([]Semantic_Cell, new_cols, allocator)
				for k in 0..<take {
					chunk[k] = old_cells[ci + k]
				}
				for k in take..<new_cols {
					chunk[k] = CELL_DEFAULT
				}
				append(&new_rows, Scrollback_Row{cells = chunk})
				ci += take
			}
		}
		// Clean up old_row.cells backing (we copied handles, so don't release handles, just delete slice)
		delete(old_row.cells, allocator)
	}

	// Keep memory bounded to s.max_lines
	for len(new_rows) > s.max_lines {
		old := new_rows[0]
		_scrollback_release_row(&old, store)
		delete(old.cells, allocator)
		ordered_remove(&new_rows, 0)
	}

	delete(s.rows)
	s.rows = new_rows
	s.col_count = new_cols
}


// scrollback_push appends a COPY of cells as the newest row.
// A cols mismatch (resize changed cols without a clear) drops the row
// instead of storing a ragged row. Past max_lines the oldest row is
// evicted after releasing its grapheme handles, so memory stays bounded.
scrollback_push :: proc(s: ^Scrollback, cells: []Semantic_Cell, store: ^Grapheme_Store, allocator: runtime.Allocator = context.allocator) {
	if len(cells) != s.col_count {
		return
	}
	cp := make([]Semantic_Cell, len(cells), allocator)
	copy(cp, cells)
	append(&s.rows, Scrollback_Row{cells = cp})
	if len(s.rows) > s.max_lines {
		old := s.rows[0]
		_scrollback_release_row(&old, store)
		delete(old.cells, allocator)
		ordered_remove(&s.rows, 0)
	}
}

// _scrollback_release_row releases every pool handle in a scrollback row.
// Literal codepoints are a no-op inside grapheme_store_release.
_scrollback_release_row :: proc(row: ^Scrollback_Row, store: ^Grapheme_Store) {
	if store.live_count == 0 {
		return
	}
	for c in 0..<len(row.cells) {
		grapheme_store_release(store, row.cells[c].content)
	}
}
