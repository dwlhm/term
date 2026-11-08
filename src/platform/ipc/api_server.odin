package platform_ipc

// Server: accepts peers that pass HELLO for its Protocol, hands requests to
// the owner as Request values and takes exactly one final answer per request.
// .Frames: binary, many requests per connection, correlated by req.
// .Line: one line in, one answer out, then close (the control socket).

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
	peer: Peer,
	kind: u8,
	_req: u32,
	_body: []u8,
}

Stream_Input :: struct {
	peer:    Peer,
	channel: u32,
	kind:    u8,
	body:    []u8,
}

Server_Event :: union {
	Peer_Joined,
	Peer_Left,
	Request,
	Stream_Input,
}

Notify_All :: struct {}
Notify_To :: union {
	Peer,
	Notify_All,
}

server_open :: proc(s: ^Server, at: Endpoint, proto: Protocol, set: ^Poll_Set, opts := Server_Opts{}) -> Error {
	return _not_implemented()
}

// server_open_thread runs the IO on a thread of its own, for an owner whose
// main loop is not a Poll_Set (a GUI window): on_wake wakes that loop, which
// then calls server_next. The owner's thread never blocks.
server_open_thread :: proc(s: ^Server, at: Endpoint, proto: Protocol, on_wake: proc "contextless" (data: rawptr), data: rawptr, opts := Server_Opts{}) -> Error {
	return _not_implemented()
}

// server_close drops every peer and unlinks the socket while its inode is still ours.
server_close :: proc(s: ^Server) {}

// server_next: call until false after each poll_set_wait (or on_wake).
server_next :: proc(s: ^Server) -> (Server_Event, bool) {
	return nil, false
}

// request_decode is the only way to read a request body. false = the body did
// not decode to its end, and FAIL Bad_Request has been sent.
request_decode :: proc(req: ^Request, out: ^$T, decode: proc(r: ^Wire_Reader) -> T) -> bool {
	return false
}

// request_line: a .Line request without its '\n'.
request_line :: proc(req: ^Request) -> string {
	return ""
}

// reply sends the final answer; its kind comes from the catalog.
reply :: proc(s: ^Server, req: Request, body: ..[]u8) {}

fail :: proc(s: ^Server, req: Request, code: u8, reason: string) {}

// progress: only for a request whose catalog row has a progress kind.
progress :: proc(s: ^Server, req: Request, body: ..[]u8) {}

// notify: only for kinds the catalog marks as notices.
notify :: proc(s: ^Server, to: Notify_To, kind: u8, body: ..[]u8) {}

server_stream_open :: proc(s: ^Server, peer: Peer, credited: bool) -> (channel: u32, ok: bool) {
	return 0, false
}

// server_stream_data: false = the reader is too far behind; send a repaint.
server_stream_data :: proc(s: ^Server, peer: Peer, channel: u32, bytes: []u8) -> bool {
	return false
}

server_stream_finish :: proc(s: ^Server, peer: Peer, channel: u32) {}

server_stream_close :: proc(s: ^Server, peer: Peer, channel: u32, reason := "") {}
