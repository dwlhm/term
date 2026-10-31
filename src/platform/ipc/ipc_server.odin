package platform_ipc

import "core:c"
import "base:intrinsics"
import "core:sync"
import "core:sys/posix"
import "core:thread"

IPC_STOP_FLUSH_MS :: 500
#assert(IPC_MAILBOX_CAP < IPC_MAX_CONNS)

@(private = "file")
_poke :: proc(fd: posix.FD) {
	b: u8 = 1
	_ = posix.write(fd, &b, 1) // non-blocking; a full pipe already means "wake up"
}

// _snapshot expires stale hand-offs and copies every slot state under the mutex.
// Slots the snapshot shows as .Free/.Reading/.Writing are listener-owned.
@(private = "file")
_snapshot :: proc(srv: ^Ipc_Server) -> (states: [IPC_MAX_CONNS]Ipc_Conn_State) {
	now := _now()
	sync.mutex_lock(&srv.mutex)
	defer sync.mutex_unlock(&srv.mutex)
	for &conn, i in srv.conns {
		if (conn.state == .Queued || conn.state == .Taken) && conn.deadline_ns <= now {
			_begin_write(&conn, "err timeout\n")
		}
		states[i] = conn.state
	}
	return
}

@(private = "file")
_count :: proc(states: [IPC_MAX_CONNS]Ipc_Conn_State, want: Ipc_Conn_State) -> (n: int) {
	for st in states do if st == want do n += 1
	return
}

@(private = "file")
_poll_timeout :: proc(srv: ^Ipc_Server, states: [IPC_MAX_CONNS]Ipc_Conn_State, stopping: bool) -> c.int {
	nearest := _deadline(IPC_POLL_MAX_MS)
	for st, i in states {
		if st != .Free && srv.conns[i].deadline_ns < nearest do nearest = srv.conns[i].deadline_ns
	}
	ms := clamp((nearest - _now()) / 1_000_000 + 1, 0, i64(IPC_POLL_MAX_MS))
	return c.int(min(ms, 50) if stopping else ms)
}

@(private = "file")
_wait :: proc(srv: ^Ipc_Server, states: [IPC_MAX_CONNS]Ipc_Conn_State, stopping: bool) -> bool {
	pfds: [IPC_MAX_CONNS + 2]posix.pollfd
	pfds[0] = {fd = srv.notify_pipe[0], events = {.IN}}
	n := 1
	if !stopping && _count(states, .Free) > 0 {
		pfds[n] = {fd = srv.listen_fd, events = {.IN}}
		n += 1
	}
	for st, i in states {
		if st != .Reading && st != .Writing do continue
		pfds[n] = {fd = srv.conns[i].fd, events = {.IN} if st == .Reading else {.OUT}}
		n += 1
	}
	if posix.poll(&pfds[0], posix.nfds_t(n), _poll_timeout(srv, states, stopping)) >= 0 do return true
	return posix.errno() == .EINTR
}

@(private = "file")
_drain_pipe :: proc(srv: ^Ipc_Server) {
	buf: [64]u8
	for posix.read(srv.notify_pipe[0], &buf[0], len(buf)) > 0 {}
}

@(private = "file")
_listener :: proc(srv: ^Ipc_Server) {
	flush_until: i64 = 0
	for {
		stopping := intrinsics.atomic_load(&srv.stopping)
		states := _snapshot(srv)
		if stopping && flush_until == 0 do flush_until = _deadline(IPC_STOP_FLUSH_MS)
		if stopping && (_count(states, .Writing) == 0 || _now() >= flush_until) do return
		if !_wait(srv, states, stopping) do return
		_drain_pipe(srv)
		if !stopping do _accept_all(srv, &states)
		for st, i in states {
			if st == .Reading && !stopping do _read_slot(srv, &srv.conns[i])
			if st == .Writing do _write_slot(&srv.conns[i])
		}
	}
}

@(private = "file")
_unlink_if_ours :: proc(srv: ^Ipc_Server) {
	if srv.path_len == 0 || srv.path_len >= len(srv.path_buf) do return
	srv.path_buf[srv.path_len] = 0
	cpath := cstring(raw_data(srv.path_buf[:]))
	st: posix.stat_t
	if posix.lstat(cpath, &st) == .OK && u64(st.st_ino) == srv.listen_ino do posix.unlink(cpath)
}

@(private = "file")
_release_fds :: proc(srv: ^Ipc_Server) {
	for &conn in srv.conns do _close_slot(&conn)
	if srv.listen_fd >= 0 do posix.close(srv.listen_fd)
	for fd in srv.notify_pipe do if fd >= 0 do posix.close(fd)
	srv.listen_fd, srv.notify_pipe = -1, {-1, -1}
}

ipc_server_start :: proc(srv: ^Ipc_Server, path: string, wake: Ipc_Wakeup_Proc, wake_data: rawptr) -> Ipc_Error {
	if srv.running do return .Already_Running
	if len(path) + 1 > len(srv.path_buf) do return .Path_Too_Long
	srv.listen_fd, srv.notify_pipe = -1, {-1, -1}
	for &conn in srv.conns do conn.fd, conn.state = -1, .Free
	fd, ino, err := ipc_bind_listener(path)
	if err != .None do return err
	srv.listen_fd, srv.listen_ino = fd, ino
	srv.path_len = copy(srv.path_buf[:], path)
	if posix.pipe(&srv.notify_pipe) != .OK || !ipc_set_nonblocking_cloexec(srv.notify_pipe[0]) || !ipc_set_nonblocking_cloexec(srv.notify_pipe[1]) {
		_unlink_if_ours(srv)
		_release_fds(srv)
		return .Socket_Failed
	}
	srv.wake, srv.wake_data, srv.next_ticket = wake, wake_data, 1
	intrinsics.atomic_store(&srv.stopping, false)
	srv.thread = thread.create_and_start_with_poly_data(srv, _listener)
	if srv.thread == nil {
		_unlink_if_ours(srv)
		_release_fds(srv)
		return .Socket_Failed
	}
	srv.running = true
	return .None
}

ipc_server_poll :: proc(srv: ^Ipc_Server, out: ^Ipc_Request) -> bool {
	sync.mutex_lock(&srv.mutex)
	defer sync.mutex_unlock(&srv.mutex)
	chosen: ^Ipc_Conn
	for &conn in srv.conns {
		if conn.state == .Queued && (chosen == nil || conn.ticket < chosen.ticket) do chosen = &conn
	}
	if chosen == nil do return false
	out.line_len = copy(out.line_buf[:], chosen.in_buf[:chosen.in_len])
	out.ticket = chosen.ticket
	chosen.state = .Taken
	return true
}

ipc_server_reply :: proc(srv: ^Ipc_Server, ticket: u64, payload: string) {
	found := false
	sync.mutex_lock(&srv.mutex)
	for &conn in srv.conns {
		if conn.state != .Taken || conn.ticket != ticket do continue
		_begin_write(&conn, payload) // copy truncates at IPC_MAX_REPLY
		found = true
		break
	}
	sync.mutex_unlock(&srv.mutex)
	if found do _poke(srv.notify_pipe[1])
}

ipc_server_stop :: proc(srv: ^Ipc_Server) {
	if srv == nil || !srv.running do return
	intrinsics.atomic_store(&srv.stopping, true)
	_poke(srv.notify_pipe[1])
	thread.join(srv.thread)
	thread.destroy(srv.thread)
	srv.thread = nil
	_unlink_if_ours(srv)
	_release_fds(srv)
	srv.running = false
}
