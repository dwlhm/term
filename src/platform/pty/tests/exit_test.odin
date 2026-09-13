package pty_test

import "core:c"
import "core:testing"
import "core:time"
import posix "core:sys/posix"
import pty "../"

// Exit/wait + close tests (Langkah 5).
//
// No-zombie assertion strategy: pty_poll_exit owns waitpid and reaps
// exactly once. After it returns true, a second raw
// waitpid(pid, &status, {.NOHANG}) must return -1 with errno ECHILD
// (no waitable child left = no zombie). This is robust: it does not
// depend on /bin/ps output parsing or timing.

// _exit_poll_until polls until the child is reaped or the budget runs
// out. Returns whether poll reported exit.
_exit_poll_until :: proc(p: ^pty.Pty) -> bool {
	for _ in 0..<DRAIN_POLL_ITERS {
		if pty.pty_poll_exit(p) {
			return true
		}
		time.sleep(10 * time.Millisecond)
	}
	return false
}

// _exit_assert_reaped asserts the no-zombie postcondition: the child was
// already reaped by pty_poll_exit, so a further waitpid reports ECHILD.
_exit_assert_reaped :: proc(t: ^testing.T, pid: int) {
	status: c.int
	r := posix.waitpid(posix.pid_t(pid), &status, posix.Wait_Flags{.NOHANG})
	testing.expect(t, int(r) == -1, "reaped child must leave no waitable child (no zombie)")
	testing.expect(t, posix.errno() == .ECHILD, "second waitpid must report ECHILD")
}

// _exit_kill sends SIGTERM to a live child; failures are ignored because
// the child may already have exited on its own.
_exit_kill :: proc(p: ^pty.Pty) {
	if p.pid > 0 {
		posix.kill(posix.pid_t(p.pid), .SIGTERM)
	}
}

@(test)
test_poll_quick_exit_code_0 :: proc(t: ^testing.T) {
	p: pty.Pty
	ok := pty.pty_spawn(&p, 24, 80, "/usr/bin/true", {})
	testing.expect(t, ok, "pty_spawn /usr/bin/true must succeed")
	if !ok {
		return
	}
	defer pty.pty_close(&p)
	reaped := _exit_poll_until(&p)
	testing.expect(t, reaped, "poll must report quick exit")
	testing.expect(t, p.state == .Exited, "state must be Exited")
	testing.expect(t, p.exit_code == 0, "exit_code must be 0")
	// Idempotent second poll: true again, values stable, no syscall harm.
	testing.expect(t, pty.pty_poll_exit(&p), "second poll must stay true (idempotent)")
	testing.expect(t, p.state == .Exited, "state stable on re-poll")
	testing.expect(t, p.exit_code == 0, "exit_code stable on re-poll")
	_exit_assert_reaped(t, p.pid)
}

@(test)
test_poll_running_untouched_then_signaled :: proc(t: ^testing.T) {
	p: pty.Pty
	ok := pty.pty_spawn(&p, 24, 80, "/bin/cat", {})
	testing.expect(t, ok, "pty_spawn /bin/cat must succeed")
	if !ok {
		return
	}
	defer pty.pty_close(&p)
	// Running child: nonblocking poll reports false, p untouched.
	testing.expect(t, !pty.pty_poll_exit(&p), "running child must poll false")
	testing.expect(t, p.state == .Running, "state untouched while running")
	testing.expect(t, p.exit_code == 0, "exit_code untouched while running")
	_exit_kill(&p)
	reaped := _exit_poll_until(&p)
	testing.expect(t, reaped, "poll must report signaled exit after SIGTERM")
	testing.expect(t, p.state == .Exited, "state must be Exited after signal")
	want := pty.PTY_SIGNAL_EXIT_BASE + int(posix.Signal.SIGTERM)
	testing.expect(t, p.exit_code == want, "signaled exit_code must follow 128+signo convention")
	_exit_assert_reaped(t, p.pid)
}

@(test)
test_close_twice_safe :: proc(t: ^testing.T) {
	p: pty.Pty
	ok := pty.pty_spawn(&p, 24, 80, "/bin/cat", {})
	testing.expect(t, ok, "pty_spawn /bin/cat must succeed")
	if !ok {
		return
	}
	pid := p.pid
	pty.pty_close(&p)
	testing.expect(t, p.master == -1, "first close must park master at -1")
	testing.expect(t, p.pid == pid, "close must leave pid for the poller")
	testing.expect(t, p.state == .Running, "close must leave state for the poller")
	// Second close is a safe no-op: no EBADF crash, sentinel stable.
	pty.pty_close(&p)
	testing.expect(t, p.master == -1, "second close must stay a no-op at -1")
	testing.expect(t, p.pid == pid, "second close must still leave pid")
	// Close-then-poll with a running child: kill, then reap through poll.
	_exit_kill(&p)
	reaped := _exit_poll_until(&p)
	testing.expect(t, reaped, "close-then-poll must still reap the child")
	testing.expect(t, p.state == .Exited, "state must be Exited after close-then-poll")
	_exit_assert_reaped(t, p.pid)
	// Close after poll stays safe too.
	pty.pty_close(&p)
	testing.expect(t, p.master == -1, "close after poll must stay safe")
}

@(test)
test_poll_then_close :: proc(t: ^testing.T) {
	p: pty.Pty
	ok := pty.pty_spawn(&p, 24, 80, "/usr/bin/true", {})
	testing.expect(t, ok, "pty_spawn /usr/bin/true must succeed")
	if !ok {
		return
	}
	reaped := _exit_poll_until(&p)
	testing.expect(t, reaped, "poll must report quick exit")
	testing.expect(t, p.exit_code == 0, "exit_code must be 0")
	pid := p.pid
	pty.pty_close(&p)
	testing.expect(t, p.master == -1, "close after poll must park master at -1")
	testing.expect(t, p.state == .Exited, "close must leave Exited state intact")
	testing.expect(t, p.exit_code == 0, "close must leave exit_code intact")
	pty.pty_close(&p)
	testing.expect(t, p.master == -1, "double close after poll must stay safe")
	testing.expect(t, p.state == .Exited, "state stable after poll-then-close")
	_exit_assert_reaped(t, pid)
}

@(test)
test_close_then_poll :: proc(t: ^testing.T) {
	p: pty.Pty
	ok := pty.pty_spawn(&p, 24, 80, "/usr/bin/true", {})
	testing.expect(t, ok, "pty_spawn /usr/bin/true must succeed")
	if !ok {
		return
	}
	pid := p.pid
	time.sleep(10 * time.Millisecond)
	pty.pty_close(&p)
	testing.expect(t, p.master == -1, "close must park master at -1")
	testing.expect(t, p.pid == pid, "close must preserve pid for poll")
	reaped := _exit_poll_until(&p)
	testing.expect(t, reaped, "poll after close must still reap the child")
	testing.expect(t, p.state == .Exited, "state must be Exited after close-then-poll")
	testing.expect(t, p.exit_code == 0, "exit_code must be 0")
	_exit_assert_reaped(t, pid)
}

@(test)
test_exit_rejects_bad_pty :: proc(t: ^testing.T) {
	testing.expect(t, !pty.pty_poll_exit(nil), "nil Pty poll must be false")
	pty.pty_close(nil)
	bad := pty.Pty{master = -1, pid = -1, state = .Running}
	testing.expect(t, !pty.pty_poll_exit(&bad), "invalid pid poll must be false")
	testing.expect(t, bad.state == .Running, "state untouched on invalid pid")
	pty.pty_close(&bad)
	testing.expect(t, bad.master == -1, "close on closed fd stays a no-op")
	already := pty.Pty{master = -1, pid = 12345678, state = .Exited, exit_code = 3}
	testing.expect(t, pty.pty_poll_exit(&already), "already-Exited poll must stay true without a syscall")
	testing.expect(t, already.exit_code == 3, "exit_code stable on idempotent poll")
}
