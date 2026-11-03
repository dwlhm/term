package feature_session_core

// One loop round: wait for sockets or the nearest deadline, then serve.

import "core:sys/posix"
import ipc "../../platform/ipc"
import poller "../../platform/poller"

@(private = "file")
Poll_Who :: enum u8 { Stop, Listener, Holder, Viewer }

CORE_MAX_POLL :: 2 + CORE_MAX_HOLDERS + CORE_MAX_VIEWERS

@(private = "file")
Poll_Set :: struct {
	fds:   [CORE_MAX_POLL]posix.pollfd,
	who:   [CORE_MAX_POLL]Poll_Who,
	index: [CORE_MAX_POLL]int,
	n:     int,
}

@(private = "file")
_add :: proc(ps: ^Poll_Set, fd: posix.FD, conn: ^ipc.Stream_Conn, who: Poll_Who, index: int) {
	events: posix.Poll_Event = {.IN}
	if conn != nil && ipc.stream_wants_write(conn) do events += {.OUT}
	ps.fds[ps.n] = {fd = fd, events = events}
	ps.who[ps.n], ps.index[ps.n] = who, index
	ps.n += 1
}

@(private)
_core_step :: proc(c: ^Core) {
	ps: Poll_Set
	_add(&ps, c.stop_pipe[0], nil, .Stop, 0)
	_add(&ps, c.listen_fd, nil, .Listener, 0)
	for &h, i in c.holders do if h.used do _add(&ps, h.conn.fd, &h.conn, .Holder, i)
	for &v, i in c.viewers do if v.used do _add(&ps, v.conn.fd, &v.conn, .Viewer, i)
	ready := poller.poller_poll(&c.poller, ps.fds[:ps.n], _timeout_ms(c))
	if ready < 0 && posix.errno() != .EINTR do return
	for i in 0..<ps.n {
		rev := ps.fds[i].revents
		if rev == {} do continue
		switch ps.who[i] {
		case .Stop:     _stop_drain(c)
		case .Listener: _accept_viewers(c)
		case .Holder:   core_holder_service(c, ps.index[i], rev)
		case .Viewer:   core_viewer_service(c, ps.index[i], rev)
		}
	}
	core_lists_due(c)
	core_settle_due(c, _now())
	core_stitch_tick(c)
	for &h in c.holders do if h.used do ipc.stream_flush(&h.conn)
	for &v in c.viewers do if v.used do ipc.stream_flush(&v.conn)
}

// _timeout_ms: the nearest deadline (a waiting LIST, a stitch step, the empty
// grace), else -1.
@(private = "file")
_timeout_ms :: proc(c: ^Core) -> int {
	due := i64(-1)
	for &v in c.viewers do if v.used && v.list_waiting do due = _earliest(due, v.list_due_ns)
	for &s in c.sessions {
		if !s.used do continue
		if s.settle_due_ns != 0 do due = _earliest(due, s.settle_due_ns)
		if s.stitch != nil && s.stitch.active do due = _earliest(due, core_stitch_due_ns(&s))
	}
	if c.empty_since > 0 do due = _earliest(due, c.empty_since + c.grace_ns)
	if due < 0 do return -1
	return max(0, int((due - _now()) / 1_000_000) + 1)
}

@(private = "file")
_earliest :: proc(a, b: i64) -> i64 { return b if a < 0 || b < a else a }

@(private = "file")
_accept_viewers :: proc(c: ^Core) {
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
		v^ = {used = true, seq = c.viewer_seq}
		if !ipc.stream_conn_init(&v.conn, fd, CORE_VIEWER_CTL) {
			ipc.stream_conn_destroy(&v.conn)
			v^ = {}
		}
	}
}

@(private = "file")
_free_viewer :: proc(c: ^Core) -> int {
	for &v, i in c.viewers do if !v.used do return i
	return -1
}
