package feature_session_proto

// Codecs of broker request payloads (msg_broker.odin).

import ipc "../../platform/ipc"

enc_row_request :: proc(w: ^ipc.Wire_Writer, m: Row_Request) {
	ipc.ww_u32(w, m.serving); ipc.ww_u64(w, m.serving_id); ipc.ww_u32(w, m.awaiting); ipc.ww_u32(w, m.listening)
}

dec_row_request :: proc(r: ^ipc.Wire_Reader) -> (m: Row_Request) {
	m.serving, m.serving_id, m.awaiting, m.listening = ipc.wr_u32(r), ipc.wr_u64(r), ipc.wr_u32(r), ipc.wr_u32(r)
	return
}

enc_tell_req :: proc(w: ^ipc.Wire_Writer, m: Tell_Request) {
	ipc.ww_u32(w, m.to); ipc.ww_u32(w, m.from); ipc.ww_u32(w, m.timeout_ms); ipc.ww_u64(w, m.parent); ipc.ww_bool(w, m.wait); ipc.ww_bool(w, m.shell)
	ipc.ww_str(w, m.body)
}

dec_tell_req :: proc(r: ^ipc.Wire_Reader) -> (m: Tell_Request) {
	m.to, m.from, m.timeout_ms, m.parent, m.wait, m.shell = ipc.wr_u32(r), ipc.wr_u32(r), ipc.wr_u32(r), ipc.wr_u64(r), ipc.wr_bool(r), ipc.wr_bool(r)
	m.body = ipc.wr_str(r)
	return
}

enc_tell_result :: proc(w: ^ipc.Wire_Writer, m: Tell_Result) {
	ipc.ww_u64(w, m.id)
	ipc.ww_u8(w, u8(m.phase)); ipc.ww_u8(w, u8(m.reject)); ipc.ww_u8(w, u8(m.status))
	ipc.ww_i32(w, m.exit_code); ipc.ww_u32(w, m.from); ipc.ww_u32(w, m.to)
	ipc.ww_str(w, m.progress); ipc.ww_str(w, m.text)
}

dec_tell_result :: proc(r: ^ipc.Wire_Reader) -> (m: Tell_Result) {
	m.id = ipc.wr_u64(r)
	phase, reject, status := ipc.wr_u8(r), ipc.wr_u8(r), ipc.wr_u8(r)
	if phase < u8(Tell_Phase.Accepted) || phase > u8(Tell_Phase.Finished) do r.ok = false
	if reject > u8(max(Tell_Reject)) || status > u8(max(Tell_Status)) do r.ok = false
	m.phase, m.reject, m.status = Tell_Phase(phase), Tell_Reject(reject), Tell_Status(status)
	m.exit_code, m.from, m.to = ipc.wr_i32(r), ipc.wr_u32(r), ipc.wr_u32(r)
	m.progress, m.text = ipc.wr_str(r), ipc.wr_str(r)
	return
}

enc_next_result :: proc(w: ^ipc.Wire_Writer, m: Next_Result) {
	ipc.ww_u64(w, m.id); ipc.ww_u32(w, m.from); ipc.ww_u64(w, m.parent); ipc.ww_str(w, m.body)
}

dec_next_result :: proc(r: ^ipc.Wire_Reader) -> (m: Next_Result) {
	m.id, m.from, m.parent, m.body = ipc.wr_u64(r), ipc.wr_u32(r), ipc.wr_u64(r), ipc.wr_str(r)
	return
}

enc_answer :: proc(w: ^ipc.Wire_Writer, m: Answer_Msg) {
	ipc.ww_u32(w, m.by); ipc.ww_u64(w, m.id); ipc.ww_bool(w, m.failed); ipc.ww_str(w, m.text)
}

dec_answer :: proc(r: ^ipc.Wire_Reader) -> (m: Answer_Msg) {
	m.by, m.id, m.failed, m.text = ipc.wr_u32(r), ipc.wr_u64(r), ipc.wr_bool(r), ipc.wr_str(r)
	return
}

enc_result_req :: proc(w: ^ipc.Wire_Writer, m: Result_Request) {
	ipc.ww_u32(w, m.caller); ipc.ww_bool(w, m.wait); ipc.ww_bool(w, m.follow); ipc.ww_u32(w, m.timeout_ms)
	ipc.ww_u32(w, m.n_ids)
	ids := m.ids
	for id in ids[:min(m.n_ids, RESULT_MAX_IDS)] do ipc.ww_u64(w, id)
}

dec_result_req :: proc(r: ^ipc.Wire_Reader) -> (m: Result_Request) {
	m.caller, m.wait, m.follow, m.timeout_ms = ipc.wr_u32(r), ipc.wr_bool(r), ipc.wr_bool(r), ipc.wr_u32(r)
	m.n_ids = ipc.wr_u32(r)
	if m.n_ids == 0 || m.n_ids > RESULT_MAX_IDS {
		r.ok = false
		return
	}
	n := m.n_ids // a range bound is evaluated every iteration
	for k in 0..<n do m.ids[k] = ipc.wr_u64(r)
	return
}
