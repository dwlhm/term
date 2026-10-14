package platform_pty

pty_spawn :: proc(config: Pty_Config) -> (handle: ^Pty_Handle, err: Pty_Error) {
	return _pty_spawn_platform(config)
}

pty_close :: proc(handle: ^Pty_Handle) {
	_pty_close_platform(handle)
}

pty_resize :: proc(handle: ^Pty_Handle, cols, rows: u16) -> bool {
	return _pty_resize_platform(handle, cols, rows)
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
