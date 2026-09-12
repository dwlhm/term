package pty

import "core:c"
import "core:strings"
import posix "core:sys/posix"
import sys_darwin "core:sys/darwin"

// PTY spawn (Langkah 1): posix_openpt + fork + setsid + slave setup.
// Later steps add drain/write/winsize/exit here as separate procs —
// they are intentionally absent, not stubbed.

// PTY_DEFAULT_ROWS is the row count used when the caller passes rows <= 0.
PTY_DEFAULT_ROWS :: 24

// PTY_DEFAULT_COLS is the column count used when the caller passes cols <= 0.
PTY_DEFAULT_COLS :: 80

// TIOCSWINSZ sets the window size of a terminal device.
// BSD/macOS value, verified against the system headers on this machine.
TIOCSWINSZ :: 0x80087467

// PTY_CHILD_FAIL_EXIT is the exit status the child uses when slave setup
// or exec fails after fork. The parent learns of the failure through the
// error pipe, not through this status.
PTY_CHILD_FAIL_EXIT :: 127

// Pty_State tracks child liveness. Exit collection arrives in a later step.
Pty_State :: enum u8 {
	Running,
	Exited,
}

// Pty owns one pty master fd plus the child process attached to its slave.
Pty :: struct {
	master:    int,
	pid:       int,
	state:     Pty_State,
	exit_code: int,
	rows:      int,
	cols:      int,
}

// Winsize mirrors BSD struct winsize for the TIOCSWINSZ ioctl.
Winsize :: struct {
	ws_row:    c.ushort,
	ws_col:    c.ushort,
	ws_xpixel: c.ushort,
	ws_ypixel: c.ushort,
}

// NOTE: winsize is set via the raw ioctl syscall (core:sys/darwin), not
// the libc ioctl wrapper: on Darwin the wrapper mishandles the TIOCSWINSZ
// pointer argument (EFAULT) while raw SYS_ioctl succeeds.

// pty_spawn forks a child attached to a new pseudo-terminal.
//
// The child gets a new session with the pty slave as its controlling
// terminal and stdio (stdin/stdout/stderr all wired to the slave), then
// execs prog with argv[0] = prog followed by argv. When prog contains a
// slash it is executed with a clean environment (TERM + PATH only); a bare
// name falls back to PATH lookup with the inherited environment.
//
// Non-positive rows/cols are clamped to PTY_DEFAULT_ROWS/COLS.
// On success the parent returns true with master >= 0, pid > 0 and state
// Running. On any failure all half-open fds are closed, the failed child
// (if any) is reaped, *p is left untouched, and the result is false.
pty_spawn :: proc(p: ^Pty, rows: int, cols: int, prog: string, argv: []string) -> bool {
	if p == nil {
		return false
	}
	if len(prog) == 0 {
		return false
	}

	r := rows
	if r <= 0 {
		r = PTY_DEFAULT_ROWS
	}
	ncols := cols
	if ncols <= 0 {
		ncols = PTY_DEFAULT_COLS
	}

	// Master-side setup happens fully before fork, so a fork failure only
	// has the master fd to clean up.
	master := posix.posix_openpt({.RDWR, .NOCTTY})
	if int(master) < 0 {
		return false
	}
	if posix.grantpt(master) != .OK {
		posix.close(master)
		return false
	}
	if posix.unlockpt(master) != .OK {
		posix.close(master)
		return false
	}
	slave_name := posix.ptsname(master)
	if slave_name == nil {
		posix.close(master)
		return false
	}

	// ptsname points at a static buffer: copy it so the child never depends
	// on shared libc state after fork.
	slave_buf: [128]u8
	name := string(slave_name)
	if len(name) <= 0 || len(name) >= len(slave_buf) {
		posix.close(master)
		return false
	}
	copy(slave_buf[:], name)
	slave_buf[len(name)] = 0
	slave_path := cstring(&slave_buf[0])

	// The master must never block the event loop.
	flags := posix.fcntl(master, .GETFL)
	if flags == -1 {
		posix.close(master)
		return false
	}
	if posix.fcntl(master, .SETFL, flags | c.int(posix.O_NONBLOCK)) == -1 {
		posix.close(master)
		return false
	}

	// Initial size is applied to the slave in the child after fork: on
	// Darwin TIOCSWINSZ is only valid on the slave side, and the size
	// set there is visible to the parent through the master.
	ws := Winsize{ws_row = c.ushort(r), ws_col = c.ushort(ncols)}

	// Error pipe: the write end is CLOEXEC, so the parent reads EOF exactly
	// when exec succeeds and one byte when the child fails before exec.
	errfd: [2]posix.FD
	if posix.pipe(&errfd) != .OK {
		posix.close(master)
		return false
	}
	if posix.fcntl(errfd[1], .SETFD, c.int(posix.FD_CLOEXEC)) == -1 {
		posix.close(errfd[0])
		posix.close(errfd[1])
		posix.close(master)
		return false
	}

	// exec argv: argv[0] is always prog, then the caller args, NUL-terminated.
	argc := len(argv) + 2
	c_argv := make([]cstring, argc)
	defer delete(c_argv)
	c_argv[0] = strings.clone_to_cstring(prog)
	defer delete(c_argv[0])
	for arg, i in argv {
		c_argv[i + 1] = strings.clone_to_cstring(arg)
	}
	// Hoisted out of the loop: a per-iteration `defer delete(c_argv[i+1])`
	// miscompiles the argv stores (child observed duplicated argv entries
	// with 2+ caller args), so the element frees live in one exit block.
	defer {
		for j in 1 ..< len(c_argv) - 1 {
			delete(c_argv[j])
		}
	}
	c_argv[argc - 1] = nil

	// Clean environment for absolute/relative prog paths.
	c_env: [6]cstring = {"TERM=xterm-256color", "COLORTERM=truecolor", "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "PROMPT_EOL_MARK=", "TERM_PROGRAM=WezTerm", nil}
	has_slash := strings.contains(prog, "/")

	pid := posix.fork()
	if pid == 0 {
		// --- child: never returns, never touches parent allocators ---
		posix.close(errfd[0])
		if posix.setsid() == posix.pid_t(-1) {
			_child_fail(errfd[1])
		}
		// Opened without NOCTTY after setsid, so the slave becomes the
		// controlling terminal.
		slave := posix.open(slave_path, {.RDWR})
		if int(slave) < 0 {
			_child_fail(errfd[1])
		}
		if sys_darwin.syscall_ioctl(c.int(slave), TIOCSWINSZ, rawptr(&ws)) != 0 {
			_child_fail(errfd[1])
		}
		posix.dup2(slave, posix.FD(0))
		posix.dup2(slave, posix.FD(1))
		posix.dup2(slave, posix.FD(2))
		if int(slave) > 2 {
			posix.close(slave)
		}
		posix.close(master)
		if has_slash {
			posix.execve(c_argv[0], raw_data(c_argv), raw_data(c_env[:]))
		} else {
			posix.execvp(c_argv[0], raw_data(c_argv))
		}
		_child_fail(errfd[1])
	}
	if int(pid) < 0 {
		posix.close(errfd[0])
		posix.close(errfd[1])
		posix.close(master)
		return false
	}

	// --- parent: exec outcome arrives over the error pipe ---
	posix.close(errfd[1])
	mark: [1]byte
	n := posix.read(errfd[0], raw_data(mark[:]), 1)
	posix.close(errfd[0])
	if n != 0 {
		status: c.int
		if n > 0 {
			// Child reported failure and already exited: reap it.
			posix.waitpid(pid, &status, posix.Wait_Flags{})
		} else {
			// Read error (not expected on a blocking pipe): reap only if
			// the child already exited, never hang a running child here.
			posix.waitpid(pid, &status, posix.Wait_Flags{.NOHANG})
		}
		posix.close(master)
		return false
	}

	p.master = int(master)
	p.pid = int(pid)
	p.state = .Running
	p.exit_code = 0
	p.rows = r
	p.cols = ncols
	return true
}

// pty_drain reads available child output from the pty master without
// blocking.
//
// At most min(len(out), max_bytes) bytes are copied into out; callers pass
// their per-frame cap (64KB) as max_bytes. Partial reads are fine: any
// unread bytes stay in the kernel buffer for the next call.
//
// Returns the bytes read with eof=false on data, (0, false) when no data is
// available (EAGAIN), and (n, true) on EOF (read returns 0) or EIO, which is
// how the master reports a dead child. EINTR retries internally. Exit
// collection is NOT done here (a later step owns waitpid).
pty_drain :: proc(p: ^Pty, out: []u8, max_bytes: int) -> (n: int, eof: bool) {
	if p == nil {
		return 0, false
	}
	if p.master < 0 {
		return 0, false
	}
	if len(out) == 0 || max_bytes <= 0 {
		return 0, false
	}
	want := len(out)
	if max_bytes < want {
		want = max_bytes
	}
	for {
		r := posix.read(posix.FD(p.master), raw_data(out), c.size_t(want))
		if r > 0 {
			return int(r), false
		}
		if r == 0 {
			return 0, true
		}
		#partial switch posix.errno() {
		case .EINTR:
			continue
		case .EAGAIN:
			return 0, false
		case .EIO:
			return 0, true
		case:
			return 0, false
		}
	}
}

// pty_wait_readable waits for input or terminal completion without draining
// or mutating the pty. Nil, exited, invalid, timeout, and poll errors return
// false. Readable, hangup, and error events return true. EINTR retries.
pty_wait_readable :: proc(p: ^Pty, timeout_ms: int) -> bool {
	if p == nil || p.state == .Exited || p.master < 0 || timeout_ms < 0 {
		return false
	}
	pfd := posix.pollfd{fd = posix.FD(p.master), events = {.IN}}
	for {
		r := posix.poll(&pfd, 1, c.int(timeout_ms))
		if r > 0 {
			return (pfd.revents & {.IN, .HUP, .ERR}) != {}
		}
		if r == 0 {
			return false
		}
		#partial switch posix.errno() {
		case .EINTR:
			pfd.revents = {}
			continue
		case:
			return false
		}
	}
}

// PTY_WRITE_POLL_MS is how long each EAGAIN wait polls for master
// writability. The poll returns early as soon as the master is writable,
// so this only costs time when the child is not reading.
PTY_WRITE_POLL_MS :: 1

// PTY_WRITE_EAGAIN_RETRIES bounds the total EAGAIN waits per pty_write
// call (worst ~5s). The budget must cover slow consumers: a canonical-mode
// child accepts ~1KB per write, so a 64KB payload needs dozens of
// write/poll cycles even when everything flows.
PTY_WRITE_EAGAIN_RETRIES :: 5000

// pty_write sends child stdin through the pty master without blocking.
//
// All of data is written, looping over short writes. EINTR retries
// internally with no backoff. EAGAIN (buffer full on the nonblocking
// master) polls briefly for writability and retries, up to
// PTY_WRITE_EAGAIN_RETRIES waits; when still blocked the result is false.
// Any other error fails immediately with false.
//
// Empty data is a no-op true. A nil pty, a negative master, or Exited
// state returns false without issuing a syscall. No byte counters are
// kept here: on incomplete writes the caller counts what was lost.
pty_write :: proc(p: ^Pty, data: []u8) -> bool {
	if p == nil {
		return false
	}
	if p.master < 0 {
		return false
	}
	if p.state == .Exited {
		return false
	}
	if len(data) == 0 {
		return true
	}
	written := 0
	waits := 0
	for written < len(data) {
		r := posix.write(posix.FD(p.master), raw_data(data[written:]), c.size_t(len(data[written:])))
		if r > 0 {
			written += int(r)
			continue
		}
		#partial switch posix.errno() {
		case .EINTR:
			continue
		case .EAGAIN:
			if waits >= PTY_WRITE_EAGAIN_RETRIES {
				return false
			}
			waits += 1
			pfd := posix.pollfd{fd = posix.FD(p.master), events = {.OUT}}
			posix.poll(&pfd, 1, PTY_WRITE_POLL_MS)
		case:
			return false
		}
	}
	return true
}

// pty_set_winsize resizes the live pty via TIOCSWINSZ on the master fd.
//
// Non-positive rows/cols are clamped to PTY_DEFAULT_ROWS/COLS, mirroring
// pty_spawn. On success p.rows/p.cols are updated and the result is true.
// A nil pty, a negative master, or Exited state returns false without
// issuing a syscall; an ioctl error returns false with p.rows/p.cols
// unchanged.
pty_set_winsize :: proc(p: ^Pty, rows: int, cols: int) -> bool {
	if p == nil {
		return false
	}
	if p.master < 0 {
		return false
	}
	if p.state == .Exited {
		return false
	}
	r := rows
	if r <= 0 {
		r = PTY_DEFAULT_ROWS
	}
	ncols := cols
	if ncols <= 0 {
		ncols = PTY_DEFAULT_COLS
	}
	ws := Winsize{ws_row = c.ushort(r), ws_col = c.ushort(ncols)}
	if sys_darwin.syscall_ioctl(c.int(p.master), TIOCSWINSZ, rawptr(&ws)) != 0 {
		return false
	}
	p.rows = r
	p.cols = ncols
	return true
}

// PTY_SIGNAL_EXIT_BASE is added to a terminating signal number to form
// exit_code for signaled children (shell convention: 128+signo, e.g.
// SIGTERM (15) -> 143). Documents the signaled-exit convention.
PTY_SIGNAL_EXIT_BASE :: 128

// pty_poll_exit reaps a finished child without blocking.
//
// waitpid(WNOHANG) on p.pid: 0 means still running (p untouched, false).
// A reaped child sets p.state=.Exited with exit_code=WEXITSTATUS on normal
// exit or PTY_SIGNAL_EXIT_BASE+signo when signaled, and returns true.
// An already-Exited pty returns true immediately (idempotent, values
// stable) without a syscall. A nil pty or pid <= 0 returns false.
//
// Ordering contract with pty_close (both orders valid, no zombie either
// way): poll never touches the master fd, close never reaps the child.
// close->poll works because close leaves pid/state for the poller;
// poll->close works because poll leaves master for the closer. Either
// order leaves no zombie (waitpid reaps exactly once) and no fd leak.
// Never blocks: only WNOHANG is used; EINTR retries internally.
pty_poll_exit :: proc(p: ^Pty) -> bool {
	if p == nil {
		return false
	}
	if p.state == .Exited {
		return true
	}
	if p.pid <= 0 {
		return false
	}
	for {
		status: c.int
		r := posix.waitpid(posix.pid_t(p.pid), &status, posix.Wait_Flags{.NOHANG})
		if int(r) == 0 {
			return false
		}
		if int(r) < 0 {
			#partial switch posix.errno() {
			case .EINTR:
				continue
			case:
				return false
			}
		}
		if posix.WIFEXITED(status) {
			p.exit_code = int(posix.WEXITSTATUS(status))
			p.state = .Exited
			return true
		}
		if posix.WIFSIGNALED(status) {
			signo := int(posix.WTERMSIG(status))
			p.exit_code = PTY_SIGNAL_EXIT_BASE + signo
			p.state = .Exited
			return true
		}
		return false
	}
}

// pty_close closes the pty master fd exactly once.
//
// A nil pty or an already-closed master (master < 0) is a safe no-op, so
// double-close is safe. pid/state/exit_code are deliberately left for the
// poller: close never reaps, poll never closes, and close->poll as well as
// poll->close both end with no zombie and no fd leak.
pty_close :: proc(p: ^Pty) {
	if p == nil {
		return
	}
	if p.master < 0 {
		return
	}
	posix.close(posix.FD(p.master))
	p.master = -1
}

// _child_fail reports pre-exec failure to the parent over the error pipe
// and exits. It must not run any parent cleanup or return.
_child_fail :: proc(w: posix.FD) -> ! {
	mark: [1]u8 = {1}
	posix.write(w, raw_data(mark[:]), 1)
	posix._exit(PTY_CHILD_FAIL_EXIT)
}
