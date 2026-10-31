package platform_ipc

// Socket path resolution, safe bind with stale-socket recovery, peer identity.
// Contract: see ipc.odin invariants 4.

import "core:sys/posix"

// ipc_default_socket_path writes the control socket path into buf.
// $TERM_CTL_SOCK, if set and non-empty, is returned as-is (no dir handling).
// Otherwise "<$TMPDIR or /tmp, trailing '/' trimmed>/term-<uid>/ctl.sock":
// the dir is created with mode 0700 if missing, then validated with lstat
// (S_ISDIR, not a symlink, st_uid == getuid(), (st_mode & 0o077) == 0) →
// Unsafe_Path otherwise. Path_Too_Long if the result (+NUL) does not fit
// sockaddr_un.sun_path or buf.
ipc_default_socket_path :: proc(buf: []u8) -> (path: string, err: Ipc_Error) {
	unimplemented("T5a")
}

// ipc_probe connects to path once (non-blocking connect, ≤ 200 ms poll).
// .None = a live server accepted; .Not_Running = ENOENT or ECONNREFUSED;
// .Socket_Failed otherwise. Always closes its fd.
ipc_probe :: proc(path: string) -> Ipc_Error {
	unimplemented("T5a")
}

// ipc_bind_listener: ipc_probe(path) == .None → Already_Running.
// If path exists after a failed probe: unlink only when lstat reports
// S_IFSOCK with st_uid == getuid(), else Unsafe_Path.
// socket(AF_UNIX, SOCK_STREAM), fcntl O_NONBLOCK + FD_CLOEXEC, bind,
// chmod 0600, listen(IPC_LISTEN_BACKLOG), lstat → ino. On any failure the fd
// is closed and nothing is left bound.
ipc_bind_listener :: proc(path: string) -> (fd: posix.FD, ino: u64, err: Ipc_Error) {
	unimplemented("T5a")
}

// ipc_peer_uid returns the effective uid of the connected peer.
// Darwin: getpeereid (foreign import libc). Linux: getsockopt SO_PEERCRED.
ipc_peer_uid :: proc(fd: posix.FD) -> (uid: posix.uid_t, ok: bool) {
	unimplemented("T5a")
}

// ipc_set_nonblocking_cloexec sets O_NONBLOCK and FD_CLOEXEC; false on failure.
ipc_set_nonblocking_cloexec :: proc(fd: posix.FD) -> bool {
	unimplemented("T5a")
}

// ipc_fill_sockaddr fills a sockaddr_un for path (sun_len set on Darwin).
// false if path (+NUL) does not fit sun_path.
ipc_fill_sockaddr :: proc(path: string, addr: ^posix.sockaddr_un) -> bool {
	unimplemented("T5a")
}
