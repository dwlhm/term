package feature_session_core

// MSG_SETTLE: wait until a session's screen moved past a generation and its
// program went quiet, or it exited. Event-driven: output only moves the next
// wake-up, the loop checks waits once per round.

import proto "../session_proto"
import ipc "../../platform/ipc"

CORE_MAX_SETTLES :: 32

Core_Settle :: struct {
	used:       bool,
	sess_id:    u32,
	req:        ipc.Request,
	since:      u64,
	quiet_ns:   i64,
	due_ns:     i64, // 0 = no deadline
}

core_viewer_settle :: proc(c: ^Core, req: ^ipc.Request) {
	m: proto.Settle_Request
	if !ipc.request_decode(req, &m, proto.dec_settle_req) do return
	if _target(c, req, m.id, false) == nil do return
	w := Core_Settle{
		used = true, sess_id = m.id, req = req^,
		since = m.since, quiet_ns = i64(m.quiet_ms) * 1_000_000,
		due_ns = (_now() + i64(m.timeout_ms) * 1_000_000) if m.timeout_ms > 0 else 0,
	}
	if _settle_try(c, &w, _now()) do return
	for &slot in c.settles {
		if slot.used do continue
		slot = w
		return
	}
	core_viewer_fail(c, req, .Busy, "too many settle waits")
}

// core_settles_due answers the waits that settled, ended or timed out.
core_settles_due :: proc(c: ^Core, now: i64) {
	for &w in c.settles {
		if w.used && _settle_try(c, &w, now) do w = {}
	}
}

// core_settles_next_ns: when the loop must look again (-1 = only on output).
core_settles_next_ns :: proc(c: ^Core) -> (due: i64) {
	due = -1
	for &w in c.settles {
		if !w.used do continue
		if w.due_ns > 0 do due = _earliest_ns(due, w.due_ns)
		// A stitch wakes the loop on its own; the wait is checked when it ends.
		s := core_session_find(c, w.sess_id)
		if s != nil && s.gen > w.since && (s.stitch == nil || !s.stitch.active) {
			due = _earliest_ns(due, s.output_ns + w.quiet_ns)
		}
	}
	return
}

// core_settles_cancel_viewer drops a disconnected viewer's waits.
core_settles_cancel_viewer :: proc(c: ^Core, peer: ipc.Peer) {
	for &w in c.settles do if w.used && w.req.peer == peer do w = {}
}

// _settle_try answers w when it is done; false = keep waiting.
@(private = "file")
_settle_try :: proc(c: ^Core, w: ^Core_Settle, now: i64) -> bool {
	s := core_session_find(c, w.sess_id)
	switch {
	case s == nil:
		_settle_fail(c, w, .Not_Found, "session was removed")
	case s.exited:
		_settle_answer(c, w, s)
	case s.gen > w.since && now - s.output_ns >= w.quiet_ns && (s.stitch == nil || !s.stitch.active):
		_settle_answer(c, w, s)
	case w.due_ns > 0 && now >= w.due_ns:
		_settle_fail(c, w, .Timeout, "the screen did not settle in time")
	case:
		return false
	}
	return true
}

@(private = "file")
_settle_answer :: proc(c: ^Core, w: ^Core_Settle, s: ^Core_Session) {
	msg := ipc.wire_writer(c.msg)
	proto.enc_settle_result(&msg, {id = s.id, gen = s.gen, exited = s.exited, exit_code = s.exit.code})
	ipc.reply(&c.srv, w.req, ipc.wire_bytes_written(&msg))
}

@(private = "file")
_settle_fail :: proc(c: ^Core, w: ^Core_Settle, code: proto.Fail_Code, reason: string) {
	core_viewer_fail(c, &w.req, code, reason)
}

@(private = "file")
_earliest_ns :: proc(a, b: i64) -> i64 { return b if a < 0 || b < a else a }
