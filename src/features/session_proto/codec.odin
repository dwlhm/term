package feature_session_proto

// Encoders/decoders for the structs in msg.odin. enc_* append to a
// Wire_Writer; dec_* read from a Wire_Reader and leave validity in r.ok.

import ipc "../../platform/ipc"

enc_hello :: proc(w: ^ipc.Wire_Writer, m: Hello_Msg) {
	ipc.ww_u32(w, m.version)
	ipc.ww_u8(w, u8(m.role))
	ipc.ww_u64(w, m.caps)
	ipc.ww_str(w, m.build)
}

dec_hello :: proc(r: ^ipc.Wire_Reader) -> (m: Hello_Msg) {
	m.version = ipc.wr_u32(r)
	role := ipc.wr_u8(r)
	if role < u8(Stream_Role.Core) || role > u8(Stream_Role.Cli) do r.ok = false
	m.role = Stream_Role(role)
	m.caps = ipc.wr_u64(r)
	m.build = ipc.wr_str(r)
	return
}

enc_size :: proc(w: ^ipc.Wire_Writer, m: Size_Msg) {
	ipc.ww_u16(w, m.cols); ipc.ww_u16(w, m.rows); ipc.ww_u16(w, m.xpixel); ipc.ww_u16(w, m.ypixel)
}

dec_size :: proc(r: ^ipc.Wire_Reader) -> (m: Size_Msg) {
	m.cols, m.rows, m.xpixel, m.ypixel = ipc.wr_u16(r), ipc.wr_u16(r), ipc.wr_u16(r), ipc.wr_u16(r)
	return
}

enc_spawn :: proc(w: ^ipc.Wire_Writer, m: ^Spawn_Msg) {
	ipc.ww_u32(w, u32(m.argc))
	for s in m.argv[:m.argc] do ipc.ww_str(w, s)
	ipc.ww_u32(w, u32(m.envc))
	for s in m.env[:m.envc] do ipc.ww_str(w, s)
	ipc.ww_str(w, m.cwd)
	enc_size(w, m.size)
}

dec_spawn :: proc(r: ^ipc.Wire_Reader, m: ^Spawn_Msg) {
	m^ = {}
	m.argc = int(ipc.wr_u32(r))
	if m.argc < 1 || m.argc > STREAM_MAX_ARGV {
		r.ok = false
		return
	}
	for i in 0..<m.argc do m.argv[i] = ipc.wr_str(r)
	m.envc = int(ipc.wr_u32(r))
	if m.envc > STREAM_MAX_ENV {
		r.ok = false
		return
	}
	for i in 0..<m.envc do m.env[i] = ipc.wr_str(r)
	m.cwd = ipc.wr_str(r)
	m.size = dec_size(r)
	if m.cols == 0 || m.rows == 0 do r.ok = false
}

enc_exit :: proc(w: ^ipc.Wire_Writer, m: Exit_Msg) {
	ipc.ww_i32(w, m.code); ipc.ww_i32(w, m.signal); ipc.ww_bool(w, m.signaled)
}

dec_exit :: proc(r: ^ipc.Wire_Reader) -> (m: Exit_Msg) {
	m.code, m.signal, m.signaled = ipc.wr_i32(r), ipc.wr_i32(r), ipc.wr_bool(r)
	return
}

enc_proc_info :: proc(w: ^ipc.Wire_Writer, m: Proc_Info_Msg) {
	ipc.ww_i32(w, m.pgid); ipc.ww_str(w, m.name); ipc.ww_str(w, m.cwd)
}

dec_proc_info :: proc(r: ^ipc.Wire_Reader) -> (m: Proc_Info_Msg) {
	m.pgid, m.name, m.cwd = ipc.wr_i32(r), ipc.wr_str(r), ipc.wr_str(r)
	return
}

enc_welcome :: proc(w: ^ipc.Wire_Writer, m: Welcome_Msg) {
	ipc.ww_u32(w, m.version); ipc.ww_u64(w, m.instance); ipc.ww_u32(w, m.pid)
	ipc.ww_str(w, m.build); ipc.ww_u8(w, m.previous); ipc.ww_u32(w, m.crashes); ipc.ww_u32(w, m.count)
}

dec_welcome :: proc(r: ^ipc.Wire_Reader) -> (m: Welcome_Msg) {
	m.version, m.instance, m.pid = ipc.wr_u32(r), ipc.wr_u64(r), ipc.wr_u32(r)
	m.build, m.previous, m.crashes, m.count = ipc.wr_str(r), ipc.wr_u8(r), ipc.wr_u32(r), ipc.wr_u32(r)
	return
}

enc_held :: proc(w: ^ipc.Wire_Writer, m: Held_Session) {
	ipc.ww_u32(w, m.id); ipc.ww_u32(w, m.pid); ipc.ww_u64(w, u64(m.started_unix)); enc_size(w, m.size)
	ipc.ww_bool(w, m.exited); enc_exit(w, m.exit)
}

dec_held :: proc(r: ^ipc.Wire_Reader) -> (m: Held_Session) {
	m.id, m.pid, m.started_unix, m.size = ipc.wr_u32(r), ipc.wr_u32(r), i64(ipc.wr_u64(r)), dec_size(r)
	m.exited, m.exit = ipc.wr_bool(r), dec_exit(r)
	return
}

enc_attach :: proc(w: ^ipc.Wire_Writer, m: Attach_Msg) {
	ipc.ww_u32(w, m.id); enc_size(w, m.size); ipc.ww_u32(w, m.history); ipc.ww_bool(w, m.observe)
}

dec_attach :: proc(r: ^ipc.Wire_Reader) -> (m: Attach_Msg) {
	m.id, m.size, m.history, m.observe = ipc.wr_u32(r), dec_size(r), ipc.wr_u32(r), ipc.wr_bool(r)
	return
}

enc_facts :: proc(w: ^ipc.Wire_Writer, m: Facts_Msg) {
	ipc.ww_u16(w, m.cell_w); ipc.ww_u16(w, m.cell_h)
}

dec_facts :: proc(r: ^ipc.Wire_Reader) -> (m: Facts_Msg) {
	m.cell_w, m.cell_h = ipc.wr_u16(r), ipc.wr_u16(r)
	return
}

enc_row :: proc(w: ^ipc.Wire_Writer, m: Session_Row) {
	ipc.ww_u32(w, m.id); ipc.ww_u8(w, u8(m.state)); ipc.ww_bool(w, m.active); ipc.ww_bool(w, m.attached)
	ipc.ww_u32(w, m.pid); ipc.ww_u32(w, m.elapsed_s); ipc.ww_u32(w, m.quiet_s); ipc.ww_i32(w, m.exit_code); ipc.ww_bool(w, m.endpoint)
	enc_row_request(w, m.request)
	ipc.ww_str(w, m.process); ipc.ww_str(w, m.cwd); ipc.ww_str(w, m.title); ipc.ww_str(w, m.status); ipc.ww_str(w, m.controller); ipc.ww_bool(w, m.controller_pass)
}

dec_row :: proc(r: ^ipc.Wire_Reader) -> (m: Session_Row) {
	m.id = ipc.wr_u32(r)
	state := ipc.wr_u8(r)
	if state < u8(Session_State.Idle) || state > u8(Session_State.Exited) do r.ok = false
	m.state = Session_State(state)
	m.active, m.attached = ipc.wr_bool(r), ipc.wr_bool(r)
	m.pid, m.elapsed_s, m.quiet_s, m.exit_code, m.endpoint = ipc.wr_u32(r), ipc.wr_u32(r), ipc.wr_u32(r), ipc.wr_i32(r), ipc.wr_bool(r)
	m.request = dec_row_request(r)
	m.process, m.cwd, m.title, m.status, m.controller = ipc.wr_str(r), ipc.wr_str(r), ipc.wr_str(r), ipc.wr_str(r), ipc.wr_str(r)
	m.controller_pass = ipc.wr_bool(r)
	return
}

enc_observe_result :: proc(w: ^ipc.Wire_Writer, m: Observe_Result) {
	enc_row(w, m.row)
	ipc.ww_u16(w, m.cols); ipc.ww_u16(w, m.rows)
	ipc.ww_bool(w, m.is_alt)
	ipc.ww_u8(w, u8(m.prompt_state))
	ipc.ww_bool(w, m.has_cmd_exit)
	ipc.ww_i32(w, m.cmd_exit_code)
	ipc.ww_u32(w, m.cmd_seq)
	ipc.ww_str(w, m.text)
}

dec_observe_result :: proc(r: ^ipc.Wire_Reader) -> (m: Observe_Result) {
	m.row = dec_row(r)
	m.cols, m.rows = ipc.wr_u16(r), ipc.wr_u16(r)
	m.is_alt = ipc.wr_bool(r)
	ps := ipc.wr_u8(r)
	if ps > u8(Prompt_State.Executing) do r.ok = false
	m.prompt_state = Prompt_State(ps)
	m.has_cmd_exit = ipc.wr_bool(r)
	m.cmd_exit_code = ipc.wr_i32(r)
	m.cmd_seq = ipc.wr_u32(r)
	m.text = ipc.wr_str(r)
	return
}

enc_watch_req :: proc(w: ^ipc.Wire_Writer, m: Watch_Request) {
	ipc.ww_u32(w, m.id)
	ipc.ww_u8(w, transmute(u8)m.events)
	ipc.ww_u32(w, m.timeout_ms)
	ipc.ww_bool(w, m.has_since)
	ipc.ww_u32(w, m.since)
}

dec_watch_req :: proc(r: ^ipc.Wire_Reader) -> (m: Watch_Request) {
	m.id = ipc.wr_u32(r)
	m.events = transmute(Watch_Event_Flags)ipc.wr_u8(r)
	m.timeout_ms = ipc.wr_u32(r)
	m.has_since = ipc.wr_bool(r)
	m.since = ipc.wr_u32(r)
	return
}

enc_watch_result :: proc(w: ^ipc.Wire_Writer, m: Watch_Result) {
	ipc.ww_u32(w, m.id)
	ipc.ww_u8(w, u8(m.event))
	ipc.ww_i32(w, m.exit_code)
	ipc.ww_u8(w, u8(m.prompt_state))
	ipc.ww_u32(w, m.cmd_seq)
}

dec_watch_result :: proc(r: ^ipc.Wire_Reader) -> (m: Watch_Result) {
	m.id = ipc.wr_u32(r)
	ev := ipc.wr_u8(r)
	if ev > u8(Watch_Event.Exit) do r.ok = false
	m.event = Watch_Event(ev)
	m.exit_code = ipc.wr_i32(r)
	ps := ipc.wr_u8(r)
	if ps > u8(Prompt_State.Executing) do r.ok = false
	m.prompt_state = Prompt_State(ps)
	m.cmd_seq = ipc.wr_u32(r)
	return
}
