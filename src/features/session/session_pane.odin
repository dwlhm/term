package feature_session

import "core:fmt"
import terminal "../../core/terminal"
import damage "../../core/terminal/damage"
import grid "../../core/terminal/grid"
import parser "../../core/terminal/parser"

// session_pane_parts returns the active Grid, Damage_Tracker, and Parser for a
// specific surface within `sess` (`surface_id == 0` selects Root).
session_pane_parts :: proc(
	sess: ^Terminal_Session,
	surface_id: u16,
) -> (^grid.Grid, ^damage.Damage_Tracker, ^parser.Parser) {
	if sess == nil do return nil, nil, nil
	return terminal.terminal_surface_parts(&sess.term, surface_id)
}

session_pane_key_modes :: proc(sess: ^Terminal_Session, surface_id: u16) -> (app_cursor: bool, kitty_flags: u8, ok: bool) {
	_, _, p := session_pane_parts(sess, surface_id)
	if p == nil do return false, 0, false
	return p.cursor_key_mode, parser.parser_kitty_keyboard_flags(p), true
}

// session_pane_scroll_offset returns a pointer to the scrollback offset for
// `surface_id` within `sess`.
session_pane_scroll_offset :: proc(sess: ^Terminal_Session, surface_id: u16) -> ^int {
	if sess == nil do return nil
	if surface_id != 0 {
		if s := terminal.terminal_surface_find(&sess.term, surface_id); s != nil {
			return &s.scroll_offset
		}
	}
	return &sess.scroll_offset
}

// session_focus_pane updates the focused surface on `sess` and notifies the
// host program via `OSC 8400;8;<id>` when child surfaces exist.
session_focus_pane :: proc(sess: ^Terminal_Session, surface_id: u16) {
	if sess == nil || sess.term.focused_surface_id == surface_id do return
	prev := sess.term.focused_surface_id
	sess.term.focused_surface_id = surface_id
	if len(sess.term.surfaces) > 0 || prev != 0 {
		buf: [48]u8
		msg := fmt.bprintf(buf[:], "\x1b]8400;8;%d\x1b\\", surface_id)
		session_write(sess, transmute([]u8)msg)
	}
}

@(private = "file")
HEX_DIGITS := [16]u8{'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'}

// session_write_pane routes input bytes from the active pane to `sess`.
// Root (`surface_id == 0`) writes raw bytes directly; child surfaces (`> 0`)
// frame the payload in `OSC 8400;7;<id>;<hex>` so the host multiplexes it to
// the target surface without intercepting root editor keystrokes.
session_write_pane :: proc(sess: ^Terminal_Session, surface_id: u16, data: []u8) {
	if sess == nil || len(data) == 0 do return
	if sess.term.focused_surface_id != surface_id {
		session_focus_pane(sess, surface_id)
	}
	if surface_id == 0 {
		session_write(sess, data)
		return
	}
	// Chunk hex-encoded OSC 8400;7 frames so large pastes fit on stack
	CHUNK :: 256
	buf: [32 + CHUNK * 2]u8
	offset := 0
	for offset < len(data) {
		end := min(offset + CHUNK, len(data))
		hdr := fmt.bprintf(buf[:24], "\x1b]8400;7;%d;", surface_id)
		pos := len(hdr)
		for b in data[offset:end] {
			buf[pos]     = HEX_DIGITS[(b >> 4) & 0x0F]
			buf[pos + 1] = HEX_DIGITS[b & 0x0F]
			pos += 2
		}
		buf[pos]     = 0x1b
		buf[pos + 1] = '\\'
		pos += 2
		session_write(sess, buf[:pos])
		offset = end
	}
}

session_write_pane_string :: proc(sess: ^Terminal_Session, surface_id: u16, s: string) {
	session_write_pane(sess, surface_id, transmute([]u8)s)
}

// session_close_pane closes a child surface (`surface_id > 0`) inside `sess`.
session_close_pane :: proc(sess: ^Terminal_Session, surface_id: u16) {
	if sess == nil || surface_id == 0 do return
	if terminal.terminal_surface_close(&sess.term, surface_id) {
		buf: [64]u8
		msg := fmt.bprintf(buf[:], "\x1b]8400;6;%d\x1b\\\x1b]8400;8;%d\x1b\\", surface_id, sess.term.focused_surface_id)
		session_write(sess, transmute([]u8)msg)
	}
}

// session_resize_pane resizes the target pane (`0` = Root PTY + grid, `>0` =
// child surface grid + `OSC 8400;9` resize notification).
session_resize_pane :: proc(
	sess: ^Terminal_Session,
	surface_id: u16,
	cols, rows: u16,
	xpixel: u16 = 0,
	ypixel: u16 = 0,
) -> bool {
	if sess == nil do return false
	c := max(1, int(cols))
	r := max(1, int(rows))
	if surface_id == 0 {
		cw := int(xpixel) / c if xpixel > 0 else sess.term.parser.cell_w
		ch := int(ypixel) / r if ypixel > 0 else sess.term.parser.cell_h
		if c != sess.term.cols || r != sess.term.rows ||
		   sess.term.grid.col_count != c || sess.term.grid.row_count != r ||
		   cw != sess.term.parser.cell_w || ch != sess.term.parser.cell_h {
			session_resize(sess, u16(c), u16(r), xpixel, ypixel)
			return true
		}
		return false
	}
	s := terminal.terminal_surface_find(&sess.term, surface_id)
	if s == nil || !s.visible do return false
	if terminal.terminal_surface_resize_grid(&s.grid, &s.damage, &s.parser, r, c) {
		s.cell_rect[2] = c
		s.cell_rect[3] = r
		s.scroll_offset = clamp(s.scroll_offset, 0, s.grid.history_count)
		buf: [64]u8
		msg := fmt.bprintf(buf[:], "\x1b]8400;9;%d;%d;%d\x1b\\", surface_id, c, r)
		session_write(sess, transmute([]u8)msg)
		return true
	}
	return false
}
