package feature_session_core

// Automation leases: one connection holds a session's input. While it does,
// what people type is held (or passed through in pass mode) and reported to
// the owner, other drivers' input and broker requests are refused, and the
// session row names the owner. The lease ends on release, when the owner's
// connection closes (held input is dropped), on a takeover from a window, or
// when the session ends.

import "core:fmt"
import proto "../session_proto"
import ipc "../../platform/ipc"

Core_Lease :: struct {
	used:       bool,
	pass:       bool, // a person's input goes through (a handoff)
	owner:      ipc.Peer, // the connection that holds it
	owner_buf:  [proto.LEASE_OWNER_MAX]u8,
	owner_len:  int,
	held:       [dynamic]u8, // allocated while the lease lasts
}

core_lease_owner :: proc(s: ^Core_Session) -> string {
	return string(s.lease.owner_buf[:s.lease.owner_len]) if s.lease.used else ""
}

// core_lease_blocks: s is leased by a connection other than peer.
core_lease_blocks :: proc(s: ^Core_Session, peer: ipc.Peer) -> bool {
	return s.lease.used && s.lease.owner != peer
}

// core_lease_fail answers FAIL Busy when s is leased by someone else.
core_lease_fail :: proc(c: ^Core, s: ^Core_Session, req: ^ipc.Request) -> bool {
	if !core_lease_blocks(s, req.peer) do return false
	owner := core_lease_owner(s)
	msg := "an automation holds this session"
	if len(owner) > 0 {
		msg = fmt.tprintf("held by %s", owner)
	}
	core_viewer_fail(c, req, .Busy, msg)
	return true
}

core_viewer_lease :: proc(c: ^Core, req: ^ipc.Request) {
	m: proto.Lease_Request
	if !ipc.request_decode(req, &m, proto.dec_lease_req) do return
	s := _target(c, req, m.id, true)
	if s == nil || _no_program(c, req, s) do return
	switch {
	case len(m.owner) == 0 || len(m.owner) > proto.LEASE_OWNER_MAX:
		core_viewer_fail(c, req, .Bad_Request, "a lease owner is 1 to 64 bytes")
	case s.lease.used:
		core_viewer_fail(c, req, .Busy, "an automation holds this session")
	case broker_types_into(&c.broker, s.id):
		core_viewer_fail(c, req, .Busy, "a shell request runs in this session")
	case:
		s.lease = {used = true, owner = req.peer, owner_len = len(m.owner)}
		copy(s.lease.owner_buf[:], m.owner)
		reserve(&s.lease.held, 4096)
		core_broadcast_row(c, s)
		_ok(c, req)
	}
}

core_viewer_lease_release :: proc(c: ^Core, req: ^ipc.Request) {
	s, m := _owned_lease(c, req)
	if s == nil do return
	_lease_end(c, s, m.on)
	_ok(c, req)
}

core_viewer_lease_mode :: proc(c: ^Core, req: ^ipc.Request) {
	s, m := _owned_lease(c, req)
	if s == nil do return
	s.lease.pass = m.on
	core_broadcast_row(c, s) // windows show that it waits for a person
	_ok(c, req)
}

// _owned_lease reads a LEASE_RELEASE/LEASE_MODE body; the session whose
// lease req's connection holds, or nil (answered).
@(private = "file")
_owned_lease :: proc(c: ^Core, req: ^ipc.Request) -> (s: ^Core_Session, m: proto.Lease_Flag_Request) {
	if !ipc.request_decode(req, &m, proto.dec_lease_flag) do return
	if s = _target(c, req, m.id, false); s == nil do return
	if !s.lease.used || s.lease.owner != req.peer {
		core_viewer_fail(c, req, .Not_Found, "this connection holds no lease on the session")
		return nil, m
	}
	return
}

// core_lease_human_input takes what a person typed into a leased session:
// reported to the owner, and held unless the lease passes it through.
// true = held (the caller must not deliver it).
core_lease_human_input :: proc(c: ^Core, s: ^Core_Session, typed: []u8) -> bool {
	if !s.lease.used do return false
	l := &s.lease
	if !l.pass do append(&l.held, ..typed[:min(len(typed), max(0, proto.LEASE_HELD_MAX - len(l.held)))])
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
core_leases_viewer_gone :: proc(c: ^Core, peer: ipc.Peer) {
	for &s in c.sessions {
		if s.used && s.lease.used && s.lease.owner == peer do _lease_end(c, &s, false)
	}
}

@(private = "file")
_lease_end :: proc(c: ^Core, s: ^Core_Session, flush: bool) {
	l := &s.lease
	if flush && len(l.held) > 0 && !s.exited do core_holder_send(c, s.holder, proto.MSG_INPUT, s.id, l.held[:])
	delete(l.held)
	l^ = {}
	core_broadcast_row(c, s)
}

@(private = "file")
_lease_event :: proc(c: ^Core, s: ^Core_Session, ev: proto.Lease_Event) {
	e := ev
	e.id = s.id
	e.bytes = e.bytes[:min(len(e.bytes), CORE_ANSWER_MAX - 64)]
	w := ipc.wire_writer(c.msg)
	proto.enc_lease_event(&w, e)
	ipc.notify(&c.srv, s.lease.owner, proto.MSG_LEASE_EVENT, ipc.wire_bytes_written(&w))
}
