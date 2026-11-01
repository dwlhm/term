package feature_session_core

// Stopping the core: SIGTERM/SIGINT or core_request_stop are a planned
// restart (core_handover: holders keep every program, the next core restores
// the saved screens). The request goes through a self-pipe in the poll set,
// so a stop that lands just before poll(-1) still wakes the loop.

import "core:sync"
import "core:sys/posix"
import ipc "../../platform/ipc"

@(private = "file")
_stop_requested: bool

// _stop_fd: write end of the running core's stop pipe, -1 when none runs.
@(private = "file")
_stop_fd: posix.FD = -1

// core_request_stop asks the running core to stop (as SIGTERM does).
core_request_stop :: proc "contextless" () {
	sync.atomic_store(&_stop_requested, true)
	b: u8 = 1
	if fd := sync.atomic_load(&_stop_fd); fd >= 0 do posix.write(fd, &b, 1)
}

@(private)
_stop_is_requested :: proc() -> bool { return sync.atomic_load(&_stop_requested) }

@(private)
_stop_pipe_open :: proc(c: ^Core) -> bool {
	if posix.pipe(&c.stop_pipe) != .OK do return false
	for fd in c.stop_pipe do ipc.ipc_set_nonblocking_cloexec(fd)
	sync.atomic_store(&_stop_requested, false)
	sync.atomic_store(&_stop_fd, c.stop_pipe[1])
	return true
}

@(private)
_stop_pipe_close :: proc(c: ^Core) {
	if c.stop_pipe[1] >= 0 do sync.atomic_compare_exchange_strong(&_stop_fd, c.stop_pipe[1], -1)
	for fd in c.stop_pipe do if fd >= 0 do posix.close(fd)
	c.stop_pipe = {-1, -1}
}

@(private)
_stop_drain :: proc(c: ^Core) {
	buf: [16]u8
	for posix.read(c.stop_pipe[0], &buf[0], len(buf)) > 0 {}
}

@(private = "file")
_stop_handler :: proc "c" (sig: posix.Signal) {
	saved := posix.errno()
	core_request_stop()
	posix.errno(saved)
}

@(private)
_install_stop_signals :: proc() {
	posix.signal(.SIGTERM, _stop_handler)
	posix.signal(.SIGINT, _stop_handler)
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
}
