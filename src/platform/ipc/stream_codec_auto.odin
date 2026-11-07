package platform_ipc

// Codecs of the automation payloads. A snapshot is written in pieces so the
// core can stream rows straight from its grid:
//   head · u32 n + n history rows · u32 n + n screen rows · u32 n + n links

import "base:runtime"

enc_snapshot_req :: proc(w: ^Wire_Writer, m: Snapshot_Request) {
	ww_u32(w, m.id); ww_u32(w, m.history); ww_i64(w, m.since)
}

dec_snapshot_req :: proc(r: ^Wire_Reader) -> (m: Snapshot_Request) {
	m.id, m.history, m.since = wr_u32(r), wr_u32(r), wr_i64(r)
	return
}

enc_snapshot_head :: proc(w: ^Wire_Writer, m: Snapshot) {
	ww_u32(w, m.id); ww_u64(w, m.gen)
	ww_u16(w, m.cols); ww_u16(w, m.rows); ww_i64(w, m.top_line)
	ww_u16(w, m.cursor_row); ww_u16(w, m.cursor_col); ww_u8(w, m.cursor_shape)
	ww_bool(w, m.cursor_visible); ww_bool(w, m.cursor_blinking)
	ww_bool(w, m.alt_screen); ww_bool(w, m.app_cursor); ww_bool(w, m.bracketed_paste)
	ww_bool(w, m.report_focus); ww_bool(w, m.sync_output)
	ww_u8(w, m.kitty_flags); ww_u8(w, m.mouse_mode); ww_u8(w, m.mouse_format)
	ww_u8(w, u8(m.prompt_state)); ww_bool(w, m.has_cmd_exit); ww_i32(w, m.cmd_exit_code); ww_u32(w, m.cmd_seq)
	ww_i64(w, m.output_start); ww_i64(w, m.output_end)
	ww_bool(w, m.exited); ww_i32(w, m.exit_code)
	ww_u8(w, m.status_state); ww_str(w, m.status_app); ww_str(w, m.status_kind); ww_str(w, m.status_msg)
	ww_str(w, m.title); ww_str(w, m.process)
	ww_bool(w, m.history_truncated)
}

@(private = "file")
_dec_snapshot_head :: proc(r: ^Wire_Reader, m: ^Snapshot) {
	m.id, m.gen = wr_u32(r), wr_u64(r)
	m.cols, m.rows, m.top_line = wr_u16(r), wr_u16(r), wr_i64(r)
	m.cursor_row, m.cursor_col, m.cursor_shape = wr_u16(r), wr_u16(r), wr_u8(r)
	m.cursor_visible, m.cursor_blinking = wr_bool(r), wr_bool(r)
	m.alt_screen, m.app_cursor, m.bracketed_paste = wr_bool(r), wr_bool(r), wr_bool(r)
	m.report_focus, m.sync_output = wr_bool(r), wr_bool(r)
	m.kitty_flags, m.mouse_mode, m.mouse_format = wr_u8(r), wr_u8(r), wr_u8(r)
	ps := wr_u8(r)
	if ps > u8(Prompt_State.Executing) do r.ok = false
	m.prompt_state = Prompt_State(ps)
	m.has_cmd_exit, m.cmd_exit_code, m.cmd_seq = wr_bool(r), wr_i32(r), wr_u32(r)
	m.output_start, m.output_end = wr_i64(r), wr_i64(r)
	m.exited, m.exit_code = wr_bool(r), wr_i32(r)
	m.status_state, m.status_app, m.status_kind, m.status_msg = wr_u8(r), wr_str(r), wr_str(r), wr_str(r)
	m.title, m.process = wr_str(r), wr_str(r)
	m.history_truncated = wr_bool(r)
}

enc_snap_row :: proc(w: ^Wire_Writer, line: i64, wrap, prompt: bool, runs: []Snap_Run) {
	ww_i64(w, line); ww_bool(w, wrap); ww_bool(w, prompt)
	ww_u32(w, u32(len(runs)))
	for run in runs {
		ww_u16(w, run.cells)
		s := run.style
		ww_u8(w, s.fg); ww_u8(w, s.bg)
		ww_bool(w, s.has_fg_rgb); ww_bool(w, s.has_bg_rgb)
		for b in s.fg_rgb do ww_u8(w, b)
		for b in s.bg_rgb do ww_u8(w, b)
		ww_u8(w, s.style); ww_u8(w, s.underline); ww_u16(w, s.link)
		ww_str(w, run.text)
	}
}

enc_snap_link :: proc(w: ^Wire_Writer, l: Snap_Link) {
	ww_u16(w, l.id); ww_str(w, l.uri)
}

// dec_snapshot allocates the row, run and link slices from allocator; the
// strings are views into the payload.
dec_snapshot :: proc(r: ^Wire_Reader, allocator: runtime.Allocator) -> (m: Snapshot) {
	_dec_snapshot_head(r, &m)
	m.history = _dec_rows(r, allocator)
	m.screen = _dec_rows(r, allocator)
	n := _dec_count(r, 2 + 4)
	m.links = make([]Snap_Link, n, allocator)
	for &l in m.links do l = {wr_u16(r), wr_str(r)}
	return
}

// _dec_count reads a count and rejects one the rest of the payload cannot hold
// (each item takes at least min_size bytes), so a hostile count never allocates.
@(private = "file")
_dec_count :: proc(r: ^Wire_Reader, min_size: int) -> int {
	n := int(wr_u32(r))
	if !r.ok || n * min_size > len(r.buf) - r.off {
		r.ok = false
		return 0
	}
	return n
}

@(private = "file")
_dec_rows :: proc(r: ^Wire_Reader, allocator: runtime.Allocator) -> []Snap_Row {
	rows := make([]Snap_Row, _dec_count(r, 8 + 2 + 4), allocator)
	for &row in rows {
		row.line, row.wrap, row.prompt = wr_i64(r), wr_bool(r), wr_bool(r)
		row.runs = make([]Snap_Run, _dec_count(r, 2 + 14 + 4), allocator)
		for &run in row.runs {
			run.cells = wr_u16(r)
			s := &run.style
			s.fg, s.bg = wr_u8(r), wr_u8(r)
			s.has_fg_rgb, s.has_bg_rgb = wr_bool(r), wr_bool(r)
			for &b in s.fg_rgb do b = wr_u8(r)
			for &b in s.bg_rgb do b = wr_u8(r)
			s.style, s.underline, s.link = wr_u8(r), wr_u8(r), wr_u16(r)
			run.text = wr_str(r)
		}
	}
	return rows
}

enc_settle_req :: proc(w: ^Wire_Writer, m: Settle_Request) {
	ww_u32(w, m.id); ww_u64(w, m.since); ww_u32(w, m.quiet_ms); ww_u32(w, m.timeout_ms)
}

dec_settle_req :: proc(r: ^Wire_Reader) -> (m: Settle_Request) {
	m.id, m.since, m.quiet_ms, m.timeout_ms = wr_u32(r), wr_u64(r), wr_u32(r), wr_u32(r)
	return
}

enc_settle_result :: proc(w: ^Wire_Writer, m: Settle_Result) {
	ww_u32(w, m.id); ww_u64(w, m.gen); ww_bool(w, m.exited); ww_i32(w, m.exit_code)
}

dec_settle_result :: proc(r: ^Wire_Reader) -> (m: Settle_Result) {
	m.id, m.gen, m.exited, m.exit_code = wr_u32(r), wr_u64(r), wr_bool(r), wr_i32(r)
	return
}

enc_act_keys :: proc(w: ^Wire_Writer, id: u32, keys: []Act_Key) {
	ww_u32(w, id); ww_u8(w, u8(Act_Kind.Keys)); ww_u32(w, u32(len(keys)))
	for k in keys {
		ww_u8(w, k.key); ww_u32(w, k.char); ww_u8(w, k.mods)
	}
}

enc_act_text :: proc(w: ^Wire_Writer, id: u32, text: string, paste: bool) {
	ww_u32(w, id); ww_u8(w, u8(Act_Kind.Text)); ww_bool(w, paste); ww_str(w, text)
}

enc_act_mouse :: proc(w: ^Wire_Writer, id: u32, m: Act_Mouse) {
	ww_u32(w, id); ww_u8(w, u8(Act_Kind.Mouse))
	ww_u8(w, m.kind); ww_u8(w, m.button); ww_u8(w, m.mods); ww_u16(w, m.col); ww_u16(w, m.row)
}

dec_act_key :: proc(r: ^Wire_Reader) -> Act_Key {
	return {key = wr_u8(r), char = wr_u32(r), mods = wr_u8(r)}
}

dec_act_mouse :: proc(r: ^Wire_Reader) -> Act_Mouse {
	return {kind = wr_u8(r), button = wr_u8(r), mods = wr_u8(r), col = wr_u16(r), row = wr_u16(r)}
}

enc_lease_event :: proc(w: ^Wire_Writer, m: Lease_Event) {
	ww_u32(w, m.id); ww_u8(w, u8(m.kind)); ww_bool(w, m.interrupt); ww_u32(w, m.held); ww_i32(w, m.exit_code); ww_str(w, m.bytes)
}

dec_lease_event :: proc(r: ^Wire_Reader) -> (m: Lease_Event) {
	m.id = wr_u32(r)
	k := wr_u8(r)
	if k < u8(Lease_Event_Kind.Human) || k > u8(Lease_Event_Kind.Removed) do r.ok = false
	m.kind = Lease_Event_Kind(k) if r.ok else .Human
	m.interrupt, m.held, m.exit_code, m.bytes = wr_bool(r), wr_u32(r), wr_i32(r), wr_str(r)
	return
}
