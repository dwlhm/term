package feature_session_core

// MSG_SNAPSHOT: the parsed screen of a session for automation — rows as style
// runs, cursor, modes, shell (OSC 133) and program (OSC 7501) state. No side
// effects: it never resizes, scrolls or focuses the session.

import "core:strings"
import terminal "../../core/terminal"
import cell "../../core/terminal/cell"
import extension "../../core/terminal/extension"
import grid "../../core/terminal/grid"
import parser "../../core/terminal/parser"
import ipc "../../platform/ipc"
import session "../session"

core_viewer_snapshot :: proc(c: ^Core, vi: int, r: ^ipc.Wire_Reader) {
	req := ipc.dec_snapshot_req(r)
	if !ipc.wr_done(r) {
		core_viewer_fail(c, vi, 0, .Bad_Request, "malformed snapshot request")
		return
	}
	s := core_session_find(c, req.id)
	if s == nil {
		core_viewer_fail(c, vi, 0, .Not_Found, "no such session")
		return
	}
	if s.stitch != nil && s.stitch.active {
		core_viewer_fail(c, vi, 0, .Busy, "a read is scrolling this session")
		return
	}
	// A screen that does not fit with its history is sent with less of it.
	history := min(int(req.history), ipc.SNAPSHOT_HISTORY_MAX)
	for {
		w := ipc.wire_writer(c.msg)
		_snap_write(c, s, &w, req.since, history)
		if w.ok {
			ipc.stream_send(&c.viewers[vi].conn, ipc.MSG_SNAPSHOT_RESULT, 0, ipc.wire_bytes_written(&w))
			return
		}
		if history == 0 {
			core_viewer_fail(c, vi, 0, .Bad_Request, "the screen does not fit in one snapshot")
			return
		}
		history /= 2
	}
}

@(private = "file")
_snap_write :: proc(c: ^Core, s: ^Core_Session, w: ^ipc.Wire_Writer, since: i64, history: int) {
	t := &s.sess.term
	g := &t.grid
	first := -g.history_count
	if since >= 0 do first = max(first, int(since - g.scrolled))
	from := max(first, -history)

	head := _snap_head(s)
	head.history_truncated = from > first
	ipc.enc_snapshot_head(w, head)
	clear(&c.snap_links)
	ipc.ww_u32(w, u32(max(0, -from)))
	for row in from ..< 0 do _snap_row(c, t, w, row)
	ipc.ww_u32(w, u32(g.row_count))
	for row in 0 ..< g.row_count do _snap_row(c, t, w, row)
	ipc.ww_u32(w, u32(len(c.snap_links)))
	for id in c.snap_links {
		ipc.enc_snap_link(w, {id, extension.hyperlinks_uri(&t.hyperlinks, id)})
	}
}

@(private = "file")
_snap_head :: proc(s: ^Core_Session) -> ipc.Snapshot {
	sess := s.sess
	t := &sess.term
	p := &t.parser
	st := &sess.program_status
	shape, blinking, visible := terminal.terminal_cursor_style(t)
	process := session.session_process_name(sess)
	if len(process) == 0 do process = extension.program_status_app(st)
	out_start, out_end := _snap_output(p)
	return {
		id = s.id, gen = s.gen,
		cols = u16(t.grid.col_count), rows = u16(t.grid.row_count), top_line = t.grid.scrolled,
		cursor_row = u16(p.cursor.row), cursor_col = u16(p.cursor.col), cursor_shape = u8(shape),
		cursor_visible = visible, cursor_blinking = blinking,
		alt_screen = p.in_alt_screen, app_cursor = p.cursor_key_mode,
		bracketed_paste = p.bracketed_paste, report_focus = p.report_focus, sync_output = p.sync_output,
		kitty_flags = terminal.terminal_kitty_keyboard_flags(t),
		mouse_mode = u8(p.mouse_mode), mouse_format = u8(p.mouse_format),
		prompt_state = ipc.Prompt_State(p.prompt_state),
		has_cmd_exit = p.has_cmd_exit, cmd_exit_code = p.last_cmd_exit, cmd_seq = p.cmd_seq,
		output_start = out_start, output_end = out_end,
		exited = s.exited, exit_code = s.exit.code,
		status_state = u8(st.state), status_app = extension.program_status_app(st),
		status_kind = string(st.kind_buf[:st.kind_len]), status_msg = extension.program_status_msg(st),
		title = string(t.title_buf[:t.title_len]),
		process = process,
	}
}

// _snap_row encodes one row as style runs up to its last cell with content or
// attributes. Run texts are built first: c.text may move while it grows.
@(private = "file")
_snap_row :: proc(c: ^Core, t: ^terminal.Terminal, w: ^ipc.Wire_Writer, row: int) {
	g := &t.grid
	gr := grid.grid_get_row(g, row)
	if gr == nil do return
	clear(&c.snap_runs)
	clear(&c.snap_spans)
	clear(&c.text)
	b := strings.Builder{buf = c.text}
	for col in 0 ..< _snap_row_end(gr) {
		ch := gr.cells[col]
		style := _snap_style(ch, gr.direct_colors[col] if col < len(gr.direct_colors) else {})
		n := len(c.snap_runs)
		if n == 0 || c.snap_runs[n - 1].style != style {
			append(&c.snap_runs, ipc.Snap_Run{style = style})
			append(&c.snap_spans, [2]int{len(b.buf), len(b.buf)})
			n += 1
			if style.link != 0 do _snap_note_link(c, style.link)
		}
		c.snap_runs[n - 1].cells += 1
		terminal.terminal_cell_append_utf8(&b, &t.egc_pool, ch)
		c.snap_spans[n - 1][1] = len(b.buf)
	}
	c.text = b.buf
	for &run, i in c.snap_runs do run.text = string(c.text[c.snap_spans[i][0]:c.snap_spans[i][1]])
	ipc.enc_snap_row(w, g.scrolled + i64(row), gr.wrap, gr.is_prompt, c.snap_runs[:])
}

// _snap_row_end: one past the last cell that is not a default blank.
@(private = "file")
_snap_row_end :: proc(gr: ^grid.Row) -> int {
	for i := min(int(gr.occ), len(gr.cells)) - 1; i >= 0; i -= 1 {
		ch := gr.cells[i]
		if (ch.char != ' ' && ch.char != 0) || ch.fg != 7 || ch.bg != 0 || ch.style != {} || ch.flags != {} {
			return i + 1
		}
	}
	return 0
}

@(private = "file")
_snap_style :: proc(ch: cell.Semantic_Cell, dc: cell.Direct_Color) -> ipc.Snap_Style {
	return {
		fg = ch.fg, bg = ch.bg,
		has_fg_rgb = dc.has_fg, has_bg_rgb = dc.has_bg,
		fg_rgb = dc.fg if dc.has_fg else {}, bg_rgb = dc.bg if dc.has_bg else {},
		style = transmute(u8)ch.style,
		underline = u8(cell.cell_underline_style(ch, dc)),
		link = dc.link_id if .Has_Hyperlink in ch.flags else 0,
	}
}

@(private = "file")
_snap_note_link :: proc(c: ^Core, id: u16) {
	for known in c.snap_links do if known == id do return
	append(&c.snap_links, id)
}

// _snap_output: the last command's output lines on the main screen.
@(private = "file")
_snap_output :: proc(p: ^parser.Parser) -> (start, end: i64) {
	o := &p.cmd_out
	if !o.started || p.in_alt_screen do return -1, -1
	if !o.ended do return o.start, -1
	return o.start, o.end + (1 if o.end_col > 0 else 0)
}
