package parser

import termgrid "../terminal"

// CSI_Params holds CSI parameters.
// subparam_mask bit i is 1 when values[i] was introduced by a colon (ECMA-48
// sub-parameter) rather than a semicolon. SGR uses this to distinguish
// colon-joined forms (4:2 underline style, 38:2::R:G:B truecolor) from
// semicolon-separated codes (4;2 = underline + dim).
CSI_Params :: struct {
	values:        [16]u32, // max 16 parameters (DEC limit)
	subparam_mask: u16,     // bit i = 1 if parameter i was introduced by ':'
	count:         u8,      // number of parameters collected
}

// csi_is_subparam reports whether parameter idx was introduced by a colon.
csi_is_subparam :: proc(params: CSI_Params, idx: int) -> bool {
	if idx < 0 || idx >= 16 {
		return false
	}
	return (params.subparam_mask & (u16(1) << u16(idx))) != 0
}

// DECTCEM_CURSOR_PARAM is the DEC private mode number for cursor visibility
// (CSI ? 25 h = show, CSI ? 25 l = hide).
DECTCEM_CURSOR_PARAM :: 25

// ALT_SCREEN_PARAM is the DEC private mode number for alternate screen buffer (CSI ? 1049 h/l).
ALT_SCREEN_PARAM :: 1049

// ALT_SCREEN_PARAM_LEGACY is the legacy DEC private mode number for alternate screen buffer (CSI ? 47 h/l).
ALT_SCREEN_PARAM_LEGACY :: 47

// csi_collect_param collects a CSI parameter byte.
// Handles digits (0-9), semicolon (;) as parameter separator, and colon (:)
// as ECMA-48 sub-parameter separator. Colon-joined params are flagged in
// csi_subparam_mask so SGR can distinguish 4:2 (underline style) from 4;2
// (underline + dim), and 38:2::R:G:B from 38;2;R;G;B.
csi_collect_param :: proc(p: ^Parser, b: u8) {
	if b >= 0x30 && b <= 0x39 {
		// Digit: accumulate into current parameter
		if p.csi_count < 16 {
			p.csi_values[p.csi_count] = p.csi_values[p.csi_count] * 10 + u32(b - 0x30)
		}
	} else if b == 0x3B {
		// Semicolon: next parameter (not a sub-parameter)
		if p.csi_count < 16 {
			p.csi_count += 1
			if p.csi_count < 16 {
				p.csi_subparam_mask &= ~(u16(1) << u16(p.csi_count))
			}
		}
	} else if b == 0x3A {
		// Colon: next sub-parameter
		if p.csi_count < 16 {
			p.csi_count += 1
			if p.csi_count < 16 {
				p.csi_subparam_mask |= (u16(1) << u16(p.csi_count))
			}
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
		values        = p.csi_values,
		subparam_mask = p.csi_subparam_mask,
		count         = p.csi_count + 1, // count is 0-indexed, so add 1
	}
	private := p.intermediate == '?'
	
	// Dispatch based on final byte
	switch final_byte {
	case 'A': // CUU - Cursor Up
		_csi_execute_cuu(t, params)
	case 'B', 'e': // CUD / VPR - Cursor Down / Line Position Relative
		_csi_execute_cud(t, params)
	case 'C', 'a': // CUF / HPR - Cursor Forward / Character Position Relative
		_csi_execute_cuf(t, params)
	case 'D': // CUB - Cursor Back
		_csi_execute_cub(t, params)
	case 'H', 'f': // CUP / HVP - Cursor Position / Character and Line Position
		_csi_execute_cup(t, params)
	case 'G': // CHA - Cursor Character Absolute
		_csi_execute_cha(t, params)
	case 'd': // VPA - Line Position Absolute
		_csi_execute_vpa(t, params)
	case 'J': // ED - Erase in Display
		_csi_execute_ed(t, params)
	case 'K': // EL - Erase in Line
		_csi_execute_el(t, params)
	case 'X': // ECH - Erase Character
		_csi_execute_ech(t, params)
	case 'L': // IL - Insert Line
		_csi_execute_il(t, params)
	case 'M': // DL - Delete Line
		_csi_execute_dl(t, params)
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
	case 'c': // DA - Device Attributes
		_csi_execute_da(t, params, p)
	case 'n': // DSR - Device Status Report (non-private only)
		if !private {
			_csi_execute_dsr(t, params, p)
		}
	case 'q': // DECSCUSR (intermediate space) / XTVERSION (intermediate '>')
		if p.intermediate == ' ' {
			_csi_execute_decscusr(t, params)
		} else if p.intermediate == '>' {
			_csi_execute_xtversion(t, params, p)
		}
		// Plain CSI q (DECSCA, character protection) is unimplemented
		// and safely ignored.
	case 'u': // Kitty keyboard protocol (= set, ? query/set, > push, < pop)
		_csi_execute_kitty_keyboard(t, params, p)
	case 'h': // SM - Set Mode (private: DECTCEM show, alt screen enter, bracketed paste, focus reporting)
		if private {
			_csi_execute_dectcem(t, params, true)
			_csi_execute_alt_screen(t, params, true)
			_csi_execute_private_mode(t, params, true)
		}
	case 'l': // RM - Reset Mode (private: DECTCEM hide, alt screen leave, bracketed paste, focus reporting)
		if private {
			_csi_execute_dectcem(t, params, false)
			_csi_execute_alt_screen(t, params, false)
			_csi_execute_private_mode(t, params, false)
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
	p.csi_subparam_mask = 0
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
	case 3:
		termgrid.terminal_clear_scrollback(t)
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
		termgrid.terminal_move_cursor(t, 0, 0)
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
	termgrid.terminal_move_cursor(t, 0, 0)
}

// _csi_execute_cha executes Cursor Character Absolute (CHA).
// Moves cursor to the specified column on the current row (1-indexed, default 1).
_csi_execute_cha :: proc(t: ^termgrid.Terminal, params: CSI_Params) {
	col := int(params.values[0])
	if col == 0 {
		col = 1
	}
	termgrid.terminal_move_cursor(t, t.cursor.row, col - 1)
}

// _csi_execute_vpa executes Line Position Absolute (VPA).
// Moves cursor to the specified row on the current column (1-indexed, default 1).
_csi_execute_vpa :: proc(t: ^termgrid.Terminal, params: CSI_Params) {
	row := int(params.values[0])
	if row == 0 {
		row = 1
	}
	termgrid.terminal_move_cursor(t, row - 1, t.cursor.col)
}

// _csi_execute_ech executes Erase Character (ECH).
// Erases n characters at cursor position without moving cursor.
_csi_execute_ech :: proc(t: ^termgrid.Terminal, params: CSI_Params) {
	n := int(params.values[0])
	if n == 0 {
		n = 1
	}
	termgrid.terminal_erase_chars(t, n)
}

// _csi_execute_il executes Insert Line (IL).
// Inserts n blank lines at current cursor row.
_csi_execute_il :: proc(t: ^termgrid.Terminal, params: CSI_Params) {
	n := int(params.values[0])
	if n == 0 {
		n = 1
	}
	termgrid.terminal_insert_lines(t, n)
}

// _csi_execute_dl executes Delete Line (DL).
// Deletes n lines at current cursor row.
_csi_execute_dl :: proc(t: ^termgrid.Terminal, params: CSI_Params) {
	n := int(params.values[0])
	if n == 0 {
		n = 1
	}
	termgrid.terminal_delete_lines(t, n)
}

// _csi_execute_alt_screen executes alternate screen switching (DEC private mode 1049 / 47).
_csi_execute_alt_screen :: proc(t: ^termgrid.Terminal, params: CSI_Params, enter: bool) {
	for i in 0..<int(params.count) {
		val := int(params.values[i])
		if val == ALT_SCREEN_PARAM || val == ALT_SCREEN_PARAM_LEGACY {
			if enter {
				termgrid.terminal_enter_alt_screen(t)
			} else {
				termgrid.terminal_leave_alt_screen(t)
			}
			return
		}
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

// _csi_execute_private_mode handles additional private modes:
// - Mode 1: Application Cursor Keys (DECCKM)
// - Mode 1000: Mouse Tracking Normal (press/release)
// - Mode 1002: Mouse Tracking Button-Event (press/release/drag)
// - Mode 1003: Mouse Tracking Any-Event (all motion)
// - Mode 1006: Mouse SGR Extended Format (\e[<...M/m)
// - Mode 1004: Focus Reporting (send \e[I on focus gain, \e[O on focus loss)
// - Mode 2004: Bracketed Paste (wrap pastes with \e[200~ and \e[201~)
// - Mode 2026: Synchronized Output
_csi_execute_private_mode :: proc(t: ^termgrid.Terminal, params: CSI_Params, enable: bool) {
	for i in 0..<int(params.count) {
		switch int(params.values[i]) {
		case 1:
			t.app_cursor_keys = enable
		case 1000:
			t.mouse_tracking = enable ? .Normal : .None
		case 1002:
			t.mouse_tracking = enable ? .Button_Event : .None
		case 1003:
			t.mouse_tracking = enable ? .Any_Event : .None
		case 1006:
			t.mouse_format = enable ? .SGR : .X10
		case 1004:
			t.focus_reporting = enable
		case 2004:
			t.bracketed_paste = enable
		case 2026:
			termgrid.terminal_set_sync_output(t, enable)
		}
	}
}

// _csi_execute_decscusr handles DECSCUSR (Set Cursor Style): CSI Ps SP q
// Ps = 0 or 1: blinking block (default)
// Ps = 2: steady block
// Ps = 3: blinking underline
// Ps = 4: steady underline
// Ps = 5: blinking bar
// Ps = 6: steady bar
_csi_execute_decscusr :: proc(t: ^termgrid.Terminal, params: CSI_Params) {
	n := int(params.values[0])
	if n < 0 || n > 6 {
		n = 0
	}
	t.cursor.style = u8(n)
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
// _csi_execute_xtversion answers XTVERSION (CSI > q) with a DCS response
// identifying this terminal. fish uses it only for temporary workarounds
// for incompatible terminals, so any well-formed response suffices.
_csi_execute_xtversion :: proc(t: ^termgrid.Terminal, params: CSI_Params, p: ^Parser) {
	_ = t
	_ = params
	if p.response_cb == nil {
		return
	}
	// DCS > | Term ST
	response := [10]u8{0x1B, 'P', '>', '|', 'T', 'e', 'r', 'm', 0x1B, '\\'}
	p.response_cb(response[:])
}

// _csi_execute_kitty_keyboard handles the kitty keyboard protocol's CSI u
// sequences. The intermediate byte selects the operation:
// - '=': CSI = flags ; mode u sets enhancements (mode 1 replace (default),
//   mode 2 set bits, mode 3 clear bits).
// - '?': CSI ? u queries (responds CSI ? flags u); CSI ? flags u with
//   parameters applies them (the enable form fish documents).
// - '>': CSI > flags u pushes the current flags and sets the new subset.
// - '<': CSI < n u pops n stack entries (default 1).
// Only the disambiguate flag (0b1) is supported; other bits are masked off
// and report as unset, which applications detect via the query response.
_csi_execute_kitty_keyboard :: proc(t: ^termgrid.Terminal, params: CSI_Params, p: ^Parser) {
	count := int(params.count)
	flags := u8(0)
	if count > 0 {
		flags = u8(params.values[0])
	}
	mode := u8(1)
	if count > 1 {
		mode = u8(params.values[1])
	}

	switch p.intermediate {
	case '=':
		termgrid.terminal_kitty_set(t, flags, mode)
	case '?':
		if count <= 1 && flags == 0 {
			// Query: respond CSI ? flags u with the active screen's flags.
			if p.response_cb == nil {
				return
			}
			active := termgrid.terminal_kitty_active(t)
			resp: [8]u8
			n := 0
			resp[n] = 0x1B; n += 1
			resp[n] = '['; n += 1
			resp[n] = '?'; n += 1
			if active.flags >= 10 {
				resp[n] = '0' + active.flags / 10
				n += 1
			}
			resp[n] = '0' + active.flags % 10
			n += 1
			resp[n] = 'u'; n += 1
			p.response_cb(resp[:n])
		} else {
			// Enable form with parameters: apply like '='.
			termgrid.terminal_kitty_set(t, flags, mode)
		}
	case '>':
		termgrid.terminal_kitty_push(t, flags)
	case '<':
		termgrid.terminal_kitty_pop(t, flags)
	}
}

// _csi_execute_da handles Device Attributes (CSI c / CSI ? c / CSI > c).
// Primary DA (intermediate 0 or '?'): responds with \x1b[?62c (VT220).
// Secondary DA (intermediate '>'): responds with \x1b[>0;10;0c.
// The response is sent via the parser's response_cb to write back to PTY.
_csi_execute_da :: proc(t: ^termgrid.Terminal, params: CSI_Params, p: ^Parser) {
	_ = t
	_ = params
	if p.response_cb == nil {
		return
	}
	if p.intermediate == '>' {
		response := [10]u8{0x1B, '[', '>', '0', ';', '1', '0', ';', '0', 'c'}
		p.response_cb(response[:])
	} else {
		// VT220 Primary DA response: ESC [ ? 6 2 c (no trailing separator).
		// 62 = VT220, which is the standard xterm-compatible response.
		response := [6]u8{0x1B, '[', '?', '6', '2', 'c'}
		p.response_cb(response[:])
	}
}

// _csi_execute_dsr handles Device Status Report (CSI 5 n / CSI 6 n).
// Parameter 5: Status Report -> responds \x1b[0n (terminal OK).
// Parameter 6: Cursor Position Report (CPR) -> responds \x1b[<row>;<col>R (1-indexed).
// Used by fish shell and modern CLIs for terminal queries and layout negotiation.
_csi_execute_dsr :: proc(t: ^termgrid.Terminal, params: CSI_Params, p: ^Parser) {
	if p.response_cb == nil || params.count == 0 {
		return
	}
	if params.values[0] == 5 {
		response := [4]u8{0x1B, '[', '0', 'n'}
		p.response_cb(response[:])
	} else if params.values[0] == 6 {
		// Format row and col as decimal strings (1-indexed)
		row_1 := t.cursor.row + 1
		col_1 := t.cursor.col + 1
		// Build response: ESC [ row ; col R
		// Max digits: row up to 9999 (4 digits), col up to 9999 (4 digits)
		// Total: 3 (ESC [) + 4 + 1 (;) + 4 + 1 (R) = 13 bytes max
		buf: [16]u8
		n := 0
		buf[n] = 0x1B; n += 1
		buf[n] = '['; n += 1
		// Write row
		if row_1 >= 1000 { buf[n] = '0' + u8(row_1 / 1000); n += 1 }
		if row_1 >= 100 { buf[n] = '0' + u8((row_1 / 100) % 10); n += 1 }
		if row_1 >= 10 { buf[n] = '0' + u8((row_1 / 10) % 10); n += 1 }
		buf[n] = '0' + u8(row_1 % 10); n += 1
		buf[n] = ';'; n += 1
		// Write col
		if col_1 >= 1000 { buf[n] = '0' + u8(col_1 / 1000); n += 1 }
		if col_1 >= 100 { buf[n] = '0' + u8((col_1 / 100) % 10); n += 1 }
		if col_1 >= 10 { buf[n] = '0' + u8((col_1 / 10) % 10); n += 1 }
		buf[n] = '0' + u8(col_1 % 10); n += 1
		buf[n] = 'R'; n += 1
		p.response_cb(buf[:n])
	}
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
	theme := t.grid.style_table.theme

	count := int(params.count)
	if count == 0 {
		// Bare ESC[m with no params: treat as [0] reset.
		cur = termgrid.style_table_default(&t.grid.style_table)
		termgrid.terminal_set_style(t, termgrid.style_table_insert(&t.grid.style_table, cur))
		return
	}

	i := 0
	for i < count {
		code := int(params.values[i])

		switch code {
		case 0: // Reset
			cur = termgrid.style_table_default(&t.grid.style_table)
		case 1: // Bold
			cur.flags |= termgrid.STYLE_FLAG_BOLD
		case 2: // Dim (fish autosuggestion uses this)
			cur.flags |= termgrid.STYLE_FLAG_DIM
		case 3: // Italic
			cur.flags |= termgrid.STYLE_FLAG_ITALIC
		case 4: // Underline, or underline style variant when colon-joined (4:0..4:5)
			if i + 1 < count && csi_is_subparam(params, i + 1) {
				sub := int(params.values[i + 1])
				if sub == 0 {
					cur.flags = cur.flags & (~termgrid.STYLE_FLAG_UNDERLINE)
				} else if sub >= 1 && sub <= 5 {
					cur.flags |= termgrid.STYLE_FLAG_UNDERLINE
				}
				i += 1 // consume the colon-joined style sub-parameter
			} else {
				cur.flags |= termgrid.STYLE_FLAG_UNDERLINE
			}
		case 7: // Inverse
			cur.flags |= termgrid.STYLE_FLAG_INVERSE
		case 9: // Strike
			cur.flags |= termgrid.STYLE_FLAG_STRIKE
		case 22: // Normal intensity: clears both bold and dim (xterm)
			cur.flags = cur.flags & (~(termgrid.STYLE_FLAG_BOLD | termgrid.STYLE_FLAG_DIM))
		case 23: // Italic off
			cur.flags = cur.flags & (~termgrid.STYLE_FLAG_ITALIC)
		case 24: // Underline off
			cur.flags = cur.flags & (~termgrid.STYLE_FLAG_UNDERLINE)
		case 27: // Inverse off
			cur.flags = cur.flags & (~termgrid.STYLE_FLAG_INVERSE)
		case 29: // Strike off
			cur.flags = cur.flags & (~termgrid.STYLE_FLAG_STRIKE)
		case 30..=37: // Standard foreground
			cur.fg = termgrid.theme_palette_256(theme, code - 30)
		case 40..=47: // Standard background
			cur.bg = termgrid.theme_palette_256(theme, code - 40)
		case 90..=97: // Bright foreground
			cur.fg = termgrid.theme_palette_256(theme, code - 90 + 8)
		case 100..=107: // Bright background
			cur.bg = termgrid.theme_palette_256(theme, code - 100 + 8)
		case 38, 48, 58: // Extended color: 38 fg, 48 bg, 58 underline
			is_fg := code == 38
			is_ul := code == 58
			if i + 1 >= count {
				// Truncated: lone 38/48/58, ignore tail.
				i = count
				break
			}
			mode := int(params.values[i + 1])
			if mode == 5 {
				// 256-color: need 2 more values (38;5;idx or 38:5:idx).
				if i + 2 >= count {
					i = count
					break
				}
				idx := int(params.values[i + 2])
				if idx >= 0 && idx < termgrid.THEME_256_COUNT {
					c := termgrid.theme_palette_256(theme, idx)
					if is_fg {
						cur.fg = c
					} else if is_ul {
						cur.underline = c
					} else {
						cur.bg = c
					}
				}
				i += 2
			} else if mode == 2 {
				// Truecolor: semicolon form needs 4 more values (38;2;r;g;b);
				// colon form has an empty field (38:2::r:g:b) which the
				// parser records as a zero sub-parameter — skip it.
				offset := i + 2
				if offset < count && int(params.values[offset]) == 0 && csi_is_subparam(params, offset) {
					offset += 1
				}
				if offset + 2 >= count {
					i = count
					break
				}
				r := _sgr_clamp_rgb(params.values[offset])
				g := _sgr_clamp_rgb(params.values[offset + 1])
				b := _sgr_clamp_rgb(params.values[offset + 2])
				c := 0xFF000000 | (r << 16) | (g << 8) | b
				if is_fg {
					cur.fg = c
				} else if is_ul {
					cur.underline = c
				} else {
					cur.bg = c
				}
				i = offset + 2
			} else {
				// Unknown extended mode: swallow the mode byte.
				i += 1
			}
		case 39: // Default foreground
			cur.fg = termgrid.style_table_default(&t.grid.style_table).fg
		case 49: // Default background
			cur.bg = termgrid.style_table_default(&t.grid.style_table).bg
		case 59: // Default underline color (follow foreground)
			cur.underline = termgrid.style_table_default(&t.grid.style_table).underline
		}
		i += 1
	}

	termgrid.terminal_set_style(t, termgrid.style_table_insert(&t.grid.style_table, cur))
}
