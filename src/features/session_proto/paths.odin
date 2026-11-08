package feature_session_proto

// Where term's sockets and logs live, from the environment: the session dir
// ($TERM_SESSION_DIR or the control socket's dir, $TMPDIR/term-<uid>), the
// control socket ($TERM_CTL_SOCK) and the tier logs. platform/ipc knows none
// of these names; it validates whatever dir it is given.

import "core:fmt"
import "core:os"
import "core:sys/posix"
import ipc "../../platform/ipc"

// SESSION_ID_ENV names the session a program runs in (set for every spawn,
// last so it wins over an inherited one): `term session` verbs default to it.
SESSION_ID_ENV :: "TERM_SESSION_ID"
SESSION_DIR_ENV :: "TERM_SESSION_DIR" // a private session (Standalone runs, tests)
// "1": one viewer process owns the session dir (client_use_private_session):
// the core ends every session when that owner's last viewer link goes.
SESSION_OWNED_ENV :: "TERM_SESSION_OWNED"

CTL_SOCK_ENV :: "TERM_CTL_SOCK" // the control socket, used as is

// ctl_socket_path writes the control socket path into buf.
// $TERM_CTL_SOCK, if set and non-empty, is returned as-is: the IPC package
// validates its dir wherever it is used. Otherwise
// "$TMPDIR/term-<uid>/ctl.sock" (ipc.private_dir: created 0700, validated).
// .Unsafe_Path when the dir is not private or the path does not fit
// sockaddr_un.sun_path or buf.
ctl_socket_path :: proc(buf: []u8) -> (path: string, err: ipc.Error) {
	env: [256]u8
	override, _ := os.lookup_env(env[:], CTL_SOCK_ENV)
	if len(override) > 0 {
		if len(override) + 1 > _SUN_PATH || len(override) + 1 > len(buf) do return "", _too_long(override)
		return string(buf[:copy(buf, override)]), {}
	}
	dir_buf: [256]u8
	dir: string
	if dir, err = ipc.private_dir(dir_buf[:], "term"); err.kind != .None do return
	full_len := len(dir) + len("/ctl.sock")
	if full_len + 1 > _SUN_PATH || full_len + 1 > len(buf) do return "", _too_long(dir)
	copy(buf[:len(dir)], dir)
	copy(buf[len(dir):], "/ctl.sock")
	return string(buf[:full_len]), {}
}

// session_dir: $TERM_SESSION_DIR (created 0700) or the directory of the
// control socket ($TMPDIR/term-<uid>). Both are validated private to us.
session_dir :: proc(buf: []u8) -> (dir: string, err: ipc.Error) {
	env: [256]u8
	if override, _ := os.lookup_env(env[:], SESSION_DIR_ENV); len(override) > 0 {
		if len(override) + 16 > _SUN_PATH || len(override) > len(buf) do return "", _too_long(override)
		dir = string(buf[:copy(buf, override)])
		return dir, _ensure_private_dir(dir)
	}
	path: string
	if path, err = ctl_socket_path(buf); err.kind != .None do return
	for i := len(path) - 1; i > 0; i -= 1 do if path[i] == '/' do return path[:i], {}
	return "", {kind = .Unsafe_Path, reason = "the control socket path has no directory"}
}

// session_path joins dir and name into buf, checking sun_path.
session_path :: proc(buf: []u8, dir, name: string) -> (string, bool) {
	path := fmt.bprintf(buf, "%s/%s", dir, name)
	return path, len(path) == len(dir) + 1 + len(name) && len(path) + 1 <= _SUN_PATH
}

@(private = "file")
_ensure_private_dir :: proc(dir: string) -> ipc.Error {
	cbuf: [256]u8
	cpath, ok := _cstr(cbuf[:], dir)
	if !ok do return _too_long(dir)
	if posix.mkdir(cpath, posix.S_IRWXU) != .OK && posix.errno() != .EEXIST do return _unsafe(dir, "cannot be created")
	st: posix.stat_t
	switch {
	case posix.lstat(cpath, &st) != .OK:             return _unsafe(dir, "cannot be read")
	case !posix.S_ISDIR(st.st_mode):                 return _unsafe(dir, "is not a directory")
	case st.st_uid != posix.getuid():                return _unsafe(dir, "belongs to another user")
	case st.st_mode & (posix.S_IRWXG + posix.S_IRWXO) != {}: return _unsafe(dir, "is open to group or others")
	}
	return {}
}

@(private = "file")
_unsafe :: proc(path, why: string) -> ipc.Error {
	return {kind = .Unsafe_Path, reason = fmt.tprintf("%s %s", path, why)}
}

@(private = "file")
_too_long :: proc(path: string) -> ipc.Error { return _unsafe(path, "is too long for a unix socket") }

// log_path is where a detached tier appends its stdout/stderr: the shared
// $TMPDIR/term-<uid> dir even for a private session, so a private session dir
// holds nothing but sockets and is removed when its last tier exits.
log_path :: proc(buf: []u8, name: string) -> string {
	sock_buf: [256]u8
	path, err := ctl_socket_path(sock_buf[:])
	if err.kind != .None do return "/dev/null"
	for i := len(path) - 1; i > 0; i -= 1 {
		if path[i] != '/' do continue
		if p, ok := session_path(buf, path[:i], name); ok do return p
		break
	}
	return "/dev/null"
}

@(private = "file")
_SUN_PATH :: len(posix.sockaddr_un{}.sun_path)

// _cstr: path as a C string in buf; false when it does not fit.
@(private)
_cstr :: proc(buf: []u8, path: string) -> (cstring, bool) {
	if len(path) + 1 > len(buf) do return nil, false
	copy(buf, path)
	buf[len(path)] = 0
	return cstring(raw_data(buf)), true
}
