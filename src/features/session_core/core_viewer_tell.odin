package feature_session_core

// Broker requests from viewers and the CLI: tell, cancel, next, answer,
// progress, result. Each answers at once (OK, FAIL or a result); `next`,
// `result --wait` and a waiting tell keep their Request in c.waits, whose
// index is the broker's waiter key, and broker effects answer them later.

import proto "../session_proto"
import ipc "../../platform/ipc"

core_viewer_tell :: proc(c: ^Core, req: ^ipc.Request) {
	m: proto.Tell_Request
	if !ipc.request_decode(req, &m, proto.dec_tell_req) do return
	s := core_session_find(c, m.to)
	if s == nil || s.exited {
		core_viewer_fail(c, req, .Not_Found, "no such session")
		return
	}
	from := m.from if core_session_find(c, m.from) != nil else 0 // a stale $TERM_SESSION_ID
	if s.lease.used {
		_answer_result(c, req, {phase = .Rejected, reject = .Leased, from = from, to = m.to}, true)
		return
	}
	waiter := -1
	if m.wait {
		waiter = core_wait_new(c, req)
		if waiter < 0 do return
	}
	id, reject := broker_tell(&c.broker, from, m.to, m.body, m.timeout_ms, _now(), core_shell_readiness(s), waiter, m.parent, m.shell)
	res := proto.Tell_Result{id = id, phase = .Rejected if reject != .None else .Accepted, reject = reject, from = from, to = m.to}
	// A waiting tell hears Accepted as progress; its Finished result ends it.
	if waiter >= 0 && reject != .None do c.waits[waiter] = {}
	_answer_result(c, req, res, waiter < 0 || reject != .None)
	core_broker_apply(c)
}

core_viewer_cancel :: proc(c: ^Core, req: ^ipc.Request) {
	id: u64
	if !ipc.request_decode(req, &id, proto.dec_request_id) do return
	if !broker_cancel(&c.broker, id) {
		core_viewer_fail(c, req, .Not_Found, "no such running request")
		return
	}
	_ok(c, req)
	core_broker_apply(c)
}

// core_viewer_next: a worker of the session waits for its next request.
core_viewer_next :: proc(c: ^Core, req: ^ipc.Request) {
	m: proto.Next_Request
	if !ipc.request_decode(req, &m, proto.dec_next_req) do return
	if s := core_session_find(c, m.sid); s == nil || s.exited {
		core_viewer_fail(c, req, .Not_Found, "no such session (next takes requests for a session)")
		return
	}
	key := core_wait_new(c, req)
	if key < 0 do return
	if !broker_next(&c.broker, m.sid, key, m.timeout_ms, _now()) {
		c.waits[key] = {}
		core_viewer_fail(c, req, .Busy, "too many workers waiting")
		return
	}
	core_broker_apply(c)
}

// core_viewer_answer handles MSG_ANSWER and MSG_PROGRESS.
core_viewer_answer :: proc(c: ^Core, req: ^ipc.Request, final: bool) {
	m: proto.Answer_Msg
	if !ipc.request_decode(req, &m, proto.dec_answer) do return
	err := broker_answer(&c.broker, m.by, m.id, m.text, m.failed) if final else broker_progress(&c.broker, m.by, m.id, m.text)
	switch err {
	case .None:      _ok(c, req)
	case .Unknown:   core_viewer_fail(c, req, .Not_Found, "no such request (it ended and was fetched, or expired)")
	case .Ended:     core_viewer_fail(c, req, .Exited, "request ended")
	case .Not_Yours: core_viewer_fail(c, req, .Bad_Request, "this session did not take that request")
	}
	core_broker_apply(c)
}

// core_viewer_result reads a request now, or waits until one of several ends.
core_viewer_result :: proc(c: ^Core, req: ^ipc.Request) {
	m: proto.Result_Request
	if !ipc.request_decode(req, &m, proto.dec_result_req) do return
	ids := m.ids[:m.n_ids]
	for id in ids {
		if broker_request(&c.broker, id) == nil {
			core_viewer_fail(c, req, .Not_Found, "no such request (unknown, fetched or expired)")
			return
		}
	}
	if !m.wait {
		q := broker_result(&c.broker, m.caller, ids[0])
		_answer_result(c, req, _result_of(q, .Finished if q.phase == .Finished || q.phase == .Spent else .Running), true)
		core_broker_apply(c)
		return
	}
	key := core_wait_new(c, req)
	if key < 0 do return
	if !broker_watch(&c.broker, key, m.caller, ids, m.follow, m.timeout_ms, _now()) {
		c.waits[key] = {}
		core_viewer_fail(c, req, .Busy, "too many waits")
		return
	}
	core_broker_apply(c)
}

// core_reply_request answers a worker's `next` with the request it took.
core_reply_request :: proc(c: ^Core, key: int, r: ^Broker_Request) {
	req, ok := _wait_take(c, key)
	if !ok do return
	w := ipc.wire_writer(c.msg)
	proto.enc_next_result(&w, {id = r.id, from = r.from, parent = r.parent, body = broker_body(r)})
	ipc.reply(&c.srv, req, ipc.wire_bytes_written(&w))
}

// core_reply_result tells the waiter of key about r: Finished ends its
// request, Progress keeps it waiting.
core_reply_result :: proc(c: ^Core, key: int, r: ^Broker_Request, phase: proto.Tell_Phase) {
	if key < 0 || key >= CORE_MAX_WAITS || !c.waits[key].used do return
	req := c.waits[key].req
	if phase == .Finished do c.waits[key] = {}
	_answer_result(c, &req, _result_of(r, phase), phase == .Finished)
}

// core_fail_wait ends the request the broker held under key with FAIL.
core_fail_wait :: proc(c: ^Core, key: int, code: proto.Fail_Code, reason: string) {
	req, ok := _wait_take(c, key)
	if ok do core_viewer_fail(c, &req, code, reason)
}

@(private = "file")
_wait_take :: proc(c: ^Core, key: int) -> (req: ipc.Request, ok: bool) {
	if key < 0 || key >= CORE_MAX_WAITS || !c.waits[key].used do return
	req = c.waits[key].req
	c.waits[key] = {}
	return req, true
}

@(private = "file")
_result_of :: proc(r: ^Broker_Request, phase: proto.Tell_Phase) -> proto.Tell_Result {
	return {
		id = r.id, phase = phase, status = r.status, exit_code = r.exit_code, from = r.from, to = r.to,
		progress = broker_progress_text(r), text = broker_text(r) if phase == .Finished else "",
	}
}

// _answer_result sends res as the final TELL_RESULT, or as TELL_PROGRESS.
@(private = "file")
_answer_result :: proc(c: ^Core, req: ^ipc.Request, res: proto.Tell_Result, final: bool) {
	w := ipc.wire_writer(c.msg)
	proto.enc_tell_result(&w, res)
	if final do ipc.reply(&c.srv, req^, ipc.wire_bytes_written(&w))
	else do ipc.progress(&c.srv, req^, ipc.wire_bytes_written(&w))
}
