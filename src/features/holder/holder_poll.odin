package feature_holder

// The round's deadline (the nearest one), what each master waits for, and
// the masters' readiness.

import "core:time"
import ipc "../../platform/ipc"

NO_DEADLINE :: max(i64)

_now :: proc() -> i64 { return time.tick_now()._nsec }
_now_unix :: proc() -> i64 { return time.to_unix_seconds(time.now()) }

_ms :: proc(ms: int) -> i64 { return i64(ms) * 1_000_000 }

// _backlogged: the core is too far behind; PTY reads wait.
_backlogged :: proc(h: ^Holder) -> bool {
	return h.core_state == .Linked && ipc.link_backlog(&h.link) > HOLDER_BACKLOG
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
	if h.core_state == .Closing && now >= h.core_deadline do _core_closed(h, now)
	for slot in h.live[:h.count] do _session_check_exit(h, &h.sessions[slot], now)
	if h.draining && h.count == 0 && !h.stopping do _holder_finish(h, now)
	_supervise(h, now)
}

// _holder_due: the nearest deadline for poll_set_wait (-1 = none).
_holder_due :: proc(h: ^Holder, now: i64) -> i64 {
	next := _supervise_deadline(h, now)
	if h.core_state == .Closing do next = min(next, h.core_deadline)
	if !h.paused {
		for slot in h.live[:h.count] {
			s := &h.sessions[slot]
			if s.reaped && !s.exit_final do next = min(next, s.exit_deadline)
		}
	}
	return -1 if next == NO_DEADLINE else next
}

// _holder_wants: a master is read unless the core is too far behind, and
// written while input waits for the program.
_holder_wants :: proc(h: ^Holder) {
	for slot in h.live[:h.count] {
		s := &h.sessions[slot]
		if s.watch == 0 do continue
		want: ipc.Fd_Want
		if !h.paused do want += {.Readable}
		if s.input.len > 0 do want += {.Writable}
		ipc.poll_set_want(&h.set, s.watch, want)
	}
}

// _session_ready: a master's readiness from the Poll_Set.
_session_ready :: proc(data: rawptr, ev: ipc.Fd_Event) {
	s := (^Session)(data)
	if !s.used || s.eof do return
	switch ev {
	case .Readable: _session_drain(s.holder, s, _now())
	case .Writable: _session_write(s)
	case .Ended:
		// Hung up, maybe with output left: the Poll_Set forgot the master, so it
		// is watched again until a read reaches EOF.
		s.watch = 0
		_session_drain(s.holder, s, _now())
		if s.used && !s.eof do _session_watch(s.holder, s)
	}
}
