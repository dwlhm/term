package platform_ipc

// Socket path resolution, safe bind with stale-socket recovery, peer identity.

import "core:c"
import "core:fmt"
import "core:sys/posix"
import "core:time"

when ODIN_OS == .Darwin {
	foreign import libc "system:System.framework"
	foreign libc {
		getpeereid :: proc(fd: posix.FD, uid: ^posix.uid_t, gid: ^posix.gid_t) -> posix.result ---
	}
} else {
	Peer_Cred :: struct {
		pid: posix.pid_t,
		uid: posix.uid_t,
		gid: posix.gid_t,
	}
	SO_PEERCRED :: 17
}

@(private)
_LISTEN_BACKLOG :: 16

@(private)
cstring_from :: proc(buf: []u8, path: string) -> (cstring, bool) {
	if len(path) + 1 > len(buf) do return "", false
	copy(buf, path)
	buf[len(path)] = 0
	return cstring(raw_data(buf)), true
}

@(private)
sun_path_len :: proc "contextless" () -> int { return len((posix.sockaddr_un{}).sun_path) }

// group_other_access reports any permission bit outside the owner trio.
@(private)
group_other_access :: proc "contextless" (m: posix.mode_t) -> bool {
	return card(m & posix.mode_t{.IRGRP, .IWGRP, .IXGRP, .IROTH, .IWOTH, .IXOTH}) != 0
}

// _probe_result finishes a non-blocking connect: poll POLLOUT then SO_ERROR.
@(private = "file")
_probe_result :: proc(fd: posix.FD) -> bool {
	pfd := posix.pollfd{fd = fd, events = {.OUT}}
	ready: c.int
	for {
		ready = posix.poll(&pfd, 1, 200)
		if ready >= 0 || posix.errno() != .EINTR do break
	}
	if ready <= 0 do return false
	so_error: c.int
	so_len := posix.socklen_t(size_of(so_error))
	if posix.getsockopt(fd, posix.SOL_SOCKET, .ERROR, &so_error, &so_len) != .OK {
		return false
	}
	return posix.Errno(so_error) == .NONE
}

// _probe connects to path once (non-blocking connect, <= 200 ms poll).
// Returns true only when a live server accepted the connection.
@(private = "file")
_probe :: proc(path: string) -> bool {
	addr: posix.sockaddr_un
	if !_fill_sockaddr(path, &addr) do return false
	fd := posix.socket(.UNIX, .STREAM)
	if fd == -1 do return false
	defer posix.close(fd)
	if !_set_nonblocking_cloexec(fd) do return false
	if posix.connect(fd, (^posix.sockaddr)(&addr), size_of(addr)) == .OK {
		return true
	}
	#partial switch posix.errno() {
	case .EINPROGRESS, .EAGAIN:
		return _probe_result(fd)
	case:
		return false
	}
}

// _probe_settled returns true if any probe succeeds. It only reports false
// when three probes 50 ms apart all fail: macOS answers ECONNREFUSED while
// a live listener's backlog is full, and a live socket must never be mistaken
// for a stale one and unlinked.
@(private)
_probe_settled :: proc(path: string) -> bool {
	for attempt in 0 ..< 3 {
		if _probe(path) do return true
		if attempt < 2 do time.sleep(50 * time.Millisecond)
	}
	return false
}

@(private = "file")
_unlink_bound :: proc(fd: posix.FD, cpath: cstring) {
	posix.close(fd)
	posix.unlink(cpath)
}

// _bind_listener binds and listens on path. If the socket exists and a live
// server is running, returns .Already_Running. If it exists as a stale socket
// owned by us, unlinks it and rebinds.
@(private)
_bind_listener :: proc(path: string) -> (fd: posix.FD, ino: u64, err: Error) {
	path_c: [256]u8
	cpath, ok := cstring_from(path_c[:], path)
	if !ok do return -1, 0, {kind = .Unsafe_Path, reason = fmt.tprintf("cannot use %s", path)}
	st: posix.stat_t
	exists := posix.lstat(cpath, &st) == .OK
	if !exists && posix.errno() != .ENOENT {
		return -1, 0, {kind = .Start_Failed, reason = fmt.tprintf("cannot listen at %s", path)}
	}
	if exists && (!posix.S_ISSOCK(st.st_mode) || st.st_uid != posix.getuid()) {
		return -1, 0, {kind = .Unsafe_Path, reason = fmt.tprintf("cannot use %s", path)}
	}
	if exists {
		if _probe_settled(path) {
			return -1, 0, {kind = .Already_Running, reason = fmt.tprintf("another server listens at %s", path)}
		}
		if posix.unlink(cpath) != .OK {
			return -1, 0, {kind = .Start_Failed, reason = fmt.tprintf("cannot listen at %s", path)}
		}
	}
	addr: posix.sockaddr_un
	if !_fill_sockaddr(path, &addr) do return -1, 0, {kind = .Unsafe_Path, reason = fmt.tprintf("cannot use %s", path)}
	sock := posix.socket(.UNIX, .STREAM)
	if sock == -1 do return -1, 0, {kind = .Start_Failed, reason = fmt.tprintf("cannot listen at %s", path)}
	if !_set_nonblocking_cloexec(sock) {
		posix.close(sock)
		return -1, 0, {kind = .Start_Failed, reason = fmt.tprintf("cannot listen at %s", path)}
	}
	if posix.bind(sock, (^posix.sockaddr)(&addr), size_of(addr)) != .OK {
		posix.close(sock)
		return -1, 0, {kind = .Start_Failed, reason = fmt.tprintf("cannot listen at %s", path)}
	}
	if posix.chmod(cpath, posix.mode_t{.IRUSR, .IWUSR}) != .OK {
		_unlink_bound(sock, cpath)
		return -1, 0, {kind = .Start_Failed, reason = fmt.tprintf("cannot listen at %s", path)}
	}
	if posix.listen(sock, _LISTEN_BACKLOG) != .OK {
		_unlink_bound(sock, cpath)
		return -1, 0, {kind = .Start_Failed, reason = fmt.tprintf("cannot listen at %s", path)}
	}
	if posix.lstat(cpath, &st) != .OK {
		_unlink_bound(sock, cpath)
		return -1, 0, {kind = .Start_Failed, reason = fmt.tprintf("cannot listen at %s", path)}
	}
	return sock, u64(st.st_ino), {}
}

// _peer_uid returns the effective uid of the connected peer.
// Darwin: getpeereid (foreign import libc). Linux: getsockopt SO_PEERCRED.
@(private)
_peer_uid :: proc(fd: posix.FD) -> (uid: posix.uid_t, ok: bool) {
	when ODIN_OS == .Darwin {
		gid: posix.gid_t
		if getpeereid(fd, &uid, &gid) != .OK do return 0, false
		return uid, true
	} else {
		cred: Peer_Cred
		cred_len := posix.socklen_t(size_of(cred))
		opt := posix.Sock_Option(SO_PEERCRED)
		if posix.getsockopt(fd, posix.SOL_SOCKET, opt, &cred, &cred_len) != .OK do return 0, false
		return cred.uid, true
	}
}

// _set_nonblocking_cloexec sets O_NONBLOCK and FD_CLOEXEC; false on failure.
@(private)
_set_nonblocking_cloexec :: proc(fd: posix.FD) -> bool {
	flags := posix.fcntl(fd, .GETFL)
	if flags == -1 do return false
	if posix.fcntl(fd, .SETFL, flags | c.int(posix.O_NONBLOCK)) == -1 do return false
	fd_flags := posix.fcntl(fd, .GETFD)
	if fd_flags == -1 do return false
	if posix.fcntl(fd, .SETFD, fd_flags | c.int(posix.FD_CLOEXEC)) == -1 do return false
	return true
}

// _fill_sockaddr fills a sockaddr_un for path (sun_len set on Darwin).
// false if path (+NUL) does not fit sun_path.
@(private)
_fill_sockaddr :: proc(path: string, addr: ^posix.sockaddr_un) -> bool {
	if addr == nil do return false
	addr^ = {}
	addr.sun_family = .UNIX
	when ODIN_OS == .Darwin {
		addr.sun_len = c.uchar(size_of(posix.sockaddr_un))
	}
	if len(path) + 1 > len(addr.sun_path) do return false
	for i in 0 ..< len(path) do addr.sun_path[i] = c.char(path[i])
	addr.sun_path[len(path)] = 0
	return true
}
