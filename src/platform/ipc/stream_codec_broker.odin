package platform_ipc

// Codecs of broker request payloads (stream_msg_broker.odin).

enc_row_request :: proc(w: ^Wire_Writer, m: Row_Request) {
	ww_u32(w, m.serving); ww_u64(w, m.serving_id); ww_u32(w, m.awaiting); ww_u32(w, m.listening)
}

dec_row_request :: proc(r: ^Wire_Reader) -> (m: Row_Request) {
	m.serving, m.serving_id, m.awaiting, m.listening = wr_u32(r), wr_u64(r), wr_u32(r), wr_u32(r)
	return
}

enc_tell_req :: proc(w: ^Wire_Writer, m: Tell_Request) {
	ww_u32(w, m.to); ww_u32(w, m.from); ww_u32(w, m.timeout_ms); ww_u64(w, m.parent); ww_bool(w, m.wait); ww_bool(w, m.shell)
	ww_str(w, m.body)
}

dec_tell_req :: proc(r: ^Wire_Reader) -> (m: Tell_Request) {
	m.to, m.from, m.timeout_ms, m.parent, m.wait, m.shell = wr_u32(r), wr_u32(r), wr_u32(r), wr_u64(r), wr_bool(r), wr_bool(r)
	m.body = wr_str(r)
	return
}

enc_tell_result :: proc(w: ^Wire_Writer, m: Tell_Result) {
	ww_u64(w, m.id)
	ww_u8(w, u8(m.phase)); ww_u8(w, u8(m.reject)); ww_u8(w, u8(m.status))
	ww_i32(w, m.exit_code); ww_u32(w, m.from); ww_u32(w, m.to)
	ww_str(w, m.progress); ww_str(w, m.text)
}

dec_tell_result :: proc(r: ^Wire_Reader) -> (m: Tell_Result) {
	m.id = wr_u64(r)
	phase, reject, status := wr_u8(r), wr_u8(r), wr_u8(r)
	if phase < u8(Tell_Phase.Accepted) || phase > u8(Tell_Phase.Finished) do r.ok = false
	if reject > u8(max(Tell_Reject)) || status > u8(max(Tell_Status)) do r.ok = false
	m.phase, m.reject, m.status = Tell_Phase(phase), Tell_Reject(reject), Tell_Status(status)
	m.exit_code, m.from, m.to = wr_i32(r), wr_u32(r), wr_u32(r)
	m.progress, m.text = wr_str(r), wr_str(r)
	return
}

enc_next_result :: proc(w: ^Wire_Writer, m: Next_Result) {
	ww_u64(w, m.id); ww_u32(w, m.from); ww_u64(w, m.parent); ww_str(w, m.body)
}

dec_next_result :: proc(r: ^Wire_Reader) -> (m: Next_Result) {
	m.id, m.from, m.parent, m.body = wr_u64(r), wr_u32(r), wr_u64(r), wr_str(r)
	return
}

enc_answer :: proc(w: ^Wire_Writer, m: Answer_Msg) {
	ww_u32(w, m.by); ww_u64(w, m.id); ww_bool(w, m.failed); ww_str(w, m.text)
}

dec_answer :: proc(r: ^Wire_Reader) -> (m: Answer_Msg) {
	m.by, m.id, m.failed, m.text = wr_u32(r), wr_u64(r), wr_bool(r), wr_str(r)
	return
}

enc_result_req :: proc(w: ^Wire_Writer, m: Result_Request) {
	ww_u32(w, m.caller); ww_bool(w, m.wait); ww_bool(w, m.follow); ww_u32(w, m.timeout_ms)
	ww_u32(w, m.n_ids)
	ids := m.ids
	for id in ids[:min(m.n_ids, RESULT_MAX_IDS)] do ww_u64(w, id)
}

dec_result_req :: proc(r: ^Wire_Reader) -> (m: Result_Request) {
	m.caller, m.wait, m.follow, m.timeout_ms = wr_u32(r), wr_bool(r), wr_bool(r), wr_u32(r)
	m.n_ids = wr_u32(r)
	if m.n_ids == 0 || m.n_ids > RESULT_MAX_IDS {
		r.ok = false
		return
	}
	n := m.n_ids // a range bound is evaluated every iteration
	for k in 0..<n do m.ids[k] = wr_u64(r)
	return
}
