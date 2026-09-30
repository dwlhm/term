package termgrid

import "core:strings"

// Terminal_Point identifies one cell in the combined scrollback document.
// Row zero is the oldest retained row; live grid rows follow scrollback.rows.
Terminal_Point :: struct {
	row: int,
	col: int,
}

// Terminal_Selection stores the two endpoints of a local text selection.
// Endpoints are inclusive and are normalized before they are queried.
Terminal_Selection :: struct {
	active: bool,
	block:  bool,
	anchor: Terminal_Point,
	focus:  Terminal_Point,
}

// Terminal_View is local viewport and selection state. It never changes the
// terminal grid, its ring origin, or the scrollback FIFO.
Terminal_View :: struct {
	scrollback_offset: int,
	selection:         Terminal_Selection,
	visual_mode:       bool,
}

// terminal_view_max_offset returns the number of retained history rows that
// can be placed above the live grid viewport.
terminal_view_max_offset :: proc(t: ^Terminal) -> int {
	if t == nil || t.is_alt_screen {
		return 0
	}
	return scrollback_len(&t.scrollback)
}

// terminal_view_set_offset clamps a local scrollback offset to the retained
// history and returns the resulting offset.
terminal_view_set_offset :: proc(view: ^Terminal_View, t: ^Terminal, offset: int) -> int {
	if view == nil {
		return 0
	}
	max_offset := terminal_view_max_offset(t)
	view.scrollback_offset = clamp(offset, 0, max_offset)
	return view.scrollback_offset
}

// terminal_view_scroll adjusts the local scrollback offset without changing
// terminal content or the terminal's ring-buffer origin.
terminal_view_scroll :: proc(view: ^Terminal_View, t: ^Terminal, delta: int) -> int {
	if view == nil {
		return 0
	}
	return terminal_view_set_offset(view, t, view.scrollback_offset+delta)
}

// terminal_view_document_row maps a visible viewport row to a combined
// scrollback/live row. Invalid rows return -1.
terminal_view_document_row :: proc(t: ^Terminal, view: ^Terminal_View, viewport_row: int) -> int {
	if t == nil || view == nil || viewport_row < 0 || viewport_row >= t.grid.row_count {
		return -1
	}
	offset := clamp(view.scrollback_offset, 0, terminal_view_max_offset(t))
	return scrollback_len(&t.scrollback) - offset + viewport_row
}

// terminal_view_point_from_viewport maps a visible local point to a document
// point and clamps its column to the live grid width.
terminal_view_point_from_viewport :: proc(t: ^Terminal, view: ^Terminal_View, viewport: Terminal_Point) -> Terminal_Point {
	point := Terminal_Point{}
	if t == nil || view == nil || t.grid.row_count <= 0 || t.grid.col_count <= 0 {
		return point
	}
	point.row = terminal_view_document_row(t, view, viewport.row)
	if point.row < 0 {
		point.row = 0
	}
	point.col = clamp(viewport.col, 0, t.grid.col_count-1)
	return point
}

// terminal_view_get_cell reads a cell from the local viewport. It maps
// retained history before live Grid rows and returns CELL_DEFAULT at a
// boundary.
terminal_view_get_cell :: proc(t: ^Terminal, view: ^Terminal_View, viewport_row, col: int) -> Semantic_Cell {
	if t == nil || view == nil || viewport_row < 0 || viewport_row >= t.grid.row_count {
		return CELL_DEFAULT
	}
	if col < 0 || col >= t.grid.col_count {
		return CELL_DEFAULT
	}
	document_row := terminal_view_document_row(t, view, viewport_row)
	if document_row < 0 {
		return CELL_DEFAULT
	}
	if document_row < scrollback_len(&t.scrollback) {
		row := scrollback_get(&t.scrollback, document_row)^
		if col < len(row.cells) {
			return row.cells[col]
		}
		return CELL_DEFAULT
	}
	return grid_get_cell(&t.grid, document_row-scrollback_len(&t.scrollback), col)
}

// terminal_view_get_document_cell reads one combined-document cell without
// converting it through viewport coordinates.
terminal_view_get_document_cell :: proc(t: ^Terminal, point: Terminal_Point) -> Semantic_Cell {
	if t == nil || point.row < 0 || point.col < 0 || point.col >= t.grid.col_count {
		return CELL_DEFAULT
	}
	if point.row < scrollback_len(&t.scrollback) {
		row := scrollback_get(&t.scrollback, point.row)^
		if point.col < len(row.cells) {
			return row.cells[point.col]
		}
		return CELL_DEFAULT
	}
	return grid_get_cell(&t.grid, point.row-scrollback_len(&t.scrollback), point.col)
}

// terminal_view_normalize_point clamps a document point and moves a wide
// continuation endpoint to its wide lead cell.
terminal_view_normalize_point :: proc(t: ^Terminal, point: Terminal_Point) -> Terminal_Point {
	if t == nil || t.grid.row_count <= 0 || t.grid.col_count <= 0 {
		return Terminal_Point{}
	}
	total_rows := scrollback_len(&t.scrollback) + t.grid.row_count
	result := point
	result.row = clamp(result.row, 0, total_rows-1)
	result.col = clamp(result.col, 0, t.grid.col_count-1)
	cell := terminal_view_get_document_cell(t, result)
	if u8(cell.flags) & u8(Cell_Flags.Wide_Continuation) != 0 && result.col > 0 {
		result.col -= 1
	}
	return result
}

// terminal_view_selection_bounds returns normalized inclusive selection
// bounds. Inactive or empty selections return false.
terminal_view_selection_bounds :: proc(t: ^Terminal, view: ^Terminal_View) -> (start, end: Terminal_Point, ok: bool) {
	if t == nil || view == nil || !view.selection.active || t.grid.row_count <= 0 || t.grid.col_count <= 0 {
		return Terminal_Point{}, Terminal_Point{}, false
	}
	start = terminal_view_normalize_point(t, view.selection.anchor)
	end = terminal_view_normalize_point(t, view.selection.focus)
	if start.row > end.row || (start.row == end.row && start.col > end.col) {
		start, end = end, start
	}
	return start, end, true
}

// terminal_view_selection_contains reports whether a document point falls
// inside the normalized inclusive selection range.
terminal_view_selection_contains :: proc(t: ^Terminal, view: ^Terminal_View, point: Terminal_Point) -> bool {
	start, end, ok := terminal_view_selection_bounds(t, view)
	if !ok {
		return false
	}
	p := terminal_view_normalize_point(t, point)
	if view.selection.block {
		min_row := min(start.row, end.row)
		max_row := max(start.row, end.row)
		min_col := min(start.col, end.col)
		max_col := max(start.col, end.col)
		return p.row >= min_row && p.row <= max_row && p.col >= min_col && p.col <= max_col
	}
	if p.row < start.row || p.row > end.row {
		return false
	}
	if p.row == start.row && p.col < start.col {
		return false
	}
	if p.row == end.row && p.col > end.col {
		return false
	}
	return true
}

// terminal_view_copy generates selected text with trailing blank cells
// removed from every line, newline separators preserved, and bounded
// grapheme marks emitted after their resolved base rune.
terminal_view_copy :: proc(t: ^Terminal, view: ^Terminal_View) -> string {
	start, end, ok := terminal_view_selection_bounds(t, view)
	if !ok {
		return ""
	}
	b := strings.builder_make()
	for row := start.row; row <= end.row; row += 1 {
		if row > start.row {
			strings.write_rune(&b, '\n')
		}
		line_start := 0
		line_end := t.grid.col_count-1
		if view.selection.block {
			line_start = min(start.col, end.col)
			line_end = min(max(start.col, end.col), t.grid.col_count-1)
		} else {
			line_start = row == start.row ? start.col : 0
			line_end = row == end.row ? end.col : t.grid.col_count-1
		}
		last := line_end
		for last >= line_start {
			cell := terminal_view_get_document_cell(t, Terminal_Point{row = row, col = last})
			if !_terminal_view_cell_is_blank(cell) {
				break
			}
			last -= 1
		}
		for col := line_start; col <= last; col += 1 {
			_terminal_view_write_cell(&b, terminal_view_get_document_cell(t, Terminal_Point{row = row, col = col}), &t.grapheme_store)
		}
	}
	return strings.to_string(b)
}

// _terminal_view_cell_is_blank treats empty cells and literal spaces as
// trailing copy padding while preserving non-space content.
_terminal_view_cell_is_blank :: proc(cell: Semantic_Cell) -> bool {
	return cell.content == 0 || cell.content == Content_Handle(' ')
}

// _terminal_view_write_cell writes one cell's printable base and bounded
// combining marks. Blank and wide-continuation cells are represented by no
// additional text because their lead cell owns the grapheme content.
_terminal_view_write_cell :: proc(b: ^strings.Builder, cell: Semantic_Cell, store: ^Grapheme_Store) {
	if cell.content == 0 || u8(cell.flags) & u8(Cell_Flags.Wide_Continuation) != 0 {
		return
	}
	if !content_is_grapheme(cell.content) {
		strings.write_rune(b, rune(cell.content))
		return
	}
	idx := int(cell.content - CONTENT_GRAPHEME_BASE)
	if idx < 0 || idx >= GRAPHEME_STORE_CAP {
		strings.write_rune(b, grapheme_resolve_base(cell.content, store))
		return
	}
	cluster := store.entries[idx]
	count := min(int(cluster.rune_count), GRAPHEME_INLINE_CAP)
	for i in 0..<count {
		strings.write_rune(b, cluster.runes[i])
	}
}

// terminal_view_get_direct_color returns a pointer to the cell's Direct_Color_Channel if the row has .Direct_Color active.
terminal_view_get_direct_color :: proc(t: ^Terminal, view: ^Terminal_View, viewport_row, col: int) -> ^Direct_Color_Channel {
	if t == nil do return nil
	if view != nil {
		document_row := terminal_view_document_row(t, view, viewport_row)
		if document_row < 0 do return nil
		sb_len := scrollback_len(&t.scrollback)
		if document_row < sb_len {
			sb_row := scrollback_get(&t.scrollback, document_row)
			if sb_row != nil && .Direct_Color in sb_row.ext.channels && col >= 0 && col < len(sb_row.ext.colors) {
				return &sb_row.ext.colors[col]
			}
			return nil
		}
		live_row := document_row - sb_len
		if live_row < 0 || live_row >= t.grid.row_count do return nil
		phys := _grid_physical_row(&t.grid, live_row)
		row := &t.grid.rows[phys]
		if .Direct_Color in row.ext.channels && col >= 0 && col < len(row.ext.colors) {
			return &row.ext.colors[col]
		}
		return nil
	}
	if viewport_row < 0 || viewport_row >= t.grid.row_count do return nil
	phys := _grid_physical_row(&t.grid, viewport_row)
	row := &t.grid.rows[phys]
	if .Direct_Color in row.ext.channels && col >= 0 && col < len(row.ext.colors) {
		return &row.ext.colors[col]
	}
	return nil
}
