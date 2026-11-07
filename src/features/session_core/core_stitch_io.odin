package feature_session_core

// The IO half of a stitch: wheel encoding for the program's mouse mode,
// screen snapshots, the reply text and the hold buffer. Nothing here sleeps.

import "core:strings"
import terminal "../../core/terminal"
import grid "../../core/terminal/grid"
import ie "../../core/terminal/input_encode"
import ipc "../../platform/ipc"

// _stitch_reply answers the read with the stitched history and the screen the
// read started on (the view has scrolled away and comes back to it).
@(private)
_stitch_reply :: proc(c: ^Core, s: ^Core_Session) {
	st := s.stitch
	clear(&c.text)
	b := strings.Builder{buf = c.text}
	_stitch_write_history(&b, st.hist[:], min(st.got, st.want))
	_stitch_write_page(&b, &st.pages[2])
	if st.restore_failed do strings.write_string(&b, CORE_READ_RESTORE_NOTE)
	c.text = b.buf
	n := min(len(c.text), ipc.STREAM_MAX_PAYLOAD)
	if core_viewer_current(c, st.viewer, st.seq) {
		v := &c.viewers[st.viewer]
		ipc.stream_send(&v.conn, ipc.MSG_TEXT, 0, c.text[len(c.text) - n:])
	}
}

// _stitch_write_history writes the newest `keep` lines of a newest-first
// buffer in reading order (oldest first).
@(private)
_stitch_write_history :: proc(b: ^strings.Builder, hist: []u8, keep: int) {
	end, lines := len(hist), 0
	if keep <= 0 do return
	// Cut the buffer after the keep-th line (the newest keep lines).
	scan := 0
	for lines < keep {
		i := strings.index_byte(string(hist[scan:]), '\n')
		if i < 0 {
			scan = len(hist)
			break
		}
		scan += i + 1
		lines += 1
	}
	end = scan
	for end > 0 {
		start := end - 1 if hist[end - 1] == '\n' else end
		for start > 0 && hist[start - 1] != '\n' do start -= 1
		strings.write_bytes(b, hist[start:end])
		end = start
	}
}

// _stitch_write_page appends a page's rows, trailing empty rows dropped (the
// same shape terminal_text gives the active screen).
@(private)
_stitch_write_page :: proc(b: ^strings.Builder, page: ^Stitch_Page) {
	start, keep := len(b.buf), len(b.buf)
	for i in 0..<page.count {
		row := string(page.text[page.off[i]:page.off[i] + page.len[i]])
		strings.write_string(b, row)
		if len(row) > 0 do keep = len(b.buf)
		strings.write_byte(b, '\n')
	}
	resize(&b.buf, keep)
	if keep > start do strings.write_byte(b, '\n')
}

@(private)
_stitch_input :: proc(c: ^Core, s: ^Core_Session, bytes: []u8) {
	if len(bytes) == 0 || s.exited do return
	core_holder_send(c, s.holder, ipc.MSG_INPUT, s.id, bytes)
}

// _stitch_wheel encodes one wheel notch at the screen centre the way the
// program asked for mouse reports. 0 = it wants none.
@(private)
_stitch_wheel :: proc(t: ^terminal.Terminal, down: bool, out: []u8) -> int {
	col := clamp(t.cols / 2, 1, t.cols)
	row := clamp(t.rows / 2, 1, t.rows)
	cw := t.parser.cell_w if t.parser.cell_w > 0 else 1
	ch := t.parser.cell_h if t.parser.cell_h > 0 else 1
	ev := ie.Mouse_Event{
		kind = .Wheel_Down if down else .Wheel_Up,
		col  = col, row = row,
		px   = (col - 1) * cw + 1, py = (row - 1) * ch + 1,
	}
	enc, ok := ie.encode_mouse(ev, ie.mouse_modes(&t.parser))
	if !ok do return 0
	return copy(out, enc.bytes[:enc.len])
}

// _stitch_read snapshots the visible screen into a page.
@(private)
_stitch_read :: proc(s: ^Core_Session, page: ^Stitch_Page) -> bool {
	t := &s.sess.term
	rows := min(t.rows, STITCH_MAX_ROWS)
	need := rows * (t.cols * STITCH_CELL_BYTES + 1)
	if need > cap(page.text) do return false
	page.count = 0
	clear(&page.text)
	b := strings.Builder{buf = page.text}
	for r in 0..<rows {
		row := grid.grid_get_row(&t.grid, r)
		last := terminal.terminal_row_last_content_col(row)
		start := len(b.buf)
		for col in 0..=last do terminal.terminal_cell_append_utf8(&b, &t.egc_pool, row.cells[col])
		page.off[r], page.len[r] = start, len(b.buf) - start
		if len(b.buf) > need { // an EGC cluster wider than the bound: no stitch
			page.text = b.buf
			return false
		}
	}
	page.text, page.count = b.buf, rows
	return true
}

@(private)
_stitch_rows :: proc(page: ^Stitch_Page, out: []string) -> []string {
	for i in 0..<page.count do out[i] = string(page.text[page.off[i]:page.off[i] + page.len[i]])
	return out[:page.count]
}

// core_stitch_free releases a session's stitch buffers.
core_stitch_free :: proc(s: ^Core_Session) {
	if s.stitch == nil do return
	delete(s.stitch.hist)
	delete(s.stitch.hold)
	for &p in s.stitch.pages do delete(p.text)
	free(s.stitch)
	s.stitch = nil
}
