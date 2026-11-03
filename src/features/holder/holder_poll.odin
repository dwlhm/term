package feature_holder

// The poll set, its timeout (nearest deadline) and event dispatch.

import "core:c"
import "core:sys/posix"
import "core:time"
import ipc "../../platform/ipc"

NO_DEADLINE :: max(i64)

_now :: proc() -> i64 { return time.tick_now()._nsec }
_now_unix :: proc() -> i64 { return time.to_unix_seconds(time.now()) }

_ms :: proc(ms: int) -> i64 { return i64(ms) * 1_000_000 }

// _backlogged: the core is too far behind; PTY reads wait.
_backlogged :: proc(h: ^Holder) -> bool {
	return h.core_state == .Linked && ipc.stream_queued(&h.core) > HOLDER_BACKLOG
}

// _update_pause tracks backpressure; paused time does not count towards the
// EXITED flow deadline (a stalled core holds the reader back).
_update_pause :: proc(h: ^Holder, now: i64) {
	want := _backlogged(h)
	if want == h.paused do return
	h.paused = want
	if want {
		h.pause_start = now
		return
	}
	for slot in h.live[:h.count] {
		s := &h.sessions[slot]
		if s.reaped && !s.exit_final do s.exit_deadline += now - h.pause_start
	}
}

// _holder_tick fires every deadline that is due.
_holder_tick :: proc(h: ^Holder, now: i64) {
	_update_pause(h, now)
	for &p in h.pending do if p.fd >= 0 && now >= p.deadline do _pending_close(&p)
	if h.core_state == .Closing && now >= h.core_deadline do _core_closed(h, now)
	for slot in h.live[:h.count] do _session_check_exit(h, &h.sessions[slot], now)
	if h.draining && h.count == 0 && !h.stopping do _holder_finish(h, now)
	_supervise(h, now)
}

_poll_timeout :: proc(h: ^Holder, now: i64) -> c.int {
	next := _supervise_deadline(h, now)
	for p in h.pending do if p.fd >= 0 do next = min(next, p.deadline)
	if h.core_state == .Closing do next = min(next, h.core_deadline)
	if !h.paused {
		for slot in h.live[:h.count] {
			s := &h.sessions[slot]
			if s.reaped && !s.exit_final do next = min(next, s.exit_deadline)
		}
	}
	if next == NO_DEADLINE do return -1
	wait := max(next - now, 0)
	return c.int(min((wait + 999_999) / 1_000_000, i64(max(i32))))
}

_poll_build :: proc(h: ^Holder) -> int {
	n := 0
	add :: proc(h: ^Holder, n: ^int, fd: posix.FD, events: posix.Poll_Event, kind: Poll_Kind, index: int) {
		h.pfds[n^] = {fd = fd, events = events}
		h.tags[n^] = {kind, index}
		n^ += 1
	}
	if h.listen_fd >= 0 && !h.stopping do add(h, &n, h.listen_fd, {.IN}, .Listener, 0)
	add(h, &n, h.signals.pipe[0], {.IN}, .Signal, 0)
	for p, i in h.pending do if p.fd >= 0 do add(h, &n, p.fd, {.IN}, .Pending, i)
	if h.core_state != .None {
		events: posix.Poll_Event = {.IN} if h.core_state == .Linked else {}
		if ipc.stream_wants_write(&h.core) do events += {.OUT}
		add(h, &n, h.core.fd, events, .Core, 0)
	}
	for slot in h.live[:h.count] {
		s := &h.sessions[slot]
		if s.eof do continue
		events: posix.Poll_Event
		if !h.paused do events += {.IN}
		if s.input.len > 0 do events += {.OUT}
		if events != {} do add(h, &n, posix.FD(s.master), events, .Session, int(slot))
	}
	return n
}

_poll_dispatch :: proc(h: ^Holder, n: int, now: i64) {
	for i in 0..<n {
		ev := h.pfds[i].revents
		if ev == {} do continue
		tag := h.tags[i]
		switch tag.kind {
		case .Listener: _accept_all(h, now)
		case .Signal:   _signals_drain(&h.signals); _reap_all(h, now)
		case .Pending:  _pending_read(h, tag.index, now)
		case .Core:     if h.core_state == .Linked && ev & {.IN, .HUP, .ERR, .NVAL} != {} do _core_read(h, now)
		case .Session:  _session_event(h, tag.index, h.pfds[i].fd, ev, now)
		}
	}
}

@(private = "file")
_session_event :: proc(h: ^Holder, index: int, fd: posix.FD, ev: posix.Poll_Event, now: i64) {
	s := &h.sessions[index]
	// The slot may have been released (or reused) by a core message this round.
	if !s.used || posix.FD(s.master) != fd || s.eof do return
	if ev & {.IN, .HUP, .ERR, .NVAL} != {} do _session_drain(h, s, now)
	if .OUT in ev && s.used do _session_write(s)
}
