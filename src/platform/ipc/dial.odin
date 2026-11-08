package platform_ipc

// _dial connects to path (bounded by _DIAL_MS) and checks that the other
// side runs as our uid (a second line behind the private dir, spec G7).

import "core:c"
import "core:fmt"
import "core:sys/posix"
import "core:time"

@(private)
_DIAL_MS :: 500

@(private)
_dial :: proc(path: string) -> (fd: posix.FD, err: Error) {
	addr: posix.sockaddr_un
	if !_fill_sockaddr(path, &addr) {
		return -1, {kind = .Unsafe_Path, reason = fmt.tprintf("%s is too long for a unix socket", path)}
	}
	fd = posix.socket(.UNIX, .STREAM)
	if fd == -1 do return -1, {kind = .No_Server, reason = fmt.tprintf("cannot create socket for %s", path)}
	if !_set_nonblocking_cloexec(fd) {
		posix.close(fd)
		return -1, {kind = .No_Server, reason = fmt.tprintf("cannot configure socket for %s", path)}
	}
	deadline := time.tick_now()._nsec + i64(_DIAL_MS) * 1_000_000
	if conn_err := _dial_connect(fd, &addr, deadline, path); conn_err.kind != .None {
		posix.close(fd)
		return -1, conn_err
	}
	uid, ok := _peer_uid(fd)
	if !ok || uid != posix.getuid() {
		posix.close(fd)
		return -1, {kind = .Unsafe_Peer, reason = fmt.tprintf("%s is served by another user", path)}
	}
	return fd, {}
}

@(private = "file")
_dial_connect :: proc(fd: posix.FD, addr: ^posix.sockaddr_un, deadline_ns: i64, path: string) -> Error {
	if posix.connect(fd, (^posix.sockaddr)(addr), size_of(addr^)) == .OK do return {}
	e := posix.errno()
	if e == .ENOENT || e == .ECONNREFUSED do return {kind = .No_Server, reason = fmt.tprintf("nothing listens at %s", path)}
	if e != .EINPROGRESS && e != .EAGAIN do return {kind = .No_Server, reason = fmt.tprintf("cannot connect to %s", path)}
	for {
		ms := (deadline_ns - time.tick_now()._nsec) / 1_000_000
		if ms <= 0 do return {kind = .Busy, reason = fmt.tprintf("%s does not accept", path)}
		pfd := posix.pollfd{fd = fd, events = {.OUT}}
		ready := posix.poll(&pfd, 1, c.int(ms))
		if ready > 0 do break
		if ready == 0 do return {kind = .Busy, reason = fmt.tprintf("%s does not accept", path)}
		if posix.errno() != .EINTR do return {kind = .No_Server, reason = fmt.tprintf("cannot connect to %s", path)}
	}
	so_error: c.int
	so_len := posix.socklen_t(size_of(so_error))
	if posix.getsockopt(fd, posix.SOL_SOCKET, .ERROR, &so_error, &so_len) != .OK || so_error != 0 {
		err := posix.Errno(so_error)
		if err == .ENOENT || err == .ECONNREFUSED do return {kind = .No_Server, reason = fmt.tprintf("nothing listens at %s", path)}
		return {kind = .No_Server, reason = fmt.tprintf("cannot connect to %s", path)}
	}
	return {}
}

// _STREAM_SOCKET_BUF: send and receive buffer of a Server peer and a Client.
// A unix socket starts with 8 KiB on macOS, so one DATA frame (≤ 64 KiB)
// took several write/read rounds; with a credit window of room, a reader
// that drained its socket always gets at least one whole frame per write.
@(private)
_STREAM_SOCKET_BUF :: STREAM_WINDOW

@(private)
_socket_buffers :: proc(fd: posix.FD) {
	size := i32(_STREAM_SOCKET_BUF)
	posix.setsockopt(fd, posix.SOL_SOCKET, .SNDBUF, &size, size_of(size))
	posix.setsockopt(fd, posix.SOL_SOCKET, .RCVBUF, &size, size_of(size))
}
