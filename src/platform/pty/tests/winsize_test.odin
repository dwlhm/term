package pty_test

import "core:testing"
import posix "core:sys/posix"
import pty "../"

// Winsize live-resize tests (Langkah 4): TIOCSWINSZ on the master of a
// live PTY. Reuses _teardown/_get_winsize (spawn_test.odin) and
// _drain_until/DRAIN_FRAME_CAP (drain_test.odin).

@(test)
test_winsize_live_resize :: proc(t: ^testing.T) {
	p: pty.Pty
	ok := pty.pty_spawn(&p, 24, 80, "/bin/sh", {})
	testing.expect(t, ok, "pty_spawn /bin/sh must succeed")
	if !ok {
		return
	}
	defer _teardown(&p)
	resized := pty.pty_set_winsize(&p, 40, 100)
	testing.expect(t, resized, "master-side TIOCSWINSZ on a live PTY must succeed")
	if !resized {
		return
	}
	testing.expect(t, p.rows == 40, "rows must update to 40")
	testing.expect(t, p.cols == 100, "cols must update to 100")
	rows, cols, wok := _get_winsize(p.master)
	testing.expect(t, wok, "winsize read-back must succeed")
	testing.expect(t, rows == 40, "master must report rows=40")
	testing.expect(t, cols == 100, "master must report cols=100")
	wrote := pty.pty_write(&p, transmute([]u8)string("stty size\n"))
	testing.expect(t, wrote, "pty_write stty size must succeed")
	got, found, _ := _drain_until(&p, "40 100", DRAIN_FRAME_CAP)
	defer delete(got)
	testing.expect(t, found, "child stty size must report 40 100 after resize")
}

@(test)
test_winsize_clamps_dims :: proc(t: ^testing.T) {
	p: pty.Pty
	ok := pty.pty_spawn(&p, 24, 80, "/bin/sh", {})
	testing.expect(t, ok, "pty_spawn /bin/sh must succeed")
	if !ok {
		return
	}
	defer _teardown(&p)
	testing.expect(t, pty.pty_set_winsize(&p, 0, -5), "zero/negative dims must clamp, not fail")
	testing.expect(t, p.rows == 24, "rows clamp to 24")
	testing.expect(t, p.cols == 80, "cols clamp to 80")
	rows, cols, wok := _get_winsize(p.master)
	testing.expect(t, wok, "winsize read-back must succeed")
	testing.expect(t, rows == 24, "master must report rows=24")
	testing.expect(t, cols == 80, "master must report cols=80")
}

@(test)
test_winsize_rejects_bad_pty :: proc(t: ^testing.T) {
	testing.expect(t, !pty.pty_set_winsize(nil, 40, 100), "nil Pty must fail")
	bad := pty.Pty{master = -1, pid = -1, state = .Running, rows = 24, cols = 80}
	testing.expect(t, !pty.pty_set_winsize(&bad, 40, 100), "negative master must fail without a syscall")
	testing.expect(t, bad.rows == 24, "rows untouched on bad fd")
	testing.expect(t, bad.cols == 80, "cols untouched on bad fd")
	exited: pty.Pty
	ok := pty.pty_spawn(&exited, 24, 80, "/bin/sh", {})
	testing.expect(t, ok, "pty_spawn /bin/sh must succeed")
	if !ok {
		return
	}
	defer _teardown(&exited)
	exited.state = .Exited
	testing.expect(t, !pty.pty_set_winsize(&exited, 40, 100), "Exited state must fail without a syscall")
	testing.expect(t, exited.rows == 24, "rows untouched on Exited")
	testing.expect(t, exited.cols == 80, "cols untouched on Exited")
}

@(test)
test_winsize_ioctl_error_untouched :: proc(t: ^testing.T) {
	// A valid fd that is not a terminal: the ioctl must fail and leave
	// p.rows/p.cols unchanged.
	fd := posix.open("/dev/null", {.RDWR})
	testing.expect(t, int(fd) >= 0, "open /dev/null must succeed")
	if int(fd) < 0 {
		return
	}
	defer posix.close(fd)
	notty := pty.Pty{master = int(fd), pid = -1, state = .Running, rows = 24, cols = 80}
	testing.expect(t, !pty.pty_set_winsize(&notty, 40, 100), "ioctl on a non-terminal must fail")
	testing.expect(t, notty.rows == 24, "rows unchanged on ioctl error")
	testing.expect(t, notty.cols == 80, "cols unchanged on ioctl error")
}
