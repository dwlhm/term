package platform_ipc_contract

// Inline: the test thread drives a Server itself, with raw peers whose bytes
// sit in the socket buffers meanwhile. Used where an assert must happen on
// the test thread or the exact order of events matters.

import "core:reflect"
import "core:sys/posix"
import "core:testing"
import ipc "../"

Inline :: struct {
	set: ipc.Poll_Set,
	srv: ipc.Server,
}

inline_open :: proc(t: ^testing.T, in_: ^Inline, at: ipc.Endpoint, opts := ipc.Server_Opts{}, loc := #caller_location) -> bool {
	if !expect_ok(t, ipc.poll_set_init(&in_.set, 64), "poll_set_init", loc) do return false
	if !expect_ok(t, ipc.server_open(&in_.srv, at, test_protocol(), &in_.set, opts), "server_open", loc) {
		ipc.poll_set_destroy(&in_.set)
		return false
	}
	return true
}

inline_close :: proc(in_: ^Inline) {
	ipc.server_close(&in_.srv)
	ipc.poll_set_destroy(&in_.set)
}

// inline_dial connects a raw peer and queues its HELLO; the server's HELLO
// is read by inline_take_hello once the server has run.
inline_dial :: proc(at: ipc.Endpoint) -> posix.FD {
	fd := raw_dial(at)
	hb: [64]u8
	if fd >= 0 do raw_send(fd, HELLO_KIND, 0, hello_body(hb[:], TEST_VERSION, TEST_ROLE_CLIENT))
	return fd
}

inline_take_hello :: proc(fd: posix.FD) -> bool {
	buf: [256]u8
	f, ok := raw_frame(fd, buf[:], 1000)
	return ok && f.kind == HELLO_KIND
}

// inline_next runs the server until it yields an event of type want, for up to ms.
inline_next :: proc(in_: ^Inline, ms: int, want: typeid) -> (ev: ipc.Server_Event, ok: bool) {
	due := now_ns() + i64(ms) * 1_000_000
	for now_ns() < due {
		for e in ipc.server_next(&in_.srv) {
			if reflect.union_variant_typeid(e) == want do return e, true
		}
		ipc.poll_set_wait(&in_.set, due)
	}
	return nil, false
}

inline_request :: proc(in_: ^Inline, ms := 2000) -> (ipc.Request, bool) {
	ev, ok := inline_next(in_, ms, ipc.Request)
	return ev.(ipc.Request) or_else {}, ok
}

// inline_pump runs the server for ms (sending what it queued) and returns
// how many Requests it yielded meanwhile.
inline_pump :: proc(in_: ^Inline, ms: int) -> (requests: int) {
	due := now_ns() + i64(ms) * 1_000_000
	for now_ns() < due {
		ipc.poll_set_wait(&in_.set, due)
		for e in ipc.server_next(&in_.srv) do if _, is_req := e.(ipc.Request); is_req do requests += 1
	}
	return
}

