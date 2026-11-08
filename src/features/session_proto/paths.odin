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

STREAM_PROTO_VERSION :: 2 // the session link wire until M3; the holder link stays 0.0.2

// ctl_socket_path writes the control socket path into buf.
// $TERM_CTL_SOCK, if set and non-empty, is returned as-is (no dir handling).
// Otherwise "<$TMPDIR or /tmp, trailing '/' trimmed>/term-<uid>/ctl.sock":
// the dir is created with mode 0700 if missing, then validated with lstat
// (S_ISDIR, not a symlink, st_uid == getuid(), (st_mode & 0o077) == 0) →
// Unsafe_Path otherwise. Path_Too_Long if the result (+NUL) does not fit
// sockaddr_un.sun_path or buf.
ctl_socket_path :: proc(buf: []u8) -> (path: string, err: ipc.Ipc_Error) {
	env: [256]u8
	override, _ := os.lookup_env(env[:], CTL_SOCK_ENV)
	if len(override) > 0 {
		if len(override) + 1 > _SUN_PATH || len(override) + 1 > len(buf) {
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
	if full_len + 1 > _SUN_PATH || full_len + 1 > len(buf) {
		return "", .Path_Too_Long
	}
	dir_c: [256]u8
	cpath, ok := _cstr(dir_c[:], dir)
	if !ok do return "", .Path_Too_Long
	if posix.mkdir(cpath, posix.S_IRWXU) != .OK && posix.errno() != .EEXIST {
		return "", .Unsafe_Path
	}
	st: posix.stat_t
	if posix.lstat(cpath, &st) != .OK do return "", .Unsafe_Path
	if !posix.S_ISDIR(st.st_mode) || st.st_uid != posix.getuid() || st.st_mode & (posix.S_IRWXG + posix.S_IRWXO) != {} {
		return "", .Unsafe_Path
	}
	copy(buf[:len(dir)], dir)
	copy(buf[len(dir):], "/ctl.sock")
	return string(buf[:full_len]), .None
}

// session_dir: $TERM_SESSION_DIR (created 0700) or the directory of the
// control socket ($TMPDIR/term-<uid>). Both are validated private to us.
session_dir :: proc(buf: []u8) -> (dir: string, err: ipc.Ipc_Error) {
	env: [256]u8
	if override, _ := os.lookup_env(env[:], SESSION_DIR_ENV); len(override) > 0 {
		if len(override) + 16 > _SUN_PATH || len(override) > len(buf) do return "", .Path_Too_Long
		dir = string(buf[:copy(buf, override)])
		return dir, _ensure_private_dir(dir)
	}
	path := ctl_socket_path(buf) or_return
	for i := len(path) - 1; i > 0; i -= 1 do if path[i] == '/' do return path[:i], .None
	return "", .Unsafe_Path
}

// session_path joins dir and name into buf, checking sun_path.
session_path :: proc(buf: []u8, dir, name: string) -> (string, bool) {
	path := fmt.bprintf(buf, "%s/%s", dir, name)
	return path, len(path) == len(dir) + 1 + len(name) && len(path) + 1 <= _SUN_PATH
}

@(private = "file")
_ensure_private_dir :: proc(dir: string) -> ipc.Ipc_Error {
	cbuf: [256]u8
	cpath, ok := _cstr(cbuf[:], dir)
	if !ok do return .Path_Too_Long
	if posix.mkdir(cpath, posix.S_IRWXU) != .OK && posix.errno() != .EEXIST do return .Unsafe_Path
	st: posix.stat_t
	if posix.lstat(cpath, &st) != .OK do return .Unsafe_Path
	if !posix.S_ISDIR(st.st_mode) || st.st_uid != posix.getuid() || st.st_mode & (posix.S_IRWXG + posix.S_IRWXO) != {} {
		return .Unsafe_Path
	}
	return .None
}

// log_path is where a detached tier appends its stdout/stderr: the shared
// $TMPDIR/term-<uid> dir even for a private session, so a private session dir
// holds nothing but sockets and is removed when its last tier exits.
log_path :: proc(buf: []u8, name: string) -> string {
	sock_buf: [256]u8
	path, err := ctl_socket_path(sock_buf[:])
	if err != .None do return "/dev/null"
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
@(private = "file")
_cstr :: proc(buf: []u8, path: string) -> (cstring, bool) {
	if len(path) + 1 > len(buf) do return nil, false
	copy(buf, path)
	buf[len(path)] = 0
	return cstring(raw_data(buf)), true
}
