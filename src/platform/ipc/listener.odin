package platform_ipc

// _Listener: a bound unix socket on a Poll_Set, shared by Link and Server.
// Peers of another uid are closed at once. EMFILE and the like stop polling
// the listener for _ACCEPT_BACKOFF_NS (a full fd table keeps it readable, so
// polling on would spin), then accepting resumes. NVAL/ERR or any other
// accept error breaks it: on_broken runs once and the listener holds no fd.
// Closing unlinks the socket path only while it is still the inode we bound.

import "core:fmt"
import "core:sys/posix"
import "core:time"

@(private)
_ACCEPT_BACKOFF_NS :: 100 * 1_000_000

@(private = "file")
_ACCEPT_PER_ROUND :: 64 // fairness: the rest wait for the next round

@(private)
_Listener :: struct {
	set:       ^_Poll, // nil = closed
	fd:        posix.FD,
	src:       u32,
	ino:       u64,
	path:      [_SUN_PATH]u8,
	path_len:  int,
	on_accept: proc(data: rawptr, fd: posix.FD), // fd: ours, same uid, not yet nonblocking
	on_broken: proc(data: rawptr),
	data:      rawptr,
}

@(private)
_listener_open :: proc(l: ^_Listener, p: ^_Poll, path: string, on_accept: proc(data: rawptr, fd: posix.FD), on_broken: proc(data: rawptr), data: rawptr) -> Error {
	fd, ino, err := _bind_listener(path)
	if err.kind != .None do return err
	l^ = {set = p, fd = fd, ino = ino, on_accept = on_accept, on_broken = on_broken, data = data}
	l.path_len = copy(l.path[:], path)
	id, ok := _poll_add(p, {fd = fd, want = {.IN}, on = _listener_ready, data = l, on_due = _listener_resume})
	if !ok {
		_listener_close(l)
		return {kind = .Busy, reason = "poll set is full"}
	}
	l.src = id
	return {}
}

@(private)
_listener_close :: proc(l: ^_Listener) {
	if l.set == nil do return
	_poll_remove(l.set, l.src)
	if l.fd >= 0 do posix.close(l.fd)
	_unlink_if_ours(string(l.path[:l.path_len]), l.ino)
	l^ = {}
}

@(private = "file")
_listener_ready :: proc(data: rawptr, rev: posix.Poll_Event) {
	l := (^_Listener)(data)
	if rev & {.NVAL, .ERR} != {} {
		_listener_broken(l, .NVAL not_in rev)
		return
	}
	for _ in 0 ..< _ACCEPT_PER_ROUND {
		fd := posix.accept(l.fd, nil, nil)
		if fd >= 0 {
			_listener_take(l, fd)
			continue
		}
		#partial switch posix.errno() {
		case .EINTR, .ECONNABORTED: continue
		case .EAGAIN:               return
		case .EMFILE, .ENFILE, .ENOBUFS, .ENOMEM:
			s := _poll_source(l.set, l.src)
			s.want, s.due = {}, time.tick_now()._nsec + _ACCEPT_BACKOFF_NS
			return
		case .EBADF: _listener_broken(l, false)
		case:        _listener_broken(l, true)
		}
		return
	}
}

@(private = "file")
_listener_take :: proc(l: ^_Listener, fd: posix.FD) {
	uid, ok := _peer_uid(fd)
	if !ok || uid != posix.getuid() {
		posix.close(fd)
		return
	}
	l.on_accept(l.data, fd)
}

@(private = "file")
_listener_resume :: proc(data: rawptr) {
	l := (^_Listener)(data)
	if s := _poll_source(l.set, l.src); s != nil do s.want = {.IN}
}

// _listener_broken forgets the fd; it is closed only when it is still ours
// (after NVAL/EBADF the number may already belong to someone else).
@(private = "file")
_listener_broken :: proc(l: ^_Listener, close_fd: bool) {
	_poll_remove(l.set, l.src)
	l.src = 0
	if close_fd do posix.close(l.fd)
	l.fd = -1
	l.on_broken(l.data)
}
