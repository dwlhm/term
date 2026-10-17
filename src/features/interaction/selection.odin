package feature_interaction

// Selection Models & Coordinate Storage (Tier 2 Feature Primitive).
// Pure data structure and geometric calculation layer.
// Independent of windowing libraries (Zero SDL3/OS leaks).

import terminal_grid "../../core/terminal/grid"

Cell_Pos :: struct {
	row: int,
	col: int,
}

Selection_Mode :: enum u8 {
	Stream,
	Block,
	Line,
	Word,
}

Selection_State :: struct {
	active:     bool,
	mode:       Selection_Mode,
	pane_id:    u32,
	start_cell: Cell_Pos,
	end_cell:   Cell_Pos,
}

// Backward-compatible aliases
Mouse_Selection :: Selection_State
Text_Selection  :: Selection_State

// Normalized_Selection holds selection bounds guaranteed to be in document order.
Normalized_Selection :: struct {
	start_row, start_col: int,
	end_row,   end_col:   int,
	mode:                 Selection_Mode,
}

selection_init :: proc(s: ^Selection_State) {
	if s == nil do return
	s.active = false
	s.mode = .Stream
	s.pane_id = 0
	s.start_cell = {}
	s.end_cell = {}
}

selection_clear :: proc(s: ^Selection_State) {
	if s == nil do return
	s.active = false
}

// selection_normalize sorts selection endpoints into top-to-bottom, left-to-right order.
selection_normalize :: proc(sel: Selection_State) -> (norm: Normalized_Selection, ok: bool) {
	if !sel.active do return {}, false
	sr, sc := sel.start_cell.row, sel.start_cell.col
	er, ec := sel.end_cell.row, sel.end_cell.col
	if sr > er || (sr == er && sc > ec) {
		sr, er = er, sr
		sc, ec = ec, sc
	}
	return Normalized_Selection{
		start_row = sr, start_col = sc,
		end_row   = er, end_col   = ec,
		mode      = sel.mode,
	}, true
}

// selection_contains_cell reports whether a given cell (r, c) falls inside the active selection.
selection_contains_cell :: proc(sel: Selection_State, r, c: int) -> bool {
	norm, ok := selection_normalize(sel)
	if !ok do return false

	#partial switch norm.mode {
	case .Block:
		min_c := min(norm.start_col, norm.end_col)
		max_c := max(norm.start_col, norm.end_col)
		return r >= norm.start_row && r <= norm.end_row && c >= min_c && c <= max_c

	case: // .Stream, .Line, .Word
		if r > norm.start_row && r < norm.end_row do return true
		if r == norm.start_row && r == norm.end_row do return c >= norm.start_col && c <= norm.end_col
		if r == norm.start_row do return c >= norm.start_col
		if r == norm.end_row   do return c <= norm.end_col
		return false
	}
}

// selection_row_bounds computes the active column range for row `r` within the selection.
selection_row_bounds :: proc(norm: Normalized_Selection, r, row_len: int) -> (start_c, end_c: int, valid: bool) {
	if r < norm.start_row || r > norm.end_row || row_len <= 0 do return 0, 0, false

	#partial switch norm.mode {
	case .Block:
		min_c := clamp(min(norm.start_col, norm.end_col), 0, row_len - 1)
		max_c := clamp(max(norm.start_col, norm.end_col), 0, row_len - 1)
		return min_c, max_c, true

	case: // .Stream, .Line, .Word
		start_c = 0
		end_c = row_len - 1
		if r == norm.start_row && r == norm.end_row {
			start_c = norm.start_col
			end_c = min(norm.end_col, row_len - 1)
		} else if r == norm.start_row {
			start_c = norm.start_col
		} else if r == norm.end_row {
			end_c = min(norm.end_col, row_len - 1)
		}
		return start_c, end_c, true
	}
}

// pixel_to_cell transforms pixel coordinates to terminal cell coordinates.
pixel_to_cell :: proc(pos: [2]f32, pane_rect: [4]f32, cell_w, cell_h: f32, pad_x: f32 = 12.0, pad_y: f32 = 8.0) -> (row: int, col: int) {
	local_x := max(0.0, pos[0] - (pane_rect[0] + pad_x))
	local_y := max(0.0, pos[1] - (pane_rect[1] + pad_y))

	col = int(local_x / max(1.0, cell_w))
	row = int(local_y / max(1.0, cell_h))
	return row, col
}

// Backward-compatible alias
mouse_pixel_to_cell :: pixel_to_cell

// is_in_rect checks if a point lies within a bounding box.
is_in_rect :: proc(pos: [2]f32, rect: [4]f32) -> bool {
	return pos[0] >= rect[0] && pos[0] <= rect[0] + rect[2] &&
	       pos[1] >= rect[1] && pos[1] <= rect[1] + rect[3]
}

// Backward-compatible alias
mouse_is_in_rect :: is_in_rect

Char_Class :: enum u8 {
	Whitespace,
	Word,
	Punctuation,
}

char_class :: proc(ch: rune) -> Char_Class {
	if ch == 0 || ch == ' ' || ch == '\t' do return .Whitespace
	if (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_' || ch > 127 {
		return .Word
	}
	return .Punctuation
}

// word_find_bounds determines the [start_col, end_col] boundaries of the word containing `col` on a grid row.
word_find_bounds :: proc(row: ^terminal_grid.Row, col: int) -> (start_col, end_col: int) {
	if row == nil || len(row.cells) == 0 do return 0, 0
	c := clamp(col, 0, len(row.cells) - 1)
	target_class := char_class(row.cells[c].char)

	start_col = c
	for start_col > 0 && char_class(row.cells[start_col - 1].char) == target_class {
		start_col -= 1
	}

	end_col = c
	for end_col < len(row.cells) - 1 && char_class(row.cells[end_col + 1].char) == target_class {
		end_col += 1
	}

	return start_col, end_col
}

// line_find_bounds returns the column boundaries for an entire line.
line_find_bounds :: proc(cols: int) -> (start_col, end_col: int) {
	return 0, max(0, cols - 1)
}
