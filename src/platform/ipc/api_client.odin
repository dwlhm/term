package platform_ipc

// Client: one connection to a Server. client_open validates the endpoint,
// connects (or starts the server), checks the server's uid and does HELLO.
// Answers are matched to their request inside; callers never see req.
// State: client_impl.odin, client_call.odin.

import "core:sync"
import "core:sys/posix"
import "core:time"

Client :: struct {
	_impl: rawptr,
}

Client_Opts :: struct {
	role:     u8,
	start:    []string, // when nothing listens: argv spawned detached ("" in argv[0] = this executable); empty = don't
	log:      string,   // log file of the spawned process
	start_ms: int,      // 0 = 3000
}

CALL_DEFAULT :: 5 * time.Second
WAIT_FOREVER :: time.Duration(-1)

Event_Action :: enum u8 {
	Continue,
	Stop, // the call ends with .Interrupted
}

Call_Opts :: struct {
	timeout:  time.Duration, // 0 = CALL_DEFAULT; WAIT_FOREVER = until answered, closed or interrupted
	on_event: proc(data: rawptr, ev: Client_Event) -> Event_Action, // other events while waiting; nil = ignore
	data:     rawptr,
	watch:    posix.FD,      // one non-IPC fd to wait on as well (stdin); 0 = none
	on_watch: proc(data: rawptr),
}

// Answer: body without req; valid until the next client_* call.
Answer :: struct {
	kind: u8,
	body: []u8,
}

Ticket :: distinct u32

Late_Answer :: struct {
	ticket: Ticket,
	answer: Answer,
	err:    Error,
}

Progress :: struct {
	ticket: Ticket,
	kind:   u8,
	body:   []u8,
}

Notice :: struct {
	kind: u8,
	body: []u8,
}

Stream_Data :: struct {
	channel: u32,
	bytes:   []u8,
}

Stream_End :: struct {
	channel: u32,
	reason:  string,
}

Client_Event :: union {
	Late_Answer,
	Progress,
	Notice,
	Stream_Data,
	Stream_End,
}

client_open :: proc(c: ^Client, at: Endpoint, proto: Protocol, opts := Client_Opts{}) -> Error {
	if c._impl != nil do return {kind = .Bad_Opts, reason = "the client is already open"}
	path_buf: [_SUN_PATH]u8
	path, err := _endpoint_path(at, path_buf[:])
	if err.kind != .None do return err
	p: Protocol
	if p, err = _protocol_resolve(proto, false); err.kind != .None do return err
	o := opts
	if o.start_ms == 0 do o.start_ms = 3000
	if o.start_ms < 0 do return {kind = .Bad_Opts, reason = "Client_Opts.start_ms is out of range"}
	k := new(_Client)
	k^ = {proto = p, wake = {-1, -1}, allocator = context.allocator}
	if posix.pipe(&k.wake) != .OK {
		_client_free(k)
		return {kind = .Start_Failed, reason = "cannot create the wake pipe"}
	}
	for fd in k.wake do _set_nonblocking_cloexec(fd)
	if err = _client_connect(k, path, o); err.kind != .None {
		_client_free(k)
		return err
	}
	c._impl = k
	return {}
}

// client_close sends what is queued (at most 1 s), then closes. Idempotent.
client_close :: proc(c: ^Client) {
	k := _client(c)
	if k == nil do return
	due := time.tick_now()._nsec + 1_000_000_000
	for k.conn.open && k.conn.err == .None && stream_wants_write(&k.conn) && _client_wait(k, due) != .Timeout {}
	_client_free(k)
	c^ = {}
}

@(private = "file")
_client_free :: proc(k: ^_Client) {
	context.allocator = k.allocator
	stream_conn_destroy(&k.conn)
	for fd in k.wake do if fd >= 0 do posix.close(fd)
	free(k)
}

client_call :: proc(c: ^Client, kind: u8, body: []u8, opts := Call_Opts{}) -> (Answer, Error) {
	k := _client(c)
	if k == nil do return {}, {kind = .Closed, reason = "the client is not open"}
	if _, ok := _row(k.proto, kind); !ok do return {}, {kind = .Bad_Protocol, reason = "not a request kind of the catalog"}
	req, err := _client_send(k, kind, body)
	if err.kind != .None do return {}, err
	return _client_await(k, req, kind, opts)
}

// client_start sends a request whose answer comes later, as a Late_Answer.
client_start :: proc(c: ^Client, kind: u8, body: []u8) -> (Ticket, Error) {
	k := _client(c)
	if k == nil do return 0, {kind = .Closed, reason = "the client is not open"}
	if _, ok := _row(k.proto, kind); !ok do return 0, {kind = .Bad_Protocol, reason = "not a request kind of the catalog"}
	for &t in k.tickets {
		if t.used do continue
		req, err := _client_send(k, kind, body)
		if err.kind != .None do return 0, err
		t = {req, kind, true}
		return Ticket(req), {}
	}
	return 0, {kind = .Busy, reason = "too many requests started"}
}

// client_poll waits for the next event. watch (0 = none) is one non-IPC fd
// to wait on as well: once it is readable, on_watch(data) runs and
// client_poll returns (nil, no error).
client_poll :: proc(c: ^Client, timeout: time.Duration, watch: posix.FD = 0, on_watch: proc(data: rawptr) = nil, data: rawptr = nil) -> (Client_Event, Error) {
	k := _client(c)
	if k == nil do return nil, {kind = .Closed, reason = "the client is not open"}
	return _client_next_event(k, timeout, watch, on_watch, data)
}

// client_interrupt ends the current wait with .Interrupted; safe from a
// signal handler or another thread.
client_interrupt :: proc "contextless" (c: ^Client) {
	k := _client(c)
	if k == nil do return
	sync.atomic_store(&k.interrupted, true)
	b := u8(1)
	posix.write(k.wake[1], &b, 1)
}

client_stream_send :: proc(c: ^Client, channel: u32, kind: u8, body: []u8) -> Error {
	k := _client(c)
	if k == nil do return {kind = .Closed, reason = "the client is not open"}
	if channel == 0 do return {kind = .Bad_Opts, reason = "channel 0 carries requests"}
	if k.conn.err != .None do return {kind = .Closed, reason = "the connection is closed"}
	if !stream_send(&k.conn, kind, channel, body) {
		k.conn.err = .None
		return {kind = .Busy, reason = "the send queue is full"}
	}
	stream_flush(&k.conn)
	return {}
}

client_stream_ack :: proc(c: ^Client, channel: u32, n: int) {
	k := _client(c)
	if k == nil || n <= 0 do return
	stream_ack(&k.conn, channel, n)
	stream_flush(&k.conn)
}

// line_call: a .Line client. Connects, checks the server's uid, sends one
// line (a missing '\n' is added) and reads until the server closes. The
// answer is returned as is, "err ..." lines included; out too small for it
// is .Bad_Reply.
line_call :: proc(at: Endpoint, line: string, out: []u8, timeout := CALL_DEFAULT) -> (reply: string, err: Error) {
	path_buf: [_SUN_PATH]u8
	path: string
	if path, err = _endpoint_path(at, path_buf[:]); err.kind != .None do return
	fd: posix.FD
	if fd, err = _dial(path); err.kind != .None do return
	defer posix.close(fd)
	due := _call_due(timeout)
	nl := "" if len(line) > 0 && line[len(line) - 1] == '\n' else "\n"
	if err = _line_send(fd, transmute([]u8)line, due); err.kind != .None do return
	if err = _line_send(fd, transmute([]u8)nl, due); err.kind != .None do return
	n: int
	n, err = _line_read_all(fd, out, due)
	return string(out[:n]), err
}
