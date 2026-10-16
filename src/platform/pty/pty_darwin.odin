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

	ws := Winsize{
		ws_row = c.ushort(rows),
		ws_col = c.ushort(cols),
	}

	master, slave: c.int
	sync.mutex_lock(&_spawn_mutex)
	res := openpty(&master, &slave, nil, nil, &ws)
	sync.mutex_unlock(&_spawn_mutex)
	if res != 0 {
		return nil, .Master_Open_Failed
	}

	// Set non-blocking on master
	fl := posix.fcntl(posix.FD(master), .GETFL)
	_ = posix.fcntl(posix.FD(master), .SETFL, fl | c.int(posix.O_NONBLOCK))

	pid := posix.fork()
	if pid < 0 {
		posix.close(posix.FD(master))
		posix.close(posix.FD(slave))
		return nil, .Fork_Failed
	}

	if pid == 0 {
		// --- CHILD PROCESS ---
		posix.close(posix.FD(master))
		_ = login_tty(slave)

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

		// Prepare env: inherit full user environment (HOME, USER, PATH, etc.)
		c_env: [dynamic]cstring
		if posix.environ != nil {
			for i := 0; posix.environ[i] != nil; i += 1 {
				entry := string(posix.environ[i])
				if !strings.has_prefix(entry, "TERM=") && !strings.has_prefix(entry, "COLORTERM=") {
					append(&c_env, posix.environ[i])
				}
			}
		}
		append(&c_env, strings.clone_to_cstring("TERM=xterm-256color"))
		append(&c_env, strings.clone_to_cstring("COLORTERM=truecolor"))
		append(&c_env, nil)

		_ = posix.execve(c_argv[0], &c_argv[0], &c_env[0])
		posix.exit(127)
	}

	// --- PARENT PROCESS ---
	posix.close(posix.FD(slave))

	h := new(Pty_Handle)
	h.master_fd = i32(master)
	h.child_pid = i32(pid)
	h.rows = rows
	h.cols = cols
	h.is_running = true
	h.exit_code = 0
	ring_init(&h.ring)

	// Spawn background drain thread
	h.drain_thread = thread.create_and_start_with_data(rawptr(h), proc(data: rawptr) {
		handle := (^Pty_Handle)(data)
		buf: [4096]u8

		for handle.is_running {
			n := posix.read(posix.FD(handle.master_fd), &buf[0], len(buf))
			if n > 0 {
				ring_write(&handle.ring, buf[:n])
			} else if n == 0 {
				// EOF
				break
			} else {
				err_no := posix.errno()
				if err_no == .EAGAIN || err_no == .EINTR {
					posix.nanosleep(&posix.timespec{tv_nsec = 1_000_000}, nil) // 1ms sleep
					continue
				}
				// EIO or other terminal hangup
				break
			}
		}

		// Collect exit code
		status: c.int = 0
		_ = posix.waitpid(posix.pid_t(handle.child_pid), &status, {})
		handle.exit_code = int(status >> 8)
		handle.is_running = false
	})

	return h, .None
}

_pty_close_platform :: proc(h: ^Pty_Handle) {
	if h == nil do return
	h.is_running = false

	if h.master_fd >= 0 {
		posix.close(posix.FD(h.master_fd))
		h.master_fd = -1
	}

	if h.child_pid > 0 {
		_ = posix.kill(posix.pid_t(h.child_pid), .SIGHUP)
		status: c.int = 0
		_ = posix.waitpid(posix.pid_t(h.child_pid), &status, {.NOHANG})
	}

	if h.drain_thread != nil {
		thread.join(h.drain_thread)
		thread.destroy(h.drain_thread)
		h.drain_thread = nil
	}

	free(h)
}

_pty_resize_platform :: proc(h: ^Pty_Handle, cols, rows: u16) -> bool {
	if h == nil || h.master_fd < 0 do return false
	h.cols = int(cols)
	h.rows = int(rows)

	ws := Winsize{
		ws_row = c.ushort(rows),
		ws_col = c.ushort(cols),
	}
	res := ioctl(c.int(h.master_fd), TIOCSWINSZ, &ws)
	return res == 0
}

_pty_write_platform :: proc(h: ^Pty_Handle, data: []u8) -> (int, Pty_Error) {
	if h == nil || h.master_fd < 0 do return 0, .Closed
	if len(data) == 0 do return 0, .None

	n := posix.write(posix.FD(h.master_fd), &data[0], len(data))
	if n < 0 do return 0, .Write_Failed
	return n, .None
}
