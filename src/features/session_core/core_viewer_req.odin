package feature_session_core

// Channel 0 requests: each handler reads its body with ipc.request_decode
// (a body that does not decode is answered Bad_Request by the package) and
// answers exactly once, now or later from a record that keeps the Request.

import "core:fmt"
import "core:strings"
import terminal "../../core/terminal"
import proto "../session_proto"
import ipc "../../platform/ipc"

core_viewer_request :: proc(c: ^Core, req: ^ipc.Request) {
	switch req.kind {
	case proto.MSG_LIST:           core_list_request(c, req)
	case proto.MSG_CREATE:         _create(c, req)
	case proto.MSG_ATTACH:         _attach(c, req)
	case proto.MSG_KILL:           core_viewer_kill(c, req)
	case proto.MSG_SHUTDOWN:       core_viewer_shutdown(c, req)
	case proto.MSG_OBSERVE:        core_viewer_observe(c, req)
	case proto.MSG_READ:           _read(c, req)
	case proto.MSG_SEND:           core_viewer_send(c, req)
	case proto.MSG_TELL:           core_viewer_tell(c, req)
	case proto.MSG_CANCEL:         core_viewer_cancel(c, req)
	case proto.MSG_NEXT:           core_viewer_next(c, req)
	case proto.MSG_ANSWER:         core_viewer_answer(c, req, true)
	case proto.MSG_PROGRESS:       core_viewer_answer(c, req, false)
	case proto.MSG_RESULT:         core_viewer_result(c, req)
	case proto.MSG_ENDPOINT:       core_viewer_endpoint(c, req)
	case proto.MSG_WATCH:          core_viewer_watch(c, req)
	case proto.MSG_SNAPSHOT:       core_viewer_snapshot(c, req)
	case proto.MSG_SETTLE:         core_viewer_settle(c, req)
	case proto.MSG_ACT:            core_viewer_act(c, req)
	case proto.MSG_LEASE:          core_viewer_lease(c, req)
	case proto.MSG_LEASE_RELEASE:  core_viewer_lease_release(c, req)
	case proto.MSG_LEASE_MODE:     core_viewer_lease_mode(c, req)
	case proto.MSG_ELEMENTS:       core_viewer_elements(c, req)
	case proto.MSG_SESSION_SIGNAL: core_viewer_signal(c, req)
	case proto.MSG_SESSION_SIZE:   core_viewer_resize(c, req)
	case: // the package lets only catalog kinds through
	}
}

@(private = "file")
_create :: proc(c: ^Core, req: ^ipc.Request) {
	m: proto.Create_Request
	if !ipc.request_decode(req, &m, proto.dec_create) do return
	s := core_session_create(c, m.raw, m.spec.size)
	if s == nil {
		core_viewer_fail(c, req, .Spawn_Failed, "no holder or no free session slot")
		return
	}
	if !core_attach(c, s, req, {id = s.id, size = m.spec.size}) do core_viewer_fail(c, req, .Busy, "no free attach slot")
}

@(private = "file")
_attach :: proc(c: ^Core, req: ^ipc.Request) {
	m: proto.Attach_Msg
	if !ipc.request_decode(req, &m, proto.dec_attach) do return
	s := core_session_find(c, m.id)
	switch {
	case s == nil:                   core_viewer_fail(c, req, .Not_Found, "no such session")
	case s.exited:                   core_viewer_fail(c, req, .Exited, "session has exited")
	case !core_attach(c, s, req, m): core_viewer_fail(c, req, .Busy, "too many viewers on this session")
	case:                            core_broadcast_row(c, s)
	}
}

// _read answers the plain text of a session's screen (agents: `term session
// read`). Invariant S1: read never alters session, size, scroll or focus.
@(private = "file")
_read :: proc(c: ^Core, req: ^ipc.Request) {
	m: proto.Read_Request
	if !ipc.request_decode(req, &m, proto.dec_read_req) do return
	s := core_session_find(c, m.id)
	if s == nil {
		core_viewer_fail(c, req, .Not_Found, "no such session")
		return
	}
	defer free_all(context.temp_allocator)

	if m.last {
		_read_last(c, s, req)
	} else {
		_read_screen(c, s, req, m.history)
	}
}

@(private = "file")
_read_last :: proc(c: ^Core, s: ^Core_Session, req: ^ipc.Request) {
	p := &s.sess.term.parser
	if !p.saw_osc133 {
		msg := fmt.tprintf("session %d does not mark commands (OSC 133)", s.id)
		core_viewer_fail(c, req, .Bad_Request, msg)
		return
	}
	if !p.cmd_out.started {
		core_viewer_fail(c, req, .Bad_Request, "no command has run yet")
		return
	}

	clear(&c.text)
	b := strings.Builder{buf = c.text}
	to_cursor := !p.cmd_out.ended
	_, head_lost := terminal.terminal_cmd_output(&s.sess.term, &b, to_cursor)
	if head_lost {
		g := &s.sess.term.grid
		from := int(p.cmd_out.start - g.scrolled)
		truncated := -g.history_count - from
		if truncated > 0 {
			prefix := fmt.tprintf("[truncated %d lines]\n", truncated)
			temp := strings.clone(string(b.buf[:]), context.temp_allocator)
			clear(&b.buf)
			strings.write_string(&b, prefix)
			strings.write_string(&b, temp)
		}
	}
	if len(b.buf) > 0 && b.buf[len(b.buf) - 1] != '\n' {
		strings.write_byte(&b, '\n')
	}
	if to_cursor {
		strings.write_string(&b, "[running]\n")
	} else {
		exit_code := p.last_cmd_exit if p.has_cmd_exit else 0
		fmt.sbprintf(&b, "[exit %d]\n", exit_code)
	}
	c.text = b.buf
	core_reply_text(c, req)
}

@(private = "file")
_read_screen :: proc(
	c: ^Core,
	s: ^Core_Session,
	req: ^ipc.Request,
	history: u32,
) {
	clear(&c.text)
	b := strings.Builder{buf = c.text}
	n := int(min(history, CORE_PAINT_HISTORY_MAX))
	terminal.terminal_text(&s.sess.term, &b, n)
	if s.exited {
		if len(b.buf) > 0 && b.buf[len(b.buf) - 1] != '\n' {
			strings.write_byte(&b, '\n')
		}
		fmt.sbprintf(&b, "[exited %d]\n", s.exit.code)
	}
	c.text = b.buf
	core_reply_text(c, req)
}

// core_reply_text answers MSG_READ with c.text (its tail when too long).
core_reply_text :: proc(c: ^Core, req: ^ipc.Request) {
	n := min(len(c.text), CORE_ANSWER_MAX)
	ipc.reply(&c.srv, req^, c.text[len(c.text) - n:])
}

@(private)
_ok :: proc(c: ^Core, req: ^ipc.Request) {
	ipc.reply(&c.srv, req^)
}
