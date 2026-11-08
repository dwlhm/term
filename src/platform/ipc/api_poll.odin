package platform_ipc

// Poll_Set: the one way to wait. It owns the poll backend (kqueue on Darwin,
// poll on Linux), a wake pipe and the deadlines of the Servers and Links
// registered on it. NVAL/ERR/HUP end a resource; EMFILE gets a backoff.
// State: poll_impl.odin.

import "core:sys/posix"
import "core:time"

Poll_Set :: struct {
	_impl: rawptr,
}

Fd_Event :: enum u8 {
	Readable,
	Writable,
	Ended, // NVAL/ERR/HUP: the fd is no longer watched afterwards
}

Fd_Watch :: distinct u32

@(private = "file")
_POLL_SET_MAX :: 4096 // capacity bound

// poll_set_init allocates everything the set will need: capacity sources
// (watched fds, Server and Link sockets) besides its own wake pipe.
poll_set_init :: proc(set: ^Poll_Set, capacity: int) -> Error {
	if set._impl != nil do return {kind = .Bad_Opts, reason = "poll set is already open"}
	if capacity < 1 || capacity > _POLL_SET_MAX do return {kind = .Bad_Opts, reason = "poll set capacity out of range"}
	p := new(_Poll)
	p.allocator = context.allocator
	p.wake = {-1, -1}
	if !_backend_init(&p.backend, capacity + 1) || posix.pipe(&p.wake) != .OK {
		_poll_free(p)
		return {kind = .Start_Failed, reason = "cannot create the poll backend"}
	}
	for fd in p.wake do ipc_set_nonblocking_cloexec(fd)
	p.sources = make([]_Source, capacity + 1)
	p.pfds = make([]posix.pollfd, capacity + 1)
	p.refs = make([]_Ref, capacity + 1)
	p.sources[0] = {fd = p.wake[0], want = {.IN}, on = _wake_ready, data = p, used = true}
	set._impl = p
	return {}
}

poll_set_destroy :: proc(set: ^Poll_Set) {
	if p := _poll(set); p != nil do _poll_free(p)
	set^ = {}
}

@(private = "file")
_poll_free :: proc(p: ^_Poll) {
	context.allocator = p.allocator
	_backend_destroy(&p.backend)
	for fd in p.wake do if fd >= 0 do posix.close(fd)
	delete(p.sources)
	delete(p.pfds)
	delete(p.refs)
	free(p)
}

// poll_set_wait blocks until an event, a poke, or the nearest deadline: the
// caller's due_ns (time.tick_now()._nsec; -1 = none) or one of a registered
// Server/Link.
poll_set_wait :: proc(set: ^Poll_Set, due_ns: i64) {
	p := _poll(set)
	if p == nil do return
	timeout_ms := -1
	if due_ns >= 0 do timeout_ms = int(max(0, (due_ns - time.tick_now()._nsec + 999_999) / 1_000_000))
	_poll_round(p, timeout_ms)
}

// poll_set_poke wakes poll_set_wait; safe from a signal handler or another thread.
poll_set_poke :: proc "contextless" (set: ^Poll_Set) {
	p := _poll(set)
	if p == nil do return
	b := u8(1)
	posix.write(p.wake[1], &b, 1) // a full pipe already wakes the set
}

// poll_set_woken is true once per poke (the wake is drained).
poll_set_woken :: proc(set: ^Poll_Set) -> bool {
	p := _poll(set)
	if p == nil || !p.woken do return false
	p.woken = false
	return true
}

// poll_set_watch adds a non-IPC fd (a PTY master, stdin) for input. The
// caller keeps owning fd; on_ready runs from poll_set_wait.
poll_set_watch :: proc(set: ^Poll_Set, fd: posix.FD, on_ready: proc(data: rawptr, ev: Fd_Event), data: rawptr) -> (Fd_Watch, Error) {
	p := _poll(set)
	if p == nil do return 0, {kind = .Closed, reason = "poll set is not open"}
	if fd < 0 || on_ready == nil do return 0, {kind = .Bad_Opts, reason = "nothing to watch"}
	id, ok := _poll_add(p, {fd = fd, want = {.IN}, watch = on_ready, data = data})
	if !ok do return 0, {kind = .Busy, reason = "poll set is full"}
	return Fd_Watch(id), {}
}

poll_set_unwatch :: proc(set: ^Poll_Set, id: Fd_Watch) {
	_poll_remove(_poll(set), u32(id))
}
