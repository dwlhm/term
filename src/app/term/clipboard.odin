package term

// Dedicated Terminal Clipboard Synchronization, Selection Extraction & Paste Engine
// Part of Tier 3 Application Shell (src/app/term/*).
// Independent of windowing libraries (Zero SDL3/OS leaks).

import "base:runtime"
import "core:strings"

import sess_feat "../../features/session"
import terminal_grid "../../core/terminal/grid"
import egc "../../core/terminal/egc"
import cell "../../core/terminal/cell"

Clipboard_Set_Text_Proc :: proc(text: string, user_data: rawptr) -> bool
Clipboard_Get_Text_Proc :: proc(allocator: runtime.Allocator, user_data: rawptr) -> (string, bool)
Clipboard_Has_Text_Proc :: proc(user_data: rawptr) -> bool

// Clipboard_Bridge abstracts host platform clipboard facilities via pure procedure callbacks.
Clipboard_Bridge :: struct {
	user_data: rawptr,
	set_text:  Clipboard_Set_Text_Proc,
	get_text:  Clipboard_Get_Text_Proc,
	has_text:  Clipboard_Has_Text_Proc,
}

// clipboard_init binds host platform clipboard operations to the bridge.
clipboard_init :: proc(
	cb: ^Clipboard_Bridge,
	set_text: Clipboard_Set_Text_Proc = nil,
	get_text: Clipboard_Get_Text_Proc = nil,
	has_text: Clipboard_Has_Text_Proc = nil,
	user_data: rawptr = nil,
) {
	if cb == nil do return
	cb.set_text  = set_text
	cb.get_text  = get_text
	cb.has_text  = has_text
	cb.user_data = user_data
}

// Normalized_Selection holds selection bounds guaranteed to be in document order.
Normalized_Selection :: struct {
	start_row, start_col: int,
	end_row,   end_col:   int,
	mode:                 Selection_Mode,
}

// selection_normalize sorts mouse selection endpoints into top-to-bottom, left-to-right order.
selection_normalize :: proc(sel: Mouse_Selection) -> (norm: Normalized_Selection, ok: bool) {
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
// Shared between clipboard text extraction and GPU terminal view highlight.
selection_contains_cell :: proc(sel: Mouse_Selection, r, c: int) -> bool {
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

// row_last_content_col locates the index of the rightmost non-whitespace character in a row.
row_last_content_col :: proc(row: ^terminal_grid.Row) -> int {
	if row == nil do return -1
	for i := len(row.cells) - 1; i >= 0; i -= 1 {
		ch := row.cells[i].char
		if ch != 0 && ch != ' ' do return i
	}
	return -1
}

// cell_append_utf8 resolves EGC clusters and encodes cell text into a strings.Builder.
cell_append_utf8 :: proc(b: ^strings.Builder, pool: ^egc.Egc_Pool, c: cell.Semantic_Cell) {
	if .Wide_Continuation in c.flags do return

	if .Has_Egc in c.flags && pool != nil {
		if runes := egc.egc_pool_get(pool, int(c.char - egc.EGC_INDEX_BASE)); runes != nil {
			for rn in runes {
				strings.write_rune(b, rn)
			}
			return
		}
	}

	ch := c.char if (c.char != 0) else ' '
	strings.write_rune(b, ch)
}

// session_extract_selection extracts clean UTF-8 text from the grid selection.
// Decoupled from host OS facilities; reusable for drag & drop, text search, and headless tests.
session_extract_selection :: proc(sess: ^sess_feat.Terminal_Session, sel: Mouse_Selection, allocator: runtime.Allocator = context.temp_allocator) -> (string, bool) {
	if sess == nil do return "", false
	norm, ok := selection_normalize(sel)
	if !ok do return "", false

	g := &sess.term.grid
	b := strings.builder_make(allocator)

	for r in norm.start_row..=norm.end_row {
		phy_r := terminal_grid.grid_physical_row(g, r)
		if phy_r >= len(g.rows) do continue
		row := &g.rows[phy_r]

		row_cells := len(row.cells)
		start_c, end_c, valid := selection_row_bounds(norm, r, row_cells)
		if !valid do continue

		// In stream mode, trim trailing empty cells on intermediate lines
		if norm.mode == .Stream && r < norm.end_row {
			last_used := row_last_content_col(row)
			if last_used < start_c {
				strings.write_byte(&b, '\n')
				continue
			}
			end_c = min(end_c, last_used)
		}

		for c in start_c..=end_c {
			cell_append_utf8(&b, &sess.term.egc_pool, row.cells[c])
		}

		if r < norm.end_row {
			strings.write_byte(&b, '\n')
		}
	}

	text := strings.to_string(b)
	return text, len(text) > 0
}

// clipboard_set_text sets UTF-8 text on the host clipboard via the bridge provider.
clipboard_set_text :: proc(cb: ^Clipboard_Bridge, text: string) -> bool {
	if cb == nil || cb.set_text == nil || len(text) == 0 do return false
	return cb.set_text(text, cb.user_data)
}

// clipboard_get_text retrieves UTF-8 text from the host clipboard via the bridge provider.
clipboard_get_text :: proc(cb: ^Clipboard_Bridge, allocator: runtime.Allocator = context.temp_allocator) -> (string, bool) {
	if cb == nil || cb.get_text == nil do return "", false
	if cb.has_text != nil && !cb.has_text(cb.user_data) do return "", false
	return cb.get_text(allocator, cb.user_data)
}

// clipboard_copy_selection extracts active selection and sends it to the host clipboard.
clipboard_copy_selection :: proc(cb: ^Clipboard_Bridge, sess: ^sess_feat.Terminal_Session, sel: Mouse_Selection) -> bool {
	if cb == nil do return false
	text, ok := session_extract_selection(sess, sel, context.temp_allocator)
	if !ok do return false
	return clipboard_set_text(cb, text)
}

// clipboard_paste retrieves text from the host clipboard and streams it to the PTY.
clipboard_paste :: proc(cb: ^Clipboard_Bridge, sess: ^sess_feat.Terminal_Session, bracketed: bool = false) -> bool {
	if cb == nil || sess == nil do return false
	text, ok := clipboard_get_text(cb, context.temp_allocator)
	if !ok || len(text) == 0 do return false

	if bracketed {
		sess_feat.session_write_string(sess, "\x1b[200~")
		sess_feat.session_write_string(sess, text)
		sess_feat.session_write_string(sess, "\x1b[201~")
	} else {
		sess_feat.session_write_string(sess, text)
	}
	return true
}
