#+build linux
package platform_pty

import "core:c"
import "core:fmt"
import posix "core:sys/posix"

foreign import libc "system:c"

@(default_calling_convention="c")
foreign libc {
	tcgetpgrp :: proc(fd: c.int) -> c.int ---
}

// _proc_name reads /proc/<pid>/comm into out_buf (trailing newline trimmed).
_proc_name :: proc(pid: c.int, out_buf: []u8) -> string {
	if pid <= 0 || len(out_buf) == 0 do return ""
	path_buf: [64]u8
	path := fmt.bprintf(path_buf[:len(path_buf) - 1], "/proc/%d/comm", pid)
	path_buf[len(path)] = 0
	fd := posix.open(cstring(&path_buf[0]), {.CLOEXEC})
	if fd < 0 do return ""
	defer posix.close(fd)
	n := posix.read(fd, raw_data(out_buf), uint(len(out_buf)))
	if n <= 0 do return ""
	k := int(n)
	for k > 0 && (out_buf[k - 1] == '\n' || out_buf[k - 1] == ' ') do k -= 1
	return string(out_buf[:k])
}

// _proc_cwd resolves /proc/<pid>/cwd into out_buf.
_proc_cwd :: proc(pid: c.int, out_buf: []u8) -> string {
	if pid <= 0 || len(out_buf) == 0 do return ""
	path_buf: [64]u8
	path := fmt.bprintf(path_buf[:len(path_buf) - 1], "/proc/%d/cwd", pid)
	path_buf[len(path)] = 0
	n := posix.readlink(cstring(&path_buf[0]), raw_data(out_buf), c.size_t(len(out_buf)))
	if n <= 0 do return ""
	return string(out_buf[:n])
}
