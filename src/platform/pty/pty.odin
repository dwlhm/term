package platform_pty

// Pty_Handle: a PTY child (pty_spawn_raw) plus a drain thread that copies its
// output into the handle's ring and wakes the app.

import "core:c"
import "core:thread"
import "core:sys/posix"

// fd flag helpers go through core:sys/posix on purpose: a second foreign
// `fcntl` declaration with a different signature makes -o:speed builds panic
// in the LLVM backend once another package also calls posix.fcntl.
_fd_set_cloexec :: proc(fd: posix.FD) {
	if flags := posix.fcntl(fd, .GETFD); flags >= 0 do posix.fcntl(fd, .SETFD, flags | c.int(posix.FD_CLOEXEC))
}

_fd_set_nonblocking :: proc(fd: posix.FD) {
	if flags := posix.fcntl(fd, .GETFL); flags >= 0 do posix.fcntl(fd, .SETFL, flags | c.int(posix.O_NONBLOCK))
}

pty_spawn :: proc(config: Pty_Config) -> (handle: ^Pty_Handle, err: Pty_Error) {
	master, pid, spawn_err := pty_spawn_raw(config, nil)
	if spawn_err != .None do return nil, spawn_err
	pipe_fds: [2]posix.FD
	if posix.pipe(&pipe_fds) != .OK {
		pty_hangup(master, pid)
		return nil, .Pipe_Failed
	}
	for fd in pipe_fds {
		_fd_set_cloexec(fd)
		_fd_set_nonblocking(fd)
	}
	h := new(Pty_Handle)
	h^ = {
		master_fd     = master,
		child_pid     = pid,
		shutdown_pipe = {i32(pipe_fds[0]), i32(pipe_fds[1])},
		rows          = max(1, config.rows),
		cols          = max(1, config.cols),
		is_running    = true,
	}
	ring_init(&h.ring)
	h.drain_thread = thread.create_and_start_with_data(rawptr(h), _drain)
	return h, .None
}

// _drain copies output into the ring until EOF/EIO or the shutdown pipe fires.
@(private = "file")
_drain :: proc(data: rawptr) {
	h := (^Pty_Handle)(data)
	buf: [65536]u8
	pfds := [2]posix.pollfd{
		{fd = posix.FD(h.master_fd), events = {.IN}},
		{fd = posix.FD(h.shutdown_pipe[0]), events = {.IN}},
	}
	for h.is_running {
		if posix.poll(&pfds[0], 2, -1) < 0 {
			if posix.errno() == .EINTR do continue
			break
		}
		if !h.is_running || pfds[1].revents & {.IN, .HUP, .ERR} != {} do break
		if .IN not_in pfds[0].revents {
			if pfds[0].revents & {.HUP, .ERR, .NVAL} != {} do break
			continue
		}
		fd := h.master_fd
		if fd < 0 do break
		n := posix.read(posix.FD(fd), &buf[0], len(buf))
		if n > 0 {
			ring_write(&h.ring, buf[:n])
			continue
		}
		if n < 0 && (posix.errno() == .EINTR || posix.errno() == .EAGAIN) do continue
		break // EOF, EIO or hangup
	}
	status: c.int = 0
	posix.waitpid(posix.pid_t(h.child_pid), &status, {.NOHANG})
	h.exit_code = int(status >> 8)
	h.is_running = false
	pty_notify_wakeup()
}

// pty_close hangs up before joining the drain thread, so a grandchild that
// holds the slave can never stall teardown.
pty_close :: proc(h: ^Pty_Handle) {
	if h == nil do return
	h.is_running = false
	if h.shutdown_pipe[1] >= 0 {
		sig: u8 = 1
		posix.write(posix.FD(h.shutdown_pipe[1]), &sig, 1)
	}
	master := h.master_fd
	h.master_fd = -1
	pty_hangup(master, h.child_pid)
	if h.drain_thread != nil {
		thread.join(h.drain_thread)
		thread.destroy(h.drain_thread)
		h.drain_thread = nil
	}
	for fd in h.shutdown_pipe do if fd >= 0 do posix.close(posix.FD(fd))
	ring_destroy(&h.ring)
	free(h)
}

pty_resize :: proc(handle: ^Pty_Handle, cols, rows: u16, xpixel: u16 = 0, ypixel: u16 = 0) -> bool {
	if handle == nil || handle.master_fd < 0 do return false
	handle.cols, handle.rows = int(cols), int(rows)
	xp := xpixel if xpixel > 0 else cols * 10
	yp := ypixel if ypixel > 0 else rows * 20
	return pty_set_size(handle.master_fd, cols, rows, xp, yp)
}

pty_write :: proc(handle: ^Pty_Handle, data: []u8) -> (int, Pty_Error) {
	if handle == nil || handle.master_fd < 0 do return 0, .Closed
	fd := posix.FD(handle.master_fd)
	total := 0
	for total < len(data) {
		rem := len(data) - total
		n := posix.write(fd, &data[total], uint(rem))
		if n > 0 {
			total += int(n)
			continue
		}
		if n < 0 && posix.errno() == .EINTR do continue
		if n < 0 && posix.errno() == .EAGAIN {
			pfd := posix.pollfd{fd = fd, events = {.OUT}}
			if posix.poll(&pfd, 1, 2) <= 0 do break
			continue
		}
		if total > 0 do return total, .None
		return 0, .Write_Failed
	}
	return total, .None
}

pty_read_available :: proc(handle: ^Pty_Handle, buf: []u8) -> int {
	if handle == nil do return 0
	return ring_read(&handle.ring, buf)
}

pty_is_alive :: proc(handle: ^Pty_Handle) -> (alive: bool, exit_code: int) {
	if handle == nil do return false, -1
	return handle.is_running, handle.exit_code
}

// _target_pid: the foreground job's leader, else the child itself.
@(private = "file")
_target_pid :: proc(handle: ^Pty_Handle) -> c.int {
	if handle == nil do return 0
	if handle.master_fd >= 0 {
		if fg := tcgetpgrp(handle.master_fd); fg > 0 do return fg
	}
	return c.int(max(handle.child_pid, 0))
}

pty_get_foreground_process_name :: proc(handle: ^Pty_Handle, out_buf: []u8) -> string {
	pid := _target_pid(handle)
	return _proc_name(pid, out_buf) if pid > 0 else ""
}

pty_get_foreground_cwd :: proc(handle: ^Pty_Handle, out_buf: []u8) -> string {
	pid := _target_pid(handle)
	return _proc_cwd(pid, out_buf) if pid > 0 else ""
}
