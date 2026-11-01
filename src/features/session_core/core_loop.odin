package feature_session_core

// One poll iteration: wait for sockets or the nearest deadline, then serve.

import "core:sys/posix"
import ipc "../../platform/ipc"

@(private = "file")
Poll_Who :: enum u8 { Listener, Holder, Viewer }

@(private = "file")
Poll_Set :: struct {
	fds:   [1 + CORE_MAX_HOLDERS + CORE_MAX_VIEWERS]posix.pollfd,
	who:   [1 + CORE_MAX_HOLDERS + CORE_MAX_VIEWERS]Poll_Who,
	index: [1 + CORE_MAX_HOLDERS + CORE_MAX_VIEWERS]int,
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
	_add(&ps, c.listen_fd, nil, .Listener, 0)
	for &h, i in c.holders do if h.used do _add(&ps, h.conn.fd, &h.conn, .Holder, i)
	for &v, i in c.viewers do if v.used do _add(&ps, v.conn.fd, &v.conn, .Viewer, i)
	ready := posix.poll(raw_data(ps.fds[:]), posix.nfds_t(ps.n), i32(_timeout_ms(c)))
	if ready < 0 && posix.errno() != .EINTR do return
	for i in 0..<ps.n {
		rev := ps.fds[i].revents
		if rev == {} do continue
		switch ps.who[i] {
		case .Listener: _accept_viewers(c)
		case .Holder:   core_holder_service(c, ps.index[i], rev)
		case .Viewer:   core_viewer_service(c, ps.index[i], rev)
		}
	}
	core_lists_due(c)
	core_proc_refresh_due(c)
	for &h in c.holders do if h.used do ipc.stream_flush(&h.conn)
	for &v in c.viewers do if v.used do ipc.stream_flush(&v.conn)
}

// _timeout_ms: the nearest deadline (a waiting LIST, the empty grace), else -1.
@(private = "file")
_timeout_ms :: proc(c: ^Core) -> int {
	due := i64(-1)
	for &v in c.viewers do if v.used && v.list_waiting do due = _earliest(due, v.list_due_ns)
	for &s in c.sessions do if s.used && s.proc_due_ns != 0 do due = _earliest(due, s.proc_due_ns)
	if c.empty_since > 0 do due = _earliest(due, c.empty_since + CORE_GRACE_MS * 1_000_000)
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
		v^ = {used = true}
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
