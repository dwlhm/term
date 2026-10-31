package platform_pty

import "core:c"
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
	return _pty_spawn_platform(config)
}

pty_close :: proc(handle: ^Pty_Handle) {
	_pty_close_platform(handle)
}

pty_resize :: proc(handle: ^Pty_Handle, cols, rows: u16, xpixel: u16 = 0, ypixel: u16 = 0) -> bool {
	return _pty_resize_platform(handle, cols, rows, xpixel, ypixel)
}

pty_write :: proc(handle: ^Pty_Handle, data: []u8) -> (int, Pty_Error) {
	return _pty_write_platform(handle, data)
}

pty_read_available :: proc(handle: ^Pty_Handle, buf: []u8) -> int {
	if handle == nil do return 0
	return ring_read(&handle.ring, buf)
}

pty_is_alive :: proc(handle: ^Pty_Handle) -> (alive: bool, exit_code: int) {
	if handle == nil do return false, -1
	return handle.is_running, handle.exit_code
}

pty_get_foreground_process_name :: proc(handle: ^Pty_Handle, out_buf: []u8) -> string {
	return _pty_get_foreground_process_platform(handle, out_buf)
}

pty_get_foreground_cwd :: proc(handle: ^Pty_Handle, out_buf: []u8) -> string {
	return _pty_get_cwd_platform(handle, out_buf)
}
