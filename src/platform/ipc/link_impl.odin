package platform_ipc

// What a Link holds behind its handle (spec 7.8): one Stream_Conn whose
// buffers are reserved at open and reattached to each new peer, the
// listener and pending HELLO slots on the listening side, and a small queue
// of Up/Down events in front of the frames. Peers that pass HELLO on the
// listening side replace the current one (link_pending.odin).

import "base:runtime"
import "core:sys/posix"
import "core:time"

@(private = "file")
_LINK_EVENTS :: 16

@(private)
_Link :: struct {
	set:       ^_Poll,
	proto:     Protocol,
	opts:      Link_Opts,
	listener:  _Listener,
	pending:   []_Pending,
	seq:       u64,
	conn:      Stream_Conn,
	conn_src:  u32,
	up:        bool, // HELLO done both ways
	closing:   bool, // the peer is gone: the frames still buffered go out first
	dialed:    bool,
	ended:     bool, // nothing more will come (a dial that went down, a broken listener)
	events:    [_LINK_EVENTS]Link_Event,
	ev_head:   int,
	ev_len:    int,
	allocator: runtime.Allocator,
}

@(private)
_link :: proc(l: ^Link) -> ^_Link { return (^_Link)(l._impl) }

// _link_push queues an Up/Down; a full queue drops its oldest event.
@(private)
_link_push :: proc(k: ^_Link, ev: Link_Event) {
	if k.ev_len == _LINK_EVENTS {
		k.ev_head = (k.ev_head + 1) % _LINK_EVENTS
		k.ev_len -= 1
	}
	k.events[(k.ev_head + k.ev_len) % _LINK_EVENTS] = ev
	k.ev_len += 1
}

@(private)
_link_pop :: proc(k: ^_Link) -> (ev: Link_Event, ok: bool) {
	if k.ev_len == 0 do return
	ev = k.events[k.ev_head]
	k.ev_head = (k.ev_head + 1) % _LINK_EVENTS
	k.ev_len -= 1
	return ev, true
}

// _link_attach makes fd the link's peer: the conn takes it (with what was
// already read), and its source watches it. due > 0 = HELLO deadline.
@(private)
_link_attach :: proc(k: ^_Link, fd: posix.FD, read_ahead: []u8, due: i64) -> bool {
	if !stream_conn_attach(&k.conn, fd, read_ahead) do return false
	id, ok := _poll_add(k.set, {fd = fd, want = {.IN}, on = _link_conn_ready, data = k, due = due, on_due = _link_hello_late})
	if !ok {
		stream_conn_detach(&k.conn)
		return false
	}
	k.conn_src = id
	return true
}

// _link_lost ends the current peer and reports why.
@(private)
_link_lost :: proc(k: ^_Link, err: Error, replaced := false) {
	_link_detach(k)
	_link_push(k, Link_Down{err, replaced})
	if k.dialed do k.ended = true
}

@(private)
_link_detach :: proc(k: ^_Link) {
	_poll_remove(k.set, k.conn_src)
	stream_conn_detach(&k.conn)
	k.conn_src, k.up, k.closing = 0, false, false
}

@(private)
_link_send_hello :: proc(k: ^_Link, role: u8) {
	hb: [_HELLO_MAX]u8
	stream_send(&k.conn, k.proto.hello_kind, 0, _hello_body(hb[:], k.proto.version, role))
	_link_flush(k)
}

// _link_flush writes what it can and polls for writable while more waits.
@(private)
_link_flush :: proc(k: ^_Link) {
	if !k.conn.open do return
	if stream_flush(&k.conn) != .None do k.closing = true
	if s := _poll_source(k.set, k.conn_src); s != nil {
		s.want = {.OUT} if stream_wants_write(&k.conn) else {}
		if !k.closing do s.want += {.IN}
	}
}

@(private = "file")
_link_conn_ready :: proc(data: rawptr, rev: posix.Poll_Event) {
	k := (^_Link)(data)
	if rev & {.IN, .HUP, .ERR, .NVAL} != {} && stream_fill(&k.conn) != .None do k.closing = true
	_link_flush(k)
	if k.dialed && !k.up do _link_take_hello(k)
}

// _link_take_hello: the dialled side is up once the peer's HELLO matches.
@(private = "file")
_link_take_hello :: proc(k: ^_Link) {
	f, ok := stream_next(&k.conn)
	if !ok {
		if k.closing || k.conn.err == .Bad_Frame do _link_lost(k, {kind = .Handshake, reason = "the peer closed before HELLO"})
		return
	}
	h, good := _hello_decode(f.payload)
	switch {
	case f.kind != k.proto.hello_kind || f.channel != 0 || !good:
		_link_lost(k, {kind = .Handshake, reason = "the peer did not answer with HELLO"})
	case !_version_match(k.proto.version, h.version):
		_link_lost(k, {kind = .Version, reason = _version_reason(k.proto.name, k.proto.version, h.version)})
	case:
		k.up = true
		if s := _poll_source(k.set, k.conn_src); s != nil do s.due = 0
		_link_push(k, Link_Up{})
	}
}

@(private = "file")
_link_hello_late :: proc(data: rawptr) {
	k := (^_Link)(data)
	if !k.up do _link_lost(k, {kind = .Handshake, reason = "no HELLO in time"})
}

@(private)
_link_hello_due :: proc(k: ^_Link) -> i64 {
	return time.tick_now()._nsec + i64(k.opts.hello_ms) * 1_000_000
}

// _link_new validates everything link_listen and link_dial share and
// reserves the conn buffers; path is laid out in buf.
@(private)
_link_new :: proc(l: ^Link, at: Endpoint, proto: Protocol, set: ^Poll_Set, opts: Link_Opts, buf: []u8) -> (k: ^_Link, path: string, err: Error) {
	if l._impl != nil do return nil, "", {kind = .Bad_Opts, reason = "the link is already open"}
	if path, err = _endpoint_path(at, buf); err.kind != .None do return
	p: Protocol
	if p, err = _protocol_resolve(proto, true); err.kind != .None do return
	o: Link_Opts
	if o, err = _link_opts(opts); err.kind != .None do return
	ps := _poll(set)
	if ps == nil do return nil, "", {kind = .Closed, reason = "the poll set is not open"}
	k = new(_Link)
	k^ = {set = ps, proto = p, opts = o, allocator = context.allocator}
	stream_conn_reserve(&k.conn, o.backlog)
	return k, path, {}
}

@(private = "file")
_link_opts :: proc(opts: Link_Opts) -> (o: Link_Opts, err: Error) {
	o = opts
	if o.hello_ms == 0 do o.hello_ms = 5000
	if o.pending == 0 do o.pending = 4
	if o.backlog == 0 do o.backlog = 4 << 20
	if o.hello_ms < 0 || o.pending < 0 || o.pending > 16 || o.backlog < 0 || o.backlog > 64 << 20 {
		return o, {kind = .Bad_Opts, reason = "a Link_Opts limit is out of range"}
	}
	return o, {}
}

@(private)
_link_free :: proc(k: ^_Link) {
	context.allocator = k.allocator
	for &pd in k.pending do if pd.src != 0 do _pending_drop(&pd)
	_listener_close(&k.listener)
	_poll_remove(k.set, k.conn_src)
	stream_conn_destroy(&k.conn)
	delete(k.pending)
	free(k)
}
