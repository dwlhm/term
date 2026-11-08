package platform_ipc

// Session tier plumbing: where the tiers' sockets live, which binary we are,
// and how one tier starts another detached from its caller's session.

import "core:c"
import "core:fmt"
import "core:sys/posix"

when ODIN_OS == .Darwin {
	foreign import libc "system:System.framework"
	@(default_calling_convention = "c")
	foreign libc {
		_NSGetExecutablePath :: proc(buf: [^]u8, size: ^u32) -> c.int ---
	}
}

// _self_exe is the absolute path of the running binary ("" if unknown).
@(private)
_self_exe :: proc(buf: []u8) -> string {
	when ODIN_OS == .Darwin {
		size := u32(len(buf))
		if _NSGetExecutablePath(raw_data(buf), &size) != 0 do return ""
		n := 0
		for n < len(buf) && buf[n] != 0 do n += 1
		return string(buf[:n])
	} else {
		n := posix.readlink("/proc/self/exe", raw_data(buf), c.size_t(len(buf)))
		return string(buf[:n]) if n > 0 && int(n) < len(buf) else ""
	}
}

// _build_id names the running build: binary size + mtime. Two tiers of
// different builds never adopt each other's protocol state (old holders drain).
@(private)
_build_id :: proc(buf: []u8) -> string {
	exe_buf: [1024]u8
	exe := _self_exe(exe_buf[:])
	cbuf: [1024]u8
	cpath, ok := cstring_from(cbuf[:], exe)
	st: posix.stat_t
	if !ok || posix.stat(cpath, &st) != .OK do return "unknown"
	return fmt.bprintf(buf, "%x-%x", i64(st.st_size), i64(st.st_mtim.tv_sec))
}

@(private)
_SPAWN_MAX_ARGS :: 8

// _spawn_detached starts argv ("" in argv[0] = this binary) in a new
// session (double fork + setsid, reparented to init), stdin from /dev/null
// and stdout/stderr appended to log_path ("" = /dev/null). Everything the
// child touches between fork and exec is prepared up front (the caller may
// be multi-threaded).
@(private)
_spawn_detached :: proc(argv_in: []string, log_path: string) -> bool {
	if len(argv_in) == 0 || len(argv_in) > _SPAWN_MAX_ARGS do return false
	exe_buf: [1024]u8
	exe := argv_in[0] if argv_in[0] != "" else _self_exe(exe_buf[:])
	if len(exe) == 0 do return false
	store: [_SPAWN_MAX_ARGS][512]u8
	argv: [_SPAWN_MAX_ARGS + 1]cstring
	ok: bool
	if argv[0], ok = cstring_from(store[0][:], exe); !ok do return false
	for a, i in argv_in[1:] do if argv[i + 1], ok = cstring_from(store[i + 1][:], a); !ok do return false
	log_buf: [512]u8
	log_c, log_ok := cstring_from(log_buf[:], log_path if log_path != "" else "/dev/null")
	if !log_ok do return false
	pid := posix.fork()
	if pid < 0 do return false
	if pid == 0 do _detached_child(argv[0], raw_data(argv[:]), log_c)
	status: c.int
	for posix.waitpid(pid, &status, {}) == -1 && posix.errno() == .EINTR {}
	return true
}

@(private = "file")
_detached_child :: proc(exe: cstring, argv: [^]cstring, log_c: cstring) -> ! {
	posix.setsid()
	if posix.fork() != 0 do posix._exit(0)
	null_fd := posix.open("/dev/null", {.RDWR})
	log_fd := posix.open(log_c, {.WRONLY, .CREAT, .APPEND, .CLOEXEC}, {.IRUSR, .IWUSR})
	out_fd := log_fd if log_fd >= 0 else null_fd
	posix.dup2(null_fd, 0)
	posix.dup2(out_fd, 1)
	posix.dup2(out_fd, 2)
	// Unblock what the GUI blocks for its sigwait thread: the new tier owns its signals.
	empty: posix.sigset_t
	posix.sigemptyset(&empty)
	posix.pthread_sigmask(.SETMASK, &empty, nil)
	posix.execv(exe, argv)
	posix._exit(127)
}

// _unlink_if_ours removes path only while it is still the socket inode we bound.
@(private)
_unlink_if_ours :: proc(path: string, ino: u64) {
	cbuf: [256]u8
	cpath, ok := cstring_from(cbuf[:], path)
	st: posix.stat_t
	if ok && posix.lstat(cpath, &st) == .OK && u64(st.st_ino) == ino do posix.unlink(cpath)
}
