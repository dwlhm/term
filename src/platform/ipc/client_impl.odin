package platform_ipc

// What a Client holds behind its handle (spec 7.7): one Stream_Conn, the
// next req, the tickets of client_start requests still open, and a wake
// pipe that client_interrupt writes from a signal handler. Every wait is one
// poll(2) on the conn, the wake pipe and the caller's watch fd, bounded by
// its deadline: no polling in chunks. Calls: client_call.odin.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:time"

@(private)
_CLIENT_TICKETS :: 64

@(private = "file")
_HANDSHAKE_MS :: 5000

@(private)
_Ticket_Slot :: struct {
	req:  u32,
	kind: u8,
	used: bool,
}

@(private)
_Client :: struct {
	conn:        Stream_Conn,
	proto:       Protocol,
	next_req:    u32,
	tickets:     [_CLIENT_TICKETS]_Ticket_Slot,
	wake:        [2]posix.FD,
	interrupted: bool, // atomic
	allocator:   runtime.Allocator,
}

@(private)
_client :: proc "contextless" (c: ^Client) -> ^_Client {
	return (^_Client)(c._impl) if c != nil else nil
}

@(private)
_Wait :: enum u8 {
	Ready,   // the conn moved (or may have): look at it
	Woken,   // client_interrupt
	Watch,   // the caller's watch fd is readable
	Timeout,
}

// _client_wait polls once until due (-1 = none), writing and reading the
// conn as far as it can.
@(private)
_client_wait :: proc(k: ^_Client, due: i64, watch: posix.FD = -1) -> _Wait {
	fds := [3]posix.pollfd{{fd = k.conn.fd, events = {.IN}}, {fd = k.wake[0], events = {.IN}}, {fd = watch, events = {.IN}}}
	if stream_wants_write(&k.conn) do fds[0].events += {.OUT}
	timeout := -1
	if due >= 0 do timeout = int(max(0, (due - time.tick_now()._nsec + 999_999) / 1_000_000))
	n := posix.poll(raw_data(fds[:]), 3 if watch > 0 else 2, i32(timeout))
	if n == 0 do return .Timeout
	if n < 0 do return .Ready // EINTR: the caller looks at the interrupt flag
	if .OUT in fds[0].revents do stream_flush(&k.conn)
	if fds[0].revents - {.OUT} != {} do stream_fill(&k.conn)
	if fds[1].revents != {} {
		buf: [64]u8
		for posix.read(k.wake[0], raw_data(buf[:]), len(buf)) > 0 {}
		return .Woken
	}
	if watch > 0 && fds[2].revents != {} && fds[0].revents == {} do return .Watch
	return .Ready
}

// _client_connect dials (starting the server when asked), says HELLO and
// waits for the server's; a refusal is HELLO + FAIL.
@(private)
_client_connect :: proc(k: ^_Client, path: string, opts: Client_Opts) -> Error {
	fd, err := _dial(path)
	if err.kind == .No_Server && len(opts.start) > 0 do fd, err = _start_server(path, opts)
	if err.kind != .None do return err
	stream_conn_reserve(&k.conn, 0, k.allocator)
	if !stream_conn_attach(&k.conn, fd) do return {kind = .Closed, reason = "cannot set up the connection"}
	hb: [_HELLO_MAX]u8
	stream_send(&k.conn, k.proto.hello_kind, 0, _hello_body(hb[:], k.proto.version, opts.role))
	stream_flush(&k.conn)
	return _client_handshake(k, time.tick_now()._nsec + _HANDSHAKE_MS * 1_000_000)
}

@(private = "file")
_client_handshake :: proc(k: ^_Client, due: i64) -> Error {
	for {
		if f, ok := stream_next(&k.conn); ok do return _client_hello(k, f)
		if k.conn.err != .None do return {kind = .Handshake, reason = fmt.tprintf("%s: the server closed during the handshake", k.proto.name)}
		if _client_wait(k, due) == .Timeout do return {kind = .Handshake, reason = fmt.tprintf("%s: no HELLO from the server", k.proto.name)}
	}
}

// _client_hello checks the server's HELLO and whether a FAIL came with it.
@(private = "file")
_client_hello :: proc(k: ^_Client, f: Stream_Frame) -> Error {
	h, ok := _hello_decode(f.payload)
	if f.kind != k.proto.hello_kind || f.channel != 0 || !ok do return {kind = .Handshake, reason = "the server did not answer with HELLO"}
	if !_version_match(k.proto.version, h.version) {
		return {kind = .Version, reason = _version_reason(k.proto.name, k.proto.version, h.version)}
	}
	stream_fill(&k.conn) // a refusal is written together with its HELLO
	next, more := stream_next(&k.conn)
	if !more || next.kind != k.proto.fail_kind || next.channel != 0 do return {}
	_, code, reason := _fail_decode(next.payload)
	switch code {
	case FAIL_BUSY:    return {kind = .Busy, reason = reason}
	case FAIL_VERSION: return {kind = .Version, reason = reason}
	}
	return {kind = .Handshake, reason = reason}
}

// _fail_decode reads FAIL: u32 req · u8 code · str reason (reason in temp_allocator).
@(private)
_fail_decode :: proc(payload: []u8) -> (req: u32, code: u8, reason: string) {
	r := wire_reader(payload)
	req, code = wr_u32(&r), wr_u8(&r)
	return req, code, strings.clone(wr_str(&r), context.temp_allocator)
}

// _start_server spawns opts.start, then dials until start_ms.
@(private = "file")
_start_server :: proc(path: string, opts: Client_Opts) -> (fd: posix.FD, err: Error) {
	if opts.log != "" {
		slash := strings.last_index_byte(opts.log, '/')
		if err = _dir_check(opts.log[:max(slash, 0)] if slash > 0 else "/"); err.kind != .None do return -1, err
	}
	if !_spawn_detached(opts.start, opts.log) do return -1, {kind = .Start_Failed, reason = "cannot start the server"}
	due := time.tick_now()._nsec + i64(opts.start_ms) * 1_000_000
	for time.tick_now()._nsec < due {
		if fd, err = _dial(path); err.kind != .No_Server do return
		time.sleep(20 * time.Millisecond)
	}
	return -1, {kind = .Start_Failed, reason = fmt.tprintf("the started server did not listen at %s in time", path)}
}
