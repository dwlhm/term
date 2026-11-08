package feature_session_core

// One loop round: wait on the Poll_Set (the viewer listener and viewers as
// watched fds, holders as ipc.Links) until the nearest deadline, then serve.

import "core:sys/posix"
import ipc "../../platform/ipc"

CORE_MAX_POLL :: 2 + CORE_MAX_HOLDERS * 2 + CORE_MAX_VIEWERS

@(private)
_core_step :: proc(c: ^Core) {
	for &v in c.viewers {
		if !v.used || v.watch == 0 do continue
		want := ipc.Fd_Want{.Readable}
		if ipc.stream_wants_write(&v.conn) do want += {.Writable}
		ipc.poll_set_want(&c.set, v.watch, want)
	}
	ipc.poll_set_wait(&c.set, _due_ns(c))
	_ = ipc.poll_set_woken(&c.set) // a stop request: the run loop reads the flag
	for &h, i in c.holders do if h.used do core_holder_events(c, i)
	core_lists_due(c)
	core_settle_due(c, _now())
	core_stitch_tick(c)
	if c.broker_due_ns > 0 && _now() >= c.broker_due_ns do core_broker_tick(c, _now())
	core_watchers_due(c, _now())
	core_settles_due(c, _now())
	for &v in c.viewers do if v.used do ipc.stream_flush(&v.conn)
}

// _due_ns: the nearest deadline (a waiting LIST, a stitch step, the empty
// grace), else -1.
@(private = "file")
_due_ns :: proc(c: ^Core) -> i64 {
	due := i64(-1)
	for &v in c.viewers {
		if !v.used do continue
		if v.list_waiting do due = _earliest(due, v.list_due_ns)
	}
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

// _accept_viewers (the listener's watch): a viewer slot per same-uid peer.
@(private)
_accept_viewers :: proc(data: rawptr, ev: ipc.Fd_Event) {
	c := (^Core)(data)
	for {
		fd := posix.accept(c.listen_fd, nil, nil)
		if fd < 0 do return
		uid, ok := ipc.ipc_peer_uid(fd)
		slot := _free_viewer(c)
		if !ok || uid != posix.getuid() || slot < 0 {
			posix.close(fd)
			continue
		}
		v := &c.viewers[slot]
		c.viewer_seq += 1
		v^ = {used = true, seq = c.viewer_seq, core = c, index = slot}
		if !ipc.stream_conn_init(&v.conn, fd, CORE_VIEWER_CTL) {
			v^ = {}
			continue
		}
		id, err := ipc.poll_set_watch(&c.set, fd, _viewer_ready, v)
		if err.kind != .None {
			ipc.stream_conn_destroy(&v.conn)
			v^ = {}
			continue
		}
		v.watch = id
	}
}

@(private = "file")
_viewer_ready :: proc(data: rawptr, ev: ipc.Fd_Event) {
	v := (^Core_Viewer)(data)
	if !v.used do return
	if ev == .Ended do v.watch = 0 // forgotten by the Poll_Set: the service drops it
	rev := posix.Poll_Event{.OUT} if ev == .Writable else {.IN}
	core_viewer_service(v.core, v.index, rev)
}

@(private = "file")
_free_viewer :: proc(c: ^Core) -> int {
	for &v, i in c.viewers do if !v.used do return i
	return -1
}
