package feature_session_core

// Channel 0 requests: each handler reads its body with ipc.request_decode
// (a body that does not decode is answered Bad_Request by the package) and
// answers exactly once, now or later from a record that keeps the Request.

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
// read`). A full-screen program keeps its history itself: asking for history
// starts a stitch, and MSG_TEXT follows when the core has scrolled it.
@(private = "file")
_read :: proc(c: ^Core, req: ^ipc.Request) {
	m: proto.Read_Request
	if !ipc.request_decode(req, &m, proto.dec_read_req) do return
	s := core_session_find(c, m.id)
	if s == nil {
		core_viewer_fail(c, req, .Not_Found, "no such session")
		return
	}
	if m.history > 0 && terminal.terminal_in_alt_screen(&s.sess.term) && core_lease_fail(c, s, req) do return
	start := core_stitch_begin(c, s, req, int(m.history))
	switch start {
	case .Started:
		return // MSG_TEXT comes from the stitch
	case .Busy:
		core_viewer_fail(c, req, .Busy, "this session's history is already being read")
		return
	case .Screen, .Screen_Marked:
	}
	clear(&c.text)
	b := strings.Builder{buf = c.text}
	terminal.terminal_text(&s.sess.term, &b, int(min(m.history, CORE_PAINT_HISTORY_MAX)))
	// A full-screen program that does not report the mouse cannot be scrolled:
	// say so instead of pretending the screen is its history.
	if start == .Screen_Marked do strings.write_string(&b, CORE_READ_ALT_NOTE)
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
