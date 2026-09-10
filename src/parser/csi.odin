package parser

import termgrid "../terminal"

// CSI_Params holds CSI parameters.
CSI_Params :: struct {
	values: [16]u32, // max 16 parameters (DEC limit)
	count:  u8,      // number of parameters collected
}

// DECTCEM_CURSOR_PARAM is the DEC private mode number for cursor visibility
// (CSI ? 25 h = show, CSI ? 25 l = hide).
DECTCEM_CURSOR_PARAM :: 25

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
// The DEC private marker (?) arrives via the Collect action into
// p.intermediate (vt.odin CSI_Entry/CSI_Param paths), so it is read here
// directly — no signature change needed. intermediate is cleared alongside
// the params so a stale marker never leaks into the next sequence.
csi_dispatch :: proc(p: ^Parser, t: ^termgrid.Terminal, final_byte: u8) {
	// Build CSI_Params from parser state
	params := CSI_Params{
		values = p.csi_values,
		count  = p.csi_count + 1, // count is 0-indexed, so add 1
	}
	private := p.intermediate == '?'
	
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
	case 'h': // SM - Set Mode (private: DECTCEM show)
		if private {
			_csi_execute_dectcem(t, params, true)
		}
	case 'l': // RM - Reset Mode (private: DECTCEM hide)
		if private {
			_csi_execute_dectcem(t, params, false)
		}
	}
	
	// Reset CSI state
	p.intermediate = 0
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

// _csi_execute_dectcem executes DECTCEM (DEC private mode 25): sets cursor
// visibility. Applies when mode 25 is present anywhere in the params
// (multi-param sequences like ? 25 ; 1 h still apply); idempotent.
_csi_execute_dectcem :: proc(t: ^termgrid.Terminal, params: CSI_Params, visible: bool) {
	for i in 0..<int(params.count) {
		if int(params.values[i]) == DECTCEM_CURSOR_PARAM {
			termgrid.terminal_set_cursor_visible(t, visible)
			return
		}
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
// SGR palette (xterm): stored as 0xFFRRGGBB.
_SGR_STANDARD := [8]u32{
	0xFF000000, // black
	0xFFCD0000, // red
	0xFF00CD00, // green
	0xFFCDCD00, // yellow
	0xFF0000EE, // blue
	0xFFCD00CD, // magenta
	0xFF00CDCD, // cyan
	0xFFE5E5E5, // white
}

// SGR bright palette (xterm): stored as 0xFFRRGGBB.
_SGR_BRIGHT := [8]u32{
	0xFF7F7F7F, // bright black
	0xFFFF0000, // bright red
	0xFF00FF00, // bright green
	0xFFFFFF00, // bright yellow
	0xFF5C5CFF, // bright blue
	0xFFFF00FF, // bright magenta
	0xFF00FFFF, // bright cyan
	0xFFFFFFFF, // bright white
}

// _sgr_cube_level maps a 6x6x6 cube component (0..5) to its intensity.
_sgr_cube_level :: proc(v: int) -> u32 {
	levels := [6]u32{0, 95, 135, 175, 215, 255}
	if v < 0 || v > 5 {
		return 0
	}
	return levels[v]
}

// _sgr_palette_256 resolves a 256-color index to 0xFFRRGGBB:
// 0-7 standard, 8-15 bright, 16-231 6x6x6 cube, 232-255 grayscale.
// Out-of-range indices return default white (callers guard bounds).
_sgr_palette_256 :: proc(idx: int) -> u32 {
	if idx < 0 || idx > 255 {
		return termgrid.STYLE_DEFAULT.fg
	}
	if idx < 8 {
		return _SGR_STANDARD[idx]
	}
	if idx < 16 {
		return _SGR_BRIGHT[idx - 8]
	}
	if idx < 232 {
		i := idx - 16
		r := _sgr_cube_level(i / 36)
		g := _sgr_cube_level((i % 36) / 6)
		b := _sgr_cube_level(i % 6)
		return 0xFF000000 | (r << 16) | (g << 8) | b
	}
	g := u32(8 + 10 * (idx - 232))
	return 0xFF000000 | (g << 16) | (g << 8) | g
}

// _sgr_clamp_rgb clamps an SGR truecolor component to 0..255.
_sgr_clamp_rgb :: proc(v: u32) -> u32 {
	if v > 255 {
		return 255
	}
	return v
}

// _csi_execute_sgr executes Select Graphic Rendition (SGR).
// Loads the current style ONCE, mutates a local copy across all params,
// then inserts + sets ONCE (single style-table insert per sequence).
// Unknown codes are ignored (never fail); a truncated 38/48 tail drops
// the tail while prior params still apply.
_csi_execute_sgr :: proc(t: ^termgrid.Terminal, params: CSI_Params) {
	cur := termgrid.style_table_get(&t.grid.style_table, t.current_style)

	count := int(params.count)
	if count == 0 {
		// Bare ESC[m with no params: treat as [0] reset.
		cur = termgrid.STYLE_DEFAULT
		termgrid.terminal_set_style(t, termgrid.style_table_insert(&t.grid.style_table, cur))
		return
	}

	i := 0
	for i < count {
		code := int(params.values[i])

		switch code {
		case 0: // Reset
			cur = termgrid.STYLE_DEFAULT
		case 1: // Bold
			cur.flags |= termgrid.STYLE_FLAG_BOLD
		case 3: // Italic
			cur.flags |= termgrid.STYLE_FLAG_ITALIC
		case 4: // Underline
			cur.flags |= termgrid.STYLE_FLAG_UNDERLINE
		case 7: // Inverse
			cur.flags |= termgrid.STYLE_FLAG_INVERSE
		case 9: // Strike
			cur.flags |= termgrid.STYLE_FLAG_STRIKE
		case 22: // Bold off
			cur.flags = cur.flags & (~termgrid.STYLE_FLAG_BOLD)
		case 23: // Italic off
			cur.flags = cur.flags & (~termgrid.STYLE_FLAG_ITALIC)
		case 24: // Underline off
			cur.flags = cur.flags & (~termgrid.STYLE_FLAG_UNDERLINE)
		case 27: // Inverse off
			cur.flags = cur.flags & (~termgrid.STYLE_FLAG_INVERSE)
		case 29: // Strike off
			cur.flags = cur.flags & (~termgrid.STYLE_FLAG_STRIKE)
		case 30..=37: // Standard foreground
			cur.fg = _sgr_palette_256(code - 30)
		case 40..=47: // Standard background
			cur.bg = _sgr_palette_256(code - 40)
		case 90..=97: // Bright foreground
			cur.fg = _sgr_palette_256(code - 90 + 8)
		case 100..=107: // Bright background
			cur.bg = _sgr_palette_256(code - 100 + 8)
		case 38, 48: // Extended color: 38 fg, 48 bg
			is_fg := code == 38
			if i + 1 >= count {
				// Truncated: lone 38/48, ignore tail.
				i = count
				break
			}
			mode := int(params.values[i + 1])
			if mode == 5 {
				// 256-color: need 2 more values (38;5;idx).
				if i + 2 >= count {
					i = count
					break
				}
				idx := int(params.values[i + 2])
				if idx >= 0 && idx <= 255 {
					c := _sgr_palette_256(idx)
					if is_fg {
						cur.fg = c
					} else {
						cur.bg = c
					}
				}
				i += 2
			} else if mode == 2 {
				// Truecolor: need 4 more values (38;2;r;g;b).
				if i + 4 >= count {
					i = count
					break
				}
				r := _sgr_clamp_rgb(params.values[i + 2])
				g := _sgr_clamp_rgb(params.values[i + 3])
				b := _sgr_clamp_rgb(params.values[i + 4])
				c := 0xFF000000 | (r << 16) | (g << 8) | b
				if is_fg {
					cur.fg = c
				} else {
					cur.bg = c
				}
				i += 4
			} else {
				// Unknown extended mode: swallow the mode byte.
				i += 1
			}
		case 39: // Default foreground (white)
			cur.fg = termgrid.STYLE_DEFAULT.fg
		case 49: // Default background (black)
			cur.bg = termgrid.STYLE_DEFAULT.bg
		}
		i += 1
	}

	termgrid.terminal_set_style(t, termgrid.style_table_insert(&t.grid.style_table, cur))
}
