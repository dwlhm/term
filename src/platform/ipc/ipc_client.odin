package platform_ipc

import "core:c"
import "core:strings"
import "core:sys/posix"
import "core:time"

// One-shot client used by the `term` CLI. Contract: see ipc.odin wire format.

// ipc_client_request connects (non-blocking; ENOENT/ECONNREFUSED →
// Not_Running, EAGAIN → Busy), sends line + '\n' with MSG_NOSIGNAL, then reads
// until EOF into out. One overall deadline of timeout_ms covers every phase
// (poll-based) → Timeout. len(line)+1 > IPC_MAX_LINE or a '\n' inside line →
// Too_Large / Socket_Failed respectively before connecting. out full before
// EOF → Too_Large. A reply of exactly "err busy\n" → Busy (reply still
// returned). Always closes its fd.
ipc_client_request :: proc(path: string, line: string, out: []u8, timeout_ms: int = IPC_CLIENT_TIMEOUT_MS) -> (reply: string, err: Ipc_Error) {
	if len(line) + 1 > IPC_MAX_LINE do return "", .Too_Large
	if strings.contains_rune(line, '\n') do return "", .Socket_Failed
	addr: posix.sockaddr_un
	if !ipc_fill_sockaddr(path, &addr) do return "", .Path_Too_Long
	deadline_ns := time.tick_now()._nsec + i64(timeout_ms) * 1_000_000

	fd := posix.socket(.UNIX, .STREAM)
	if fd == -1 do return "", .Socket_Failed
	defer posix.close(fd)
	if !ipc_set_nonblocking_cloexec(fd) do return "", .Socket_Failed

	if err = _connect(fd, &addr, deadline_ns); err != .None do return "", err
	buf: [IPC_MAX_LINE]u8
	copy(buf[:], line)
	buf[len(line)] = '\n'
	if err = _send_all(fd, buf[:len(line) + 1], deadline_ns); err != .None do return "", err
	n: int
	if n, err = _recv_all(fd, out, deadline_ns); err != .None do return "", err

	reply = string(out[:n])
	if reply == "err busy\n" do return reply, .Busy
	return reply, .None
}

// _wait_fd polls fd for events until deadline_ns (EINTR retried).
@(private = "file")
_wait_fd :: proc(fd: posix.FD, events: posix.Poll_Event, deadline_ns: i64) -> Ipc_Error {
	pfd := posix.pollfd{fd = fd, events = events}
	for {
		ms := (deadline_ns - time.tick_now()._nsec) / 1_000_000
		if ms <= 0 do return .Timeout
		ready := posix.poll(&pfd, 1, c.int(ms))
		if ready > 0 do return .None
		if ready == 0 do return .Timeout
		if posix.errno() != .EINTR do return .Socket_Failed
	}
}

@(private = "file")
_connect_errno :: proc(e: posix.Errno) -> Ipc_Error {
	#partial switch e {
	case .NONE:                return .None
	case .ENOENT, .ECONNREFUSED: return .Not_Running
	case .EAGAIN:              return .Busy
	}
	return .Socket_Failed
}

@(private = "file")
_connect :: proc(fd: posix.FD, addr: ^posix.sockaddr_un, deadline_ns: i64) -> Ipc_Error {
	if posix.connect(fd, (^posix.sockaddr)(addr), size_of(addr^)) == .OK do return .None
	if e := posix.errno(); e != .EINPROGRESS do return _connect_errno(e)
	if err := _wait_fd(fd, {.OUT}, deadline_ns); err != .None do return err
	so_error: c.int
	so_len := posix.socklen_t(size_of(so_error))
	if posix.getsockopt(fd, posix.SOL_SOCKET, .ERROR, &so_error, &so_len) != .OK do return .Socket_Failed
	return _connect_errno(posix.Errno(so_error))
}

@(private = "file")
_send_all :: proc(fd: posix.FD, data: []u8, deadline_ns: i64) -> Ipc_Error {
	sent := 0
	for sent < len(data) {
		remaining := len(data) - sent
		n := posix.send(fd, &data[sent], c.size_t(remaining), {.NOSIGNAL})
		if n > 0 {
			sent += int(n)
			continue
		}
		e := posix.errno()
		if n < 0 && e == .EINTR do continue
		if n < 0 && e == .EAGAIN {
			if err := _wait_fd(fd, {.OUT}, deadline_ns); err != .None do return err
			continue
		}
		return .Socket_Failed
	}
	return .None
}

// _recv_all reads until EOF; data beyond out → Too_Large.
@(private = "file")
_recv_all :: proc(fd: posix.FD, out: []u8, deadline_ns: i64) -> (received: int, err: Ipc_Error) {
	scratch: [1]u8
	for {
		dst := out[received:] if received < len(out) else scratch[:]
		n := posix.recv(fd, raw_data(dst), c.size_t(len(dst)), {})
		if n == 0 do return received, .None
		if n > 0 {
			if received >= len(out) do return received, .Too_Large
			received += int(n)
			continue
		}
		e := posix.errno()
		if e == .EINTR do continue
		if e != .EAGAIN do return received, .Socket_Failed
		if err = _wait_fd(fd, {.IN}, deadline_ns); err != .None do return received, err
	}
}

// ipc_connect opens a non-blocking, close-on-exec connection to path within
// timeout_ms (stream links). The caller owns the fd.
ipc_connect :: proc(path: string, timeout_ms: int = IPC_CLIENT_TIMEOUT_MS) -> (fd: posix.FD, err: Ipc_Error) {
	addr: posix.sockaddr_un
	if !ipc_fill_sockaddr(path, &addr) do return -1, .Path_Too_Long
	fd = posix.socket(.UNIX, .STREAM)
	if fd == -1 do return -1, .Socket_Failed
	if !ipc_set_nonblocking_cloexec(fd) {
		posix.close(fd)
		return -1, .Socket_Failed
	}
	if err = _connect(fd, &addr, time.tick_now()._nsec + i64(timeout_ms) * 1_000_000); err != .None {
		posix.close(fd)
		return -1, err
	}
	return fd, .None
}
