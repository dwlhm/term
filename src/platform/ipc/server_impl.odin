package platform_ipc

// What a Server holds behind its handle (spec 7.6): the listener and
// max_peers peer slots, each a Stream_Conn reserved at open with its table
// of open requests, plus a queue of Joined/Left/Down events that server_next
// hands out before the requests. A peer joins only after a matching HELLO;
// a full server answers HELLO + FAIL Busy and closes. Requests:
// server_req.odin.

import "base:runtime"
import "core:c"
import "core:sys/posix"
import "core:time"

@(private)
_Peer_State :: enum u8 {
	Free,
	Hello,  // accepted, HELLO not seen yet
	Joined,
}

@(private)
_Open_Req :: struct {
	req:  u32,
	kind: u8,
	used: bool,
}

@(private)
_Peer_Slot :: struct {
	srv:          ^_Server,
	conn:         Stream_Conn,
	src:          u32,
	gen:          u16,
	state:        _Peer_State,
	closing:      bool, // gone: what it sent is still handed out, then it is dropped
	open:         []_Open_Req,
	next_channel: u32,
}

@(private)
_Server :: struct {
	set:       ^_Poll,
	proto:     Protocol,
	opts:      Server_Opts,
	listener:  _Listener,
	peers:     []_Peer_Slot,
	events:    []Server_Event,
	ev_head:   int,
	ev_len:    int,
	turn:      int,
	down:      bool,
	line:      ^_Line, // .Line: everything lives there (line_impl.odin)
	allocator: runtime.Allocator,
}

@(private)
_server :: proc(s: ^Server) -> ^_Server { return (^_Server)(s._impl) }

@(private)
_server_push :: proc(k: ^_Server, ev: Server_Event) {
	if k.ev_len == len(k.events) do return // cannot happen: 2 events per slot + Down fit
	k.events[(k.ev_head + k.ev_len) % len(k.events)] = ev
	k.ev_len += 1
}

@(private)
_server_pop :: proc(k: ^_Server) -> (ev: Server_Event, ok: bool) {
	if k.ev_len == 0 do return
	ev = k.events[k.ev_head]
	k.ev_head = (k.ev_head + 1) % len(k.events)
	k.ev_len -= 1
	return ev, true
}

@(private)
_peer_of :: proc(k: ^_Server, p: Peer) -> ^_Peer_Slot {
	if k == nil || int(p.slot) >= len(k.peers) do return nil
	slot := &k.peers[p.slot]
	return slot if slot.state == .Joined && slot.gen == p.gen else nil
}

@(private)
_peer_handle :: proc(slot: ^_Peer_Slot) -> Peer {
	return {u16((uintptr(slot) - uintptr(raw_data(slot.srv.peers))) / size_of(_Peer_Slot)), slot.gen}
}

// _HELLO_SPARE: slots beyond max_peers for peers still saying HELLO, so a
// full server reads a newcomer's HELLO before it answers Busy (closing a unix
// socket with unread input resets it, and the refusal would be lost), and a
// silent connection never takes a real peer's place.
@(private)
_HELLO_SPARE :: 2

@(private)
_server_accept :: proc(data: rawptr, fd: posix.FD) {
	k := (^_Server)(data)
	for &slot in k.peers {
		if slot.state != .Free do continue
		if !stream_conn_attach(&slot.conn, fd) do return
		due := time.tick_now()._nsec + i64(k.opts.hello_ms) * 1_000_000
		id, ok := _poll_add(k.set, {fd = fd, want = {.IN}, on = _peer_ready, data = &slot, due = due, on_due = _peer_hello_late})
		if !ok {
			stream_conn_detach(&slot.conn)
			return
		}
		slot.src, slot.state = id, .Hello
		return
	}
	_refuse_fd(k, fd, FAIL_BUSY, k.opts.busy_reason)
}

// _refuse_fd answers a peer that has no slot with HELLO + FAIL and closes:
// a few bytes into an empty socket buffer, so one non-blocking send.
@(private = "file")
_refuse_fd :: proc(k: ^_Server, fd: posix.FD, code: u8, reason: string) {
	buf: [STREAM_HEADER * 2 + _HELLO_MAX + 512]u8
	n := _refusal(k, buf[:], code, reason)
	posix.send(fd, raw_data(buf[:]), c.size_t(n), {.NOSIGNAL})
	posix.close(fd)
}

// _refusal lays out HELLO + FAIL(req 0, code, reason) in buf.
@(private)
_refusal :: proc(k: ^_Server, buf: []u8, code: u8, reason: string) -> int {
	hb: [_HELLO_MAX]u8
	hello := _hello_body(hb[:], k.proto.version, 0)
	stream_put_header(buf, k.proto.hello_kind, 0, len(hello))
	n := STREAM_HEADER + copy(buf[STREAM_HEADER:], hello)
	fb: [512]u8
	fail := _fail_body(fb[:], 0, code, reason)
	stream_put_header(buf[n:], k.proto.fail_kind, 0, len(fail))
	return n + STREAM_HEADER + copy(buf[n + STREAM_HEADER:], fail)
}

@(private)
_fail_body :: proc(buf: []u8, req: u32, code: u8, reason: string) -> []u8 {
	w := wire_writer(buf)
	ww_u32(&w, req)
	ww_u8(&w, code)
	ww_str(&w, reason[:min(len(reason), len(buf) - 9)])
	return wire_bytes_written(&w)
}

@(private = "file")
_peer_ready :: proc(data: rawptr, rev: posix.Poll_Event) {
	slot := (^_Peer_Slot)(data)
	if rev & {.IN, .HUP, .ERR, .NVAL} != {} && stream_fill(&slot.conn) != .None {
		if slot.state != .Joined || slot.conn.in_used == slot.conn.in_len {
			_peer_drop(slot)
			return
		}
		slot.closing = true // server_next drains it, then drops it
		if s := _poll_source(slot.srv.set, slot.src); s != nil do s.want = {}
		return
	}
	if slot.state == .Hello do _peer_hello(slot)
	if slot.state != .Free do _peer_flush(slot)
}

@(private = "file")
_peer_hello_late :: proc(data: rawptr) {
	slot := (^_Peer_Slot)(data)
	if slot.state == .Hello do _peer_drop(slot)
}

// _peer_hello admits a peer whose first frame is a matching HELLO.
@(private = "file")
_peer_hello :: proc(slot: ^_Peer_Slot) {
	k := slot.srv
	f, ok := stream_next(&slot.conn)
	if !ok {
		if slot.conn.err == .Bad_Frame do _peer_drop(slot)
		return
	}
	h, good := _hello_decode(f.payload)
	switch {
	case f.kind != k.proto.hello_kind || f.channel != 0 || !good:
		_peer_drop(slot)
	case !_version_match(h.version, k.proto.version):
		_peer_refuse(slot, FAIL_VERSION, _version_reason(k.proto.name, h.version, k.proto.version))
	case int(h.role) >= 64 || int(h.role) not_in k.proto.roles:
		_peer_refuse(slot, FAIL_BAD_REQUEST, "this role may not connect")
	case _joined(k) >= k.opts.max_peers:
		_peer_refuse(slot, FAIL_BUSY, k.opts.busy_reason)
	case:
		hb: [_HELLO_MAX]u8
		stream_send(&slot.conn, k.proto.hello_kind, 0, _hello_body(hb[:], k.proto.version, 0))
		slot.state = .Joined
		if s := _poll_source(k.set, slot.src); s != nil do s.due = 0
		_server_push(k, Peer_Joined{_peer_handle(slot), h.role})
	}
}

@(private = "file")
_joined :: proc(k: ^_Server) -> (n: int) {
	for slot in k.peers do if slot.state == .Joined do n += 1
	return
}

@(private = "file")
_peer_refuse :: proc(slot: ^_Peer_Slot, code: u8, reason: string) {
	buf: [STREAM_HEADER * 2 + _HELLO_MAX + 512]u8
	n := _refusal(slot.srv, buf[:], code, reason)
	posix.send(slot.conn.fd, raw_data(buf[:]), c.size_t(n), {.NOSIGNAL})
	_peer_drop(slot)
}

// _peer_flush writes what it can; a peer that cannot keep up is dropped.
@(private)
_peer_flush :: proc(slot: ^_Peer_Slot) {
	if stream_flush(&slot.conn) != .None || slot.conn.err == .Overflow {
		_peer_drop(slot)
		return
	}
	if s := _poll_source(slot.srv.set, slot.src); s != nil && !slot.closing {
		s.want = {.IN, .OUT} if stream_wants_write(&slot.conn) else {.IN}
	}
}

// _peer_drop frees the slot; a joined peer is reported as Peer_Left and its
// Peer handle goes stale (gen).
@(private)
_peer_drop :: proc(slot: ^_Peer_Slot) {
	if slot.state == .Free do return
	k := slot.srv
	if slot.state == .Joined do _server_push(k, Peer_Left{_peer_handle(slot)})
	_poll_remove(k.set, slot.src)
	stream_conn_detach(&slot.conn)
	for &o in slot.open do o = {}
	slot.src, slot.state, slot.closing, slot.next_channel = 0, .Free, false, 0
	slot.gen += 1
}

// _server_broken: the listener is gone; peers go quietly, Server_Down once.
@(private)
_server_broken :: proc(data: rawptr) {
	k := (^_Server)(data)
	for &slot in k.peers {
		slot.state = .Hello if slot.state == .Joined else slot.state // no Peer_Left after Down
		_peer_drop(&slot)
	}
	k.ev_len = 0
	_server_push(k, Server_Down{{kind = .Listener_Broken, reason = "the server can no longer accept"}})
	k.down = true
}
