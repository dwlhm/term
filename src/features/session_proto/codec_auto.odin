package feature_session_proto

// Codecs of the automation payloads. A snapshot is written in pieces so the
// core can stream rows straight from its grid:
//   head · u32 n + n history rows · u32 n + n screen rows · u32 n + n links

import "base:runtime"
import ipc "../../platform/ipc"

enc_snapshot_req :: proc(w: ^ipc.Wire_Writer, m: Snapshot_Request) {
	ipc.ww_u32(w, m.id); ipc.ww_u32(w, m.history); ipc.ww_i64(w, m.since)
}

dec_snapshot_req :: proc(r: ^ipc.Wire_Reader) -> (m: Snapshot_Request) {
	m.id, m.history, m.since = ipc.wr_u32(r), ipc.wr_u32(r), ipc.wr_i64(r)
	return
}

enc_snapshot_head :: proc(w: ^ipc.Wire_Writer, m: Snapshot) {
	ipc.ww_u32(w, m.id); ipc.ww_u64(w, m.gen)
	ipc.ww_u16(w, m.cols); ipc.ww_u16(w, m.rows); ipc.ww_i64(w, m.top_line)
	ipc.ww_u16(w, m.cursor_row); ipc.ww_u16(w, m.cursor_col); ipc.ww_u8(w, m.cursor_shape)
	ipc.ww_bool(w, m.cursor_visible); ipc.ww_bool(w, m.cursor_blinking)
	ipc.ww_bool(w, m.alt_screen); ipc.ww_bool(w, m.app_cursor); ipc.ww_bool(w, m.bracketed_paste)
	ipc.ww_bool(w, m.report_focus); ipc.ww_bool(w, m.sync_output)
	ipc.ww_u8(w, m.kitty_flags); ipc.ww_u8(w, m.mouse_mode); ipc.ww_u8(w, m.mouse_format)
	ipc.ww_u8(w, u8(m.prompt_state)); ipc.ww_bool(w, m.has_cmd_exit); ipc.ww_i32(w, m.cmd_exit_code); ipc.ww_u32(w, m.cmd_seq)
	ipc.ww_i64(w, m.output_start); ipc.ww_i64(w, m.output_end)
	ipc.ww_bool(w, m.exited); ipc.ww_i32(w, m.exit_code)
	ipc.ww_u8(w, m.status_state); ipc.ww_str(w, m.status_app); ipc.ww_str(w, m.status_kind); ipc.ww_str(w, m.status_msg)
	ipc.ww_str(w, m.title); ipc.ww_str(w, m.process)
	ipc.ww_bool(w, m.history_truncated)
	ipc.ww_u64(w, m.input_gen); ipc.ww_u64(w, m.prompt_gen); ipc.ww_u64(w, m.status_gen)
}

@(private = "file")
_dec_snapshot_head :: proc(r: ^ipc.Wire_Reader, m: ^Snapshot) {
	m.id, m.gen = ipc.wr_u32(r), ipc.wr_u64(r)
	m.cols, m.rows, m.top_line = ipc.wr_u16(r), ipc.wr_u16(r), ipc.wr_i64(r)
	m.cursor_row, m.cursor_col, m.cursor_shape = ipc.wr_u16(r), ipc.wr_u16(r), ipc.wr_u8(r)
	m.cursor_visible, m.cursor_blinking = ipc.wr_bool(r), ipc.wr_bool(r)
	m.alt_screen, m.app_cursor, m.bracketed_paste = ipc.wr_bool(r), ipc.wr_bool(r), ipc.wr_bool(r)
	m.report_focus, m.sync_output = ipc.wr_bool(r), ipc.wr_bool(r)
	m.kitty_flags, m.mouse_mode, m.mouse_format = ipc.wr_u8(r), ipc.wr_u8(r), ipc.wr_u8(r)
	ps := ipc.wr_u8(r)
	if ps > u8(Prompt_State.Executing) do r.ok = false
	m.prompt_state = Prompt_State(ps)
	m.has_cmd_exit, m.cmd_exit_code, m.cmd_seq = ipc.wr_bool(r), ipc.wr_i32(r), ipc.wr_u32(r)
	m.output_start, m.output_end = ipc.wr_i64(r), ipc.wr_i64(r)
	m.exited, m.exit_code = ipc.wr_bool(r), ipc.wr_i32(r)
	m.status_state, m.status_app, m.status_kind, m.status_msg = ipc.wr_u8(r), ipc.wr_str(r), ipc.wr_str(r), ipc.wr_str(r)
	m.title, m.process = ipc.wr_str(r), ipc.wr_str(r)
	m.history_truncated = ipc.wr_bool(r)
	m.input_gen, m.prompt_gen, m.status_gen = ipc.wr_u64(r), ipc.wr_u64(r), ipc.wr_u64(r)
}

enc_snap_row :: proc(w: ^ipc.Wire_Writer, line: i64, wrap, prompt: bool, runs: []Snap_Run) {
	ipc.ww_i64(w, line); ipc.ww_bool(w, wrap); ipc.ww_bool(w, prompt)
	ipc.ww_u32(w, u32(len(runs)))
	for run in runs {
		ipc.ww_u16(w, run.cells)
		s := run.style
		ipc.ww_u8(w, s.fg); ipc.ww_u8(w, s.bg)
		ipc.ww_bool(w, s.has_fg_rgb); ipc.ww_bool(w, s.has_bg_rgb)
		for b in s.fg_rgb do ipc.ww_u8(w, b)
		for b in s.bg_rgb do ipc.ww_u8(w, b)
		ipc.ww_u8(w, s.style); ipc.ww_u8(w, s.underline); ipc.ww_u16(w, s.link)
		ipc.ww_str(w, run.text)
	}
}

enc_snap_link :: proc(w: ^ipc.Wire_Writer, l: Snap_Link) {
	ipc.ww_u16(w, l.id); ipc.ww_str(w, l.uri)
}

// dec_snapshot allocates the row, run and link slices from allocator; the
// strings are views into the payload.
dec_snapshot :: proc(r: ^ipc.Wire_Reader, allocator: runtime.Allocator) -> (m: Snapshot) {
	_dec_snapshot_head(r, &m)
	m.history = _dec_rows(r, allocator)
	m.screen = _dec_rows(r, allocator)
	n := _dec_count(r, 2 + 4)
	m.links = make([]Snap_Link, n, allocator)
	for &l in m.links do l = {ipc.wr_u16(r), ipc.wr_str(r)}
	return
}

// _dec_count reads a count and rejects one the rest of the payload cannot hold
// (each item takes at least min_size bytes), so a hostile count never allocates.
@(private = "file")
_dec_count :: proc(r: ^ipc.Wire_Reader, min_size: int) -> int {
	n := int(ipc.wr_u32(r))
	if !r.ok || n * min_size > len(r.buf) - r.off {
		r.ok = false
		return 0
	}
	return n
}

@(private = "file")
_dec_rows :: proc(r: ^ipc.Wire_Reader, allocator: runtime.Allocator) -> []Snap_Row {
	rows := make([]Snap_Row, _dec_count(r, 8 + 2 + 4), allocator)
	for &row in rows {
		row.line, row.wrap, row.prompt = ipc.wr_i64(r), ipc.wr_bool(r), ipc.wr_bool(r)
		row.runs = make([]Snap_Run, _dec_count(r, 2 + 14 + 4), allocator)
		for &run in row.runs {
			run.cells = ipc.wr_u16(r)
			s := &run.style
			s.fg, s.bg = ipc.wr_u8(r), ipc.wr_u8(r)
			s.has_fg_rgb, s.has_bg_rgb = ipc.wr_bool(r), ipc.wr_bool(r)
			for &b in s.fg_rgb do b = ipc.wr_u8(r)
			for &b in s.bg_rgb do b = ipc.wr_u8(r)
			s.style, s.underline, s.link = ipc.wr_u8(r), ipc.wr_u8(r), ipc.wr_u16(r)
			run.text = ipc.wr_str(r)
		}
	}
	return rows
}

enc_settle_req :: proc(w: ^ipc.Wire_Writer, m: Settle_Request) {
	ipc.ww_u32(w, m.id); ipc.ww_u64(w, m.since); ipc.ww_u32(w, m.quiet_ms); ipc.ww_u32(w, m.timeout_ms)
}

dec_settle_req :: proc(r: ^ipc.Wire_Reader) -> (m: Settle_Request) {
	m.id, m.since, m.quiet_ms, m.timeout_ms = ipc.wr_u32(r), ipc.wr_u64(r), ipc.wr_u32(r), ipc.wr_u32(r)
	return
}

enc_settle_result :: proc(w: ^ipc.Wire_Writer, m: Settle_Result) {
	ipc.ww_u32(w, m.id); ipc.ww_u64(w, m.gen); ipc.ww_bool(w, m.exited); ipc.ww_i32(w, m.exit_code)
}

dec_settle_result :: proc(r: ^ipc.Wire_Reader) -> (m: Settle_Result) {
	m.id, m.gen, m.exited, m.exit_code = ipc.wr_u32(r), ipc.wr_u64(r), ipc.wr_bool(r), ipc.wr_i32(r)
	return
}

enc_act_keys :: proc(w: ^ipc.Wire_Writer, id: u32, keys: []Act_Key) {
	ipc.ww_u32(w, id); ipc.ww_u8(w, u8(Act_Kind.Keys)); ipc.ww_u32(w, u32(len(keys)))
	for k in keys {
		ipc.ww_u8(w, k.key); ipc.ww_u32(w, k.char); ipc.ww_u8(w, k.mods)
	}
}

enc_act_text :: proc(w: ^ipc.Wire_Writer, id: u32, text: string, paste: bool) {
	ipc.ww_u32(w, id); ipc.ww_u8(w, u8(Act_Kind.Text)); ipc.ww_bool(w, paste); ipc.ww_str(w, text)
}

enc_act_mouse :: proc(w: ^ipc.Wire_Writer, id: u32, m: Act_Mouse) {
	ipc.ww_u32(w, id); ipc.ww_u8(w, u8(Act_Kind.Mouse))
	ipc.ww_u8(w, m.kind); ipc.ww_u8(w, m.button); ipc.ww_u8(w, m.mods); ipc.ww_u16(w, m.col); ipc.ww_u16(w, m.row)
}

dec_act_key :: proc(r: ^ipc.Wire_Reader) -> Act_Key {
	return {key = ipc.wr_u8(r), char = ipc.wr_u32(r), mods = ipc.wr_u8(r)}
}

dec_act_mouse :: proc(r: ^ipc.Wire_Reader) -> Act_Mouse {
	return {kind = ipc.wr_u8(r), button = ipc.wr_u8(r), mods = ipc.wr_u8(r), col = ipc.wr_u16(r), row = ipc.wr_u16(r)}
}

enc_lease_event :: proc(w: ^ipc.Wire_Writer, m: Lease_Event) {
	ipc.ww_u32(w, m.id); ipc.ww_u8(w, u8(m.kind)); ipc.ww_bool(w, m.interrupt); ipc.ww_u32(w, m.held); ipc.ww_i32(w, m.exit_code); ipc.ww_str(w, m.bytes)
}

dec_lease_event :: proc(r: ^ipc.Wire_Reader) -> (m: Lease_Event) {
	m.id = ipc.wr_u32(r)
	k := ipc.wr_u8(r)
	if k < u8(Lease_Event_Kind.Human) || k > u8(Lease_Event_Kind.Removed) do r.ok = false
	m.kind = Lease_Event_Kind(k) if r.ok else .Human
	m.interrupt, m.held, m.exit_code, m.bytes = ipc.wr_bool(r), ipc.wr_u32(r), ipc.wr_i32(r), ipc.wr_str(r)
	return
}
