package platform_ipc

// The IO side of a Server{.Line}: accept, read one line, queue it for the
// owner, write the answer, shut the write side and drain. Every phase has a
// deadline: the line within hello_ms ("err timeout"), the owner's answer
// within _LINE_REPLY_MS ("err timeout"), writing and draining within
// _LINE_IO_MS. State shared with the owner (state, gen, taken, out) changes
// only under ln.mutex.

import "core:c"
import "core:sync"
import "core:sys/posix"

@(private)
_line_accept :: proc(data: rawptr, fd: posix.FD) {
	ln := (^_Line)(data)
	busy := 0
	for sl in ln.slots do if sl.state != .Free && sl.state != .Draining do busy += 1
	for &sl in ln.slots {
		if sl.state != .Free do continue
		if !ipc_set_nonblocking_cloexec(fd) do break
		id, ok := _poll_add(ln.set, {fd = fd, want = {.IN}, on = _line_ready, data = &sl, on_due = _line_late})
		if !ok do break
		sl.fd, sl.src, sl.in_len, sl.taken = fd, id, 0, false
		if busy >= ln.max_peers {
			_line_answer(&sl, "err busy\n")
			return
		}
		_line_set_state(&sl, .Reading, ln.hello_ms)
		return
	}
	posix.close(fd)
}

// _line_broken: no new lines; those already in finish, then one Server_Down.
@(private)
_line_broken :: proc(data: rawptr) {
	ln := (^_Line)(data)
	sync.mutex_lock(&ln.mutex)
	ln.broken = true
	sync.mutex_unlock(&ln.mutex)
	if ln.on_wake != nil do ln.on_wake(ln.wake_data)
}

@(private = "file")
_line_set_state :: proc(sl: ^_Line_Slot, state: _Line_State, ms: int) {
	sl.state = state
	if s := _poll_source(sl.ln.set, sl.src); s != nil {
		s.due = _line_due(ms)
		s.want = {.OUT} if state == .Writing else ({.IN} if state != .Queued else {})
	}
}

// _line_answer starts writing text (already under the mutex, or IO-only).
@(private = "file")
_line_answer :: proc(sl: ^_Line_Slot, text: string) {
	sl.out_len, sl.out_off = copy(sl.out, text), 0
	_line_writing(sl)
}

@(private)
_line_writing :: proc(sl: ^_Line_Slot) { _line_set_state(sl, .Writing, _LINE_IO_MS) }

@(private = "file")
_line_ready :: proc(data: rawptr, rev: posix.Poll_Event) {
	sl := (^_Line_Slot)(data)
	#partial switch sl.state {
	case .Reading:  _line_read(sl)
	case .Writing:  _line_write(sl)
	case .Draining: _line_drain(sl)
	}
}

@(private = "file")
_line_read :: proc(sl: ^_Line_Slot) {
	for sl.in_len < len(sl.in_buf) {
		n := posix.recv(sl.fd, &sl.in_buf[sl.in_len], c.size_t(len(sl.in_buf[sl.in_len:])), {})
		if n < 0 && posix.errno() == .EINTR do continue
		if n < 0 && posix.errno() == .EAGAIN do return
		if n <= 0 {
			_line_close(sl) // EOF before '\n'
			return
		}
		for b, i in sl.in_buf[sl.in_len:][:n] {
			if b != '\n' do continue
			sl.in_len += i // one request per connection: what follows '\n' is drained later
			_line_queue(sl)
			return
		}
		sl.in_len += int(n)
	}
	_line_answer(sl, "err too_large\n")
}

@(private = "file")
_line_queue :: proc(sl: ^_Line_Slot) {
	ln := sl.ln
	if sl.in_len > 0 && sl.in_buf[sl.in_len - 1] == '\r' do sl.in_len -= 1
	sync.mutex_lock(&ln.mutex)
	_line_set_state(sl, .Queued, _LINE_REPLY_MS)
	ln.queue[(ln.q_head + ln.q_len) % len(ln.queue)] = _line_peer(sl)
	ln.q_len += 1
	sync.mutex_unlock(&ln.mutex)
	if ln.on_wake != nil do ln.on_wake(ln.wake_data)
}

@(private = "file")
_line_write :: proc(sl: ^_Line_Slot) {
	for sl.out_off < sl.out_len {
		n := posix.send(sl.fd, &sl.out[sl.out_off], c.size_t(len(sl.out[sl.out_off:sl.out_len])), {.NOSIGNAL})
		if n < 0 && posix.errno() == .EINTR do continue
		if n < 0 && posix.errno() == .EAGAIN do return
		if n <= 0 {
			_line_close(sl)
			return
		}
		sl.out_off += int(n)
	}
	posix.shutdown(sl.fd, .WR)
	_line_set_state(sl, .Draining, _LINE_IO_MS)
}

@(private = "file")
_line_drain :: proc(sl: ^_Line_Slot) {
	buf: [4096]u8
	for {
		n := posix.recv(sl.fd, raw_data(buf[:]), len(buf), {})
		if n < 0 && posix.errno() == .EINTR do continue
		if n < 0 && posix.errno() == .EAGAIN do return
		_line_close(sl) // EOF (or an error): the client has its answer
		return
	}
}

// _line_late: a phase ran out of time.
@(private = "file")
_line_late :: proc(data: rawptr) {
	sl := (^_Line_Slot)(data)
	sync.mutex_lock(&sl.ln.mutex)
	defer sync.mutex_unlock(&sl.ln.mutex)
	#partial switch sl.state {
	case .Reading, .Queued: _line_answer(sl, "err timeout\n")
	case .Writing, .Draining: _line_close(sl)
	}
}

@(private)
_line_close :: proc(sl: ^_Line_Slot) {
	_poll_remove(sl.ln.set, sl.src)
	if sl.fd >= 0 do posix.close(sl.fd)
	sl.fd, sl.src, sl.state, sl.taken = -1, 0, .Free, false
	sl.gen += 1
}

@(private)
_line_peer :: proc(sl: ^_Line_Slot) -> Peer {
	return {u16((uintptr(sl) - uintptr(raw_data(sl.ln.slots))) / size_of(_Line_Slot)), sl.gen}
}

// _line_start_replies (IO thread): answers the owner gave from its thread.
@(private)
_line_start_replies :: proc(ln: ^_Line) {
	sync.mutex_lock(&ln.mutex)
	defer sync.mutex_unlock(&ln.mutex)
	for &sl in ln.slots do if sl.state == .Replied do _line_writing(&sl)
}
