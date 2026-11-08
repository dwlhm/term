package platform_ipc

// Server: accepts peers that pass HELLO for its Protocol, hands requests to
// the owner as Request values and takes exactly one final answer per request.
// .Frames: binary, many requests per connection, correlated by req.
// .Line: one line in, one answer out, then close (the control socket).
// State: server_impl.odin, server_req.odin.

Server :: struct {
	_impl: rawptr,
}

Framing :: enum u8 {
	Frames,
	Line,
}

Server_Opts :: struct {
	framing:     Framing,
	max_peers:   int,    // 0 = 16; at most 256
	max_open:    int,    // open requests per peer; 0 = 32; at most 1024
	hello_ms:    int,    // 0 = 2000; .Line: the time to read the line
	max_payload: int,    // 0 = 1 MiB (.Line: 4096); at most 16 MiB
	busy_reason: string, // FAIL Busy text; "" = "all connections are in use"
}

// Peer is safe to keep: it goes stale (gen) once that peer leaves.
Peer :: struct {
	slot: u16,
	gen:  u16,
}

Peer_Joined :: struct {
	peer: Peer,
	role: u8,
}

Peer_Left :: struct {
	peer: Peer,
}

// Request: one request on channel 0. Keep it to answer later; answering a
// request whose peer left does nothing.
Request :: struct {
	peer:  Peer,
	kind:  u8,
	_req:  u32,
	_body: []u8,   // view: valid until the next server_next after a poll_set_wait
	_srv:  rawptr, // the Server it came from
}

Stream_Input :: struct {
	peer:    Peer,
	channel: u32,
	kind:    u8,
	body:    []u8,
}

// Server_Down: the server can no longer accept (err.kind = .Listener_Broken).
// It comes once; afterwards server_next returns false and the Server holds no
// fd in the Poll_Set. server_close is still the owner's to call.
Server_Down :: struct {
	err: Error,
}

Server_Event :: union {
	Peer_Joined,
	Peer_Left,
	Request,
	Stream_Input,
	Server_Down,
}

Notify_All :: struct {}
Notify_To :: union {
	Peer,
	Notify_All,
}

server_open :: proc(s: ^Server, at: Endpoint, proto: Protocol, set: ^Poll_Set, opts := Server_Opts{}) -> Error {
	path_buf: [_SUN_PATH]u8
	k, path, err := _server_new(s, at, proto, opts, path_buf[:])
	if err.kind != .None do return err
	ps := _poll(set)
	switch {
	case ps == nil:              err = {kind = .Closed, reason = "the poll set is not open"}
	case k.opts.framing == .Line: k.line, err = _line_new(path, ps, k.opts)
	case:                        err = _server_slots(k, path, ps)
	}
	if err.kind != .None {
		_server_free(k)
		return err
	}
	s._impl = k
	return {}
}

// server_open_thread runs the IO on a thread of its own, for an owner whose
// main loop is not a Poll_Set (a GUI window): on_wake wakes that loop (from
// the IO thread), which then calls server_next. The owner's thread never
// blocks. Only .Line is served this way.
server_open_thread :: proc(s: ^Server, at: Endpoint, proto: Protocol, on_wake: proc "contextless" (data: rawptr), data: rawptr, opts := Server_Opts{}) -> Error {
	path_buf: [_SUN_PATH]u8
	k, path, err := _server_new(s, at, proto, opts, path_buf[:])
	if err.kind != .None do return err
	if k.opts.framing != .Line {
		err = {kind = .Bad_Opts, reason = "server_open_thread serves .Line only"}
	} else if k.line, err = _line_new(path, nil, k.opts); err.kind == .None {
		_line_run_thread(k.line, on_wake, data)
	}
	if err.kind != .None {
		_server_free(k)
		return err
	}
	s._impl = k
	return {}
}

// server_close drops every peer and unlinks the socket while its inode is still ours.
server_close :: proc(s: ^Server) {
	if k := _server(s); k != nil do _server_free(k)
	s^ = {}
}

// server_next: call until false after each poll_set_wait (or on_wake).
// Joined/Left/Down come first, then requests and stream input, round-robin
// over peers.
server_next :: proc(s: ^Server) -> (Server_Event, bool) {
	k := _server(s)
	if k == nil do return nil, false
	if k.line != nil do return _line_next(k.line, k)
	if ev, ok := _server_pop(k); ok do return ev, true
	if k.down do return nil, false
	for i in 0 ..< len(k.peers) {
		idx := (k.turn + i) % len(k.peers)
		if ev, ok := _peer_next(k, &k.peers[idx]); ok {
			k.turn = idx
			return ev, true
		}
	}
	return _server_pop(k)
}

// request_decode is the only way to read a request body. false = the body did
// not decode to its end, and FAIL Bad_Request has been sent.
request_decode :: proc(req: ^Request, out: ^$T, decode: proc(r: ^Wire_Reader) -> T) -> bool {
	r := wire_reader(req._body)
	v := decode(&r)
	if wr_done(&r) {
		out^ = v
		return true
	}
	k := (^_Server)(req._srv)
	if slot := _peer_of(k, req.peer); slot != nil && _take_open(slot, req^) {
		_send_fail(slot, req._req, FAIL_BAD_REQUEST, "the request body does not decode")
	}
	return false
}

// request_line: a .Line request without its '\n'.
request_line :: proc(req: ^Request) -> string {
	return string(req._body)
}

// reply sends the final answer; its kind comes from the catalog.
reply :: proc(s: ^Server, req: Request, body: ..[]u8) {
	k := _server(s)
	if k == nil do return
	if k.line != nil {
		_line_reply(k.line, req, ..body)
		return
	}
	row, _ := _row(k.proto, req.kind)
	_server_reply(k, req, true, row.answer, ..body)
}

fail :: proc(s: ^Server, req: Request, code: u8, reason: string) {
	when ODIN_TEST do assert(code != FAIL_VERSION, _ASSERT_RESERVED_FAIL)
	k := _server(s)
	if k == nil do return
	if k.line != nil {
		_line_reply(k.line, req, transmute([]u8)string("err "), transmute([]u8)reason, transmute([]u8)string("\n"))
		return
	}
	fb: [512]u8
	_server_reply(k, req, true, k.proto.fail_kind, _fail_body(fb[:], 0, code, reason)[4:])
}

// progress: only for a request whose catalog row has a progress kind.
progress :: proc(s: ^Server, req: Request, body: ..[]u8) {
	k := _server(s)
	if k == nil do return
	row, _ := _row(k.proto, req.kind)
	if row.progress == 0 {
		when ODIN_TEST do assert(false, _ASSERT_NO_PROGRESS)
		return
	}
	_server_reply(k, req, false, row.progress, ..body)
}

// notify: only for kinds the catalog marks as notices.
notify :: proc(s: ^Server, to: Notify_To, kind: u8, body: ..[]u8) {
	if k := _server(s); k != nil do _server_notify(k, to, kind, ..body)
}

server_stream_open :: proc(s: ^Server, peer: Peer, credited: bool) -> (channel: u32, ok: bool) {
	slot := _peer_of(_server(s), peer)
	if slot == nil do return 0, false
	slot.next_channel = max(slot.next_channel + 1, 1)
	if !stream_channel_open(&slot.conn, slot.next_channel, credited) do return 0, false
	return slot.next_channel, true
}

// server_stream_data: false = the reader is too far behind; send a repaint.
server_stream_data :: proc(s: ^Server, peer: Peer, channel: u32, bytes: []u8) -> bool {
	slot := _peer_of(_server(s), peer)
	if slot == nil do return true
	ok := stream_data(&slot.conn, channel, bytes)
	_peer_flush(slot)
	return ok
}

server_stream_finish :: proc(s: ^Server, peer: Peer, channel: u32) {
	if slot := _peer_of(_server(s), peer); slot != nil {
		stream_channel_finish(&slot.conn, channel)
		_peer_flush(slot)
	}
}

server_stream_close :: proc(s: ^Server, peer: Peer, channel: u32, reason := "") {
	if slot := _peer_of(_server(s), peer); slot != nil {
		stream_channel_close(&slot.conn, channel, reason)
		_peer_flush(slot)
	}
}
