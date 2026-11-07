package platform_ipc

// Encoders/decoders for the structs in stream_msg.odin. enc_* append to a
// Wire_Writer; dec_* read from a Wire_Reader and leave validity in r.ok.

enc_hello :: proc(w: ^Wire_Writer, m: Hello_Msg) {
	ww_u32(w, m.version)
	ww_u8(w, u8(m.role))
	ww_u64(w, m.caps)
	ww_str(w, m.build)
}

dec_hello :: proc(r: ^Wire_Reader) -> (m: Hello_Msg) {
	m.version = wr_u32(r)
	role := wr_u8(r)
	if role < u8(Stream_Role.Core) || role > u8(Stream_Role.Cli) do r.ok = false
	m.role = Stream_Role(role)
	m.caps = wr_u64(r)
	m.build = wr_str(r)
	return
}

enc_size :: proc(w: ^Wire_Writer, m: Size_Msg) {
	ww_u16(w, m.cols); ww_u16(w, m.rows); ww_u16(w, m.xpixel); ww_u16(w, m.ypixel)
}

dec_size :: proc(r: ^Wire_Reader) -> (m: Size_Msg) {
	m.cols, m.rows, m.xpixel, m.ypixel = wr_u16(r), wr_u16(r), wr_u16(r), wr_u16(r)
	return
}

enc_spawn :: proc(w: ^Wire_Writer, m: ^Spawn_Msg) {
	ww_u32(w, u32(m.argc))
	for s in m.argv[:m.argc] do ww_str(w, s)
	ww_u32(w, u32(m.envc))
	for s in m.env[:m.envc] do ww_str(w, s)
	ww_str(w, m.cwd)
	enc_size(w, m.size)
}

dec_spawn :: proc(r: ^Wire_Reader, m: ^Spawn_Msg) {
	m^ = {}
	m.argc = int(wr_u32(r))
	if m.argc < 1 || m.argc > STREAM_MAX_ARGV {
		r.ok = false
		return
	}
	for i in 0..<m.argc do m.argv[i] = wr_str(r)
	m.envc = int(wr_u32(r))
	if m.envc > STREAM_MAX_ENV {
		r.ok = false
		return
	}
	for i in 0..<m.envc do m.env[i] = wr_str(r)
	m.cwd = wr_str(r)
	m.size = dec_size(r)
	if m.cols == 0 || m.rows == 0 do r.ok = false
}

enc_exit :: proc(w: ^Wire_Writer, m: Exit_Msg) {
	ww_i32(w, m.code); ww_i32(w, m.signal); ww_bool(w, m.signaled)
}

dec_exit :: proc(r: ^Wire_Reader) -> (m: Exit_Msg) {
	m.code, m.signal, m.signaled = wr_i32(r), wr_i32(r), wr_bool(r)
	return
}

enc_proc_info :: proc(w: ^Wire_Writer, m: Proc_Info_Msg) {
	ww_i32(w, m.pgid); ww_str(w, m.name); ww_str(w, m.cwd)
}

dec_proc_info :: proc(r: ^Wire_Reader) -> (m: Proc_Info_Msg) {
	m.pgid, m.name, m.cwd = wr_i32(r), wr_str(r), wr_str(r)
	return
}

enc_welcome :: proc(w: ^Wire_Writer, m: Welcome_Msg) {
	ww_u32(w, m.version); ww_u64(w, m.instance); ww_u32(w, m.pid)
	ww_str(w, m.build); ww_u8(w, m.previous); ww_u32(w, m.crashes); ww_u32(w, m.count)
}

dec_welcome :: proc(r: ^Wire_Reader) -> (m: Welcome_Msg) {
	m.version, m.instance, m.pid = wr_u32(r), wr_u64(r), wr_u32(r)
	m.build, m.previous, m.crashes, m.count = wr_str(r), wr_u8(r), wr_u32(r), wr_u32(r)
	return
}

enc_held :: proc(w: ^Wire_Writer, m: Held_Session) {
	ww_u32(w, m.id); ww_u32(w, m.pid); ww_u64(w, u64(m.started_unix)); enc_size(w, m.size)
	ww_bool(w, m.exited); enc_exit(w, m.exit)
}

dec_held :: proc(r: ^Wire_Reader) -> (m: Held_Session) {
	m.id, m.pid, m.started_unix, m.size = wr_u32(r), wr_u32(r), i64(wr_u64(r)), dec_size(r)
	m.exited, m.exit = wr_bool(r), dec_exit(r)
	return
}

enc_attach :: proc(w: ^Wire_Writer, m: Attach_Msg) {
	ww_u32(w, m.id); enc_size(w, m.size); ww_u32(w, m.history); ww_bool(w, m.observe)
}

dec_attach :: proc(r: ^Wire_Reader) -> (m: Attach_Msg) {
	m.id, m.size, m.history, m.observe = wr_u32(r), dec_size(r), wr_u32(r), wr_bool(r)
	return
}

enc_facts :: proc(w: ^Wire_Writer, m: Facts_Msg) {
	ww_u16(w, m.cell_w); ww_u16(w, m.cell_h)
}

dec_facts :: proc(r: ^Wire_Reader) -> (m: Facts_Msg) {
	m.cell_w, m.cell_h = wr_u16(r), wr_u16(r)
	return
}

enc_row :: proc(w: ^Wire_Writer, m: Session_Row) {
	ww_u32(w, m.id); ww_u8(w, u8(m.state)); ww_bool(w, m.active); ww_bool(w, m.attached)
	ww_u32(w, m.pid); ww_u32(w, m.elapsed_s); ww_u32(w, m.quiet_s); ww_i32(w, m.exit_code); ww_bool(w, m.endpoint)
	enc_row_request(w, m.request)
	ww_str(w, m.process); ww_str(w, m.cwd); ww_str(w, m.title); ww_str(w, m.status); ww_str(w, m.controller)
}

dec_row :: proc(r: ^Wire_Reader) -> (m: Session_Row) {
	m.id = wr_u32(r)
	state := wr_u8(r)
	if state < u8(Session_State.Idle) || state > u8(Session_State.Exited) do r.ok = false
	m.state = Session_State(state)
	m.active, m.attached = wr_bool(r), wr_bool(r)
	m.pid, m.elapsed_s, m.quiet_s, m.exit_code, m.endpoint = wr_u32(r), wr_u32(r), wr_u32(r), wr_i32(r), wr_bool(r)
	m.request = dec_row_request(r)
	m.process, m.cwd, m.title, m.status, m.controller = wr_str(r), wr_str(r), wr_str(r), wr_str(r), wr_str(r)
	return
}

enc_observe_result :: proc(w: ^Wire_Writer, m: Observe_Result) {
	enc_row(w, m.row)
	ww_u16(w, m.cols); ww_u16(w, m.rows)
	ww_bool(w, m.is_alt)
	ww_u8(w, u8(m.prompt_state))
	ww_bool(w, m.has_cmd_exit)
	ww_i32(w, m.cmd_exit_code)
	ww_u32(w, m.cmd_seq)
	ww_str(w, m.text)
}

dec_observe_result :: proc(r: ^Wire_Reader) -> (m: Observe_Result) {
	m.row = dec_row(r)
	m.cols, m.rows = wr_u16(r), wr_u16(r)
	m.is_alt = wr_bool(r)
	ps := wr_u8(r)
	if ps > u8(Prompt_State.Executing) do r.ok = false
	m.prompt_state = Prompt_State(ps)
	m.has_cmd_exit = wr_bool(r)
	m.cmd_exit_code = wr_i32(r)
	m.cmd_seq = wr_u32(r)
	m.text = wr_str(r)
	return
}

enc_watch_req :: proc(w: ^Wire_Writer, m: Watch_Request) {
	ww_u32(w, m.id)
	ww_u8(w, transmute(u8)m.events)
	ww_u32(w, m.timeout_ms)
	ww_bool(w, m.has_since)
	ww_u32(w, m.since)
}

dec_watch_req :: proc(r: ^Wire_Reader) -> (m: Watch_Request) {
	m.id = wr_u32(r)
	m.events = transmute(Watch_Event_Flags)wr_u8(r)
	m.timeout_ms = wr_u32(r)
	m.has_since = wr_bool(r)
	m.since = wr_u32(r)
	return
}

enc_watch_result :: proc(w: ^Wire_Writer, m: Watch_Result) {
	ww_u32(w, m.id)
	ww_u8(w, u8(m.event))
	ww_i32(w, m.exit_code)
	ww_u8(w, u8(m.prompt_state))
	ww_u32(w, m.cmd_seq)
}

dec_watch_result :: proc(r: ^Wire_Reader) -> (m: Watch_Result) {
	m.id = wr_u32(r)
	ev := wr_u8(r)
	if ev > u8(Watch_Event.Exit) do r.ok = false
	m.event = Watch_Event(ev)
	m.exit_code = wr_i32(r)
	ps := wr_u8(r)
	if ps > u8(Prompt_State.Executing) do r.ok = false
	m.prompt_state = Prompt_State(ps)
	m.cmd_seq = wr_u32(r)
	return
}

// stream_hello_check validates a peer HELLO against what this side speaks.
stream_hello_check :: proc(payload: []u8, allowed: bit_set[Stream_Role]) -> (m: Hello_Msg, err: Fail_Code, ok: bool) {
	r := wire_reader(payload)
	m = dec_hello(&r)
	if !wr_done(&r) do return m, .Bad_Request, false
	if m.version != STREAM_PROTO_VERSION do return m, .Version, false
	if m.role not_in allowed do return m, .Bad_Request, false
	return m, {}, true
}
