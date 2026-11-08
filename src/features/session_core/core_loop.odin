package feature_session_core

// One loop round: wait on the Poll_Set (the session Server and the holders'
// ipc.Links) until the nearest deadline, then serve.

import ipc "../../platform/ipc"

// CORE_MAX_POLL: the wake pipe, the Server's listener and its peer slots
// (HELLO spares included), and two sources per holder Link.
CORE_MAX_POLL :: 8 + CORE_MAX_HOLDERS * 2 + CORE_MAX_VIEWERS

@(private)
_core_step :: proc(c: ^Core) {
	ipc.poll_set_wait(&c.set, _due_ns(c))
	_ = ipc.poll_set_woken(&c.set) // a stop request: the run loop reads the flag
	core_viewer_events(c)
	for &h, i in c.holders do if h.used do core_holder_events(c, i)
	core_lists_due(c)
	core_settle_due(c, _now())
	core_stitch_tick(c)
	if c.broker_due_ns > 0 && _now() >= c.broker_due_ns do core_broker_tick(c, _now())
	core_watchers_due(c, _now())
	core_settles_due(c, _now())
}

// _due_ns: the nearest deadline (a waiting LIST, a stitch step, the empty
// grace), else -1.
@(private = "file")
_due_ns :: proc(c: ^Core) -> i64 {
	due := i64(-1)
	for &l in c.lists do if l.used do due = _earliest(due, l.due_ns)
	if c.broker_due_ns > 0 do due = _earliest(due, c.broker_due_ns)
	for &w in c.watchers {
		if w.used && w.due_ns > 0 do due = _earliest(due, w.due_ns)
	}
	for &s in c.sessions {
		if !s.used do continue
		if s.settle_due_ns != 0 do due = _earliest(due, s.settle_due_ns)
		if s.stitch != nil && s.stitch.active do due = _earliest(due, core_stitch_due_ns(&s))
	}
	if settle := core_settles_next_ns(c); settle >= 0 do due = _earliest(due, settle)
	if c.empty_since > 0 do due = _earliest(due, c.empty_since + c.grace_ns)
	return due
}

@(private = "file")
_earliest :: proc(a, b: i64) -> i64 { return b if a < 0 || b < a else a }
