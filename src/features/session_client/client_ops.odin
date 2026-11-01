package feature_session_client

// UI-thread API: create/attach/detach/kill/list and draining core events.

import "core:sync"
import ipc "../../platform/ipc"
import session "../session"

Client_Event_Kind :: enum u8 { None, Attached, Failed, Closed, Row, Removed, Sessions, Ok, Core_Lost }

// Client_Event: strings and payload are views into the client's scratch,
// valid until the next client_poll.
Client_Event :: struct {
	kind:     Client_Event_Kind,
	link:     ^Client_Link,
	code:     ipc.Fail_Code,
	reason:   string,
	row:      ipc.Session_Row,
	id:       u32,
	sessions: ipc.Wire_Reader, // .Sessions: positioned after the count; decode `count` rows
	count:    int,
}

// client_create asks the core to start a program; the returned session shows
// it once the core attaches (input typed before that is held, then sent).
client_create :: proc(c: ^Client, spec: ^ipc.Spawn_Msg) -> ^session.Terminal_Session {
	msg: [16 * 1024]u8
	w := ipc.wire_writer(msg[:])
	l := _new_link(c, spec.size)
	if l == nil do return nil
	ipc.ww_u32(&w, l.token)
	ipc.enc_spawn(&w, spec)
	if !w.ok || !_send(c, ipc.MSG_CREATE, 0, ipc.wire_bytes_written(&w)) {
		_free_link(l)
		return nil
	}
	return l.sess
}

client_attach :: proc(c: ^Client, id: u32, size: ipc.Size_Msg, history: u32) -> ^session.Terminal_Session {
	l := _new_link(c, size)
	if l == nil do return nil
	msg: [64]u8
	w := ipc.wire_writer(msg[:])
	ipc.ww_u32(&w, l.token)
	ipc.enc_attach(&w, {id = id, size = size, history = history})
	if !_send(c, ipc.MSG_ATTACH, 0, ipc.wire_bytes_written(&w)) {
		_free_link(l)
		return nil
	}
	return l.sess
}

// client_release stops showing sess. kill = end its program too; otherwise it
// keeps running in the core (a background session).
client_release :: proc(c: ^Client, sess: ^session.Terminal_Session, kill: bool) {
	l := client_link_of(c, sess)
	if l == nil do return
	sync.mutex_lock(&c.mutex)
	id, channel, state := l.id, l.channel, l.state
	if state == .Pending {
		// The core has not answered yet: the IO thread undoes it on ATTACHED.
		l.cancelled, l.cancel_kill, l.state = true, kill, .Closed
		sess := l.sess
		l.sess = nil
		sync.mutex_unlock(&c.mutex)
		session.session_destroy(sess)
		return
	}
	l.state = .Closed // DATA still in flight for the channel is dropped
	sync.mutex_unlock(&c.mutex)
	ch := _u32(channel)
	if kill && state == .Attached do client_kill(c, id)
	else if state == .Attached do _send(c, ipc.MSG_DETACH, 0, ch[:])
	_free_link(l)
}

client_kill :: proc(c: ^Client, id: u32) -> bool {
	b := _u32(id)
	return _send(c, ipc.MSG_KILL, 0, b[:])
}
client_list :: proc(c: ^Client) -> bool { return _send(c, ipc.MSG_LIST, 0) }

client_link_of :: proc(c: ^Client, sess: ^session.Terminal_Session) -> ^Client_Link {
	for &l in c.links do if l.state != .Free && l.sess == sess do return &l
	return nil
}

client_session_id :: proc(c: ^Client, sess: ^session.Terminal_Session) -> u32 {
	l := client_link_of(c, sess)
	return l.id if l != nil else 0
}

// client_poll takes the next event the IO thread queued (views valid until the
// next call). false = none left. A Failed/Closed link's session is marked not
// alive here, so whoever shows it reaps it like an exited program.
client_poll :: proc(c: ^Client, ev: ^Client_Event) -> bool {
	scratch := c.scratch
	ev^ = {}
	if sync.atomic_load(&c.broken) {
		sync.atomic_store(&c.broken, false)
		ev.kind = .Core_Lost
		return true
	}
	sync.mutex_lock(&c.mutex)
	hdr: [ipc.STREAM_HEADER]u8
	got := c.ctl_inbox.len >= ipc.STREAM_HEADER && ipc.ring_pop(&c.ctl_inbox, hdr[:]) == ipc.STREAM_HEADER
	kind, channel, length, _ := ipc.stream_parse_header(hdr[:])
	n := ipc.ring_pop(&c.ctl_inbox, scratch[:min(length, len(scratch))]) if got else 0
	sync.mutex_unlock(&c.mutex)
	if !got do return false
	_decode_event(c, ev, kind, channel, scratch[:n])
	if (ev.kind == .Failed || ev.kind == .Closed) && ev.link != nil && ev.link.sess != nil {
		ev.link.sess.info.alive = false
	}
	return true
}

// client_pump drains every queued event (hosts that show no session list).
client_pump :: proc(c: ^Client) {
	ev: Client_Event
	for client_poll(c, &ev) {
		if ev.kind == .Core_Lost do client_reconnect(c)
	}
}

// client_spawn starts config's program as a new session (Session_Provider.spawn).
client_spawn :: proc(c: ^Client, config: session.Session_Config) -> ^session.Terminal_Session {
	spec: ipc.Spawn_Msg
	if len(config.argv) > 0 {
		spec.argc = min(len(config.argv), ipc.STREAM_MAX_ARGV)
		for i in 0..<spec.argc do spec.argv[i] = config.argv[i]
	} else {
		spec.argv[0], spec.argc = config.shell, 1
	}
	spec.cwd = config.cwd
	spec.size = session.session_config_size(config)
	return client_create(c, &spec)
}

// client_provider runs panes' programs as core sessions.
client_provider :: proc(c: ^Client) -> session.Session_Provider {
	return {
		spawn = proc(user: rawptr, config: session.Session_Config) -> ^session.Terminal_Session {
			return client_spawn((^Client)(user), config)
		},
		release = proc(user: rawptr, sess: ^session.Terminal_Session, kill: bool) {
			client_release((^Client)(user), sess, kill)
		},
		user = c,
	}
}

@(private = "file")
_decode_event :: proc(c: ^Client, ev: ^Client_Event, kind: u8, channel: u32, p: []u8) {
	r := ipc.wire_reader(p)
	switch kind {
	case ipc.MSG_ATTACHED:
		token := ipc.wr_u32(&r)
		ev.kind, ev.link = .Attached, _link_by_token(c, token)
	case ipc.MSG_FAIL:
		token := ipc.wr_u32(&r)
		ev.kind, ev.link, ev.code, ev.reason = .Failed, _link_by_token(c, token), ipc.Fail_Code(ipc.wr_u8(&r)), ipc.wr_str(&r)
	case ipc.STREAM_CLOSE:
		ev.kind, ev.link, ev.reason = .Closed, _link_by_channel(c, channel), string(p)
	case ipc.MSG_EVENT:
		ev.kind, ev.row = .Row, ipc.dec_row(&r)
	case ipc.MSG_REMOVED:
		ev.kind, ev.id = .Removed, ipc.wr_u32(&r)
	case ipc.MSG_SESSIONS:
		ev.kind, ev.count = .Sessions, int(ipc.wr_u32(&r))
		ev.sessions = r
	case ipc.MSG_OK:
		ev.kind = .Ok
	}
}

@(private = "file")
_link_by_token :: proc(c: ^Client, token: u32) -> ^Client_Link {
	if token == 0 do return nil
	for &l in c.links do if l.state != .Free && l.token == token do return &l
	return nil
}

@(private = "file")
_new_link :: proc(c: ^Client, size: ipc.Size_Msg) -> ^Client_Link {
	for &l in c.links {
		if l.state != .Free do continue
		c.next_token += 1
		l = {state = .Pending, token = c.next_token, client = c}
		l.sess = session.session_create(size, {write = _link_write, resize = _link_resize, consumed = _link_consumed, user = &l})
		return &l
	}
	return nil
}

@(private = "file")
_free_link :: proc(l: ^Client_Link) {
	if l.sess != nil do session.session_destroy(l.sess)
	c := l.client // l^ = {} clears it
	sync.mutex_lock(&c.mutex)
	l^ = {}
	sync.mutex_unlock(&c.mutex)
}

@(private)
_send :: proc(c: ^Client, kind: u8, channel: u32, parts: ..[]u8) -> bool {
	sync.mutex_lock(&c.mutex)
	ok := ipc.stream_send(&c.conn, kind, channel, ..parts)
	sync.mutex_unlock(&c.mutex)
	_poke(c)
	return ok
}

@(private = "file")
_u32 :: proc(v: u32) -> [4]u8 {
	b: [4]u8
	w := ipc.wire_writer(b[:])
	ipc.ww_u32(&w, v)
	return b
}
