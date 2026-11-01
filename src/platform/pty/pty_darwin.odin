#+build darwin
package platform_pty

import "core:c"
import "core:sync"
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

_pty_open :: proc(pair: ^_Pty_Pair, ws: ^Winsize) -> Pty_Error {
	master, slave: c.int
	sync.mutex_lock(&_spawn_mutex)
	res := openpty(&master, &slave, nil, nil, ws)
	sync.mutex_unlock(&_spawn_mutex)
	if res != 0 do return .Master_Open_Failed
	pair.master, pair.slave = posix.FD(master), posix.FD(slave)
	return .None
}

// _child_attach_tty: login_tty = setsid + controlling tty + dup to 0-2.
_child_attach_tty :: proc(pair: ^_Pty_Pair, ws: ^Winsize) {
	login_tty(c.int(pair.slave))
}
