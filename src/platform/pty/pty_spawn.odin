package platform_pty

// fd-level PTY primitives shared by Pty_Handle (GUI) and the holder process:
// spawn a program on a fresh PTY and hang it up. No thread, no ring.

import "core:c"
import "core:os"
import "core:strings"
import posix "core:sys/posix"

// Our identity, set after the scrubbed user environment (extra_env wins over both).
@(private = "file")
TERM_ENV := [?]string{
	"TERM=xterm-256color",
	"COLORTERM=truecolor",
	"TERM_PROGRAM=term",
	"TERM_PROGRAM_VERSION=0.1.0",
	"KITTY_WINDOW_ID=1",
}

_Pty_Pair :: struct {
	master:     posix.FD,
	slave:      posix.FD,
	slave_path: [128]u8,
}

_is_foreign_term_env :: proc(entry: string) -> bool {
	if strings.has_prefix(entry, "TERM=") || strings.has_prefix(entry, "COLORTERM=") do return true
	if strings.has_prefix(entry, "TERM_PROGRAM=") || strings.has_prefix(entry, "TERM_PROGRAM_VERSION=") do return true
	if strings.has_prefix(entry, "GHOSTTY_") || strings.has_prefix(entry, "KITTY_") do return true
	if strings.has_prefix(entry, "WEZTERM_") || strings.has_prefix(entry, "ITERM_") do return true
	if strings.has_prefix(entry, "ALACRITTY_") || strings.has_prefix(entry, "KONSOLE_") do return true
	if strings.has_prefix(entry, "WARP_") || strings.has_prefix(entry, "TABBY_") do return true
	if strings.has_prefix(entry, "WT_SESSION=") || strings.has_prefix(entry, "TERMINFO=") do return true
	return false
}

_winsize :: proc(cols, rows, xpixel, ypixel: int) -> Winsize {
	return Winsize{
		ws_row    = c.ushort(rows),
		ws_col    = c.ushort(cols),
		ws_xpixel = c.ushort(xpixel if xpixel > 0 else cols * 10),
		ws_ypixel = c.ushort(ypixel if ypixel > 0 else rows * 20),
	}
}

// pty_spawn_raw forks cfg's program on a new PTY. The master is
// O_NONBLOCK|FD_CLOEXEC and owned by the caller (release with pty_hangup).
// Every allocation happens in the parent before fork: the child only execs.
pty_spawn_raw :: proc(cfg: Pty_Config, extra_env: []string) -> (master_fd: i32, pid: i32, err: Pty_Error) {
	argv := _exec_argv(cfg)
	defer _free_cstrings(argv)
	envp := _exec_env(extra_env)
	defer _free_cstrings(envp)
	cwd := strings.clone_to_cstring(cfg.cwd) if len(cfg.cwd) > 0 else nil
	defer delete(cwd)

	ws := _winsize(max(1, cfg.cols), max(1, cfg.rows), cfg.xpixel, cfg.ypixel)
	pair: _Pty_Pair
	if open_err := _pty_open(&pair, &ws); open_err != .None do return -1, -1, open_err
	_fd_set_cloexec(pair.master)
	_fd_set_nonblocking(pair.master)

	child := posix.fork()
	if child < 0 {
		posix.close(pair.master)
		posix.close(pair.slave)
		return -1, -1, .Fork_Failed
	}
	if child == 0 do _child_exec(&pair, &ws, cwd, argv, envp)
	posix.close(pair.slave)
	return i32(pair.master), i32(child), .None
}

// _child_exec runs in the forked child: default signal state, the PTY as
// controlling terminal on fds 0-2, nothing else inherited, then execve.
@(private = "file")
_child_exec :: proc(pair: ^_Pty_Pair, ws: ^Winsize, cwd: cstring, argv, envp: []cstring) -> ! {
	empty: posix.sigset_t
	posix.sigemptyset(&empty)
	posix.sigprocmask(.SETMASK, &empty, nil)
	// Ignored dispositions survive exec (the holder ignores SIGPIPE).
	for sig in 1..<32 {
		s := posix.Signal(sig)
		if s != .SIGKILL && s != .SIGSTOP do posix.signal(s, auto_cast posix.SIG_DFL)
	}
	posix.close(pair.master)
	_child_attach_tty(pair, ws)
	for fd in 3..<1024 do posix.close(posix.FD(fd))
	if cwd != nil do posix.chdir(cwd)
	posix.execve(argv[0], raw_data(argv), raw_data(envp))
	posix._exit(127)
}

// argv = [program, args...]; no args → a login shell ("-l").
@(private = "file")
_exec_argv :: proc(cfg: Pty_Config) -> []cstring {
	prog := cfg.shell
	if len(prog) == 0 do prog = os.get_env("SHELL", context.temp_allocator)
	if len(prog) == 0 do prog = "/bin/sh"
	extra := len(cfg.argv) if len(cfg.argv) > 0 else 1
	out := make([]cstring, extra + 2)
	out[0] = strings.clone_to_cstring(prog)
	if len(cfg.argv) == 0 do out[1] = strings.clone_to_cstring("-l")
	for arg, i in cfg.argv do out[i + 1] = strings.clone_to_cstring(arg)
	return out
}

// env = user environment minus foreign terminal identities, then TERM_ENV,
// then extra_env; a later entry drops every earlier entry with the same key.
@(private = "file")
_exec_env :: proc(extra_env: []string) -> []cstring {
	out := make([dynamic]cstring)
	if posix.environ != nil {
		for i := 0; posix.environ[i] != nil; i += 1 {
			entry := string(posix.environ[i])
			if _is_foreign_term_env(entry) || _overridden(entry, TERM_ENV[:]) || _overridden(entry, extra_env) do continue
			append(&out, strings.clone_to_cstring(entry))
		}
	}
	for entry in TERM_ENV do if !_overridden(entry, extra_env) do append(&out, strings.clone_to_cstring(entry))
	for entry in extra_env do if strings.index_byte(entry, '=') > 0 do append(&out, strings.clone_to_cstring(entry))
	append(&out, nil)
	return out[:]
}

@(private = "file")
_overridden :: proc(entry: string, by: []string) -> bool {
	eq := strings.index_byte(entry, '=')
	if eq <= 0 do return false
	for o in by do if len(o) > eq && o[eq] == '=' && o[:eq] == entry[:eq] do return true
	return false
}

@(private = "file")
_free_cstrings :: proc(list: []cstring) {
	for s in list do delete(s)
	delete(list)
}

// pty_hangup releases a PTY child: SIGCONT+SIGHUP+SIGKILL to the foreground
// job (when it is not the child's group), close the master, then the same to
// the child's process group and the child. pid <= 0 skips the child. Reaps
// only if the child is already gone (WNOHANG).
pty_hangup :: proc(master_fd: i32, pid: i32) {
	if master_fd >= 0 {
		fg := tcgetpgrp(c.int(master_fd))
		if fg > 0 && fg != c.int(pid) do _kill_all(posix.pid_t(-fg))
		posix.close(posix.FD(master_fd))
	}
	if pid <= 0 do return
	_kill_all(posix.pid_t(-pid))
	_kill_all(posix.pid_t(pid))
	status: c.int
	posix.waitpid(posix.pid_t(pid), &status, {.NOHANG})
}

@(private = "file")
_kill_all :: proc(target: posix.pid_t) {
	posix.kill(target, .SIGCONT)
	posix.kill(target, .SIGHUP)
	posix.kill(target, .SIGKILL)
}

// pty_set_size applies a window size (TIOCSWINSZ) to the PTY behind master_fd.
pty_set_size :: proc(master_fd: i32, cols, rows, xpixel, ypixel: u16) -> bool {
	if master_fd < 0 do return false
	ws := Winsize{ws_row = c.ushort(rows), ws_col = c.ushort(cols), ws_xpixel = c.ushort(xpixel), ws_ypixel = c.ushort(ypixel)}
	return ioctl(c.int(master_fd), TIOCSWINSZ, &ws) == 0
}

// pty_foreground_info: the foreground process group of the PTY and the name
// and cwd of its leader, written into the caller's buffers (no allocation).
pty_foreground_info :: proc(master_fd: i32, name_buf, cwd_buf: []u8) -> (pgid: i32, name: string, cwd: string) {
	if master_fd < 0 do return
	fg := tcgetpgrp(c.int(master_fd))
	if fg <= 0 do return
	return i32(fg), _proc_name(fg, name_buf), _proc_cwd(fg, cwd_buf)
}
