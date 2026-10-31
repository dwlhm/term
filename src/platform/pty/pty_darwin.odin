#+build darwin
package platform_pty

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import posix "core:sys/posix"

foreign import libc "system:System.framework"
@(default_calling_convention="c")
foreign libc {
	ioctl     :: proc(fd: c.int, request: c.ulong, #c_vararg args: ..rawptr) -> c.int ---
	openpty   :: proc(amaster, aslave: ^c.int, name: [^]u8, termp: rawptr, winp: ^Winsize) -> c.int ---
	login_tty :: proc(fd: c.int) -> c.int ---
}

TIOCSWINSZ :: 0x80087467

Winsize :: struct {
	ws_row:    c.ushort,
	ws_col:    c.ushort,
	ws_xpixel: c.ushort,
	ws_ypixel: c.ushort,
}

_spawn_mutex: sync.Mutex

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

_pty_spawn_platform :: proc(config: Pty_Config) -> (handle: ^Pty_Handle, err: Pty_Error) {
	rows := max(1, config.rows)
	cols := max(1, config.cols)

	prog := config.shell
	if len(prog) == 0 {
		prog = os.get_env("SHELL", context.temp_allocator)
		if len(prog) == 0 {
			prog = "/bin/sh"
		}
	}

	xp := config.xpixel if config.xpixel > 0 else cols * 10
	yp := config.ypixel if config.ypixel > 0 else rows * 20

	ws := Winsize{
		ws_row    = c.ushort(rows),
		ws_col    = c.ushort(cols),
		ws_xpixel = c.ushort(xp),
		ws_ypixel = c.ushort(yp),
	}

	master, slave: c.int
	sync.mutex_lock(&_spawn_mutex)
	res := openpty(&master, &slave, nil, nil, &ws)
	sync.mutex_unlock(&_spawn_mutex)
	if res != 0 {
		return nil, .Master_Open_Failed
	}

	pipe_fds: [2]posix.FD
	if posix.pipe(&pipe_fds) != .OK {
		posix.close(posix.FD(master))
		posix.close(posix.FD(slave))
		return nil, .Pipe_Failed
	}

	// Ensure master and shutdown pipes do not leak across execve and never block the main UI thread
	_fd_set_cloexec(posix.FD(master))
	_fd_set_cloexec(pipe_fds[0])
	_fd_set_cloexec(pipe_fds[1])
	_fd_set_nonblocking(posix.FD(master))
	_fd_set_nonblocking(pipe_fds[0])
	_fd_set_nonblocking(pipe_fds[1])

	pid := posix.fork()
	if pid < 0 {
		posix.close(pipe_fds[0])
		posix.close(pipe_fds[1])
		posix.close(posix.FD(master))
		posix.close(posix.FD(slave))
		return nil, .Fork_Failed
	}

	if pid == 0 {
		// --- CHILD PROCESS ---
		empty: posix.sigset_t
		posix.sigemptyset(&empty)
		posix.sigprocmask(.SETMASK, &empty, nil)

		posix.close(posix.FD(master))
		posix.close(pipe_fds[0])
		posix.close(pipe_fds[1])
		_ = login_tty(slave)

		// Close any file descriptors >= 3 so no master FDs or pipes leak across panes
		for fd in 3..<1024 {
			posix.close(posix.FD(fd))
		}

		if len(config.cwd) > 0 {
			c_cwd := strings.clone_to_cstring(config.cwd)
			_ = posix.chdir(c_cwd)
			delete(c_cwd)
		}

		// Prepare argv
		c_argv: [dynamic]cstring
		append(&c_argv, strings.clone_to_cstring(prog))
		if len(config.argv) == 0 {
			append(&c_argv, strings.clone_to_cstring("-l"))
		} else {
			for arg in config.argv {
				append(&c_argv, strings.clone_to_cstring(arg))
			}
		}
		append(&c_argv, nil)

		// Prepare env: inherit user environment but scrub foreign terminal identities
		c_env: [dynamic]cstring
		if posix.environ != nil {
			for i := 0; posix.environ[i] != nil; i += 1 {
				entry := string(posix.environ[i])
				if !_is_foreign_term_env(entry) {
					append(&c_env, posix.environ[i])
				}
			}
		}
		append(&c_env, strings.clone_to_cstring("TERM=xterm-256color"))
		append(&c_env, strings.clone_to_cstring("COLORTERM=truecolor"))
		append(&c_env, strings.clone_to_cstring("TERM_PROGRAM=term"))
		append(&c_env, strings.clone_to_cstring("TERM_PROGRAM_VERSION=0.1.0"))
		append(&c_env, strings.clone_to_cstring("KITTY_WINDOW_ID=1"))
		append(&c_env, nil)

		_ = posix.execve(c_argv[0], &c_argv[0], &c_env[0])
		posix.exit(127)
	}

	// --- PARENT PROCESS ---
	posix.close(posix.FD(slave))

	h := new(Pty_Handle)
	h.master_fd = i32(master)
	h.child_pid = i32(pid)
	h.shutdown_pipe = [2]i32{i32(pipe_fds[0]), i32(pipe_fds[1])}
	h.rows = rows
	h.cols = cols
	h.is_running = true
	h.exit_code = 0
	ring_init(&h.ring)

	// Spawn background drain thread with 64KB read buffer
	h.drain_thread = thread.create_and_start_with_data(rawptr(h), proc(data: rawptr) {
		handle := (^Pty_Handle)(data)
		buf: [65536]u8

		pfds := [2]posix.pollfd{
			{fd = posix.FD(handle.master_fd), events = {.IN}},
			{fd = posix.FD(handle.shutdown_pipe[0]), events = {.IN}},
		}

		for handle.is_running {
			ret := posix.poll(&pfds[0], 2, -1)
			if ret < 0 {
				if posix.errno() == .EINTR do continue
				break
			}
			if !handle.is_running do break
			if .IN in pfds[1].revents || .HUP in pfds[1].revents || .ERR in pfds[1].revents {
				break
			}
			if .IN in pfds[0].revents {
				fd := handle.master_fd
				if fd < 0 do break
				n := posix.read(posix.FD(fd), &buf[0], len(buf))
				if n > 0 {
					ring_write(&handle.ring, buf[:n])
				} else if n == 0 {
					// EOF
					break
				} else {
					err_no := posix.errno()
					if err_no == .EINTR || err_no == .EAGAIN do continue
					// EIO, EBADF, or hangup
					break
				}
			} else if .HUP in pfds[0].revents || .ERR in pfds[0].revents || .NVAL in pfds[0].revents {
				break
			}
		}

		// Non-blocking exit code harvest
		status: c.int = 0
		_ = posix.waitpid(posix.pid_t(handle.child_pid), &status, {.NOHANG})
		handle.exit_code = int(status >> 8)
		handle.is_running = false
		pty_notify_wakeup()
	})

	return h, .None
}

_pty_close_platform :: proc(h: ^Pty_Handle) {
	if h == nil do return
	h.is_running = false

	// 1. Signal shutdown pipe to immediately wake drain_thread if blocked in poll
	if h.shutdown_pipe[1] >= 0 {
		sig: u8 = 1
		_ = posix.write(posix.FD(h.shutdown_pipe[1]), &sig, 1)
	}

	// 2. Detach and close master_fd BEFORE thread.join so any grandchild holding
	// the slave FD cannot stall drain_thread in poll/read, and kernel sends SIGHUP to session.
	master_fd := h.master_fd
	h.master_fd = -1
	if master_fd >= 0 {
		fg_pg := tcgetpgrp(c.int(master_fd))
		if fg_pg > 0 && fg_pg != c.int(h.child_pid) {
			_ = posix.kill(posix.pid_t(-fg_pg), .SIGCONT)
			_ = posix.kill(posix.pid_t(-fg_pg), .SIGHUP)
			_ = posix.kill(posix.pid_t(-fg_pg), .SIGKILL)
		}
		posix.close(posix.FD(master_fd))
	}

	// 3. Terminate the child shell and its process group (wake stopped jobs with SIGCONT first)
	if h.child_pid > 0 {
		_ = posix.kill(posix.pid_t(-h.child_pid), .SIGCONT)
		_ = posix.kill(posix.pid_t(-h.child_pid), .SIGHUP)
		_ = posix.kill(posix.pid_t(-h.child_pid), .SIGKILL)
		_ = posix.kill(posix.pid_t(h.child_pid), .SIGCONT)
		_ = posix.kill(posix.pid_t(h.child_pid), .SIGHUP)
		_ = posix.kill(posix.pid_t(h.child_pid), .SIGKILL)
		status: c.int = 0
		_ = posix.waitpid(posix.pid_t(h.child_pid), &status, {.NOHANG})
	}

	// 4. Drain thread will exit promptly because shutdown_pipe was triggered and master_fd is closed
	if h.drain_thread != nil {
		thread.join(h.drain_thread)
		thread.destroy(h.drain_thread)
		h.drain_thread = nil
	}

	if h.shutdown_pipe[0] >= 0 {
		posix.close(posix.FD(h.shutdown_pipe[0]))
		h.shutdown_pipe[0] = -1
	}
	if h.shutdown_pipe[1] >= 0 {
		posix.close(posix.FD(h.shutdown_pipe[1]))
		h.shutdown_pipe[1] = -1
	}

	ring_destroy(&h.ring)
	free(h)
}

_pty_resize_platform :: proc(h: ^Pty_Handle, cols, rows: u16, xpixel: u16 = 0, ypixel: u16 = 0) -> bool {
	if h == nil || h.master_fd < 0 do return false
	h.cols = int(cols)
	h.rows = int(rows)

	xp := xpixel if xpixel > 0 else cols * 10
	yp := ypixel if ypixel > 0 else rows * 20

	ws := Winsize{
		ws_row    = c.ushort(rows),
		ws_col    = c.ushort(cols),
		ws_xpixel = c.ushort(xp),
		ws_ypixel = c.ushort(yp),
	}
	res := ioctl(c.int(h.master_fd), TIOCSWINSZ, &ws)
	return res == 0
}

_pty_write_platform :: proc(h: ^Pty_Handle, data: []u8) -> (int, Pty_Error) {
	if h == nil || h.master_fd < 0 do return 0, .Closed
	if len(data) == 0 do return 0, .None

	fd := posix.FD(h.master_fd)
	total := 0
	for total < len(data) {
		rem := len(data) - total
		n := posix.write(fd, &data[total], uint(rem))
		if n > 0 {
			total += int(n)
			continue
		}
		if n < 0 {
			err_no := posix.errno()
			if err_no == .EINTR do continue
			if err_no == .EAGAIN {
				pfd := posix.pollfd{fd = fd, events = {.OUT}}
				if posix.poll(&pfd, 1, 2) <= 0 do break
				continue
			}
		}
		if total > 0 do return total, .None
		return 0, .Write_Failed
	}
	return total, .None
}
