package feature_session_core

// Request broker (`term session tell|next|answer|result`): one party asks a
// session to process something and gets exactly one result back. A session
// takes a request through a worker waiting in `next` (any program: an agent, a
// script, an app behind a virtual endpoint) or, when it is a shell at its
// prompt, through the built-in shell adapter, which types the command and
// reads its end and output from OSC 133. No queue: without a free worker or a
// prompt a target rejects at once. Every call clears b.effects and fills it
// with what the core must do; effects stay valid until the next call.

import "core:strings"
import proto "../session_proto"

broker_init :: proc(b: ^Broker, now: proc() -> i64) {
	b.now = now
	b.next_id = 1
	b.reqs = make([]Broker_Request, CORE_MAX_REQUESTS)
}

broker_destroy :: proc(b: ^Broker) {
	delete(b.reqs)
	b^ = {now = b.now}
}

// broker_tell starts a request from → to, or says why not. waiter (-1 = none)
// is the sender's connection that gets its progress and result. parent names
// the request of from this one serves (0: the only one from runs, if any).
// shell_only: a command for the shell adapter (`run`), never for a worker.
broker_tell :: proc(b: ^Broker, from, to: u32, body: string, timeout_ms: u32, now: i64, shell: Shell_Readiness, waiter: int, parent: u64 = 0, shell_only := false) -> (id: u64, reject: Broker_Reject) {
	_broker_begin(b)
	kind, li, rej := _tell_check(b, to, body, shell, shell_only)
	if rej != .None do return 0, rej
	ri := _req_alloc(b)
	if ri < 0 do return 0, .Full
	r := &b.reqs[ri]
	r.id, r.kind, r.from, r.to, r.waiter, r.shell_only = b.next_id, kind, from, to, waiter, shell_only
	b.next_id += 1
	r.parent = _parent_of(b, from, parent)
	r.full_due_ns = now + i64(timeout_ms if timeout_ms > 0 else BROKER_DEFAULT_TIMEOUT_MS) * 1_000_000
	r.due_ns = r.full_due_ns
	r.body_len = _clean(r.body[:copy(r.body[:], body)], kind == .Worker)
	r.phase = .Running
	switch kind {
	case .Worker:
		_effect(b, .Assign, to, ri, b.listeners[li].viewer)
		b.listeners[li] = {}
	case .Shell:
		_party_get(b, to).shell = ri
		if shell == .Starting {
			r.phase = .Starting
			r.due_ns = min(r.full_due_ns, now + BROKER_START_MS * 1_000_000)
		} else {
			_effect(b, .Inject, to, ri)
		}
	}
	_effect(b, .Row, from)
	_effect(b, .Row, to)
	return r.id, .None
}

// broker_shell_ready types the request a starting shell waited for.
broker_shell_ready :: proc(b: ^Broker, sid: u32) {
	_broker_begin(b)
	p := _party_find(b, sid)
	if p == nil || p.shell < 0 || b.reqs[p.shell].phase != .Starting do return
	r := &b.reqs[p.shell]
	r.phase, r.due_ns = .Running, r.full_due_ns
	_effect(b, .Inject, sid, p.shell)
}

// broker_request finds a request by id that is still known (nil = unknown or gone).
broker_request :: proc(b: ^Broker, id: u64) -> ^Broker_Request {
	ri := _req_index(b, id)
	return &b.reqs[ri] if ri >= 0 else nil
}

// broker_row is sid's part in requests, for its session row.
broker_row :: proc(b: ^Broker, sid: u32) -> (m: proto.Row_Request) {
	if sid == 0 do return
	for &r in b.reqs {
		if r.phase != .Starting && r.phase != .Running do continue
		if r.to == sid {
			m.serving += 1
			if m.serving_id == 0 do m.serving_id = r.id
		}
		if r.from == sid do m.awaiting += 1
	}
	for &l in b.listeners do if l.used && l.sid == sid do m.listening += 1
	return
}

// broker_types_into: a request may type into session sid — its shell adapter
// runs one, or one still waits for a taker (the shell may get it). A request
// a worker took never touches the session's input.
broker_types_into :: proc(b: ^Broker, sid: u32) -> bool {
	for &r in b.reqs {
		if r.to != sid do continue
		if r.phase == .Starting || (r.phase == .Running && r.kind == .Shell) do return true
	}
	return false
}

broker_body :: proc(r: ^Broker_Request) -> string { return string(r.body[:r.body_len]) }
broker_text :: proc(r: ^Broker_Request) -> string { return string(r.text[:r.text_len]) }
broker_progress_text :: proc(r: ^Broker_Request) -> string { return string(r.progress[:r.progress_len]) }

// _tell_check: a free worker takes it first (a program in the session waits
// for requests); else the shell adapter, when the shell is at its prompt.
@(private = "file")
_tell_check :: proc(b: ^Broker, to: u32, body: string, shell: Shell_Readiness, shell_only: bool) -> (kind: Target_Kind, listener: int, reject: Broker_Reject) {
	switch {
	case !_has_visible(body):         return .Shell, -1, .Empty
	case len(body) > BROKER_BODY_CAP: return .Shell, -1, .Too_Large
	}
	if !shell_only do for &l, i in b.listeners do if l.used && l.sid == to do return .Worker, i, .None
	if p := _party_find(b, to); p != nil && (p.shell >= 0 || p.drain_due_ns != 0) do return .Shell, -1, .Busy
	if broker_row(b, to).serving > 0 do return .Shell, -1, .Busy // its workers are all taken
	switch shell {
	case .None: return .Shell, -1, .Not_Listening
	case .Busy: return .Shell, -1, .Busy
	case .Starting, .Ready:
	}
	if strings.contains_any(body, "\r\n") do return .Shell, -1, .Multi_Line
	return .Shell, -1, .None
}

// _parent_of: the request of from that a new one serves: the named one when
// from runs it, else the only one from runs (0 = none or ambiguous).
@(private = "file")
_parent_of :: proc(b: ^Broker, from: u32, named: u64) -> u64 {
	if from == 0 do return 0
	only: u64
	n := 0
	for &r in b.reqs {
		if r.to != from || (r.phase != .Starting && r.phase != .Running) do continue
		if r.id == named do return named
		only = r.id
		n += 1
	}
	return only if n == 1 && named == 0 else 0
}

@(private = "file")
_req_alloc :: proc(b: ^Broker) -> int {
	for &r, i in b.reqs {
		if r.phase != .Free do continue
		r = {}
		return i
	}
	return -1
}

@(private)
_req_index :: proc(b: ^Broker, id: u64) -> int {
	if id == 0 do return -1
	for &r, i in b.reqs do if r.phase != .Free && r.phase != .Spent && r.id == id do return i
	return -1
}

// _broker_begin frees what the previous call's effects still pointed at.
@(private)
_broker_begin :: proc(b: ^Broker) {
	b.n_effects = 0
	for &r in b.reqs do if r.phase == .Spent do r.phase = .Free
}

@(private)
_effect :: proc(b: ^Broker, kind: Broker_Effect_Kind, sid: u32, req := -1, viewer := -1) {
	if kind == .Row && sid == 0 do return
	assert(b.n_effects < BROKER_MAX_EFFECTS, "broker effect overflow")
	b.effects[b.n_effects] = {kind = kind, sid = sid, viewer = viewer, req = req}
	b.n_effects += 1
}

@(private)
_party_find :: proc(b: ^Broker, sid: u32) -> ^Broker_Party {
	if sid == 0 do return nil
	for &p in b.parties do if p.sid == sid do return &p
	return nil
}

// _party_get finds or creates sid's entry (sessions ≤ CORE_MAX_SESSIONS).
@(private)
_party_get :: proc(b: ^Broker, sid: u32) -> ^Broker_Party {
	if p := _party_find(b, sid); p != nil do return p
	for &p in b.parties {
		if p.sid != 0 do continue
		p = {sid = sid, shell = -1}
		return &p
	}
	panic("broker party table full")
}

// _party_release frees an entry that holds nothing any more.
@(private)
_party_release :: proc(p: ^Broker_Party) {
	if p != nil && p.shell < 0 && p.drain_due_ns == 0 do p^ = {}
}
