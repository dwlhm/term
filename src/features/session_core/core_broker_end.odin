package feature_session_core

// How broker requests end: the target answers or its command finishes, a
// person steps into a shell, a side goes away, the deadline passes or someone
// cancels. A request that ends cancels the requests its work sent (children,
// by parent id), so a chain unwinds from wherever it was cut.

// broker_shell_started: sid's shell started a command (133;C). A request
// cancelled before this point starts being interrupted now.
broker_shell_started :: proc(b: ^Broker, sid: u32) {
	_broker_begin(b)
	p := _party_find(b, sid)
	if p == nil do return
	if p.shell >= 0 && b.reqs[p.shell].phase == .Running do b.reqs[p.shell].started = true
	if p.drain_due_ns != 0 && p.drain_next_ns == 0 do _drain_signal(b, p)
}

// broker_shell_done ends sid's shell request when its command finished (133;D).
broker_shell_done :: proc(b: ^Broker, sid: u32, exit_code: i32, text: string) {
	_broker_begin(b)
	p := _party_find(b, sid)
	if p == nil do return
	if p.drain_due_ns != 0 {
		_drain_end(b, p) // the cancelled command ended
		return
	}
	if p.shell < 0 || b.reqs[p.shell].phase != .Running do return
	_finish(b, p.shell, .Done if exit_code == 0 else .Failed, exit_code, text, interrupt = false)
}

// broker_human_input: a person typed into sid. The request its shell adapter
// runs ends: Cancelled for ^C/Esc, else Interrupted (the person took over);
// partial is the output so far. Workers are never typed into by the broker,
// so what a person types to them is theirs to handle.
broker_human_input :: proc(b: ^Broker, sid: u32, kind: Human_Input, partial := "") {
	_broker_begin(b)
	p := _party_find(b, sid)
	if p == nil || p.shell < 0 do return
	_finish(b, p.shell, .Cancelled if kind == .Interrupt else .Interrupted, 0, partial, interrupt = false)
}

// broker_session_gone: sid exited or was removed. What it runs ends with an
// error; what it sent is cancelled and, its sender gone, freed.
broker_session_gone :: proc(b: ^Broker, sid: u32, exit_code: i32) {
	_broker_begin(b)
	for &r, i in b.reqs {
		if r.to != sid || (r.phase != .Starting && r.phase != .Running) do continue
		_finish(b, i, .Error, exit_code, "session exited", interrupt = false)
	}
	for &r, i in b.reqs {
		if r.from != sid || r.phase == .Free || r.phase == .Spent do continue
		if r.phase != .Finished do _finish(b, i, .Cancelled, 0, "the sender's session exited", interrupt = true)
		_spend(b, &r)
	}
	for &l in b.listeners {
		if !l.used || l.sid != sid do continue
		_effect(b, .Gone, sid, -1, l.viewer) // its `next` must not wait forever
		l = {}
	}
	if p := _party_find(b, sid); p != nil do p^ = {}
}

// broker_cancel ends request id on someone's behalf (`term session cancel`).
broker_cancel :: proc(b: ^Broker, id: u64) -> bool {
	_broker_begin(b)
	ri := _req_index(b, id)
	if ri < 0 || (b.reqs[ri].phase != .Starting && b.reqs[ri].phase != .Running) do return false
	_finish(b, ri, .Cancelled, 0, "cancelled", interrupt = true)
	return true
}

// broker_tick ends requests whose deadline passed, frees results nobody
// fetched in time and shells whose cancelled line never ended, and answers
// waits that timed out.
broker_tick :: proc(b: ^Broker, now: i64) {
	_broker_begin(b)
	for &r, i in b.reqs {
		switch {
		case r.phase == .Finished && now >= r.finished_ns + BROKER_RESULT_TTL_MS * 1_000_000:
			_spend(b, &r)
		case r.phase == .Starting && now >= r.due_ns:
			_finish(b, i, .Error, 0, "no shell prompt (no OSC 133 shell integration)", interrupt = false)
		case r.phase == .Running && now >= r.due_ns:
			_finish(b, i, .Timeout, 0, "timed out", interrupt = true)
		}
	}
	for &p in b.parties {
		switch {
		case p.drain_due_ns == 0:
		case now >= p.drain_due_ns:                          _drain_end(b, &p)
		case p.drain_next_ns != 0 && now >= p.drain_next_ns: _drain_signal(b, &p)
		}
	}
	_expire_waits(b, now)
}

// broker_next_due is the nearest deadline (0 = none).
broker_next_due :: proc(b: ^Broker) -> (due: i64) {
	at :: proc(due: ^i64, t: i64) { if t != 0 && (due^ == 0 || t < due^) do due^ = t }
	for &r in b.reqs {
		if r.phase == .Starting || r.phase == .Running do at(&due, r.due_ns)
		if r.phase == .Finished do at(&due, r.finished_ns + BROKER_RESULT_TTL_MS * 1_000_000)
	}
	for &p in b.parties do if p.drain_due_ns != 0 do at(&due, p.drain_next_ns if p.drain_next_ns != 0 && p.drain_next_ns < p.drain_due_ns else p.drain_due_ns)
	for &l in b.listeners do if l.used do at(&due, l.due_ns)
	for &w in b.watches do if w.used do at(&due, w.due_ns)
	return
}

// _finish ends request ri: frees its shell (interrupting what it still runs
// when asked), cancels the requests its work sent, then publishes the result.
@(private)
_finish :: proc(b: ^Broker, ri: int, status: Broker_Status, exit_code: i32, text: string, interrupt: bool) {
	r := &b.reqs[ri]
	ran := r.phase == .Running
	r.phase, r.status, r.exit_code, r.finished_ns = .Finished, status, exit_code, b.now()
	r.text_len = _clean(r.text[:_copy_capped(r.text[:], text)], true)
	if p := _party_find(b, r.to); p != nil && p.shell == ri {
		p.shell = -1
		if interrupt && ran do _interrupt_shell(b, p, r)
		_party_release(p)
	}
	_effect(b, .Row, r.to)
	_effect(b, .Row, r.from)
	for &c, ci in b.reqs {
		if c.parent != r.id || (c.phase != .Starting && c.phase != .Running) do continue
		_finish(b, ci, .Cancelled, 0, "the request it served ended", interrupt = true)
	}
	_publish(b, ri)
}

// _interrupt_shell stops what shell p runs for r. A shell that has not
// started the typed line yet would still run it: p stays bound until it does
// (broker_shell_started) and until it ends.
@(private = "file")
_interrupt_shell :: proc(b: ^Broker, p: ^Broker_Party, r: ^Broker_Request) {
	p.drain_due_ns = b.now() + BROKER_DRAIN_MS * 1_000_000
	if r.started do _drain_signal(b, p)
}

@(private = "file")
_drain_signal :: proc(b: ^Broker, p: ^Broker_Party) {
	_effect(b, .Interrupt, p.sid)
	p.drain_next_ns = b.now() + BROKER_INT_RETRY_MS * 1_000_000
}

@(private = "file")
_drain_end :: proc(b: ^Broker, p: ^Broker_Party) {
	p.drain_due_ns, p.drain_next_ns = 0, 0
	_effect(b, .Row, p.sid)
	_party_release(p)
}

// _spend retires r: freed at the next call, after this one's effects ran.
@(private)
_spend :: proc(b: ^Broker, r: ^Broker_Request) {
	if r.phase == .Free || r.phase == .Spent do return
	r.phase = .Spent
}
