package term

// Dedicated OS Clipboard Synchronization, Copy & Paste Engine
// Part of Tier 3 Application Shell (src/app/term/*).

import "base:runtime"
import "core:strings"
import "core:unicode/utf8"
import "vendor:sdl3"

import sess_feat "../../features/session"
import terminal_grid "../../core/terminal/grid"
import egc "../../core/terminal/egc"

CLIPBOARD_MAX_BUF :: 65536

Clipboard_Bridge :: struct {
	buf: [CLIPBOARD_MAX_BUF]u8,
}

clipboard_init :: proc(cb: ^Clipboard_Bridge) {
	if cb == nil do return
}

// clipboard_copy_selection extracts text from the grid selection and sends it
// to the OS clipboard as UTF-8, resolving grapheme clusters (Has_Egc) from the
// EGC pool and skipping wide-continuation cells.
clipboard_copy_selection :: proc(cb: ^Clipboard_Bridge, sess: ^sess_feat.Terminal_Session, sel: Mouse_Selection) -> bool {
	if cb == nil || sess == nil || !sel.active do return false

	min_r := min(sel.start_cell.row, sel.end_cell.row)
	max_r := max(sel.start_cell.row, sel.end_cell.row)
	min_c := min(sel.start_cell.col, sel.end_cell.col)
	max_c := max(sel.start_cell.col, sel.end_cell.col)

	g := &sess.term.grid
	len_out := 0

	for r in min_r..=max_r {
		phy_r := terminal_grid.grid_physical_row(g, r)
		if phy_r >= len(g.rows) do continue
		row := &g.rows[phy_r]

		end_c := min(max_c, len(row.cells) - 1)
		for c in min_c..=end_c {
			if len_out >= len(cb.buf) - 4 do break
			cell_val := row.cells[c]

			if .Wide_Continuation in cell_val.flags {
				continue
			}

			if .Has_Egc in cell_val.flags {
				if runes := egc.egc_pool_get(&sess.term.egc_pool, int(cell_val.char - egc.EGC_INDEX_BASE)); runes != nil {
					for rn in runes {
						if len_out >= len(cb.buf) - 4 do break
						b, w := utf8.encode_rune(rn)
						for i in 0..<w {
							cb.buf[len_out] = b[i]
							len_out += 1
						}
					}
					continue
				}
			}

			ch := cell_val.char
			if ch == 0 || ch == ' ' {
				cb.buf[len_out] = ' '
				len_out += 1
			} else {
				b, w := utf8.encode_rune(ch)
				for i in 0..<w {
					if len_out >= len(cb.buf) - 1 do break
					cb.buf[len_out] = b[i]
					len_out += 1
				}
			}
		}
		if r < max_r && len_out < len(cb.buf) - 1 {
			cb.buf[len_out] = '\n'
			len_out += 1
		}
	}

	if len_out > 0 {
		cb.buf[len_out] = 0 // Null terminate for C string
		_ = sdl3.SetClipboardText(cstring(raw_data(cb.buf[:])))
		return true
	}
	return false
}

// clipboard_paste retrieves text from OS clipboard and streams it to PTY
clipboard_paste :: proc(sess: ^sess_feat.Terminal_Session, bracketed: bool = false) -> bool {
	if sess == nil || !sdl3.HasClipboardText() do return false

	clip_cstr := sdl3.GetClipboardText()
	if clip_cstr == nil do return false

	text := string(cstring(rawptr(clip_cstr)))
	if len(text) == 0 do return false

	if bracketed {
		sess_feat.session_write_string(sess, "\x1b[200~")
		sess_feat.session_write_string(sess, text)
		sess_feat.session_write_string(sess, "\x1b[201~")
	} else {
		sess_feat.session_write_string(sess, text)
	}
	return true
}
