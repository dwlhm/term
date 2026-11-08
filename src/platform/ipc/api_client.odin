package platform_ipc

// Client: one connection to a Server. client_open validates the endpoint,
// connects (or starts the server), checks the server's uid and does HELLO.
// Answers are matched to their request inside; callers never see req.

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
	path_buf: [_SUN_PATH]u8
	if _, err := _endpoint_path(at, path_buf[:]); err.kind != .None do return err
	return _not_implemented()
}

// client_close sends what is queued (at most 1 s), then closes. Idempotent.
client_close :: proc(c: ^Client) {}

client_call :: proc(c: ^Client, kind: u8, body: []u8, opts := Call_Opts{}) -> (Answer, Error) {
	return {}, _not_implemented()
}

// client_start sends a request whose answer comes later, as a Late_Answer.
client_start :: proc(c: ^Client, kind: u8, body: []u8) -> (Ticket, Error) {
	return 0, _not_implemented()
}

client_poll :: proc(c: ^Client, timeout: time.Duration) -> (Client_Event, Error) {
	return nil, _not_implemented()
}

// client_interrupt ends the current wait with .Interrupted; safe from a
// signal handler or another thread.
client_interrupt :: proc "contextless" (c: ^Client) {}

client_stream_send :: proc(c: ^Client, channel: u32, kind: u8, body: []u8) -> Error {
	return _not_implemented()
}

client_stream_ack :: proc(c: ^Client, channel: u32, n: int) {}

// line_call: a .Line client. Connects, checks the server's uid, sends one
// line and reads until the server closes.
line_call :: proc(at: Endpoint, line: string, out: []u8, timeout := CALL_DEFAULT) -> (reply: string, err: Error) {
	path_buf: [_SUN_PATH]u8
	if _, err = _endpoint_path(at, path_buf[:]); err.kind != .None do return
	return "", _not_implemented()
}
