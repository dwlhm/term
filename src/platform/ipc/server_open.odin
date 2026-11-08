package platform_ipc

// Server lifecycle: validation and allocation at open (every peer slot,
// its conn buffers and its open-request table), teardown at close, and the
// per-peer frame pump behind server_next.

import "core:fmt"

@(private = "file")
_BUSY_DEFAULT :: "all connections are in use"

// _server_new validates what server_open and server_open_thread share and
// allocates the Server; the framing's own state comes after.
@(private)
_server_new :: proc(s: ^Server, at: Endpoint, proto: Protocol, opts: Server_Opts, buf: []u8) -> (k: ^_Server, path: string, err: Error) {
	if s._impl != nil do return nil, "", {kind = .Bad_Opts, reason = "the server is already open"}
	if path, err = _endpoint_path(at, buf); err.kind != .None do return
	p := proto
	o: Server_Opts
	if o, err = _server_opts(opts); err.kind != .None do return
	if o.framing == .Frames {
		if p, err = _protocol_resolve(proto, false); err.kind != .None do return // .Line uses no catalog
	}
	k = new(_Server)
	k^ = {proto = p, opts = o, allocator = context.allocator}
	return k, path, {}
}

// _server_slots allocates the .Frames peer slots and listens on set.
@(private)
_server_slots :: proc(k: ^_Server, path: string, set: ^_Poll) -> Error {
	k.set = set
	k.peers = make([]_Peer_Slot, k.opts.max_peers + _HELLO_SPARE)
	k.events = make([]Server_Event, 2 * len(k.peers) + 2)
	for &slot in k.peers {
		slot.srv = k
		slot.open = make([]_Open_Req, k.opts.max_open)
		stream_conn_reserve(&slot.conn, 0, max_payload = k.opts.max_payload)
	}
	return _listener_open(&k.listener, k.set, path, _server_accept, _server_broken, k)
}

@(private = "file")
_server_opts :: proc(opts: Server_Opts) -> (o: Server_Opts, err: Error) {
	o = opts
	if o.max_peers == 0 do o.max_peers = 16
	if o.max_open == 0 do o.max_open = 32
	if o.hello_ms == 0 do o.hello_ms = 2000
	if o.max_payload == 0 do o.max_payload = 4096 if o.framing == .Line else 1 << 20
	if o.busy_reason == "" do o.busy_reason = _BUSY_DEFAULT
	bad := ""
	switch {
	case o.max_peers < 1 || o.max_peers > 256:      bad = "max_peers"
	case o.max_open < 1 || o.max_open > 1024:       bad = "max_open"
	case o.hello_ms < 0:                            bad = "hello_ms"
	case o.max_payload < 1 || o.max_payload > 16 << 20: bad = "max_payload"
	}
	if bad != "" do return o, {kind = .Bad_Opts, reason = fmt.tprintf("Server_Opts.%s is out of range", bad)}
	return o, {}
}

@(private)
_server_free :: proc(k: ^_Server) {
	context.allocator = k.allocator
	if k.line != nil do _line_free(k.line)
	_listener_close(&k.listener)
	for &slot in k.peers {
		_poll_remove(k.set, slot.src)
		stream_conn_destroy(&slot.conn)
		delete(slot.open)
	}
	delete(k.peers)
	delete(k.events)
	free(k)
}

// _peer_next hands out the peer's next request or stream input; a peer that
// sent a malformed frame, or left and has nothing more, is dropped.
@(private)
_peer_next :: proc(k: ^_Server, slot: ^_Peer_Slot) -> (Server_Event, bool) {
	for slot.state == .Joined {
		f, ok := stream_next(&slot.conn)
		if !ok {
			if slot.conn.err == .Bad_Frame || slot.closing do _peer_drop(slot)
			break
		}
		if ev, yield := _peer_frame(k, slot, f); yield do return ev, true
	}
	return nil, false
}
