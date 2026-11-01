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

// _viewer_drop: its attachments end; its sessions keep running (background).
@(private = "file")
_viewer_drop :: proc(c: ^Core, vi: int) {
	for &s in c.sessions {
		if !s.used do continue
		for &a in s.attaches do if a.used && a.viewer == vi do core_detach(c, &s, &a, false)
	}
	ipc.stream_conn_destroy(&c.viewers[vi].conn)
	c.viewers[vi] = {}
}

// _viewer_frame: false = protocol violation (the connection is dropped).
@(private = "file")
_viewer_frame :: proc(c: ^Core, vi: int, f: ipc.Stream_Frame) -> bool {
	v := &c.viewers[vi]
	if !v.hello {
		if f.kind != ipc.MSG_HELLO do return false
		m, code, ok := ipc.stream_hello_check(f.payload, {.Viewer, .Cli})
		if !ok {
			_fail(c, vi, 0, code, "unsupported protocol version or role")
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
	case ipc.MSG_KILL:   _kill(c, vi, ipc.wr_u32(&r))
	case ipc.MSG_READ:   _read(c, vi, &r)
	case ipc.MSG_SEND:   _send_input(c, vi, &r)
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
		_fail(c, vi, token, .Bad_Request, "malformed spawn request")
		return
	}
	s := core_session_create(c, spec_payload, spec.size)
	if s == nil {
		_fail(c, vi, token, .Spawn_Failed, "no holder or no free session slot")
		return
	}
	channel, ok := core_attach(c, s, vi, {id = s.id, size = spec.size})
	if !ok {
		_fail(c, vi, token, .Busy, "no free attach slot")
		return
	}
	_attached(c, vi, token, s.id, channel)
}

@(private = "file")
_attach :: proc(c: ^Core, vi: int, r: ^ipc.Wire_Reader) {
	token := ipc.wr_u32(r)
	req := ipc.dec_attach(r)
	if !ipc.wr_done(r) {
		_fail(c, vi, token, .Bad_Request, "malformed attach request")
		return
	}
	s := core_session_find(c, req.id)
	switch {
	case s == nil:  _fail(c, vi, token, .Not_Found, "no such session")
	case s.exited:  _fail(c, vi, token, .Exited, "session has exited")
	case:
		channel, ok := core_attach(c, s, vi, req)
		if !ok do _fail(c, vi, token, .Busy, "too many viewers on this session")
		else {
			_attached(c, vi, token, s.id, channel)
			core_broadcast_row(c, s)
		}
	}
}

@(private = "file")
_kill :: proc(c: ^Core, vi: int, id: u32) {
	s := core_session_find(c, id)
	if s == nil {
		_fail(c, vi, 0, .Not_Found, "no such session")
		return
	}
	core_session_kill(c, s)
	ipc.stream_send(&c.viewers[vi].conn, ipc.MSG_OK, 0)
}

// _read answers the plain text of a session's screen (agents: `term session read`).
@(private = "file")
_read :: proc(c: ^Core, vi: int, r: ^ipc.Wire_Reader) {
	id, history := ipc.wr_u32(r), ipc.wr_u32(r)
	s := core_session_find(c, id)
	if !ipc.wr_done(r) || s == nil {
		_fail(c, vi, 0, .Not_Found, "no such session")
		return
	}
	clear(&c.text)
	b := strings.Builder{buf = c.text}
	terminal.terminal_text(&s.sess.term, &b, int(min(history, CORE_PAINT_HISTORY_MAX)))
	c.text = b.buf
	n := min(len(c.text), ipc.STREAM_MAX_PAYLOAD)
	ipc.stream_send(&c.viewers[vi].conn, ipc.MSG_TEXT, 0, c.text[len(c.text) - n:])
}

// _send_input types bytes into a session without attaching (agents: `term session send`).
@(private = "file")
_send_input :: proc(c: ^Core, vi: int, r: ^ipc.Wire_Reader) {
	id := ipc.wr_u32(r)
	s := core_session_find(c, id)
	switch {
	case !r.ok || s == nil: _fail(c, vi, 0, .Not_Found, "no such session")
	case s.exited:          _fail(c, vi, 0, .Exited, "session has exited")
	case:
		core_holder_send(c, s.holder, ipc.MSG_INPUT, s.id, r.buf[r.off:])
		ipc.stream_send(&c.viewers[vi].conn, ipc.MSG_OK, 0)
	}
}

@(private = "file")
_attached :: proc(c: ^Core, vi: int, token, id, channel: u32) {
	b: [12]u8
	w := ipc.wire_writer(b[:])
	ipc.ww_u32(&w, token); ipc.ww_u32(&w, id); ipc.ww_u32(&w, channel)
	// Control frames go out before stream data: ATTACHED precedes the first paint.
	ipc.stream_send(&c.viewers[vi].conn, ipc.MSG_ATTACHED, 0, b[:])
}

@(private = "file")
_fail :: proc(c: ^Core, vi: int, token: u32, code: ipc.Fail_Code, reason: string) {
	w := ipc.wire_writer(c.msg)
	ipc.ww_u32(&w, token)
	ipc.ww_u8(&w, u8(code))
	ipc.ww_str(&w, reason)
	ipc.stream_send(&c.viewers[vi].conn, ipc.MSG_FAIL, 0, ipc.wire_bytes_written(&w))
}
