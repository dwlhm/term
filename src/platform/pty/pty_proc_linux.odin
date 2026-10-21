#+build linux
package platform_pty

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"

foreign import libc "system:c"

@(default_calling_convention="c")
foreign libc {
	tcgetpgrp :: proc(fd: c.int) -> c.int ---
}

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

	comm_path := fmt.tprintf("/proc/%d/comm", target_pid)
	data, ok := os.read_entire_file(comm_path, context.temp_allocator)
	if !ok || len(data) == 0 do return ""

	s := strings.trim_space(string(data))
	copy_len := min(len(s), len(out_buf))
	copy(out_buf[:copy_len], s[:copy_len])
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

	cwd_link := fmt.tprintf("/proc/%d/cwd", target_pid)
	target, err := os.read_link(cwd_link, context.temp_allocator)
	if err != nil || len(target) == 0 do return ""

	copy_len := min(len(target), len(out_buf))
	copy(out_buf[:copy_len], target[:copy_len])
	return string(out_buf[:copy_len])
}
