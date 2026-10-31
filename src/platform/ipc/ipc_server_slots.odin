package platform_ipc

// Per-slot socket I/O for the listener thread. Every proc here runs on the
// listener and only touches slots it owns (.Free/.Reading/.Writing), except
// _complete_line, which takes srv.mutex for the .Queued hand-off.

import "core:c"
import "core:sync"
import "core:sys/posix"
import "core:time"

@(private)
_now :: proc() -> i64 { return time.tick_now()._nsec }

@(private)
_deadline :: proc(ms: int) -> i64 { return _now() + i64(ms) * 1_000_000 }

@(private)
_close_slot :: proc(conn: ^Ipc_Conn) {
	if conn.fd >= 0 do posix.close(conn.fd)
	conn.fd, conn.state, conn.in_len, conn.out_len, conn.out_off = -1, .Free, 0, 0, 0
}

// _begin_write queues a listener-generated reply ("err busy\n" etc.).
@(private)
_begin_write :: proc(conn: ^Ipc_Conn, msg: string) {
	conn.out_len = copy(conn.out_buf[:], msg)
	conn.out_off = 0
	conn.deadline_ns = _deadline(IPC_IO_DEADLINE_MS)
	conn.state = .Writing
}

@(private)
_accept_all :: proc(srv: ^Ipc_Server, states: ^[IPC_MAX_CONNS]Ipc_Conn_State) {
	for &st, i in states {
		if st != .Free do continue
		fd := posix.accept(srv.listen_fd, nil, nil)
		if fd < 0 do return
		uid, ok := ipc_peer_uid(fd)
		if !ipc_set_nonblocking_cloexec(fd) || !ok || uid != posix.getuid() {
			posix.close(fd)
			continue
		}
		conn := &srv.conns[i]
		conn.fd, conn.in_len, conn.deadline_ns, conn.state = fd, 0, _deadline(IPC_IO_DEADLINE_MS), .Reading
		st = .Reading
	}
}

// _complete_line hands a finished request to the main thread or answers busy.
@(private)
_complete_line :: proc(srv: ^Ipc_Server, conn: ^Ipc_Conn) {
	if conn.in_len > 0 && conn.in_buf[conn.in_len - 1] == '\r' do conn.in_len -= 1
	sync.mutex_lock(&srv.mutex)
	pending := 0
	for other in srv.conns do if other.state == .Queued || other.state == .Taken do pending += 1
	queued := pending < IPC_MAILBOX_CAP
	if queued {
		conn.ticket = srv.next_ticket
		srv.next_ticket += 1
		conn.deadline_ns = _deadline(IPC_REPLY_DEADLINE_MS)
		conn.state = .Queued
	}
	sync.mutex_unlock(&srv.mutex)
	if !queued do _begin_write(conn, "err busy\n")
	else if srv.wake != nil do srv.wake(srv.wake_data)
}

@(private)
_read_slot :: proc(srv: ^Ipc_Server, conn: ^Ipc_Conn) {
	if conn.deadline_ns <= _now() {
		_close_slot(conn)
		return
	}
	for conn.in_len < IPC_MAX_LINE {
		dst := conn.in_buf[conn.in_len:]
		r := posix.recv(conn.fd, raw_data(dst), c.size_t(len(dst)), {})
		if r < 0 && posix.errno() == .EINTR do continue
		if r < 0 && posix.errno() == .EAGAIN do return
		if r <= 0 {
			_close_slot(conn) // EOF before '\n' or a socket error
			return
		}
		for b, i in dst[:r] {
			if b != '\n' do continue
			conn.in_len += i // one request per connection: bytes after '\n' are ignored
			_complete_line(srv, conn)
			return
		}
		conn.in_len += int(r)
	}
	_begin_write(conn, "err too_large\n")
}

@(private)
_write_slot :: proc(conn: ^Ipc_Conn) {
	for conn.out_off < conn.out_len && conn.deadline_ns > _now() {
		remaining := conn.out_len - conn.out_off
		n := posix.send(conn.fd, &conn.out_buf[conn.out_off], c.size_t(remaining), {.NOSIGNAL})
		if n > 0 {
			conn.out_off += int(n)
			continue
		}
		if n < 0 && posix.errno() == .EINTR do continue
		if n < 0 && posix.errno() == .EAGAIN do return
		break
	}
	_close_slot(conn) // done, error, or past its deadline
}
