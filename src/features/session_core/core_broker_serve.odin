package feature_session_core

// The worker side of the broker (`next`, `progress`, `answer`) and reading
// results (`result`, `result --wait`): who may report on a request, and who
// learns what when it changes or ends.

Serve_Error :: enum u8 {
	None,
	Unknown,   // no such request (never was, or its result was fetched or expired)
	Ended,     // it already ended (cancelled, timed out, its sender gone…)
	Not_Yours, // the caller's session is not its target, or the shell adapter runs it
}

// broker_next adds a free slot: one worker of sid waiting in `next` on viewer.
// A request held for a session still starting goes to whichever is ready
// first, its shell's first prompt or this worker. false: too many workers wait.
broker_next :: proc(b: ^Broker, sid: u32, viewer: int, timeout_ms: u32, now: i64) -> bool {
	_broker_begin(b)
	if p := _party_find(b, sid); p != nil && p.shell >= 0 && b.reqs[p.shell].phase == .Starting && !b.reqs[p.shell].shell_only {
		r := &b.reqs[p.shell]
		r.kind, r.phase, r.due_ns = .Worker, .Running, r.full_due_ns
		_effect(b, .Assign, sid, p.shell, viewer)
		p.shell = -1
		_party_release(p)
		_effect(b, .Row, sid)
		return true
	}
	for &l in b.listeners {
		if l.used do continue
		l = {used = true, sid = sid, viewer = viewer, due_ns = now + i64(timeout_ms) * 1_000_000 if timeout_ms > 0 else 0}
		_effect(b, .Row, sid)
		return true
	}
	return false
}

// broker_answer ends request id with the worker's answer.
broker_answer :: proc(b: ^Broker, by: u32, id: u64, text: string, failed: bool) -> Serve_Error {
	_broker_begin(b)
	ri, err := _served_by(b, by, id)
	if err != .None do return err
	_finish(b, ri, .Failed if failed else .Done, 1 if failed else 0, text, interrupt = false)
	return .None
}

// broker_progress replaces request id's progress note; whoever follows it hears.
broker_progress :: proc(b: ^Broker, by: u32, id: u64, text: string) -> Serve_Error {
	_broker_begin(b)
	ri, err := _served_by(b, by, id)
	if err != .None do return err
	r := &b.reqs[ri]
	r.progress_len = _clean(r.progress[:_copy_capped(r.progress[:], text)], true)
	r.progress_seq += 1
	if r.waiter >= 0 do _effect(b, .Progress, r.from, ri, r.waiter)
	for &w in b.watches do if w.used && w.follow && _watches(&w, r.id) do _effect(b, .Progress, r.from, ri, w.viewer)
	return .None
}

// broker_result reads request id now (nil: unknown). The sender reading its
// own finished result takes it: it is freed after this call's answer.
broker_result :: proc(b: ^Broker, caller: u32, id: u64) -> ^Broker_Request {
	_broker_begin(b)
	ri := _req_index(b, id)
	if ri < 0 do return nil
	r := &b.reqs[ri]
	if r.phase == .Finished && caller == r.from do _spend(b, r)
	return r
}

// broker_watch answers viewer when one of ids ends (follow: on progress too),
// at once when one already has. Unknown ids are the caller's to reject first.
// false: too many watches.
broker_watch :: proc(b: ^Broker, viewer: int, caller: u32, ids: []u64, follow: bool, timeout_ms: u32, now: i64) -> bool {
	_broker_begin(b)
	for id in ids {
		ri := _req_index(b, id)
		if ri < 0 || b.reqs[ri].phase != .Finished do continue
		_effect(b, .Result, b.reqs[ri].from, ri, viewer)
		if caller == b.reqs[ri].from do _spend(b, &b.reqs[ri])
		return true
	}
	for &w in b.watches {
		if w.used do continue
		w = {used = true, follow = follow, viewer = viewer, caller = caller, due_ns = now + i64(timeout_ms) * 1_000_000 if timeout_ms > 0 else 0}
		w.n_ids = copy(w.ids[:], ids)
		return true
	}
	return false
}

// broker_viewer_gone: a connection closed. Its `next` slots and watches go;
// a request it sent and waited on is cancelled (its sender gave up).
broker_viewer_gone :: proc(b: ^Broker, viewer: int) {
	_broker_begin(b)
	for &l in b.listeners {
		if !l.used || l.viewer != viewer do continue
		_effect(b, .Row, l.sid)
		l = {}
	}
	for &w in b.watches do if w.used && w.viewer == viewer do w = {}
	for &r, i in b.reqs {
		if r.waiter != viewer || (r.phase != .Starting && r.phase != .Running) do continue
		r.waiter = -1
		_finish(b, i, .Cancelled, 0, "the sender stopped waiting", interrupt = true)
		_spend(b, &r)
	}
}

// _publish hands a finished request to whoever waits for it; the sender
// taking it (its waiting connection, or its own watch) frees it.
@(private)
_publish :: proc(b: ^Broker, ri: int) {
	r := &b.reqs[ri]
	taken := false
	if r.waiter >= 0 {
		_effect(b, .Result, r.from, ri, r.waiter)
		r.waiter, taken = -1, true
	}
	for &w in b.watches {
		if !w.used || !_watches(&w, r.id) do continue
		_effect(b, .Result, r.from, ri, w.viewer)
		taken ||= w.caller == r.from
		w = {}
	}
	if taken do _spend(b, r)
}

// _expire_waits answers `next` and `result --wait` calls whose deadline passed.
@(private)
_expire_waits :: proc(b: ^Broker, now: i64) {
	for &l in b.listeners {
		if !l.used || l.due_ns == 0 || now < l.due_ns do continue
		_effect(b, .Expired, l.sid, -1, l.viewer)
		_effect(b, .Row, l.sid)
		l = {}
	}
	for &w in b.watches {
		if !w.used || w.due_ns == 0 || now < w.due_ns do continue
		_effect(b, .Expired, w.caller, -1, w.viewer)
		w = {}
	}
}

@(private = "file")
_served_by :: proc(b: ^Broker, by: u32, id: u64) -> (int, Serve_Error) {
	ri := _req_index(b, id)
	if ri < 0 do return -1, .Unknown
	r := &b.reqs[ri]
	switch {
	case r.to != by || r.kind != .Worker: return -1, .Not_Yours
	case r.phase != .Running:             return -1, .Ended
	}
	return ri, .None
}

@(private = "file")
_watches :: proc(w: ^Broker_Watch, id: u64) -> bool {
	for x in w.ids[:w.n_ids] do if x == id do return true
	return false
}
