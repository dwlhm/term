package feature_session_proto

// Encoders/decoders for the request bodies of msg_req.odin. Each dec_* has
// the shape ipc.request_decode takes: it reads the whole body, and leaves
// structural failures in r.ok (request_decode then answers Bad_Request).

import ipc "../../platform/ipc"

dec_empty :: proc(r: ^ipc.Wire_Reader) -> Empty_Request { return {} }

// dec_id reads a bare u32 session id (KILL).
dec_id :: proc(r: ^ipc.Wire_Reader) -> u32 { return ipc.wr_u32(r) }

// dec_request_id reads a bare u64 broker request id (CANCEL).
dec_request_id :: proc(r: ^ipc.Wire_Reader) -> u64 { return ipc.wr_u64(r) }

dec_create :: proc(r: ^ipc.Wire_Reader) -> (m: Create_Request) {
	m.raw = r.buf[r.off:]
	dec_spawn(r, &m.spec)
	return
}

enc_observe_req :: proc(w: ^ipc.Wire_Writer, m: Observe_Request) { ipc.ww_u32(w, m.id); ipc.ww_u32(w, m.lines) }
dec_observe_req :: proc(r: ^ipc.Wire_Reader) -> Observe_Request { return {ipc.wr_u32(r), ipc.wr_u32(r)} }

enc_read_req :: proc(w: ^ipc.Wire_Writer, m: Read_Request) {
	ipc.ww_u32(w, m.id)
	ipc.ww_u32(w, m.history)
	ipc.ww_bool(w, m.last)
}
dec_read_req :: proc(r: ^ipc.Wire_Reader) -> (m: Read_Request) {
	m.id = ipc.wr_u32(r)
	m.history = ipc.wr_u32(r)
	if !ipc.wr_done(r) do m.last = ipc.wr_bool(r)
	return
}

// The bytes are the rest of the body, without a length.
enc_send_req :: proc(w: ^ipc.Wire_Writer, m: Send_Request) {
	ipc.ww_u32(w, m.id)
	if !w.ok || w.n + len(m.bytes) > len(w.buf) {
		w.ok = false
		return
	}
	w.n += copy(w.buf[w.n:], m.bytes)
}

dec_send_req :: proc(r: ^ipc.Wire_Reader) -> (m: Send_Request) {
	m.id = ipc.wr_u32(r)
	if r.ok do m.bytes, r.off = r.buf[r.off:], len(r.buf)
	return
}

enc_signal_req :: proc(w: ^ipc.Wire_Writer, m: Signal_Request) { ipc.ww_u32(w, m.id); ipc.ww_i32(w, m.signal) }
dec_signal_req :: proc(r: ^ipc.Wire_Reader) -> Signal_Request { return {ipc.wr_u32(r), ipc.wr_i32(r)} }

enc_size_req :: proc(w: ^ipc.Wire_Writer, m: Size_Request) { ipc.ww_u32(w, m.id); enc_size(w, m.size) }
dec_size_req :: proc(r: ^ipc.Wire_Reader) -> Size_Request { return {ipc.wr_u32(r), dec_size(r)} }

enc_next_req :: proc(w: ^ipc.Wire_Writer, m: Next_Request) { ipc.ww_u32(w, m.sid); ipc.ww_u32(w, m.timeout_ms) }
dec_next_req :: proc(r: ^ipc.Wire_Reader) -> Next_Request { return {ipc.wr_u32(r), ipc.wr_u32(r)} }

enc_endpoint_req :: proc(w: ^ipc.Wire_Writer, m: Endpoint_Request) { ipc.ww_str(w, m.name); ipc.ww_bool(w, m.owned) }
dec_endpoint_req :: proc(r: ^ipc.Wire_Reader) -> Endpoint_Request { return {ipc.wr_str(r), ipc.wr_bool(r)} }

enc_lease_req :: proc(w: ^ipc.Wire_Writer, m: Lease_Request) { ipc.ww_u32(w, m.id); ipc.ww_str(w, m.owner) }
dec_lease_req :: proc(r: ^ipc.Wire_Reader) -> Lease_Request { return {ipc.wr_u32(r), ipc.wr_str(r)} }

enc_lease_flag :: proc(w: ^ipc.Wire_Writer, m: Lease_Flag_Request) { ipc.ww_u32(w, m.id); ipc.ww_bool(w, m.on) }
dec_lease_flag :: proc(r: ^ipc.Wire_Reader) -> Lease_Flag_Request { return {ipc.wr_u32(r), ipc.wr_bool(r)} }

// dec_act reads MSG_ACT (encoded by enc_act_keys/_text/_mouse); the core
// checks the keys, text and mouse event against the session's modes.
dec_act :: proc(r: ^ipc.Wire_Reader) -> (m: Act_Request) {
	m.id = ipc.wr_u32(r)
	kind := ipc.wr_u8(r)
	if kind < u8(Act_Kind.Keys) || kind > u8(Act_Kind.Mouse) {
		r.ok = false
		return
	}
	m.kind = Act_Kind(kind)
	switch m.kind {
	case .Keys:
		n := ipc.wr_u32(r)
		if n == 0 || n > ACT_KEYS_MAX {
			r.ok = false
			return
		}
		m.n_keys = int(n)
		for i in 0 ..< m.n_keys do m.keys[i] = dec_act_key(r)
	case .Text:
		m.paste = ipc.wr_bool(r)
		m.text = ipc.wr_str(r)
	case .Mouse:
		m.mouse = dec_act_mouse(r)
	}
	return
}
