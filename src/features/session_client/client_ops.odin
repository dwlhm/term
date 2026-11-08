package feature_session_client

// UI-thread API: create/attach/release/kill/list, queued for the IO thread,
// and draining the events it queued.

import "core:sync"
import proto "../session_proto"
import ipc "../../platform/ipc"
import session "../session"

Client_Event_Kind :: enum u8 { None, Attached, Failed, Closed, Row, Removed, Sessions, Ok, Core_Lost }

// Client_Event: strings and payload are views into the client's scratch,
// valid until the next client_poll.
Client_Event :: struct {
	kind:     Client_Event_Kind,
	link:     ^Client_Link,
	code:     proto.Fail_Code,
	reason:   string,
	row:      proto.Session_Row,
	id:       u32,
	sessions: ipc.Wire_Reader, // .Sessions: positioned after the count; decode `count` rows
	count:    int,
}

// client_create asks the core to start a program; the returned session shows
// it once the core attaches (input typed before that is held, then sent).
client_create :: proc(c: ^Client, spec: ^proto.Spawn_Msg) -> ^session.Terminal_Session {
	msg: [16 * 1024]u8
	w := ipc.wire_writer(msg[:])
	proto.enc_spawn(&w, spec)
	l := _new_link(c, spec.size) if w.ok else nil
	if l == nil do return nil
	if !_enqueue(c, .Create, _link_key(c, l), ipc.wire_bytes_written(&w)) {
		_free_link(l)
		return nil
	}
	return l.sess
}

// client_attach shows session req.id. An observing attachment never owns the size.
client_attach :: proc(c: ^Client, req: proto.Attach_Msg) -> ^session.Terminal_Session {
	l := _new_link(c, req.size)
	if l == nil do return nil
	l.observe = req.observe
	if !_send_attach(c, l, req) {
		_free_link(l)
		return nil
	}
	return l.sess
}

@(private)
_send_attach :: proc(c: ^Client, l: ^Client_Link, req: proto.Attach_Msg) -> bool {
	msg: [64]u8
	w := ipc.wire_writer(msg[:])
	proto.enc_attach(&w, req)
	return _enqueue(c, .Attach, _link_key(c, l), ipc.wire_bytes_written(&w))
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
		l.cancelled, l.cancel_kill, l.state, l.sess = true, kill, .Closed, nil
		sync.mutex_unlock(&c.mutex)
		session.session_destroy(sess)
		return
	}
	l.state = .Closed // DATA still in flight for the channel is dropped
	sync.mutex_unlock(&c.mutex)
	if state == .Attached {
		b: [9]u8
		w := ipc.wire_writer(b[:])
		ipc.ww_bool(&w, kill); ipc.ww_u32(&w, id); ipc.ww_u32(&w, channel)
		_enqueue(c, .Release, _NO_LINK, b[:])
	}
	_free_link(l)
}

client_kill :: proc(c: ^Client, id: u32) -> bool {
	b := _u32(id)
	return _enqueue(c, .Kill, _NO_LINK, b[:])
}

client_list :: proc(c: ^Client) -> bool { return _enqueue(c, .List, _NO_LINK) }

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
	ev^ = {}
	if sync.atomic_load(&c.broken) || sync.atomic_load(&c.overflow) {
		sync.atomic_store(&c.broken, false)
		ev.kind = .Core_Lost
		return true
	}
	sync.mutex_lock(&c.mutex)
	kind, key, body, got := _rec_pop(&c.events, c.scratch)
	if got do ev.link = _link_of_key(c, key)
	sync.mutex_unlock(&c.mutex)
	if !got do return false
	_decode_event(ev, Client_Event_Kind(kind), body)
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
	spec: proto.Spawn_Msg
	if len(config.argv) > 0 {
		spec.argc = min(len(config.argv), proto.STREAM_MAX_ARGV)
		for i in 0..<spec.argc do spec.argv[i] = config.argv[i]
	} else if len(config.shell) > 0 {
		spec.argv[0], spec.argv[1], spec.argc = config.shell, "-l", 2 // a shell tab is a login shell
	} else {
		spec.argv[0], spec.argc = "", 1 // the holder's default: $SHELL as a login shell
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
_decode_event :: proc(ev: ^Client_Event, kind: Client_Event_Kind, p: []u8) {
	ev.kind = kind
	r := ipc.wire_reader(p)
	#partial switch kind {
	case .Failed:
		ev.code = proto.Fail_Code(ipc.wr_u8(&r))
		ev.reason = string(p[1:]) if len(p) > 0 else ""
	case .Closed:   ev.reason = string(p)
	case .Row:      ev.row = proto.dec_row(&r)
	case .Removed:  ev.id = ipc.wr_u32(&r)
	case .Sessions:
		ev.count = int(ipc.wr_u32(&r))
		ev.sessions = r
	}
}

@(private = "file")
_new_link :: proc(c: ^Client, size: proto.Size_Msg) -> ^Client_Link {
	sync.mutex_lock(&c.mutex)
	defer sync.mutex_unlock(&c.mutex)
	for &l in c.links {
		if l.state != .Free do continue
		l = {state = .Pending, client = c, gen = (l.gen + 1) & 0xFF_FFFF}
		l.sess = session.session_create(size, {write = _link_write, reply = _link_reply, resize = _link_resize, consumed = _link_consumed, user = &l})
		return &l
	}
	return nil
}

@(private)
_free_link :: proc(l: ^Client_Link) {
	if l.sess != nil do session.session_destroy(l.sess)
	c := l.client // l^ = {} clears it
	sync.mutex_lock(&c.mutex)
	l^ = {gen = l.gen} // the slot remembers its use: a stale record finds no link
	sync.mutex_unlock(&c.mutex)
}
