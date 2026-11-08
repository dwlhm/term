package platform_ipc_contract

// P9 (reserved codes), P16–P18: the Server's side of a request. Raw peers
// send exactly the frames under test; the server runs on the test thread.

import "core:sys/posix"
import "core:testing"
import "core:time"
import ipc "../"

// _one_request: an inline server with one raw peer that sent PING(req).
@(private = "file")
_one_request :: proc(t: ^testing.T, in_: ^Inline, dir: string, req: u32, opts := ipc.Server_Opts{}) -> (r: ipc.Request, fd: posix.FD, ok: bool) {
	at := ipc.Endpoint{dir, "s"}
	if !inline_open(t, in_, at, opts) do return
	fd = inline_dial(at)
	body := u32le_bytes(5)
	raw_request(fd, req, TEST_PING, body[:])
	r, ok = inline_request(in_)
	testing.expect(t, ok, "the PING never reached the server")
	return
}

@(private = "file")
_assert_dir: [256]u8

// remove_after_assert removes dir even when the test ends in its expected
// assert: the runner still runs cleanups then, but the test's own memory and
// defers are gone, so the path is kept in a fixed buffer.
remove_after_assert :: proc(t: ^testing.T, dir: string) {
	n := copy(_assert_dir[:len(_assert_dir) - 1], dir)
	_assert_dir[n] = 0
	testing.cleanup(t, proc(_: rawptr) { test_dir_remove(string(cstring(&_assert_dir[0]))) }, nil)
}

@(private = "file")
_reserved_code_asserts :: proc(t: ^testing.T, code: u8) {
	testing.set_fail_timeout(t, 10 * time.Second)
	dir := test_dir()
	remove_after_assert(t, dir)
	in_: Inline
	req, fd, ok := _one_request(t, &in_, dir, 1)
	if !ok do return
	defer { posix.close(fd); inline_close(&in_) }
	testing.expect_assert_message(t, ASSERT_RESERVED_FAIL)
	ipc.fail(&in_.srv, req, code, "reserved")
}

@(test) test_P9_fail_with_reserved_code_3_asserts :: proc(t: ^testing.T) { _reserved_code_asserts(t, ipc.FAIL_BAD_REQUEST) }
@(test) test_P9_fail_with_reserved_code_5_asserts :: proc(t: ^testing.T) { _reserved_code_asserts(t, ipc.FAIL_BUSY) }
@(test) test_P9_fail_with_reserved_code_6_asserts :: proc(t: ^testing.T) { _reserved_code_asserts(t, ipc.FAIL_VERSION) }
@(test) test_P9_fail_with_reserved_code_7_asserts :: proc(t: ^testing.T) { _reserved_code_asserts(t, ipc.FAIL_TIMEOUT) }

@(test)
test_P16_second_reply_asserts :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	dir := test_dir()
	remove_after_assert(t, dir)
	in_: Inline
	req, fd, ok := _one_request(t, &in_, dir, 1)
	if !ok do return
	defer { posix.close(fd); inline_close(&in_) }
	reply_u32(&in_.srv, req, 1)
	testing.expect_assert_message(t, ASSERT_SECOND_REPLY)
	reply_u32(&in_.srv, req, 2)
}

@(test)
test_P16_reply_to_a_peer_that_left_reaches_nobody :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	dir := test_dir()
	defer test_dir_remove(dir)
	in_: Inline
	stale, a, ok := _one_request(t, &in_, dir, 1, {max_peers = 1})
	if !ok do return
	defer inline_close(&in_)
	posix.close(a)
	_, ok = inline_next(&in_, 2000, ipc.Peer_Left)
	testing.expect(t, ok, "no Peer_Left for the peer that closed")
	b := inline_dial({dir, "s"}) // takes the one slot the old peer had
	defer posix.close(b)
	inline_pump(&in_, 100)
	if !testing.expect(t, inline_take_hello(b), "the new peer got no HELLO") do return
	reply_u32(&in_.srv, stale, 1)
	inline_pump(&in_, 300)
	testing.expect(t, raw_silent(b, 0), "the new peer received the old peer's answer")
	body := u32le_bytes(5)
	raw_request(b, 1, TEST_PING, body[:]) // same req number, its own request
	fresh, got := inline_request(&in_)
	if !testing.expect(t, got, "the new peer's PING never arrived") do return
	testing.expect(t, fresh.peer != stale.peer, "a new peer in the same slot has the same Peer")
	reply_u32(&in_.srv, fresh, 6)
	inline_pump(&in_, 100)
	buf: [64]u8
	f, read := raw_frame(b, buf[:], 1000)
	testing.expect(t, read && f.kind == TEST_PONG && raw_req(f) == 1, "the new peer did not get its own answer")
	testing.expect(t, raw_silent(b, 100), "the new peer got more than one answer")
}

// expect_fail reads the next frame from fd and checks it is FAIL(req, code).
expect_fail :: proc(t: ^testing.T, fd: posix.FD, req: u32, code: u8, loc := #caller_location) -> bool {
	buf: [512]u8
	f, ok := raw_frame(fd, buf[:], 1000)
	m, is_fail := raw_fail(f)
	good := ok && is_fail && m.req == req && m.code == code
	testing.expectf(t, good, "want FAIL req %d code %d, got kind %d %v", req, code, f.kind, m, loc = loc)
	return good
}

@(test)
test_P17_bad_req_numbers_and_too_many_open :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	dir := test_dir()
	defer test_dir_remove(dir)
	in_: Inline
	if !inline_open(t, &in_, {dir, "s"}, {max_open = 2}) do return
	defer inline_close(&in_)
	fd := inline_dial({dir, "s"})
	defer posix.close(fd)
	body := u32le_bytes(5)
	for req in ([]u32{0, 5, 5, 6, 7}) do raw_request(fd, req, TEST_PING, body[:]) // 5 twice; 7 is the third open
	seen := inline_pump(&in_, 300)
	testing.expect_value(t, seen, 2) // req 5 and 6 only
	if !testing.expect(t, inline_take_hello(fd), "no HELLO") do return
	expect_fail(t, fd, 0, ipc.FAIL_BAD_REQUEST)
	expect_fail(t, fd, 5, ipc.FAIL_BAD_REQUEST)
	expect_fail(t, fd, 7, ipc.FAIL_BUSY)
}

// Every request row of the test catalog takes one u32; each gets a body cut
// short and one with a byte to spare.
@(private = "file")
_bad_bodies := [?][]u8{{1, 2}, {1, 2, 3, 4, 5}}

@(test)
test_P18_bodies_that_do_not_decode :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	dir := test_dir()
	defer test_dir_remove(dir)
	in_: Inline
	if !inline_open(t, &in_, {dir, "s"}) do return
	defer inline_close(&in_)
	fd := inline_dial({dir, "s"})
	defer posix.close(fd)
	inline_pump(&in_, 50)
	if !testing.expect(t, inline_take_hello(fd), "no HELLO") do return
	req := u32(1)
	for row in test_catalog do if !row.notice {
		for body in _bad_bodies {
			raw_request(fd, req, row.request, body)
			r, ok := inline_request(&in_)
			if !testing.expectf(t, ok, "kind %d body %v never arrived", row.request, body) do return
			v: u32
			testing.expectf(t, !ipc.request_decode(&r, &v, dec_u32), "kind %d body %v decoded", row.request, body)
			inline_pump(&in_, 50)
			expect_fail(t, fd, req, ipc.FAIL_BAD_REQUEST)
			req += 1
		}
	}
}
