package parser

import termgrid "../terminal"

// CSI_Params holds CSI parameters.
CSI_Params :: struct {
	values: [16]u32, // max 16 parameters (DEC limit)
	count:  u8,      // number of parameters collected
}

// csi_collect_param collects a CSI parameter byte.
// Handles digits (0-9), semicolon (;), and colon (:).
csi_collect_param :: proc(p: ^Parser, b: u8) {
	if b >= 0x30 && b <= 0x39 {
		// Digit: accumulate into current parameter
		if p.csi_count < 16 {
			p.csi_values[p.csi_count] = p.csi_values[p.csi_count] * 10 + u32(b - 0x30)
		}
	} else if b == 0x3B {
		// Semicolon: next parameter
		if p.csi_count < 16 {
			p.csi_count += 1
		}
	} else if b == 0x3A {
		// Colon: sub-parameter (treat as semicolon for now)
		if p.csi_count < 16 {
			p.csi_count += 1
		}
	}
}

// csi_dispatch dispatches a CSI sequence.
// Called when the final byte of a CSI sequence is received.
csi_dispatch :: proc(p: ^Parser, t: ^termgrid.Terminal, final_byte: u8) {
	// Build CSI_Params from parser state
	params := CSI_Params{
		values = p.csi_values,
		count  = p.csi_count + 1, // count is 0-indexed, so add 1
	}
	
	// Dispatch based on final byte
	switch final_byte {
	case 'A': // CUU - Cursor Up
		_csi_execute_cuu(t, params)
	case 'B': // CUD - Cursor Down
		_csi_execute_cud(t, params)
	case 'C': // CUF - Cursor Forward
		_csi_execute_cuf(t, params)
	case 'D': // CUB - Cursor Back
		_csi_execute_cub(t, params)
	case 'H': // CUP - Cursor Position
		_csi_execute_cup(t, params)
	case 'J': // ED - Erase in Display
		_csi_execute_ed(t, params)
	case 'K': // EL - Erase in Line
		_csi_execute_el(t, params)
	case 'S': // SU - Scroll Up
		_csi_execute_su(t, params)
	case 'T': // SD - Scroll Down
		_csi_execute_sd(t, params)
	case 'r': // DECSTBM - Set Top and Bottom Margins
		_csi_execute_decstbm(t, params)
	case 'm': // SGR - Select Graphic Rendition
		_csi_execute_sgr(t, params)
	case '@': // ICH - Insert Blank Characters
		_csi_execute_ich(t, params)
	case 'P': // DCH - Delete Characters
		_csi_execute_dch(t, params)
	}
	
	// Reset CSI state
	csi_reset(p)
}

// csi_reset resets CSI parameter state.
csi_reset :: proc(p: ^Parser) {
	for i in 0..<16 {
		p.csi_values[i] = 0
	}
	p.csi_count = 0
}

// _csi_execute_cuu executes Cursor Up (CUU).
_csi_execute_cuu :: proc(t: ^termgrid.Terminal, params: CSI_Params) {
	n := int(params.values[0])
	if n == 0 {
		n = 1
	}
	termgrid.terminal_cursor_up(t, n)
}

// _csi_execute_cud executes Cursor Down (CUD).
_csi_execute_cud :: proc(t: ^termgrid.Terminal, params: CSI_Params) {
	n := int(params.values[0])
	if n == 0 {
		n = 1
	}
	termgrid.terminal_cursor_down(t, n)
}

// _csi_execute_cuf executes Cursor Forward (CUF).
_csi_execute_cuf :: proc(t: ^termgrid.Terminal, params: CSI_Params) {
	n := int(params.values[0])
	if n == 0 {
		n = 1
	}
	termgrid.terminal_cursor_right(t, n)
}

// _csi_execute_cub executes Cursor Back (CUB).
_csi_execute_cub :: proc(t: ^termgrid.Terminal, params: CSI_Params) {
	n := int(params.values[0])
	if n == 0 {
		n = 1
	}
	termgrid.terminal_cursor_left(t, n)
}

// _csi_execute_cup executes Cursor Position (CUP).
_csi_execute_cup :: proc(t: ^termgrid.Terminal, params: CSI_Params) {
	row := int(params.values[0])
	col := int(params.values[1])
	if row == 0 {
		row = 1
	}
	if col == 0 {
		col = 1
	}
	// Convert from 1-indexed to 0-indexed
	termgrid.terminal_move_cursor(t, row - 1, col - 1)
}

// _csi_execute_el executes Erase in Line (EL).
_csi_execute_el :: proc(t: ^termgrid.Terminal, params: CSI_Params) {
	mode := int(params.values[0])
	switch mode {
	case 0:
		termgrid.terminal_erase_line(t, .To_End)
	case 1:
		termgrid.terminal_erase_line(t, .To_Beginning)
	case 2:
		termgrid.terminal_erase_line(t, .Entire)
	}
}

// _csi_execute_ed executes Erase in Display (ED).
_csi_execute_ed :: proc(t: ^termgrid.Terminal, params: CSI_Params) {
	mode := int(params.values[0])
	switch mode {
	case 0:
		termgrid.terminal_erase_display(t, .To_End)
	case 1:
		termgrid.terminal_erase_display(t, .To_Beginning)
	case 2:
		termgrid.terminal_erase_display(t, .Entire)
	}
}

// _csi_execute_su executes Scroll Up (SU).
_csi_execute_su :: proc(t: ^termgrid.Terminal, params: CSI_Params) {
	n := int(params.values[0])
	if n == 0 {
		n = 1
	}
	termgrid.terminal_scroll_up(t, n)
}

// _csi_execute_sd executes Scroll Down (SD).
_csi_execute_sd :: proc(t: ^termgrid.Terminal, params: CSI_Params) {
	n := int(params.values[0])
	if n == 0 {
		n = 1
	}
	termgrid.terminal_scroll_down(t, n)
}

// _csi_execute_decstbm executes Set Top and Bottom Margins (DECSTBM).
// top;bottom r (1-indexed) sets the scroll region; bare r resets to full grid.
_csi_execute_decstbm :: proc(t: ^termgrid.Terminal, params: CSI_Params) {
	rows := t.grid.row_count
	if rows == 0 {
		return
	}

	// Bare r (no params, value 0) resets to full grid.
	if int(params.count) <= 1 && int(params.values[0]) == 0 {
		termgrid.terminal_reset_scroll_region(t)
		return
	}

	top_1: int
	bottom_1: int
	if int(params.count) >= 2 {
		top_1 = int(params.values[0])
		bottom_1 = int(params.values[1])
	} else {
		// Single param: top with bottom defaulting to last row.
		top_1 = int(params.values[0])
		bottom_1 = rows
	}

	// Zero means default: top=1, bottom=R.
	if top_1 == 0 {
		top_1 = 1
	}
	if bottom_1 == 0 {
		bottom_1 = rows
	}

	// Clamp 1-indexed to [1, R], then store 0-indexed.
	if top_1 < 1 {
		top_1 = 1
	}
	if bottom_1 < 1 {
		bottom_1 = 1
	}
	if top_1 > rows {
		top_1 = rows
	}
	if bottom_1 > rows {
		bottom_1 = rows
	}

	// Reject unchanged when top>=bottom (0-indexed comparison).
	top_0 := top_1 - 1
	bottom_0 := bottom_1 - 1
	if !termgrid.terminal_set_scroll_region(t, top_0, bottom_0) {
		// Invalid region (top>=bottom or OOR): leave margins unchanged.
		return
	}
}

// _csi_ich_n clamps the ICH/DCH count: params default 1, bounded by row rest.
_csi_ich_n :: proc(params: CSI_Params, col, cols: int) -> int {
	n := int(params.values[0])
	if n == 0 {
		n = 1
	}
	if avail := cols - col; n > avail {
		n = avail
	}
	return n
}

// _csi_execute_ich executes Insert Blank Characters (ICH).
// Shifts the physical row right by n at cursor.col, fills with blanks.
// Pre-releases the exact handles the shift discards or orphans (row repair
// blanks without releasing): evicted tail, split-pair halves at the shift
// point, and a lead pushed onto the last cell. Cursor unmoved.
_csi_execute_ich :: proc(t: ^termgrid.Terminal, params: CSI_Params) {
	col := t.cursor.col
	cols := t.grid.col_count
	if col < 0 || col >= cols {
		return
	}
	n := _csi_ich_n(params, col, cols)
	if n <= 0 {
		return
	}
	phys := termgrid._grid_physical_row(&t.grid, t.cursor.row)
	cells := t.grid.rows[phys].cells

	// Pre-release only when the pool is non-empty (pure-ASCII stays O(1)).
	if t.grapheme_store.live_count > 0 {
		for i in (len(cells) - n)..<len(cells) {
			termgrid.grapheme_store_release(&t.grapheme_store, cells[i].content)
		}
		if col > 0 && termgrid._row_cell_is_lead(&t.grid.rows[phys], col - 1) {
			termgrid.grapheme_store_release(&t.grapheme_store, cells[col - 1].content)
		}
		if col + n < len(cells) && termgrid._row_cell_is_continuation(&t.grid.rows[phys], col) {
			termgrid.grapheme_store_release(&t.grapheme_store, cells[col].content)
		}
		if len(cells) - 1 >= col + n && termgrid._row_cell_is_lead(&t.grid.rows[phys], len(cells) - 1 - n) {
			termgrid.grapheme_store_release(&t.grapheme_store, cells[len(cells) - 1 - n].content)
		}
	}

	if termgrid.row_insert_cells(&t.grid.rows[phys], col, n) {
		termgrid.damage_mark_row(&t.damage, t.cursor.row, t.grid.rows[phys].generation)
	}
}

// _csi_execute_dch executes Delete Characters (DCH).
// Shifts the physical row left by n at cursor.col, blanks the tail.
// Pre-releases the exact handles the shift discards or orphans: deleted
// cells, split-pair halves at the shift point and before the blank tail
// (tail candidate deduped against the left candidate). Cursor unmoved.
_csi_execute_dch :: proc(t: ^termgrid.Terminal, params: CSI_Params) {
	col := t.cursor.col
	cols := t.grid.col_count
	if col < 0 || col >= cols {
		return
	}
	n := _csi_ich_n(params, col, cols)
	if n <= 0 {
		return
	}
	phys := termgrid._grid_physical_row(&t.grid, t.cursor.row)
	cells := t.grid.rows[phys].cells

	// Pre-release only when the pool is non-empty (pure-ASCII stays O(1)).
	left_idx := col - 1
	tail_idx := len(cells) - n - 1
	if t.grapheme_store.live_count > 0 {
		for i in col..<(col + n) {
			termgrid.grapheme_store_release(&t.grapheme_store, cells[i].content)
		}
		if col > 0 && termgrid._row_cell_is_lead(&t.grid.rows[phys], col - 1) {
			termgrid.grapheme_store_release(&t.grapheme_store, cells[col - 1].content)
		}
		if col + n < len(cells) && termgrid._row_cell_is_continuation(&t.grid.rows[phys], col + n) {
			termgrid.grapheme_store_release(&t.grapheme_store, cells[col + n].content)
		}
		if tail_idx >= 0 && tail_idx != left_idx {
			tail_cell := cells[tail_idx] if tail_idx < col else cells[len(cells) - 1]
			if tail_cell.width == 2 && u8(tail_cell.flags) & u8(termgrid.Cell_Flags.Wide_Continuation) == 0 {
				termgrid.grapheme_store_release(&t.grapheme_store, tail_cell.content)
			}
		}
	}

	if termgrid.row_delete_cells(&t.grid.rows[phys], col, n) {
		termgrid.damage_mark_row(&t.damage, t.cursor.row, t.grid.rows[phys].generation)
	}
}
// _csi_execute_sgr executes Select Graphic Rendition (SGR).
_csi_execute_sgr :: proc(t: ^termgrid.Terminal, params: CSI_Params) {
	// Process each SGR parameter
	for i in 0..<int(params.count) {
		code := int(params.values[i])
		
		switch code {
		case 0: // Reset
			termgrid.terminal_set_style(t, 0)
		case 1: // Bold
			// TODO: implement style attributes
			_ = code
		case 30..=37: // Foreground colors (black, red, green, yellow, blue, magenta, cyan, white)
			// Simple implementation: use palette index
			fg_color := u32(code - 30)
			style := termgrid.Style{
				fg        = fg_color,
				bg        = 0,
				underline = 0,
				flags     = 0,
			}
			// TODO: need access to style table to insert and get ID
			// For now, just set a placeholder
			_ = style
		case 40..=47: // Background colors
			// TODO: implement background colors
			_ = code
		case 39: // Default foreground
			termgrid.terminal_set_style(t, 0)
		case 49: // Default background
			termgrid.terminal_set_style(t, 0)
		}
	}
}
