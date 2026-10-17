package feature_interaction

// Dedicated Terminal Clipboard Synchronization, Selection Extraction & Paste Engine
// Part of Tier 2 Feature Composition Layer (src/features/interaction/*).
// Independent of windowing libraries (Zero SDL3/OS leaks).

import "base:runtime"
import "core:strings"

import session "../session"
import terminal_grid "../../core/terminal/grid"
import egc "../../core/terminal/egc"
import cell "../../core/terminal/cell"

Clipboard_Set_Text_Proc :: proc(text: string, user_data: rawptr) -> bool
Clipboard_Get_Text_Proc :: proc(allocator: runtime.Allocator, user_data: rawptr) -> (string, bool)
Clipboard_Has_Text_Proc :: proc(user_data: rawptr) -> bool

// Clipboard_Guard enforces security and size limits on remote OSC 52 operations.
Clipboard_Guard :: struct {
	allow_remote_write: bool, // When true, remote OSC 52 can set clipboard
	max_payload_bytes:  int,  // Maximum allowable payload bytes (prevents buffer spam / DOS)
}

DEFAULT_CLIPBOARD_GUARD := Clipboard_Guard{
	allow_remote_write = true,
	max_payload_bytes  = 1024 * 1024, // 1 MiB limit
}

// Clipboard_Bridge abstracts host platform clipboard facilities via pure procedure callbacks.
Clipboard_Bridge :: struct {
	user_data: rawptr,
	set_text:  Clipboard_Set_Text_Proc,
	get_text:  Clipboard_Get_Text_Proc,
	has_text:  Clipboard_Has_Text_Proc,
	guard:     Clipboard_Guard,
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
	cb.guard     = DEFAULT_CLIPBOARD_GUARD
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
session_extract_selection :: proc(sess: ^session.Terminal_Session, sel: Mouse_Selection, allocator: runtime.Allocator = context.temp_allocator) -> (string, bool) {
	if sess == nil do return "", false
	norm, ok := selection_normalize(sel)
	if !ok do return "", false

	g := &sess.term.grid
	b := strings.builder_make(allocator)

	min_valid_row := -g.history_count
	max_valid_row := g.row_count - 1

	start_row := max(norm.start_row, min_valid_row)
	end_row   := min(norm.end_row, max_valid_row)
	if start_row > end_row do return "", false

	for r in start_row..=end_row {
		phy_r := terminal_grid.grid_physical_row(g, r)
		if phy_r >= len(g.rows) do continue
		row := &g.rows[phy_r]

		row_cells := len(row.cells)
		start_c, end_c, valid := selection_row_bounds(norm, r, row_cells)
		if !valid do continue

		// In stream mode, trim trailing empty cells on intermediate lines
		if norm.mode == .Stream && r < end_row {
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

		if r < end_row {
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

// clipboard_guard_check validates whether an incoming remote OSC 52 clipboard write is allowed.
clipboard_guard_check :: proc(guard: ^Clipboard_Guard, text: string) -> bool {
	if guard == nil do return true
	if !guard.allow_remote_write do return false
	if len(text) > guard.max_payload_bytes do return false
	return true
}

// clipboard_set_text_guarded safely updates host clipboard if permitted by the OSC 52 guard.
clipboard_set_text_guarded :: proc(cb: ^Clipboard_Bridge, text: string) -> bool {
	if cb == nil || len(text) == 0 do return false
	if !clipboard_guard_check(&cb.guard, text) do return false
	return clipboard_set_text(cb, text)
}

// clipboard_get_text retrieves UTF-8 text from the host clipboard via the bridge provider.
clipboard_get_text :: proc(cb: ^Clipboard_Bridge, allocator: runtime.Allocator = context.temp_allocator) -> (string, bool) {
	if cb == nil || cb.get_text == nil do return "", false
	if cb.has_text != nil && !cb.has_text(cb.user_data) do return "", false
	return cb.get_text(allocator, cb.user_data)
}

// clipboard_copy_selection extracts active selection and sends it to the host clipboard.
clipboard_copy_selection :: proc(cb: ^Clipboard_Bridge, sess: ^session.Terminal_Session, sel: Mouse_Selection) -> bool {
	if cb == nil do return false
	text, ok := session_extract_selection(sess, sel, context.temp_allocator)
	if !ok do return false
	return clipboard_set_text(cb, text)
}

// clipboard_paste retrieves text from the host clipboard and streams it to the PTY.
clipboard_paste :: proc(cb: ^Clipboard_Bridge, sess: ^session.Terminal_Session, bracketed: bool = false) -> bool {
	if cb == nil || sess == nil do return false
	text, ok := clipboard_get_text(cb, context.temp_allocator)
	if !ok || len(text) == 0 do return false

	if bracketed {
		session.session_write_string(sess, "\x1b[200~")
		session.session_write_string(sess, text)
		session.session_write_string(sess, "\x1b[201~")
	} else {
		session.session_write_string(sess, text)
	}
	return true
}
