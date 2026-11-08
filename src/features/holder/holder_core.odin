package feature_holder

// The core link (an ipc.Link: HELLO, newest wins and the pending HELLOs live
// there): WELCOME and TAILs when a core arrives, its frames, backpressure,
// and closing (BYE + linger).

import "core:fmt"
import "core:os"
import proto "../session_proto"
import ipc "../../platform/ipc"

// _core_events handles what the link reports after a wait.
_core_events :: proc(h: ^Holder, now: i64) {
	for ev in ipc.link_next(&h.link) {
		switch e in ev {
		case ipc.Link_Up:   _core_up(h, now)
		case ipc.Link_Down: _core_down(h, e, now)
		case ipc.Link_Frame:
			if h.core_state != .Linked do continue // Closing: only BYE goes out
			if !_core_message(h, ipc.Stream_Frame{e.kind, e.channel, e.body}, now) do _core_drop(h, now)
		}
	}
}

// _core_up greets a new core with WELCOME and, as the backlog allows, one
// TAIL per session (the link already sent our HELLO).
@(private = "file")
_core_up :: proc(h: ^Holder, now: i64) {
	if h.stopping {
		ipc.link_drop(&h.link) // on the way out: no new core
		return
	}
	h.core_state = .Linked
	_supervisor_linked(&h.sup)
	_send_welcome(h)
	h.previous = PREVIOUS_CRASH // until the core says GOODBYE
}

// _core_down: replaced by a newer core (its Up follows), or gone.
@(private = "file")
_core_down :: proc(h: ^Holder, e: ipc.Link_Down, now: i64) {
	if e.replaced {
		_core_destroy(h) // an older core loses the holder (previous stays crash)
		return
	}
	if h.core_state == .Linked do _core_crashed(h, now)
	_core_closed(h, now)
}

@(private = "file")
_send_welcome :: proc(h: ^Holder) {
	w := ipc.wire_writer(h.msg_buf[:])
	proto.enc_welcome(&w, {
		version  = proto.STREAM_PROTO_VERSION,
		instance = h.instance,
		pid      = u32(os.get_pid()),
		build    = h.build,
		previous = h.previous,
		crashes  = _recent_crashes(h, _now()),
		count    = u32(h.count),
	})
	for slot in h.live[:h.count] {
		s := &h.sessions[slot]
		proto.enc_held(&w, {id = s.id, pid = u32(s.pid), started_unix = s.started_unix, size = s.size, exited = s.exit_final, exit = s.exit})
		s.tailed, s.exit_sent = false, s.exit_final
	}
	_core_send(h, proto.MSG_WELCOME, 0, ipc.wire_bytes_written(&w))
}

// _send_tails offers each untailed session its TAIL while the backlog has
// room; until then that session's output only goes to its tail.
_send_tails :: proc(h: ^Holder) {
	for slot in h.live[:h.count] {
		s := &h.sessions[slot]
		if s.tailed do continue
		if h.core_state != .Linked do return
		if ipc.link_backlog(&h.link) + ipc.STREAM_HEADER + s.tail.len > HOLDER_BACKLOG do return
		front := ipc.ring_front(&s.tail)
		wrapped := s.tail.buf[:s.tail.len - len(front)]
		if !_core_send(h, proto.MSG_TAIL, s.id, front, wrapped) do return
		s.tailed = true
		_session_report_exit(h, s)
	}
}

// _core_send queues a frame; a core that let the backlog fill up is dropped
// (it stopped reading while asking for more).
_core_send :: proc(h: ^Holder, kind: u8, channel: u32, parts: ..[]u8) -> bool {
	if h.core_state == .None do return false
	if !ipc.link_send(&h.link, kind, channel, ..parts) {
		fmt.eprintln("holder: core stopped reading, dropping the link")
		_core_drop(h, _now())
		return false
	}
	return true
}

// _core_pump runs after every wait: tails, linger end, pause.
_core_pump :: proc(h: ^Holder, now: i64) {
	_send_tails(h)
	if h.core_state == .Closing && ipc.link_backlog(&h.link) == 0 do _core_closed(h, now)
	_update_pause(h, now)
}

// _core_begin_close queues BYE and lets the link linger until flushed.
_core_begin_close :: proc(h: ^Holder, now: i64) {
	_core_send(h, proto.MSG_BYE, 0)
	if h.core_state == .None {
		if h.stopping do h.done = true
		return
	}
	h.core_state = .Closing
	h.core_deadline = now + _ms(HOLDER_LINGER_MS)
}

// _core_drop ends a link that failed or misbehaved: a crash for the next core.
_core_drop :: proc(h: ^Holder, now: i64) {
	if h.core_state == .Linked do _core_crashed(h, now)
	_core_closed(h, now)
}

@(private = "file")
_core_crashed :: proc(h: ^Holder, now: i64) {
	h.previous = PREVIOUS_CRASH
	h.crash_times[h.crash_next] = now
	h.crash_next = (h.crash_next + 1) % HOLDER_CRASH_MEMORY
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

// _core_closed ends our side of the link (the listener stays for the next core).
_core_closed :: proc(h: ^Holder, now: i64) {
	ipc.link_drop(&h.link)
	_core_destroy(h)
	_supervisor_unlinked(&h.sup, now)
	if h.stopping do h.done = true
}

_core_destroy :: proc(h: ^Holder) {
	if h.core_state == .None do return
	h.core_state = .None
	for slot in h.live[:h.count] do h.sessions[slot].tailed = false
	_update_pause(h, _now())
}
