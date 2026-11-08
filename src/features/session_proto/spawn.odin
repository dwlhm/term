package feature_session_proto

// How term's tiers start each other: `<this executable> --holder|--core`,
// detached from the caller's session, and which build is running (tiers of
// another build never adopt each other's state: old holders drain).

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

SPAWN_MAX_ARGS :: 8

// self_exe is the absolute path of the running binary ("" if unknown).
self_exe :: proc(buf: []u8) -> string {
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

// build_id names the running build: binary size + mtime.
build_id :: proc(buf: []u8) -> string {
	exe_buf, cbuf: [1024]u8
	cpath, ok := _cstr(cbuf[:], self_exe(exe_buf[:]))
	st: posix.stat_t
	if !ok || posix.stat(cpath, &st) != .OK do return "unknown"
	return fmt.bprintf(buf, "%x-%x", i64(st.st_size), i64(st.st_mtim.tv_sec))
}

// spawn_self starts this binary with args in a new session (double fork +
// setsid, reparented to init), stdin from /dev/null and stdout/stderr
// appended to log ("" = /dev/null). Everything the child touches between
// fork and exec is prepared up front (the caller may be multi-threaded).
spawn_self :: proc(args: []string, log: string) -> bool {
	if len(args) + 1 > SPAWN_MAX_ARGS do return false
	store: [SPAWN_MAX_ARGS][512]u8
	argv: [SPAWN_MAX_ARGS + 1]cstring
	exe_buf: [1024]u8
	ok: bool
	if argv[0], ok = _cstr(store[0][:], self_exe(exe_buf[:])); !ok || argv[0] == "" do return false
	for a, i in args do if argv[i + 1], ok = _cstr(store[i + 1][:], a); !ok do return false
	log_buf: [512]u8
	log_c, log_ok := _cstr(log_buf[:], log if log != "" else "/dev/null")
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
