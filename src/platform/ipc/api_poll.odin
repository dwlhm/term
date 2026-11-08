package platform_ipc

// Poll_Set: the one way to wait. It owns the poll backend (kqueue on Darwin,
// epoll on Linux), a wake pipe and the deadlines of the Servers and Links
// registered on it. NVAL/ERR/HUP end a resource; EMFILE gets a backoff.

import "core:sys/posix"

Poll_Set :: struct {
	_impl: rawptr,
}

Fd_Event :: enum u8 {
	Readable,
	Writable,
	Ended, // NVAL/ERR/HUP: the fd is no longer watched afterwards
}

Fd_Watch :: distinct u32

// poll_set_init allocates everything the set will need (capacity fds).
poll_set_init :: proc(set: ^Poll_Set, capacity: int) -> Error {
	return _not_implemented()
}

poll_set_destroy :: proc(set: ^Poll_Set) {}

// poll_set_wait blocks until an event, a poke, or the nearest deadline: the
// caller's due_ns (-1 = none) or one of a registered Server/Link.
poll_set_wait :: proc(set: ^Poll_Set, due_ns: i64) {}

// poll_set_poke wakes poll_set_wait; safe from a signal handler or another thread.
poll_set_poke :: proc "contextless" (set: ^Poll_Set) {}

// poll_set_woken is true once per poke (the wake is drained).
poll_set_woken :: proc(set: ^Poll_Set) -> bool {
	return false
}

// poll_set_watch adds a non-IPC fd (a PTY master, stdin). The caller keeps
// owning fd; on_ready runs from poll_set_wait.
poll_set_watch :: proc(set: ^Poll_Set, fd: posix.FD, on_ready: proc(data: rawptr, ev: Fd_Event), data: rawptr) -> (Fd_Watch, Error) {
	return 0, _not_implemented()
}

poll_set_unwatch :: proc(set: ^Poll_Set, id: Fd_Watch) {}
