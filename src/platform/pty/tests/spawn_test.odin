package pty_test

import "core:c"
import "core:testing"
import posix "core:sys/posix"
import sys_darwin "core:sys/darwin"
import pty "../"

// TIOCGWINSZ reads the window size back (test-only; the setter is Langkah 4).
TIOCGWINSZ :: 0x40087468

_Winsize :: struct {
	ws_row:    c.ushort,
	ws_col:    c.ushort,
	ws_xpixel: c.ushort,
	ws_ypixel: c.ushort,
}

// _get_winsize reads the size visible through the master fd.
_get_winsize :: proc(master: int) -> (rows, cols: int, ok: bool) {
	ws: _Winsize
	if sys_darwin.syscall_ioctl(c.int(master), TIOCGWINSZ, rawptr(&ws)) != 0 {
		return 0, 0, false
	}
	return int(ws.ws_row), int(ws.ws_col), true
}

// _teardown kills the spawned child, reaps it, and closes the master fd.
// Only call after a successful spawn.
_teardown :: proc(p: ^pty.Pty) {
	if p.pid > 0 {
		posix.kill(posix.pid_t(p.pid), .SIGKILL)
		status: c.int
		posix.waitpid(posix.pid_t(p.pid), &status, posix.Wait_Flags{})
		p.pid = -1
	}
	if p.master >= 0 {
		posix.close(posix.FD(p.master))
		p.master = -1
	}
}

@(test)
test_spawn_shell :: proc(t: ^testing.T) {
	p: pty.Pty
	ok := pty.pty_spawn(&p, 24, 80, "/bin/sh", {})
	testing.expect(t, ok, "pty_spawn /bin/sh must succeed")
	if !ok {
		return
	}
	defer _teardown(&p)
	testing.expect(t, p.master >= 0, "master fd must be valid")
	testing.expect(t, p.pid > 0, "child pid must be positive")
	testing.expect(t, p.state == .Running, "state must be Running")
	testing.expect(t, p.rows == 24, "rows must be 24")
	testing.expect(t, p.cols == 80, "cols must be 80")
}

@(test)
test_spawn_with_argv :: proc(t: ^testing.T) {
	p: pty.Pty
	ok := pty.pty_spawn(&p, 24, 80, "/bin/echo", {"hello"})
	testing.expect(t, ok, "pty_spawn /bin/echo with argv must succeed")
	if !ok {
		return
	}
	defer _teardown(&p)
	testing.expect(t, p.master >= 0, "master fd must be valid")
	testing.expect(t, p.pid > 0, "child pid must be positive")
	testing.expect(t, p.state == .Running, "state must be Running")
}

@(test)
test_spawn_applies_winsize :: proc(t: ^testing.T) {
	p: pty.Pty
	ok := pty.pty_spawn(&p, 40, 100, "/bin/sh", {})
	testing.expect(t, ok, "pty_spawn must succeed")
	if !ok {
		return
	}
	defer _teardown(&p)
	rows, cols, wok := _get_winsize(p.master)
	testing.expect(t, wok, "winsize read-back must succeed")
	testing.expect(t, rows == 40, "child must observe rows=40")
	testing.expect(t, cols == 100, "child must observe cols=100")
}

@(test)
test_spawn_missing_prog :: proc(t: ^testing.T) {
	p := pty.Pty{master = -1, pid = -1, state = .Exited, exit_code = 1234, rows = -7, cols = -7}
	ok := pty.pty_spawn(&p, 24, 80, "/nonexistent-prog-xyz", {})
	testing.expect(t, !ok, "missing prog must fail")
	testing.expect(t, p.master == -1, "master untouched on failure")
	testing.expect(t, p.pid == -1, "pid untouched on failure")
	testing.expect(t, p.state == .Exited, "state untouched on failure")
	testing.expect(t, p.exit_code == 1234, "exit_code untouched on failure")
	testing.expect(t, p.rows == -7, "rows untouched on failure")
	testing.expect(t, p.cols == -7, "cols untouched on failure")
}

@(test)
test_spawn_failure_no_leak :: proc(t: ^testing.T) {
	// Repeated failures must not accumulate fds or zombies: a good spawn
	// afterwards must still succeed.
	for _ in 0..<32 {
		p := pty.Pty{master = -1, pid = -1}
		ok := pty.pty_spawn(&p, 24, 80, "/nonexistent-prog-xyz", {})
		testing.expect(t, !ok, "missing prog must fail")
		testing.expect(t, p.master == -1, "no fd leaked on failure")
	}
	p: pty.Pty
	ok := pty.pty_spawn(&p, 24, 80, "/bin/sh", {})
	testing.expect(t, ok, "spawn after failures must succeed")
	if !ok {
		return
	}
	defer _teardown(&p)
	testing.expect(t, p.master >= 0, "master fd must be valid")
	testing.expect(t, p.pid > 0, "child pid must be positive")
}

@(test)
test_spawn_clamps_dims :: proc(t: ^testing.T) {
	p: pty.Pty
	ok := pty.pty_spawn(&p, 0, -5, "/bin/sh", {})
	testing.expect(t, ok, "zero/negative dims must clamp, not fail")
	if !ok {
		return
	}
	defer _teardown(&p)
	testing.expect(t, p.rows == 24, "rows clamp to 24")
	testing.expect(t, p.cols == 80, "cols clamp to 80")
}

@(test)
test_spawn_rejects_bad_input :: proc(t: ^testing.T) {
	p: pty.Pty
	testing.expect(t, !pty.pty_spawn(nil, 24, 80, "/bin/sh", {}), "nil Pty must fail")
	testing.expect(t, !pty.pty_spawn(&p, 24, 80, "", {}), "empty prog must fail")
	testing.expect(t, p.master == 0, "failed spawn leaves Pty untouched")
	testing.expect(t, p.pid == 0, "failed spawn leaves Pty untouched")
}
