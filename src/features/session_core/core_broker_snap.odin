package feature_session_core

// Broker state across a planned restart (core_handover): the next core picks
// up every request in flight and every result not fetched yet. Connections
// (`next` slots, watches, waiting senders) end with the old core.

import ipc "../../platform/ipc"

broker_encode :: proc(b: ^Broker, w: ^ipc.Wire_Writer) {
	ipc.ww_u64(w, b.next_id)
	n := 0
	for &r in b.reqs do if r.phase != .Free && r.phase != .Spent do n += 1
	ipc.ww_u32(w, u32(n))
	for &r, i in b.reqs {
		if r.phase == .Free || r.phase == .Spent do continue
		ipc.ww_u32(w, u32(i)); ipc.ww_u64(w, r.id); ipc.ww_u64(w, r.parent)
		ipc.ww_u8(w, u8(r.phase)); ipc.ww_u8(w, u8(r.kind)); ipc.ww_u8(w, u8(r.status)); ipc.ww_bool(w, r.started); ipc.ww_bool(w, r.shell_only)
		ipc.ww_u32(w, r.from); ipc.ww_u32(w, r.to); ipc.ww_i32(w, i32(r.waiter)); ipc.ww_i32(w, r.exit_code)
		ipc.ww_i64(w, r.due_ns); ipc.ww_i64(w, r.full_due_ns); ipc.ww_i64(w, r.finished_ns); ipc.ww_u32(w, r.progress_seq)
		ipc.ww_str(w, broker_body(&r)); ipc.ww_str(w, broker_text(&r)); ipc.ww_str(w, broker_progress_text(&r))
	}
	n = 0
	for &p in b.parties do if p.sid != 0 do n += 1
	ipc.ww_u32(w, u32(n))
	for &p in b.parties {
		if p.sid == 0 do continue
		ipc.ww_u32(w, p.sid); ipc.ww_i32(w, i32(p.shell)); ipc.ww_i64(w, p.drain_due_ns); ipc.ww_i64(w, p.drain_next_ns)
	}
}

broker_decode :: proc(b: ^Broker, r: ^ipc.Wire_Reader) -> bool {
	b.next_id = max(b.next_id, ipc.wr_u64(r))
	n_reqs := ipc.wr_u32(r) // a range bound is evaluated every iteration
	for _ in 0..<n_reqs {
		i := int(ipc.wr_u32(r))
		if !r.ok || i >= len(b.reqs) do return false
		q := &b.reqs[i]
		q.id, q.parent = ipc.wr_u64(r), ipc.wr_u64(r)
		phase, kind, status := ipc.wr_u8(r), ipc.wr_u8(r), ipc.wr_u8(r)
		if phase < u8(Req_Phase.Starting) || phase > u8(Req_Phase.Finished) || kind > u8(max(Target_Kind)) || status > u8(max(Broker_Status)) do return false
		q.phase, q.kind, q.status = Req_Phase(phase), Target_Kind(kind), Broker_Status(status)
		q.started, q.shell_only = ipc.wr_bool(r), ipc.wr_bool(r)
		q.from, q.to, q.waiter, q.exit_code = ipc.wr_u32(r), ipc.wr_u32(r), int(ipc.wr_i32(r)), ipc.wr_i32(r)
		q.due_ns, q.full_due_ns, q.finished_ns, q.progress_seq = ipc.wr_i64(r), ipc.wr_i64(r), ipc.wr_i64(r), ipc.wr_u32(r)
		q.body_len = copy(q.body[:], ipc.wr_str(r))
		q.text_len = copy(q.text[:], ipc.wr_str(r))
		q.progress_len = copy(q.progress[:], ipc.wr_str(r))
	}
	n_parties := ipc.wr_u32(r)
	for k in 0..<n_parties {
		if !r.ok || int(k) >= len(b.parties) do return false
		p := &b.parties[k]
		p.sid, p.shell = ipc.wr_u32(r), int(ipc.wr_i32(r))
		p.drain_due_ns, p.drain_next_ns = ipc.wr_i64(r), ipc.wr_i64(r)
		if p.shell >= len(b.reqs) do return false
	}
	return ipc.wr_done(r)
}
