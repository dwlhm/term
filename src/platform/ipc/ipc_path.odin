package platform_ipc

// Socket path resolution, safe bind with stale-socket recovery, peer identity.
// Contract: see ipc.odin invariants 4.

import "core:c"
import "core:fmt"
import "core:os"
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

// probe_result finishes a non-blocking connect: poll POLLOUT then SO_ERROR.
@(private = "file")
probe_result :: proc(fd: posix.FD) -> Ipc_Error {
	pfd := posix.pollfd{fd = fd, events = {.OUT}}
	ready: c.int
	for {
		ready = posix.poll(&pfd, 1, 200)
		if ready >= 0 || posix.errno() != .EINTR do break
	}
	if ready <= 0 do return .Socket_Failed
	so_error: c.int
	so_len := posix.socklen_t(size_of(so_error))
	if posix.getsockopt(fd, posix.SOL_SOCKET, .ERROR, &so_error, &so_len) != .OK {
		return .Socket_Failed
	}
	#partial switch posix.Errno(so_error) {
	case .NONE:
		return .None
	case .ENOENT, .ECONNREFUSED:
		return .Not_Running
	case:
		return .Socket_Failed
	}
}

// unlink_bound releases a socket that failed after bind.
@(private = "file")
unlink_bound :: proc(fd: posix.FD, cpath: cstring) -> Ipc_Error {
	posix.close(fd)
	posix.unlink(cpath)
	return .Socket_Failed
}
// ipc_default_socket_path writes the control socket path into buf.
// $TERM_CTL_SOCK, if set and non-empty, is returned as-is (no dir handling).
// Otherwise "<$TMPDIR or /tmp, trailing '/' trimmed>/term-<uid>/ctl.sock":
// the dir is created with mode 0700 if missing, then validated with lstat
// (S_ISDIR, not a symlink, st_uid == getuid(), (st_mode & 0o077) == 0) →
// Unsafe_Path otherwise. Path_Too_Long if the result (+NUL) does not fit
// sockaddr_un.sun_path or buf.
ipc_default_socket_path :: proc(buf: []u8) -> (path: string, err: Ipc_Error) {
	env: [256]u8
	override, _ := os.lookup_env(env[:], IPC_SOCKET_PATH_ENV)
	if len(override) > 0 {
		if len(override) + 1 > sun_path_len() || len(override) + 1 > len(buf) {
			return "", .Path_Too_Long
		}
		copy(buf, override)
		return string(buf[:len(override)]), .None
	}
	tmp, _ := os.lookup_env(env[:], "TMPDIR")
	if len(tmp) == 0 do tmp = "/tmp"
	base_len := len(tmp)
	for base_len > 1 && tmp[base_len - 1] == '/' do base_len -= 1
	work: [256]u8
	dir := fmt.bprintf(work[:], "%s/term-%d", tmp[:base_len], int(posix.getuid()))
	full_len := len(dir) + len("/ctl.sock")
	if full_len + 1 > sun_path_len() || full_len + 1 > len(buf) {
		return "", .Path_Too_Long
	}
	dir_c: [256]u8
	cpath, ok := cstring_from(dir_c[:], dir)
	if !ok do return "", .Path_Too_Long
	if posix.mkdir(cpath, posix.S_IRWXU) != .OK && posix.errno() != .EEXIST {
		return "", .Unsafe_Path
	}
	st: posix.stat_t
	if posix.lstat(cpath, &st) != .OK do return "", .Unsafe_Path
	if !posix.S_ISDIR(st.st_mode) || st.st_uid != posix.getuid() || group_other_access(st.st_mode) {
		return "", .Unsafe_Path
	}
	copy(buf[:len(dir)], dir)
	copy(buf[len(dir):], "/ctl.sock")
	return string(buf[:full_len]), .None
}

// ipc_probe connects to path once (non-blocking connect, ≤ 200 ms poll).
// .None = a live server accepted; .Not_Running = ENOENT or ECONNREFUSED;
// .Socket_Failed otherwise. Always closes its fd.
ipc_probe :: proc(path: string) -> Ipc_Error {
	addr: posix.sockaddr_un
	if !ipc_fill_sockaddr(path, &addr) do return .Socket_Failed
	fd := posix.socket(.UNIX, .STREAM)
	if fd == -1 do return .Socket_Failed
	defer posix.close(fd)
	if !ipc_set_nonblocking_cloexec(fd) do return .Socket_Failed
	if posix.connect(fd, (^posix.sockaddr)(&addr), size_of(addr)) == .OK {
		return .None
	}
	#partial switch posix.errno() {
	case .EINPROGRESS, .EAGAIN:
		return probe_result(fd)
	case .ENOENT, .ECONNREFUSED:
		return .Not_Running
	case:
		return .Socket_Failed
	}
}

// _probe_settled only reports .Not_Running when three probes 50 ms apart all
// agree: macOS answers ECONNREFUSED while a live listener's backlog is full,
// and a live socket must never be mistaken for a stale one and unlinked.
@(private = "file")
_probe_settled :: proc(path: string) -> Ipc_Error {
	for attempt in 0..<3 {
		if res := ipc_probe(path); res != .Not_Running do return res
		if attempt < 2 do time.sleep(50 * time.Millisecond)
	}
	return .Not_Running
}

// ipc_bind_listener: ipc_probe(path) == .None → Already_Running.
// If path exists after a failed probe: unlink only when lstat reports
// S_IFSOCK with st_uid == getuid(), else Unsafe_Path.
// socket(AF_UNIX, SOCK_STREAM), fcntl O_NONBLOCK + FD_CLOEXEC, bind,
// chmod 0600, listen(IPC_LISTEN_BACKLOG), lstat → ino. On any failure the fd
// is closed and nothing is left bound.
ipc_bind_listener :: proc(path: string) -> (fd: posix.FD, ino: u64, err: Ipc_Error) {
	path_c: [256]u8
	cpath, ok := cstring_from(path_c[:], path)
	if !ok do return -1, 0, .Path_Too_Long
	st: posix.stat_t
	exists := posix.lstat(cpath, &st) == .OK
	if !exists && posix.errno() != .ENOENT do return -1, 0, .Socket_Failed
	if exists && (!posix.S_ISSOCK(st.st_mode) || st.st_uid != posix.getuid()) {
		return -1, 0, .Unsafe_Path
	}
	if exists {
		#partial switch _probe_settled(path) {
		case .None:        return -1, 0, .Already_Running
		case .Not_Running: if posix.unlink(cpath) != .OK do return -1, 0, .Socket_Failed
		case:              return -1, 0, .Socket_Failed
		}
	}
	addr: posix.sockaddr_un
	if !ipc_fill_sockaddr(path, &addr) do return -1, 0, .Path_Too_Long
	sock := posix.socket(.UNIX, .STREAM)
	if sock == -1 do return -1, 0, .Socket_Failed
	if !ipc_set_nonblocking_cloexec(sock) {
		posix.close(sock)
		return -1, 0, .Socket_Failed
	}
	if posix.bind(sock, (^posix.sockaddr)(&addr), size_of(addr)) != .OK {
		posix.close(sock)
		return -1, 0, .Socket_Failed
	}
	if posix.chmod(cpath, posix.mode_t{.IRUSR, .IWUSR}) != .OK {
		return -1, 0, unlink_bound(sock, cpath)
	}
	if posix.listen(sock, IPC_LISTEN_BACKLOG) != .OK do return -1, 0, unlink_bound(sock, cpath)
	if posix.lstat(cpath, &st) != .OK do return -1, 0, unlink_bound(sock, cpath)
	return sock, u64(st.st_ino), .None
}

// ipc_peer_uid returns the effective uid of the connected peer.
// Darwin: getpeereid (foreign import libc). Linux: getsockopt SO_PEERCRED.
ipc_peer_uid :: proc(fd: posix.FD) -> (uid: posix.uid_t, ok: bool) {
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

// ipc_set_nonblocking_cloexec sets O_NONBLOCK and FD_CLOEXEC; false on failure.
ipc_set_nonblocking_cloexec :: proc(fd: posix.FD) -> bool {
	flags := posix.fcntl(fd, .GETFL)
	if flags == -1 do return false
	if posix.fcntl(fd, .SETFL, flags | c.int(posix.O_NONBLOCK)) == -1 do return false
	fd_flags := posix.fcntl(fd, .GETFD)
	if fd_flags == -1 do return false
	if posix.fcntl(fd, .SETFD, fd_flags | c.int(posix.FD_CLOEXEC)) == -1 do return false
	return true
}

// ipc_fill_sockaddr fills a sockaddr_un for path (sun_len set on Darwin).
// false if path (+NUL) does not fit sun_path.
ipc_fill_sockaddr :: proc(path: string, addr: ^posix.sockaddr_un) -> bool {
	if addr == nil do return false
	addr^ = {}
	addr.sun_family = .UNIX
	when ODIN_OS == .Darwin {
		addr.sun_len = c.uchar(size_of(posix.sockaddr_un))
	}
	if len(path) + 1 > len(addr.sun_path) do return false
	for i in 0..<len(path) do addr.sun_path[i] = c.char(path[i])
	addr.sun_path[len(path)] = 0
	return true
}
