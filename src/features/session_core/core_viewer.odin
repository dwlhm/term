package feature_session_core

// Viewer and CLI connections: handshake, control requests on channel 0,
// attach-channel frames, and cleanup when a viewer goes away.

import "core:strings"
import "core:sys/posix"
import terminal "../../core/terminal"
import ipc "../../platform/ipc"

core_viewer_service :: proc(c: ^Core, vi: int, rev: posix.Poll_Event) {
	v := &c.viewers[vi]
	if .OUT in rev do ipc.stream_flush(&v.conn)
	gone := ipc.stream_fill(&v.conn) != .None
	for f in ipc.stream_next(&v.conn) {
		if !_viewer_frame(c, vi, f) {
			gone = true
			break
		}
	}
	if gone || v.conn.err != .None do _viewer_drop(c, vi)
}

// _viewer_drop: its attachments end; its sessions keep running (background),
// unless the session dir is owned and this was the owner's last viewer link:
// the kernel closes it however the owner ended, and nobody else can show them.
@(private = "file")
_viewer_drop :: proc(c: ^Core, vi: int) {
	for &s in c.sessions {
		if !s.used do continue
		for &a in s.attaches do if a.used && a.viewer == vi do core_detach(c, &s, &a, false)
	}
	was_viewer := c.viewers[vi].hello && c.viewers[vi].role == .Viewer
	core_watchers_cancel_viewer(c, vi)
	core_settles_cancel_viewer(c, vi)
	broker_viewer_gone(&c.broker, vi)
	core_broker_apply(c)
	core_endpoints_owner_gone(c, vi)
	ipc.stream_conn_destroy(&c.viewers[vi].conn)
	c.viewers[vi] = {}
	if c.owned && was_viewer && !_any_viewer(c) do for &s in c.sessions do if s.used do core_session_kill(c, &s)
}

@(private = "file")
_any_viewer :: proc(c: ^Core) -> bool {
	for &v in c.viewers do if v.used && v.hello && v.role == .Viewer do return true
	return false
}

// _viewer_frame: false = protocol violation (the connection is dropped).
@(private = "file")
_viewer_frame :: proc(c: ^Core, vi: int, f: ipc.Stream_Frame) -> bool {
	v := &c.viewers[vi]
	if !v.hello {
		if f.kind != ipc.MSG_HELLO do return false
		m, code, ok := ipc.stream_hello_check(f.payload, {.Viewer, .Cli})
		if !ok {
			core_viewer_fail(c, vi, 0, code, "unsupported protocol version or role")
			ipc.stream_flush(&v.conn)
			return false
		}
		v.hello, v.role = true, m.role
		w := ipc.wire_writer(c.msg)
		ipc.enc_hello(&w, {version = ipc.STREAM_PROTO_VERSION, role = .Core, build = c.build})
		ipc.stream_send(&v.conn, ipc.MSG_HELLO, 0, ipc.wire_bytes_written(&w))
		return true
	}
	if f.channel != 0 {
		core_attach_frame(c, vi, f)
		return true
	}
	r := ipc.wire_reader(f.payload)
	switch f.kind {
	case ipc.MSG_LIST:   core_list_request(c, vi)
	case ipc.MSG_CREATE: _create(c, vi, &r)
	case ipc.MSG_ATTACH: _attach(c, vi, &r)
	case ipc.MSG_KILL:   core_viewer_kill(c, vi, &r)
	case ipc.MSG_OBSERVE: core_viewer_observe(c, vi, &r)
	case ipc.MSG_READ:   _read(c, vi, &r)
	case ipc.MSG_SEND:   core_viewer_send(c, vi, &r)
	case ipc.MSG_TELL:   core_viewer_tell(c, vi, &r)
	case ipc.MSG_CANCEL: core_viewer_cancel(c, vi, &r)
	case ipc.MSG_NEXT:     core_viewer_next(c, vi, &r)
	case ipc.MSG_ANSWER:   core_viewer_answer(c, vi, &r, true)
	case ipc.MSG_PROGRESS: core_viewer_answer(c, vi, &r, false)
	case ipc.MSG_RESULT:   core_viewer_result(c, vi, &r)
	case ipc.MSG_ENDPOINT: core_viewer_endpoint(c, vi, &r)
	case ipc.MSG_WATCH:      core_viewer_watch(c, vi, &r)
	case ipc.MSG_SNAPSHOT:   core_viewer_snapshot(c, vi, &r)
	case ipc.MSG_SETTLE:     core_viewer_settle(c, vi, &r)
	case ipc.MSG_ACT:        core_viewer_act(c, vi, &r)
	case ipc.MSG_SESSION_SIGNAL: core_viewer_signal(c, vi, &r)
	case ipc.MSG_SESSION_SIZE:   core_viewer_resize(c, vi, &r)
	case ipc.MSG_DETACH:
		if s, a := core_attach_find(c, vi, ipc.wr_u32(&r)); s != nil do core_detach(c, s, a, true)
	case:
		return false
	}
	return true
}

@(private = "file")
_create :: proc(c: ^Core, vi: int, r: ^ipc.Wire_Reader) {
	token := ipc.wr_u32(r)
	spec_payload := r.buf[r.off:]
	spec: ipc.Spawn_Msg
	ipc.dec_spawn(r, &spec)
	if !ipc.wr_done(r) {
		core_viewer_fail(c, vi, token, .Bad_Request, "malformed spawn request")
		return
	}
	s := core_session_create(c, spec_payload, spec.size)
	if s == nil {
		core_viewer_fail(c, vi, token, .Spawn_Failed, "no holder or no free session slot")
		return
	}
	channel, ok := core_attach(c, s, vi, {id = s.id, size = spec.size})
	if !ok {
		core_viewer_fail(c, vi, token, .Busy, "no free attach slot")
		return
	}
	_attached(c, vi, token, s.id, channel)
}

@(private = "file")
_attach :: proc(c: ^Core, vi: int, r: ^ipc.Wire_Reader) {
	token := ipc.wr_u32(r)
	req := ipc.dec_attach(r)
	if !ipc.wr_done(r) {
		core_viewer_fail(c, vi, token, .Bad_Request, "malformed attach request")
		return
	}
	s := core_session_find(c, req.id)
	switch {
	case s == nil:  core_viewer_fail(c, vi, token, .Not_Found, "no such session")
	case s.exited:  core_viewer_fail(c, vi, token, .Exited, "session has exited")
	case:
		channel, ok := core_attach(c, s, vi, req)
		if !ok do core_viewer_fail(c, vi, token, .Busy, "too many viewers on this session")
		else {
			_attached(c, vi, token, s.id, channel)
			core_broadcast_row(c, s)
		}
	}
}

// _read answers the plain text of a session's screen (agents: `term session
// read`). A full-screen program keeps its history itself: asking for history
// starts a stitch, and MSG_TEXT follows when the core has scrolled it.
@(private = "file")
_read :: proc(c: ^Core, vi: int, r: ^ipc.Wire_Reader) {
	id, history := ipc.wr_u32(r), ipc.wr_u32(r)
	s := core_session_find(c, id)
	if !ipc.wr_done(r) || s == nil {
		core_viewer_fail(c, vi, 0, .Not_Found, "no such session")
		return
	}
	start := core_stitch_begin(c, s, vi, int(history))
	switch start {
	case .Started:
		return // MSG_TEXT comes from the stitch
	case .Busy:
		core_viewer_fail(c, vi, 0, .Busy, "this session's history is already being read")
		return
	case .Screen, .Screen_Marked:
	}
	clear(&c.text)
	b := strings.Builder{buf = c.text}
	terminal.terminal_text(&s.sess.term, &b, int(min(history, CORE_PAINT_HISTORY_MAX)))
	// A full-screen program that does not report the mouse cannot be scrolled:
	// say so instead of pretending the screen is its history.
	if start == .Screen_Marked do strings.write_string(&b, CORE_READ_ALT_NOTE)
	c.text = b.buf
	n := min(len(c.text), ipc.STREAM_MAX_PAYLOAD)
	ipc.stream_send(&c.viewers[vi].conn, ipc.MSG_TEXT, 0, c.text[len(c.text) - n:])
}

@(private = "file")
_attached :: proc(c: ^Core, vi: int, token, id, channel: u32) {
	b: [12]u8
	w := ipc.wire_writer(b[:])
	ipc.ww_u32(&w, token); ipc.ww_u32(&w, id); ipc.ww_u32(&w, channel)
	// Control frames go out before stream data: ATTACHED precedes the first paint.
	ipc.stream_send(&c.viewers[vi].conn, ipc.MSG_ATTACHED, 0, b[:])
}

// core_viewer_fail answers a request with MSG_FAIL.
core_viewer_fail :: proc(c: ^Core, vi: int, token: u32, code: ipc.Fail_Code, reason: string) {
	w := ipc.wire_writer(c.msg)
	ipc.ww_u32(&w, token)
	ipc.ww_u8(&w, u8(code))
	ipc.ww_str(&w, reason)
	ipc.stream_send(&c.viewers[vi].conn, ipc.MSG_FAIL, 0, ipc.wire_bytes_written(&w))
}

// core_viewer_current: the connection in that slot is still the one with seq
// (a long request, a stitch, may outlive its connection).
core_viewer_current :: proc(c: ^Core, vi: int, seq: u32) -> bool {
	if vi < 0 || vi >= CORE_MAX_VIEWERS do return false
	v := &c.viewers[vi]
	return v.used && v.hello && v.seq == seq
}

// core_viewer_fail_seq answers a request that was accepted earlier.
core_viewer_fail_seq :: proc(c: ^Core, vi: int, seq: u32, code: ipc.Fail_Code, reason: string) {
	if !core_viewer_current(c, vi, seq) do return
	core_viewer_fail(c, vi, 0, code, reason)
}
