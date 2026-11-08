package platform_ipc_contract

// Fake peers: plain posix sockets that speak the wire of spec 7.10 by hand,
// so a test can send what no Client or Server would. Sockets are blocking;
// every read has a deadline so a missing answer fails the test, never hangs it.

import "core:c"
import "core:sys/posix"
import ipc "../"

@(private = "file")
_sockaddr :: proc(path: string, addr: ^posix.sockaddr_un) -> bool {
	addr.sun_family = .UNIX
	when ODIN_OS == .Darwin do addr.sun_len = c.uchar(size_of(posix.sockaddr_un))
	if len(path) >= len(addr.sun_path) do return false
	copy(addr.sun_path[:], path)
	return true
}

// raw_dial connects to at; -1 when nothing accepts there.
raw_dial :: proc(at: ipc.Endpoint) -> posix.FD {
	addr: posix.sockaddr_un
	if !_sockaddr(sock_path(at), &addr) do return -1
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 do return -1
	if posix.connect(fd, (^posix.sockaddr)(&addr), size_of(addr)) != .OK {
		posix.close(fd)
		return -1
	}
	return fd
}

// raw_listen binds at for a fake server (or a socket that replaces a path).
raw_listen :: proc(at: ipc.Endpoint) -> posix.FD {
	addr: posix.sockaddr_un
	if !_sockaddr(sock_path(at), &addr) do return -1
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 do return -1
	if posix.bind(fd, (^posix.sockaddr)(&addr), size_of(addr)) != .OK || posix.listen(fd, 16) != .OK {
		posix.close(fd)
		return -1
	}
	return fd
}

// raw_wait: true when fd is readable (or hung up) within timeout_ms.
raw_wait :: proc(fd: posix.FD, timeout_ms: int) -> bool {
	pfd := posix.pollfd{fd = fd, events = {.IN}}
	return posix.poll(&pfd, 1, c.int(timeout_ms)) > 0
}

raw_accept :: proc(lfd: posix.FD, timeout_ms: int) -> posix.FD {
	if !raw_wait(lfd, timeout_ms) do return -1
	return posix.accept(lfd, nil, nil)
}

raw_write :: proc(fd: posix.FD, bytes: []u8) -> bool {
	off := 0
	for off < len(bytes) {
		n := posix.send(fd, raw_data(bytes[off:]), c.size_t(len(bytes[off:])), {.NOSIGNAL})
		if n > 0 {
			off += int(n)
		} else if n < 0 && posix.errno() == .EINTR {
			continue
		} else {
			return false
		}
	}
	return true
}

// raw_read fills buf completely within timeout_ms; false on EOF, error or time.
raw_read :: proc(fd: posix.FD, buf: []u8, timeout_ms: int) -> bool {
	due := now_ns() + i64(timeout_ms) * 1_000_000
	off := 0
	for off < len(buf) {
		left := int((due - now_ns()) / 1_000_000)
		if left <= 0 || !raw_wait(fd, left) do return false
		n := posix.recv(fd, raw_data(buf[off:]), c.size_t(len(buf[off:])), {})
		if n > 0 {
			off += int(n)
		} else if n < 0 && posix.errno() == .EINTR {
			continue
		} else {
			return false
		}
	}
	return true
}

// raw_closed: true once the other side has closed within timeout_ms
// (whatever it still sent is drained and dropped).
raw_closed :: proc(fd: posix.FD, timeout_ms: int) -> bool {
	due := now_ns() + i64(timeout_ms) * 1_000_000
	scratch: [4096]u8
	for {
		left := int((due - now_ns()) / 1_000_000)
		if left <= 0 || !raw_wait(fd, left) do return false
		n := posix.recv(fd, raw_data(scratch[:]), len(scratch), {})
		if n == 0 do return true
		if n < 0 && posix.errno() != .EINTR do return true
	}
}

// raw_silent: true when nothing at all arrives (and fd stays open) for ms.
raw_silent :: proc(fd: posix.FD, ms: int) -> bool { return !raw_wait(fd, ms) }
