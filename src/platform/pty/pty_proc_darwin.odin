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

_proc_name :: proc(pid: c.int, out_buf: []u8) -> string {
	if pid <= 0 || len(out_buf) == 0 do return ""
	name_buf: [256]u8
	ret := proc_name(pid, &name_buf[0], c.uint32_t(len(name_buf)))
	if ret <= 0 do return ""
	return _copy_cstr(name_buf[:ret], out_buf)
}

_proc_cwd :: proc(pid: c.int, out_buf: []u8) -> string {
	if pid <= 0 || len(out_buf) == 0 do return ""
	vnode_buf: [PROC_PIDVNODEPATHINFO_SIZE]u8
	ret := proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode_buf[0], PROC_PIDVNODEPATHINFO_SIZE)
	if ret < PROC_PIDVNODEPATHINFO_SIZE do return ""
	return _copy_cstr(vnode_buf[CWD_PATH_OFFSET:], out_buf)
}

// _copy_cstr copies src up to its first NUL into out (truncated to fit).
_copy_cstr :: proc(src: []u8, out: []u8) -> string {
	n := 0
	for n < len(src) && src[n] != 0 do n += 1
	k := copy(out, src[:n])
	return string(out[:k])
}
