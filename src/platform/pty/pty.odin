package platform_pty

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
