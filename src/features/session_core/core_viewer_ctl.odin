package feature_session_core

// Channel-0 requests that act on one session by id without attaching
// (agents: `term session kill|send|signal|resize`). Each answers OK or FAIL.

import ipc "../../platform/ipc"
import session "../session"
import terminal "../../core/terminal"

core_viewer_kill :: proc(c: ^Core, vi: int, r: ^ipc.Wire_Reader) {
	s := _target(c, vi, r, false)
	if s == nil do return
	core_session_kill(c, s)
	_ok(c, vi)
}

// core_viewer_send types bytes into a session.
core_viewer_send :: proc(c: ^Core, vi: int, r: ^ipc.Wire_Reader) {
	s := _target(c, vi, r, true, false)
	if s == nil do return
	core_holder_send(c, s.holder, ipc.MSG_INPUT, s.id, r.buf[r.off:])
	_ok(c, vi)
}

// core_viewer_signal: the holder delivers it like ^C, to the foreground group.
core_viewer_signal :: proc(c: ^Core, vi: int, r: ^ipc.Wire_Reader) {
	s := _target(c, vi, r, true, false)
	if s == nil do return
	sig := ipc.wr_i32(r)
	if !ipc.wr_done(r) || sig < 1 || sig > 64 {
		core_viewer_fail(c, vi, 0, .Bad_Request, "bad signal number")
		return
	}
	b := _i32_bytes(sig)
	core_holder_send(c, s.holder, ipc.MSG_SIGNAL, s.id, b[:])
	_ok(c, vi)
}

// core_viewer_resize sizes a session nobody shows: a window that shows it
// leads its size (core_apply_leader), so that request fails as Busy.
core_viewer_resize :: proc(c: ^Core, vi: int, r: ^ipc.Wire_Reader) {
	s := _target(c, vi, r, true, false)
	if s == nil do return
	size := ipc.dec_size(r)
	switch {
	case !ipc.wr_done(r) || size.cols == 0 || size.rows == 0:
		core_viewer_fail(c, vi, 0, .Bad_Request, "bad size")
		return
	case s.stitch != nil && s.stitch.active:
		core_viewer_fail(c, vi, 0, .Busy, "this session's history is being read")
		return
	}
	for &a in s.attaches do if a.used && !a.observe {
		core_viewer_fail(c, vi, 0, .Busy, "shown in a window: its size follows that window")
		return
	}
	session.session_resize(s.sess, size.cols, size.rows, size.xpixel, size.ypixel)
	_ = terminal.terminal_consume_damage(&s.sess.term)
	_ok(c, vi)
}

// _target reads the session id and answers FAIL when the session is unknown,
// or (live) has exited.
@(private = "file")
_target :: proc(c: ^Core, vi: int, r: ^ipc.Wire_Reader, live: bool, exact := true) -> ^Core_Session {
	id := ipc.wr_u32(r)
	s := core_session_find(c, id)
	switch {
	case !r.ok || (exact && !ipc.wr_done(r)): core_viewer_fail(c, vi, 0, .Bad_Request, "malformed request")
	case s == nil:                            core_viewer_fail(c, vi, 0, .Not_Found, "no such session")
	case live && s.exited:                    core_viewer_fail(c, vi, 0, .Exited, "session has exited")
	case:                                     return s
	}
	return nil
}

@(private = "file")
_ok :: proc(c: ^Core, vi: int) {
	ipc.stream_send(&c.viewers[vi].conn, ipc.MSG_OK, 0)
}
