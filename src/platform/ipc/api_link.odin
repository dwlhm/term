package platform_ipc

// Link: two processes that hold each other without request/reply (term: the
// holder and the core). On the listening side the newest peer to pass HELLO
// replaces the old one (Link_Down, then Link_Up). State: link_impl.odin.

import "core:sys/posix"

Link :: struct {
	_impl: rawptr,
}

Link_Opts :: struct {
	hello_ms: int, // 0 = 5000
	pending:  int, // HELLOs in flight; 0 = 4; at most 16
	backlog:  int, // queued bytes before link_send says no; 0 = 4 MiB; at most 64 MiB
	role:     u8,  // listening side: the role its HELLO answer announces
}

Link_Up :: struct {}

// Link_Down: the peer went away, or (listening side, err.kind =
// .Listener_Broken) the link can no longer accept; that one comes once and
// link_next returns false afterwards.
Link_Down :: struct {
	err:      Error,
	replaced: bool, // a newer peer took the link (listening side)
}

Link_Frame :: struct {
	kind:    u8,
	channel: u32,
	body:    []u8,
}

Link_Event :: union {
	Link_Up,
	Link_Down,
	Link_Frame,
}

link_listen :: proc(l: ^Link, at: Endpoint, proto: Protocol, set: ^Poll_Set, opts := Link_Opts{}) -> Error {
	path_buf: [_SUN_PATH]u8
	k, path, err := _link_new(l, at, proto, set, opts, path_buf[:])
	if err.kind != .None do return err
	k.pending = make([]_Pending, k.opts.pending, k.allocator)
	for &pd in k.pending do pd.link = k
	if err = _listener_open(&k.listener, k.set, path, _link_accept, _link_broken, k); err.kind != .None {
		_link_free(k)
		return err
	}
	l._impl = k
	return {}
}

// link_dial connects and says HELLO as role; Link_Up follows once the
// listener answers with a matching HELLO.
link_dial :: proc(l: ^Link, at: Endpoint, proto: Protocol, role: u8, set: ^Poll_Set, opts := Link_Opts{}) -> Error {
	path_buf: [_SUN_PATH]u8
	k, path, err := _link_new(l, at, proto, set, opts, path_buf[:])
	if err.kind != .None do return err
	fd: posix.FD
	if fd, err = _dial(path); err.kind != .None {
		_link_free(k)
		return err
	}
	k.dialed = true
	if !_link_attach(k, fd, nil, _link_hello_due(k)) {
		_link_free(k)
		return {kind = .Busy, reason = "poll set is full"}
	}
	_link_send_hello(k, role)
	l._impl = k
	return {}
}

// link_drop ends the current peer now (no Link_Down: the caller knows); the
// listening side keeps accepting the next one.
link_drop :: proc(l: ^Link) {
	k := _link(l)
	if k == nil || !k.conn.open do return
	_link_detach(k)
	if k.dialed do k.ended = true
}

link_close :: proc(l: ^Link) {
	if k := _link(l); k != nil do _link_free(k)
	l^ = {}
}

// link_next: Up/Down first, then the current peer's frames (views valid
// until the next poll_set_wait). Call until false after each poll_set_wait.
link_next :: proc(l: ^Link) -> (Link_Event, bool) {
	k := _link(l)
	if k == nil do return nil, false
	if ev, ok := _link_pop(k); ok do return ev, true
	if !k.up do return nil, false
	if f, ok := stream_next(&k.conn); ok do return Link_Frame{f.kind, f.channel, f.payload}, true
	switch {
	case k.conn.err == .Bad_Frame: _link_lost(k, {kind = .Closed, reason = "the peer sent a malformed frame"})
	case k.closing:                _link_lost(k, {kind = .Closed, reason = "the peer went away"})
	case:                          return nil, false
	}
	return _link_pop(k)
}

// link_send: false = not connected, or the backlog is full (apply backpressure).
link_send :: proc(l: ^Link, kind: u8, channel: u32, body: ..[]u8) -> bool {
	k := _link(l)
	if k == nil || !k.conn.open || k.closing || k.ended do return false
	n := 0
	for b in body do n += len(b)
	if n > STREAM_MAX_PAYLOAD || len(k.conn.ctl.buf) - k.conn.ctl.len < STREAM_HEADER + n do return false
	stream_send(&k.conn, kind, channel, ..body)
	_link_flush(k)
	return true
}

link_backlog :: proc(l: ^Link) -> int {
	k := _link(l)
	return stream_queued(&k.conn) if k != nil && k.conn.open else 0
}
