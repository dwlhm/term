package feature_session_core

// Automation leases: one connection holds a session's input. While it does,
// what people type is held (or passed through in pass mode) and reported to
// the owner, other drivers' input and broker requests are refused, and the
// session row names the owner. The lease ends on release, when the owner's
// connection closes (held input is dropped), on a takeover from a window, or
// when the session ends.

import ipc "../../platform/ipc"

Core_Lease :: struct {
	used:       bool,
	pass:       bool, // a person's input goes through (a handoff)
	viewer_idx: int,
	viewer_seq: u32,
	owner_buf:  [ipc.LEASE_OWNER_MAX]u8,
	owner_len:  int,
	held:       [dynamic]u8, // allocated while the lease lasts
}

core_lease_owner :: proc(s: ^Core_Session) -> string {
	return string(s.lease.owner_buf[:s.lease.owner_len]) if s.lease.used else ""
}

// core_lease_blocks: s is leased by a connection other than vi.
core_lease_blocks :: proc(c: ^Core, s: ^Core_Session, vi: int) -> bool {
	return s.lease.used && !_lease_is_owner(c, s, vi)
}

// core_lease_fail answers FAIL Busy when s is leased by someone else.
core_lease_fail :: proc(c: ^Core, s: ^Core_Session, vi: int) -> bool {
	if !core_lease_blocks(c, s, vi) do return false
	core_viewer_fail(c, vi, 0, .Busy, "an automation holds this session")
	return true
}

core_viewer_lease :: proc(c: ^Core, vi: int, r: ^ipc.Wire_Reader) {
	s := _target(c, vi, r, true, false)
	if s == nil || _no_program(c, vi, s) do return
	owner := ipc.wr_str(r)
	switch {
	case !ipc.wr_done(r) || len(owner) == 0 || len(owner) > ipc.LEASE_OWNER_MAX:
		core_viewer_fail(c, vi, 0, .Bad_Request, "malformed lease request (owner: 1 to 64 bytes)")
	case s.lease.used:
		core_viewer_fail(c, vi, 0, .Busy, "an automation holds this session")
	case broker_row(&c.broker, s.id).serving > 0:
		core_viewer_fail(c, vi, 0, .Busy, "a request runs in this session")
	case:
		s.lease = {used = true, viewer_idx = vi, viewer_seq = c.viewers[vi].seq, owner_len = len(owner)}
		copy(s.lease.owner_buf[:], owner)
		reserve(&s.lease.held, 4096)
		core_broadcast_row(c, s)
		_ok(c, vi)
	}
}

core_viewer_lease_release :: proc(c: ^Core, vi: int, r: ^ipc.Wire_Reader) {
	s := _target(c, vi, r, false, false)
	if s == nil do return
	flush := ipc.wr_bool(r)
	switch {
	case !ipc.wr_done(r): core_viewer_fail(c, vi, 0, .Bad_Request, "malformed lease release")
	case !s.lease.used || !_lease_is_owner(c, s, vi): core_viewer_fail(c, vi, 0, .Not_Found, "this connection holds no lease on the session")
	case:
		_lease_end(c, s, flush)
		_ok(c, vi)
	}
}

core_viewer_lease_mode :: proc(c: ^Core, vi: int, r: ^ipc.Wire_Reader) {
	s := _target(c, vi, r, false, false)
	if s == nil do return
	pass := ipc.wr_bool(r)
	switch {
	case !ipc.wr_done(r): core_viewer_fail(c, vi, 0, .Bad_Request, "malformed lease mode")
	case !s.lease.used || !_lease_is_owner(c, s, vi): core_viewer_fail(c, vi, 0, .Not_Found, "this connection holds no lease on the session")
	case:
		s.lease.pass = pass
		core_broadcast_row(c, s) // windows show that it waits for a person
		_ok(c, vi)
	}
}

// core_lease_human_input takes what a person typed into a leased session:
// reported to the owner, and held unless the lease passes it through.
// true = held (the caller must not deliver it).
core_lease_human_input :: proc(c: ^Core, s: ^Core_Session, typed: []u8) -> bool {
	if !s.lease.used do return false
	l := &s.lease
	if !l.pass do append(&l.held, ..typed[:min(len(typed), max(0, ipc.LEASE_HELD_MAX - len(l.held)))])
	_lease_event(c, s, {kind = .Human, interrupt = core_human_kind(typed) == .Interrupt, held = u32(len(l.held)), bytes = string(typed)})
	return !l.pass
}

// core_lease_takeover: a person confirmed taking the session back in a window.
// What they typed while it was held is dropped: it was typed at another screen.
core_lease_takeover :: proc(c: ^Core, s: ^Core_Session) {
	if !s.lease.used do return
	_lease_event(c, s, {kind = .Takeover})
	_lease_end(c, s, false)
}

// core_lease_session_ended: the program exited or the session was removed.
core_lease_session_ended :: proc(c: ^Core, s: ^Core_Session, removed: bool) {
	if !s.lease.used do return
	_lease_event(c, s, {kind = .Removed if removed else .Exited, exit_code = s.exit.code})
	_lease_end(c, s, false)
}

// core_leases_viewer_gone ends the leases of a closed connection.
core_leases_viewer_gone :: proc(c: ^Core, vi: int) {
	for &s in c.sessions {
		if s.used && s.lease.used && s.lease.viewer_idx == vi do _lease_end(c, &s, false)
	}
}

@(private = "file")
_lease_is_owner :: proc(c: ^Core, s: ^Core_Session, vi: int) -> bool {
	return s.lease.viewer_idx == vi && core_viewer_current(c, vi, s.lease.viewer_seq)
}

@(private = "file")
_lease_end :: proc(c: ^Core, s: ^Core_Session, flush: bool) {
	l := &s.lease
	if flush && len(l.held) > 0 && !s.exited do core_holder_send(c, s.holder, ipc.MSG_INPUT, s.id, l.held[:])
	delete(l.held)
	l^ = {}
	core_broadcast_row(c, s)
}

@(private = "file")
_lease_event :: proc(c: ^Core, s: ^Core_Session, ev: ipc.Lease_Event) {
	if !core_viewer_current(c, s.lease.viewer_idx, s.lease.viewer_seq) do return
	e := ev
	e.id = s.id
	e.bytes = e.bytes[:min(len(e.bytes), ipc.STREAM_MAX_PAYLOAD - 64)]
	w := ipc.wire_writer(c.msg)
	ipc.enc_lease_event(&w, e)
	conn := &c.viewers[s.lease.viewer_idx].conn
	ipc.stream_send(conn, ipc.MSG_LEASE_EVENT, 0, ipc.wire_bytes_written(&w))
	ipc.stream_flush(conn)
}
