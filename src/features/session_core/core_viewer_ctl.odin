package feature_session_core

// Channel-0 requests that act on one session by id without attaching
// (agents: `term session kill|send|signal|resize|observe`). Each answers OK, FAIL or a result.

import "core:fmt"
import "core:strings"
import "core:time"
import proto "../session_proto"
import ipc "../../platform/ipc"
import session "../session"
import terminal "../../core/terminal"

core_viewer_kill :: proc(c: ^Core, req: ^ipc.Request) {
	id: u32
	if !ipc.request_decode(req, &id, proto.dec_id) do return
	s := _target(c, req, id, false)
	if s == nil do return
	core_session_kill(c, s)
	_ok(c, req)
}

// core_viewer_send types bytes into a session: like a person typing.
core_viewer_send :: proc(c: ^Core, req: ^ipc.Request) {
	m: proto.Send_Request
	if !ipc.request_decode(req, &m, proto.dec_send_req) do return
	s := _target(c, req, m.id, true)
	if s == nil || _no_program(c, req, s) || core_lease_fail(c, s, req) do return
	s.input_gen = s.gen
	core_broker_human_input(c, s, m.bytes)
	core_holder_send(c, s.holder, proto.MSG_INPUT, s.id, m.bytes)
	_ok(c, req)
}

// core_viewer_signal: the holder delivers it like ^C, to the foreground group.
core_viewer_signal :: proc(c: ^Core, req: ^ipc.Request) {
	m: proto.Signal_Request
	if !ipc.request_decode(req, &m, proto.dec_signal_req) do return
	s := _target(c, req, m.id, true)
	if s == nil || _no_program(c, req, s) || core_lease_fail(c, s, req) do return
	if m.signal < 1 || m.signal > 64 {
		core_viewer_fail(c, req, .Bad_Request, "bad signal number")
		return
	}
	now := time.now()._nsec
	if m.signal == 2 {
		if s.last_sigint_ns != 0 && (now - s.last_sigint_ns) < 400 * 1_000_000 {
			_ok(c, req)
			return
		}
		s.last_sigint_ns = now
	}
	b := _i32_bytes(m.signal)
	core_holder_send(c, s.holder, proto.MSG_SIGNAL, s.id, b[:])
	_ok(c, req)
}

// core_viewer_resize sizes a session nobody shows: a window that shows it
// leads its size (core_apply_leader), so that request fails as Busy.
core_viewer_resize :: proc(c: ^Core, req: ^ipc.Request) {
	m: proto.Size_Request
	if !ipc.request_decode(req, &m, proto.dec_size_req) do return
	s := _target(c, req, m.id, true)
	if s == nil || core_lease_fail(c, s, req) do return
	size := m.size
	switch {
	case size.cols == 0 || size.rows == 0:
		core_viewer_fail(c, req, .Bad_Request, "bad size")
		return
	case s.stitch != nil && s.stitch.active:
		core_viewer_fail(c, req, .Busy, "this session's history is being read")
		return
	}
	for &a in s.attaches do if a.used && !a.observe {
		msg := fmt.tprintf("a window shows session %d: resize the pane", s.id)
		core_viewer_fail(c, req, .Busy, msg)
		return
	}
	session.session_resize(s.sess, size.cols, size.rows, size.xpixel, size.ypixel)
	s.gen += 1 // the screen reflowed
	_ = terminal.terminal_consume_damage(&s.sess.term)
	_ok(c, req)
}

@(private = "file")
_observe_pack_result :: proc(
	c: ^Core,
	s: ^Core_Session,
	title_buf: []u8,
) -> proto.Observe_Result {
	cols := u16(s.sess.term.grid.col_count)
	rows := u16(s.sess.term.grid.row_count)
	is_alt := terminal.terminal_in_alt_screen(&s.sess.term)
	ps := proto.Prompt_State(s.sess.term.parser.prompt_state)
	row := core_row_get(c, s, title_buf)
	max_len := max(0, CORE_ANSWER_MAX - 4096)
	text_len := min(len(c.text), max_len)
	text_slice := c.text[len(c.text) - text_len:]
	return {
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
}

// core_viewer_observe pulls an atomic, zero-side-effect snapshot of session.
core_viewer_observe :: proc(c: ^Core, req: ^ipc.Request) {
	m: proto.Observe_Request
	if !ipc.request_decode(req, &m, proto.dec_observe_req) do return
	s := _target(c, req, m.id, false)
	if s == nil do return

	clear(&c.text)
	b := strings.Builder{buf = c.text}
	h_max := int(min(m.lines, CORE_PAINT_HISTORY_MAX))
	terminal.terminal_text(&s.sess.term, &b, h_max)
	c.text = b.buf

	title_buf: [256]u8
	res := _observe_pack_result(c, s, title_buf[:])
	w := ipc.wire_writer(c.msg)
	proto.enc_observe_result(&w, res)
	ipc.reply(&c.srv, req^, ipc.wire_bytes_written(&w))
}

// _target finds session id and answers FAIL when it is unknown, or (live)
// has exited.
@(private)
_target :: proc(c: ^Core, req: ^ipc.Request, id: u32, live: bool) -> ^Core_Session {
	s := core_session_find(c, id)
	switch {
	case s == nil:            core_viewer_fail(c, req, .Not_Found, "no such session")
	case live && s.exited:    core_viewer_fail(c, req, .Exited, "session has exited")
	case:                     return s
	}
	return nil
}

// _no_program fails a request that needs a program when s is an endpoint.
@(private)
_no_program :: proc(c: ^Core, req: ^ipc.Request, s: ^Core_Session) -> bool {
	if !s.endpoint.used do return false
	core_viewer_fail(c, req, .Bad_Request, "an endpoint runs no program: talk to it with tell")
	return true
}
