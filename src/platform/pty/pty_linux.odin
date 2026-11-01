#+build linux
package platform_pty

import "core:c"
import "core:sync"
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

// _pty_open: posix_openpt + the slave path (ptsname is not thread-safe). The
// parent holds the slave open too until after fork, so the master never reads
// EIO before the child has attached.
_pty_open :: proc(pair: ^_Pty_Pair, ws: ^Winsize) -> Pty_Error {
	sync.mutex_lock(&_spawn_mutex)
	defer sync.mutex_unlock(&_spawn_mutex)
	master := posix.posix_openpt({.RDWR, .NOCTTY, .NONBLOCK})
	if int(master) < 0 do return .Master_Open_Failed
	posix.grantpt(master)
	if posix.unlockpt(master) != .OK {
		posix.close(master)
		return .Master_Open_Failed
	}
	name := string(posix.ptsname(master))
	if len(name) == 0 || len(name) >= len(pair.slave_path) {
		posix.close(master)
		return .Slave_Open_Failed
	}
	copy(pair.slave_path[:], name)
	pair.slave_path[len(name)] = 0
	pair.slave = posix.open(cstring(&pair.slave_path[0]), {.RDWR, .NOCTTY, .CLOEXEC})
	if int(pair.slave) < 0 {
		posix.close(master)
		return .Slave_Open_Failed
	}
	pair.master = master
	return .None
}

// _child_attach_tty: new session, open the slave (it becomes the controlling
// tty), apply the size, dup to 0-2.
_child_attach_tty :: proc(pair: ^_Pty_Pair, ws: ^Winsize) {
	posix.setsid()
	posix.close(pair.slave)
	slave := posix.open(cstring(&pair.slave_path[0]), {.RDWR})
	if int(slave) < 0 do return
	ioctl(c.int(slave), TIOCSWINSZ, ws)
	posix.dup2(slave, posix.STDIN_FILENO)
	posix.dup2(slave, posix.STDOUT_FILENO)
	posix.dup2(slave, posix.STDERR_FILENO)
	if int(slave) > 2 do posix.close(slave)
}
