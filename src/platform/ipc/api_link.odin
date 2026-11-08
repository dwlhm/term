package platform_ipc

// Link: two processes that hold each other without request/reply (term: the
// holder and the core). On the listening side the newest peer to pass HELLO
// replaces the old one (Link_Down, then Link_Up).

Link :: struct {
	_impl: rawptr,
}

Link_Opts :: struct {
	hello_ms: int, // 0 = 5000
	pending:  int, // HELLOs in flight; 0 = 4; at most 16
	backlog:  int, // queued bytes before link_send says no; 0 = 4 MiB
}

Link_Up :: struct {}

Link_Down :: struct {
	err: Error,
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
	return _not_implemented()
}

link_dial :: proc(l: ^Link, at: Endpoint, proto: Protocol, role: u8, set: ^Poll_Set, opts := Link_Opts{}) -> Error {
	return _not_implemented()
}

link_close :: proc(l: ^Link) {}

link_next :: proc(l: ^Link) -> (Link_Event, bool) {
	return nil, false
}

// link_send: false = the backlog is full (apply backpressure).
link_send :: proc(l: ^Link, kind: u8, channel: u32, body: ..[]u8) -> bool {
	return false
}

link_backlog :: proc(l: ^Link) -> int {
	return 0
}
