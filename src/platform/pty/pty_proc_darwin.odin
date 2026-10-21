#+build darwin
package platform_pty

import "core:c"

foreign import libc "system:System.framework"

@(default_calling_convention="c")
foreign libc {
	tcgetpgrp    :: proc(fd: c.int) -> c.int ---
	proc_name    :: proc(pid: c.int, buffer: rawptr, buffersize: c.uint32_t) -> c.int ---
	proc_pidinfo :: proc(pid: c.int, flavor: c.int, arg: c.uint64_t, buffer: rawptr, buffersize: c.int) -> c.int ---
}

PROC_PIDVNODEPATHINFO      :: 9
PROC_PIDVNODEPATHINFO_SIZE :: 2352
CWD_PATH_OFFSET            :: 152

_pty_get_foreground_process_platform :: proc(handle: ^Pty_Handle, out_buf: []u8) -> string {
	if handle == nil || len(out_buf) == 0 do return ""

	target_pid: c.int = 0
	if handle.master_fd >= 0 {
		fg_pid := tcgetpgrp(handle.master_fd)
		if fg_pid > 0 do target_pid = fg_pid
	}
	if target_pid <= 0 && handle.child_pid > 0 {
		target_pid = c.int(handle.child_pid)
	}
	if target_pid <= 0 do return ""

	name_buf: [256]u8
	ret := proc_name(target_pid, &name_buf[0], c.uint32_t(len(name_buf)))
	if ret <= 0 do return ""

	name_len := 0
	for name_len < int(ret) && name_buf[name_len] != 0 {
		name_len += 1
	}
	if name_len == 0 do return ""

	copy_len := min(name_len, len(out_buf))
	copy(out_buf[:copy_len], name_buf[:copy_len])
	return string(out_buf[:copy_len])
}

_pty_get_cwd_platform :: proc(handle: ^Pty_Handle, out_buf: []u8) -> string {
	if handle == nil || len(out_buf) == 0 do return ""

	target_pid: c.int = 0
	if handle.master_fd >= 0 {
		fg_pid := tcgetpgrp(handle.master_fd)
		if fg_pid > 0 do target_pid = fg_pid
	}
	if target_pid <= 0 && handle.child_pid > 0 {
		target_pid = c.int(handle.child_pid)
	}
	if target_pid <= 0 do return ""

	vnode_buf: [PROC_PIDVNODEPATHINFO_SIZE]u8
	ret := proc_pidinfo(target_pid, PROC_PIDVNODEPATHINFO, 0, &vnode_buf[0], PROC_PIDVNODEPATHINFO_SIZE)
	if ret < PROC_PIDVNODEPATHINFO_SIZE do return ""

	path_slice := vnode_buf[CWD_PATH_OFFSET:]
	path_len := 0
	for path_len < len(path_slice) && path_slice[path_len] != 0 {
		path_len += 1
	}
	if path_len == 0 do return ""

	copy_len := min(path_len, len(out_buf))
	copy(out_buf[:copy_len], path_slice[:copy_len])
	return string(out_buf[:copy_len])
}
