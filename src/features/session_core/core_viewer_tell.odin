package feature_session_core

// Broker requests from viewers and the CLI: tell, cancel, next, answer,
// progress, result. Each answers at once (OK, FAIL or a result); `next`,
// `result --wait` and a waiting tell are answered later by broker effects.

import ipc "../../platform/ipc"

core_viewer_tell :: proc(c: ^Core, vi: int, r: ^ipc.Wire_Reader) {
	req := ipc.dec_tell_req(r)
	if !ipc.wr_done(r) {
		core_viewer_fail(c, vi, 0, .Bad_Request, "malformed tell request")
		return
	}
	s := core_session_find(c, req.to)
	if s == nil || s.exited {
		core_viewer_fail(c, vi, 0, .Not_Found, "no such session")
		return
	}
	from := req.from if core_session_find(c, req.from) != nil else 0 // a stale $TERM_SESSION_ID
	if s.lease.used {
		_send_result(c, vi, {phase = .Rejected, reject = .Leased, from = from, to = req.to})
		return
	}
	waiter := vi if req.wait else -1
	id, reject := broker_tell(&c.broker, from, req.to, req.body, req.timeout_ms, _now(), core_shell_readiness(s), waiter, req.parent, req.shell)
	_send_result(c, vi, {id = id, phase = .Rejected if reject != .None else .Accepted, reject = reject, from = from, to = req.to})
	core_broker_apply(c)
}

core_viewer_cancel :: proc(c: ^Core, vi: int, r: ^ipc.Wire_Reader) {
	id := ipc.wr_u64(r)
	if !ipc.wr_done(r) {
		core_viewer_fail(c, vi, 0, .Bad_Request, "malformed cancel request")
		return
	}
	if !broker_cancel(&c.broker, id) {
		core_viewer_fail(c, vi, 0, .Not_Found, "no such running request")
		return
	}
	_ok(c, vi)
	core_broker_apply(c)
}

// core_viewer_next: a worker of the session waits for its next request.
core_viewer_next :: proc(c: ^Core, vi: int, r: ^ipc.Wire_Reader) {
	sid, timeout_ms := ipc.wr_u32(r), ipc.wr_u32(r)
	if !ipc.wr_done(r) {
		core_viewer_fail(c, vi, 0, .Bad_Request, "malformed next request")
		return
	}
	if s := core_session_find(c, sid); s == nil || s.exited {
		core_viewer_fail(c, vi, 0, .Not_Found, "no such session (next takes requests for a session)")
		return
	}
	if !broker_next(&c.broker, sid, vi, timeout_ms, _now()) {
		core_viewer_fail(c, vi, 0, .Busy, "too many workers waiting")
		return
	}
	core_broker_apply(c)
}

// core_viewer_answer handles MSG_ANSWER and MSG_PROGRESS.
core_viewer_answer :: proc(c: ^Core, vi: int, r: ^ipc.Wire_Reader, final: bool) {
	m := ipc.dec_answer(r)
	if !ipc.wr_done(r) {
		core_viewer_fail(c, vi, 0, .Bad_Request, "malformed answer")
		return
	}
	err := broker_answer(&c.broker, m.by, m.id, m.text, m.failed) if final else broker_progress(&c.broker, m.by, m.id, m.text)
	switch err {
	case .None:      _ok(c, vi)
	case .Unknown:   core_viewer_fail(c, vi, 0, .Not_Found, "no such request (it ended and was fetched, or expired)")
	case .Ended:     core_viewer_fail(c, vi, 0, .Exited, "request ended")
	case .Not_Yours: core_viewer_fail(c, vi, 0, .Bad_Request, "this session did not take that request")
	}
	core_broker_apply(c)
}

// core_viewer_result reads a request now, or waits until one of several ends.
core_viewer_result :: proc(c: ^Core, vi: int, r: ^ipc.Wire_Reader) {
	m := ipc.dec_result_req(r)
	if !ipc.wr_done(r) {
		core_viewer_fail(c, vi, 0, .Bad_Request, "malformed result request")
		return
	}
	ids := m.ids[:m.n_ids]
	for id in ids {
		if broker_request(&c.broker, id) == nil {
			core_viewer_fail(c, vi, 0, .Not_Found, "no such request (unknown, fetched or expired)")
			return
		}
	}
	if !m.wait {
		q := broker_result(&c.broker, m.caller, ids[0])
		core_reply_result(c, vi, q, .Finished if q.phase == .Finished || q.phase == .Spent else .Running)
		core_broker_apply(c)
		return
	}
	if !broker_watch(&c.broker, vi, m.caller, ids, m.follow, m.timeout_ms, _now()) {
		core_viewer_fail(c, vi, 0, .Busy, "too many waits")
		return
	}
	core_broker_apply(c)
}

// core_reply_request answers a worker's `next` with the request it took.
core_reply_request :: proc(c: ^Core, vi: int, r: ^Broker_Request) {
	if !_viewer_ok(c, vi) do return
	w := ipc.wire_writer(c.msg)
	ipc.enc_next_result(&w, {id = r.id, from = r.from, parent = r.parent, body = broker_body(r)})
	ipc.stream_send(&c.viewers[vi].conn, ipc.MSG_REQUEST, 0, ipc.wire_bytes_written(&w))
}

core_reply_result :: proc(c: ^Core, vi: int, r: ^Broker_Request, phase: ipc.Tell_Phase) {
	_send_result(c, vi, {
		id = r.id, phase = phase, status = r.status, exit_code = r.exit_code, from = r.from, to = r.to,
		progress = broker_progress_text(r), text = broker_text(r) if phase == .Finished else "",
	})
}

@(private = "file")
_send_result :: proc(c: ^Core, vi: int, res: ipc.Tell_Result) {
	if !_viewer_ok(c, vi) do return
	w := ipc.wire_writer(c.msg)
	ipc.enc_tell_result(&w, res)
	ipc.stream_send(&c.viewers[vi].conn, ipc.MSG_TELL_RESULT, 0, ipc.wire_bytes_written(&w))
}
