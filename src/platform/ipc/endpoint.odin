package platform_ipc

// Endpoint validation: every socket lives in a directory that is ours alone
// (owned by our uid, not a symlink, no group/other bits), and dir/name must
// fit sun_path. There is no way to skip it (spec 7.2, threat model 5).

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

@(private)
_SUN_PATH :: len(posix.sockaddr_un{}.sun_path) // includes the NUL

// _endpoint_path validates at and lays out dir/name in buf.
@(private)
_endpoint_path :: proc(at: Endpoint, buf: []u8) -> (path: string, err: Error) {
	if at.name == "" || strings.contains_rune(at.name, '/') {
		return "", {kind = .Unsafe_Path, reason = "the socket name must be one path element"}
	}
	if err = _dir_check(at.dir); err.kind != .None do return "", err
	if len(at.dir) + 1 + len(at.name) >= min(_SUN_PATH, len(buf)) {
		return "", {kind = .Unsafe_Path, reason = fmt.tprintf("%s/%s is too long for a unix socket", at.dir, at.name)}
	}
	return fmt.bprintf(buf, "%s/%s", at.dir, at.name), {}
}

// _dir_check: dir is a directory, not a symlink, ours, and closed to others.
@(private)
_dir_check :: proc(dir: string) -> Error {
	cbuf: [1024]u8
	if dir == "" || len(dir) >= len(cbuf) do return {kind = .Unsafe_Path, reason = "no usable socket directory"}
	copy(cbuf[:], dir)
	st: posix.stat_t
	if posix.lstat(cstring(raw_data(cbuf[:])), &st) != .OK {
		return {kind = .Unsafe_Path, reason = fmt.tprintf("%s: %v", dir, posix.errno())}
	}
	switch {
	case posix.S_ISLNK(st.st_mode):
		return {kind = .Unsafe_Path, reason = fmt.tprintf("%s is a symlink", dir)}
	case !posix.S_ISDIR(st.st_mode):
		return {kind = .Unsafe_Path, reason = fmt.tprintf("%s is not a directory", dir)}
	case st.st_uid != posix.getuid():
		return {kind = .Unsafe_Path, reason = fmt.tprintf("%s belongs to another user", dir)}
	case st.st_mode & (posix.S_IRWXG + posix.S_IRWXO) != {}:
		return {kind = .Unsafe_Path, reason = fmt.tprintf("%s is open to group or others", dir)}
	}
	return {}
}

// _private_dir: "$TMPDIR/<app>-<uid>" (or /tmp), made 0700 when missing.
@(private)
_private_dir :: proc(buf: []u8, app: string) -> (dir: string, err: Error) {
	if app == "" || strings.contains_rune(app, '/') do return "", {kind = .Unsafe_Path, reason = "the app name must be one path element"}
	tmp := strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/")
	if tmp == "" do tmp = "/tmp"
	dir = fmt.bprintf(buf, "%s/%s-%d", tmp, app, posix.getuid())
	if len(dir) == len(buf) do return "", {kind = .Unsafe_Path, reason = "the private dir does not fit its buffer"}
	cbuf: [1024]u8
	copy(cbuf[:len(cbuf) - 1], dir)
	if posix.mkdir(cstring(raw_data(cbuf[:])), posix.S_IRWXU) != .OK && posix.errno() != .EEXIST {
		return "", {kind = .Unsafe_Path, reason = fmt.tprintf("%s: %v", dir, posix.errno())}
	}
	return dir, _dir_check(dir)
}
