package feature_session_core

// Channel-0 requests that act on one session by id without attaching
// (agents: `term session kill|send|signal|resize|observe`). Each answers OK, FAIL or a result.

import "core:strings"
import ipc "../../platform/ipc"
import session "../session"
import terminal "../../core/terminal"

core_viewer_kill :: proc(c: ^Core, vi: int, r: ^ipc.Wire_Reader) {
	s := _target(c, vi, r, false)
	if s == nil do return
	core_session_kill(c, s)
	_ok(c, vi)
}

// core_viewer_send types bytes into a session: like a person typing.
core_viewer_send :: proc(c: ^Core, vi: int, r: ^ipc.Wire_Reader) {
	s := _target(c, vi, r, true, false)
	if s == nil || _no_program(c, vi, s) do return
	core_broker_human_input(c, s, r.buf[r.off:])
	core_holder_send(c, s.holder, ipc.MSG_INPUT, s.id, r.buf[r.off:])
	_ok(c, vi)
}

// core_viewer_signal: the holder delivers it like ^C, to the foreground group.
core_viewer_signal :: proc(c: ^Core, vi: int, r: ^ipc.Wire_Reader) {
	s := _target(c, vi, r, true, false)
	if s == nil || _no_program(c, vi, s) do return
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
	s.gen += 1 // the screen reflowed
	_ = terminal.terminal_consume_damage(&s.sess.term)
	_ok(c, vi)
}

// core_viewer_observe pulls an atomic, zero-side-effect snapshot of another session.
core_viewer_observe :: proc(c: ^Core, vi: int, r: ^ipc.Wire_Reader) {
	id, lines := ipc.wr_u32(r), ipc.wr_u32(r)
	if !ipc.wr_done(r) {
		core_viewer_fail(c, vi, 0, .Bad_Request, "malformed observe request")
		return
	}
	s := core_session_find(c, id)
	if s == nil {
		core_viewer_fail(c, vi, 0, .Not_Found, "no such session")
		return
	}

	clear(&c.text)
	b := strings.Builder{buf = c.text}
	terminal.terminal_text(&s.sess.term, &b, int(min(lines, CORE_PAINT_HISTORY_MAX)))
	c.text = b.buf

	cols := u16(s.sess.term.grid.col_count)
	rows := u16(s.sess.term.grid.row_count)
	is_alt := terminal.terminal_in_alt_screen(&s.sess.term)

	ps: ipc.Prompt_State = .None
	switch s.sess.term.parser.prompt_state {
	case .Prompt:    ps = .Prompt
	case .Input:     ps = .Input
	case .Executing: ps = .Executing
	case .None:      ps = .None
	}

	title_buf: [256]u8
	row := core_row_get(c, s, title_buf[:])
	max_text_len := max(0, ipc.STREAM_MAX_PAYLOAD - 4096)
	text_len := min(len(c.text), max_text_len)
	text_slice := c.text[len(c.text) - text_len:]

	res := ipc.Observe_Result{
		row           = row,
		cols          = cols,
		rows          = rows,
		is_alt        = is_alt,
		prompt_state  = ps,
		has_cmd_exit  = s.sess.term.parser.has_cmd_exit,
		cmd_exit_code = s.sess.term.parser.last_cmd_exit,
		cmd_seq       = s.sess.term.parser.cmd_seq,
		text          = string(text_slice),
	}

	w := ipc.wire_writer(c.msg)
	ipc.enc_observe_result(&w, res)
	payload := ipc.wire_bytes_written(&w)
	ipc.stream_send(&c.viewers[vi].conn, ipc.MSG_OBSERVE_RESULT, 0, payload)
}

// _target reads the session id and answers FAIL when the session is unknown,
// or (live) has exited.
@(private)
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

// _no_program fails a request that needs a program when s is an endpoint.
@(private)
_no_program :: proc(c: ^Core, vi: int, s: ^Core_Session) -> bool {
	if !s.endpoint.used do return false
	core_viewer_fail(c, vi, 0, .Bad_Request, "an endpoint runs no program: talk to it with tell")
	return true
}

@(private)
_ok :: proc(c: ^Core, vi: int) {
	ipc.stream_send(&c.viewers[vi].conn, ipc.MSG_OK, 0)
}
