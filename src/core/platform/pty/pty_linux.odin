#+build linux
package platform_pty

import "core:c"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import posix "core:sys/posix"

foreign import libc "system:c"
@(default_calling_convention="c")
foreign libc {
	ioctl :: proc(fd: c.int, request: c.ulong, #c_vararg args: ..any) -> c.int ---
}

TIOCSWINSZ :: 0x5414

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

	sync.mutex_lock(&_spawn_mutex)
	master := posix.posix_openpt({.RDWR, .NOCTTY, .NONBLOCK})
	if int(master) < 0 {
		sync.mutex_unlock(&_spawn_mutex)
		return nil, .Master_Open_Failed
	}

	_ = posix.grantpt(master)
	if posix.unlockpt(master) != .OK {
		sync.mutex_unlock(&_spawn_mutex)
		posix.close(master)
		return nil, .Master_Open_Failed
	}

	slave_name := posix.ptsname(master)
	if slave_name == nil {
		sync.mutex_unlock(&_spawn_mutex)
		posix.close(master)
		return nil, .Slave_Open_Failed
	}

	slave_buf: [128]u8
	name := string(slave_name)
	if len(name) == 0 || len(name) >= len(slave_buf) {
		sync.mutex_unlock(&_spawn_mutex)
		posix.close(master)
		return nil, .Slave_Open_Failed
	}
	copy(slave_buf[:], name)
	slave_buf[len(name)] = 0
	slave_path := cstring(&slave_buf[0])
	sync.mutex_unlock(&_spawn_mutex)

	ws := Winsize{
		ws_row = c.ushort(rows),
		ws_col = c.ushort(cols),
	}

	pid := posix.fork()
	if pid < 0 {
		posix.close(master)
		return nil, .Fork_Failed
	}

	if pid == 0 {
		posix.close(master)
		_ = posix.setsid()

		slave := posix.open(slave_path, {.RDWR})
		if int(slave) >= 0 {
			_ = ioctl(c.int(slave), TIOCSWINSZ, &ws)
			_ = posix.dup2(slave, posix.STDIN_FILENO)
			_ = posix.dup2(slave, posix.STDOUT_FILENO)
			_ = posix.dup2(slave, posix.STDERR_FILENO)
			if int(slave) > 2 {
				posix.close(slave)
			}
		}

		if len(config.cwd) > 0 {
			c_cwd := strings.clone_to_cstring(config.cwd)
			_ = posix.chdir(c_cwd)
			delete(c_cwd)
		}

		c_argv := make([]cstring, len(config.argv) + 2)
		c_argv[0] = strings.clone_to_cstring(prog)
		for arg, i in config.argv {
			c_argv[i + 1] = strings.clone_to_cstring(arg)
		}
		c_argv[len(c_argv) - 1] = nil

		c_env: [dynamic]cstring
		append(&c_env, strings.clone_to_cstring("TERM=xterm-256color"))
		append(&c_env, strings.clone_to_cstring("COLORTERM=truecolor"))
		append(&c_env, strings.clone_to_cstring("PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"))
		append(&c_env, strings.clone_to_cstring("LANG=en_US.UTF-8"))
		append(&c_env, nil)

		_ = posix.execve(c_argv[0], &c_argv[0], &c_env[0])
		posix.exit(127)
	}

	h := new(Pty_Handle)
	h.master_fd = i32(master)
	h.child_pid = i32(pid)
	h.rows = rows
	h.cols = cols
	h.is_running = true
	h.exit_code = 0
	ring_init(&h.ring)

	h.drain_thread = thread.create_and_start_with_data(rawptr(h), proc(data: rawptr) {
		handle := (^Pty_Handle)(data)
		buf: [4096]u8

		for handle.is_running {
			n := posix.read(posix.FD(handle.master_fd), &buf[0], len(buf))
			if n > 0 {
				ring_write(&handle.ring, buf[:n])
			} else if n == 0 {
				break
			} else {
				err_no := posix.errno()
				if err_no == .EAGAIN || err_no == .EINTR {
					posix.nanosleep(&posix.timespec{tv_nsec = 1_000_000}, nil)
					continue
				}
				break
			}
		}

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
