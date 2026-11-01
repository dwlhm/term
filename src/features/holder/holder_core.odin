package feature_holder

// The core link: accepting, the HELLO handshake (newest wins), WELCOME and
// TAILs, flushing, and closing (BYE + linger).

import "core:fmt"
import "core:os"
import "core:sys/posix"
import ipc "../../platform/ipc"

_accept_all :: proc(h: ^Holder, now: i64) {
	for {
		fd := posix.accept(h.listen_fd, nil, nil)
		if fd < 0 {
			if posix.errno() == .EINTR do continue
			return
		}
		uid, ok := ipc.ipc_peer_uid(fd)
		if !ok || uid != posix.getuid() || !ipc.ipc_set_nonblocking_cloexec(fd) {
			posix.close(fd)
			continue
		}
		slot := &h.pending[0]
		for &p in h.pending {
			if p.fd < 0 || p.deadline < slot.deadline do slot = &p
			if p.fd < 0 do break
		}
		_pending_close(slot) // full: the oldest attempt gives way
		slot.fd, slot.len, slot.deadline = fd, 0, now + _ms(HOLDER_HELLO_MS)
	}
}

_pending_close :: proc(p: ^Pending) {
	if p.fd >= 0 do posix.close(p.fd)
	p.fd, p.len = -1, 0
}

// _pending_read collects one HELLO frame; anything else closes the attempt.
_pending_read :: proc(h: ^Holder, index: int, now: i64) {
	p := &h.pending[index]
	n := posix.recv(p.fd, &p.buf[p.len], uint(len(p.buf) - p.len), {})
	if n < 0 && (posix.errno() == .EAGAIN || posix.errno() == .EINTR) do return
	if n <= 0 {
		_pending_close(p)
		return
	}
	p.len += int(n)
	if p.len < ipc.STREAM_HEADER do return
	kind, _, length, valid := ipc.stream_parse_header(p.buf[:p.len])
	if !valid || kind != ipc.MSG_HELLO || length > len(p.buf) - ipc.STREAM_HEADER {
		_pending_close(p)
		return
	}
	end := ipc.STREAM_HEADER + length
	if p.len < end do return
	_, _, ok := ipc.stream_hello_check(p.buf[ipc.STREAM_HEADER:end], {.Core})
	if !ok || h.stopping {
		_pending_close(p)
		return
	}
	_core_link(h, p, end, now)
}

// _core_link makes p the core (an older link is cut) and greets it with
// HELLO, WELCOME and, as the backlog allows, one TAIL per session.
@(private = "file")
_core_link :: proc(h: ^Holder, p: ^Pending, hello_end: int, now: i64) {
	_core_destroy(h) // an older core loses the holder (previous stays crash)
	fd := p.fd
	p.fd = -1
	if !ipc.stream_conn_init(&h.core, fd, HOLDER_CTL_CAP) {
		ipc.stream_conn_destroy(&h.core)
		return
	}
	rest := p.buf[hello_end:p.len]
	copy(h.core.in_buf, rest) // frames the core pipelined behind its HELLO
	h.core.in_len = len(rest)
	p.len = 0
	h.core_state = .Linked
	_supervisor_linked(&h.sup)
	_send_hello(h)
	_send_welcome(h)
	h.previous = PREVIOUS_CRASH // until the core says GOODBYE
	_core_frames(h, now)
}

@(private = "file")
_send_hello :: proc(h: ^Holder) {
	w := ipc.wire_writer(h.msg_buf[:])
	ipc.enc_hello(&w, {version = ipc.STREAM_PROTO_VERSION, role = .Holder, build = h.build})
	_core_send(h, ipc.MSG_HELLO, 0, ipc.wire_bytes_written(&w))
}

@(private = "file")
_send_welcome :: proc(h: ^Holder) {
	w := ipc.wire_writer(h.msg_buf[:])
	ipc.enc_welcome(&w, {
		version  = ipc.STREAM_PROTO_VERSION,
		instance = h.instance,
		pid      = u32(os.get_pid()),
		build    = h.build,
		previous = h.previous,
		crashes  = _recent_crashes(h, _now()),
		count    = u32(h.count),
	})
	for &s in h.sessions {
		if !s.used do continue
		ipc.enc_held(&w, {id = s.id, pid = u32(s.pid), size = s.size, exited = s.exit_final, exit = s.exit})
		s.tailed, s.exit_sent = false, s.exit_final
	}
	h.tail_cursor = 0
	_core_send(h, ipc.MSG_WELCOME, 0, ipc.wire_bytes_written(&w))
}

// _send_tails offers each session's TAIL in order while the backlog has room;
// until then that session's output only goes to its tail.
_send_tails :: proc(h: ^Holder) {
	for h.core_state == .Linked && h.tail_cursor < HOLDER_MAX_SESSIONS {
		s := &h.sessions[h.tail_cursor]
		if s.used && !s.tailed {
			if ipc.stream_queued(&h.core) + ipc.STREAM_HEADER + s.tail.len > HOLDER_BACKLOG do return
			front := ipc.ring_front(&s.tail)
			wrapped := s.tail.buf[:s.tail.len - len(front)]
			if !_core_send(h, ipc.MSG_TAIL, s.id, front, wrapped) do return
			s.tailed = true
			_session_report_exit(h, s)
		}
		h.tail_cursor += 1
	}
}

// _core_send queues a frame; a core that let the control queue fill up is
// dropped (it stopped reading while asking for more).
_core_send :: proc(h: ^Holder, kind: u8, channel: u32, parts: ..[]u8) -> bool {
	if h.core_state == .None do return false
	total := ipc.STREAM_HEADER
	for p in parts do total += len(p)
	if len(h.core.ctl.buf) - h.core.ctl.len < total || !ipc.stream_send(&h.core, kind, channel, ..parts) {
		fmt.eprintln("holder: core stopped reading, dropping the link")
		_core_drop(h, _now())
		return false
	}
	return true
}

// _core_pump runs after every poll round: tails, flush, linger end, pause.
_core_pump :: proc(h: ^Holder, now: i64) {
	_send_tails(h)
	if h.core_state != .None && ipc.stream_wants_write(&h.core) {
		if ipc.stream_flush(&h.core) != .None do _core_drop(h, now)
	}
	if h.core_state == .Closing && !ipc.stream_wants_write(&h.core) do _core_closed(h, now)
	_update_pause(h, now)
}

// _core_begin_close queues BYE and lets the link linger until flushed.
_core_begin_close :: proc(h: ^Holder, now: i64) {
	_core_send(h, ipc.MSG_BYE, 0)
	if h.core_state == .None {
		if h.stopping do h.done = true
		return
	}
	h.core_state = .Closing
	h.core_deadline = now + _ms(HOLDER_LINGER_MS)
}

// _core_drop ends a link that failed or misbehaved: a crash for the next core.
_core_drop :: proc(h: ^Holder, now: i64) {
	if h.core_state == .Linked {
		h.previous = PREVIOUS_CRASH
		h.crash_times[h.crash_next] = now
		h.crash_next = (h.crash_next + 1) % HOLDER_CRASH_MEMORY
	}
	_core_closed(h, now)
}

// HOLDER_CRASH_MEMORY crashes are remembered; WELCOME reports those of the last 5 minutes
// so a core can stop replaying tails that keep crashing it.
HOLDER_CRASH_MEMORY :: 8

@(private = "file")
_recent_crashes :: proc(h: ^Holder, now: i64) -> u32 {
	n: u32
	for t in h.crash_times do if t != 0 && now - t < _ms(HOLDER_RESTART_WINDOW) do n += 1
	return n
}

_core_closed :: proc(h: ^Holder, now: i64) {
	_core_destroy(h)
	_supervisor_unlinked(&h.sup, now)
	if h.stopping do h.done = true
}

_core_destroy :: proc(h: ^Holder) {
	if h.core_state == .None do return
	ipc.stream_conn_destroy(&h.core)
	h.core_state = .None
	for &s in h.sessions do s.tailed = false
	_update_pause(h, _now())
}
