package platform_ipc_contract

// P25, P26: Server{.Line} on its own IO thread (server_open_thread) and
// line_call. One line in, one answer out, then close; overload, oversize and
// silence are answered by the package itself.

import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"
import ipc "../"

@(private = "file")
_wake :: proc "contextless" (data: rawptr) { sync.atomic_store((^bool)(data), true) }

@(private = "file")
_Line_Call :: struct {
	at:    ipc.Endpoint,
	buf:   [64]u8,
	reply: string,
	err:   ipc.Error,
}

@(private = "file")
_line_client :: proc(lc: ^_Line_Call) { lc.reply, lc.err = ipc.line_call(lc.at, "hello", lc.buf[:], 2 * time.Second) }

// _take_request waits for on_wake, then takes a Request from server_next,
// timing every server_next call; the slowest one comes back as well.
@(private = "file")
_take_request :: proc(s: ^ipc.Server, woken: ^bool, ms: int) -> (req: ipc.Request, ok: bool, slowest: f64) {
	due := now_ns() + i64(ms) * 1_000_000
	for now_ns() < due && !ok {
		if !sync.atomic_exchange(woken, false) {
			time.sleep(time.Millisecond)
			continue
		}
		for {
			start := time.tick_now()
			ev, more := ipc.server_next(s)
			slowest = max(slowest, ms_since(start))
			if !more do break
			if r, is_req := ev.(ipc.Request); is_req do req, ok = r, true
		}
	}
	return
}

@(test)
test_P25_line_call_to_a_threaded_line_server :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	dir := test_dir()
	defer test_dir_remove(dir)
	s: ipc.Server
	woken: bool
	if !expect_ok(t, ipc.server_open_thread(&s, {dir, "c"}, test_protocol(), _wake, &woken, {framing = .Line}), "server_open_thread") do return
	defer ipc.server_close(&s)
	start := time.tick_now()
	_, any := ipc.server_next(&s)
	testing.expect(t, !any && ms_since(start) < 5, "server_next blocked or made up an event")
	lc := _Line_Call{at = {dir, "c"}}
	client := thread.create_and_start_with_poly_data(&lc, _line_client, context)
	req, ok, slowest := _take_request(&s, &woken, 2000)
	if ok {
		testing.expect_value(t, ipc.request_line(&req), "hello")
		ipc.reply(&s, req, transmute([]u8)string("world\n"))
	}
	thread.join(client)
	thread.destroy(client)
	testing.expect(t, ok, "on_wake never led to the request")
	testing.expectf(t, slowest < 5, "server_next took %.1f ms on the owner's thread", slowest)
	expect_ok(t, lc.err, "line_call")
	testing.expect_value(t, lc.reply, "world\n")
}

// _read_to_close returns what fd receives until the server closes it.
@(private = "file")
_read_to_close :: proc(fd: posix.FD, buf: []u8, ms: int) -> string {
	due := now_ns() + i64(ms) * 1_000_000
	n := 0
	for n < len(buf) {
		left := int((due - now_ns()) / 1_000_000)
		if left <= 0 || !raw_wait(fd, left) do break
		got := posix.recv(fd, raw_data(buf[n:]), len(buf[n:]), {})
		if got <= 0 do break
		n += int(got)
	}
	return string(buf[:n])
}

LINE_OPTS :: ipc.Server_Opts{framing = .Line, max_peers = 1, hello_ms = 300, max_payload = 64}

@(private = "file")
_line_server :: proc(t: ^testing.T, s: ^ipc.Server, dir: string, woken: ^bool) -> bool {
	return expect_ok(t, ipc.server_open_thread(s, {dir, "c"}, test_protocol(), _wake, woken, LINE_OPTS), "server_open_thread")
}

@(test)
test_P26_line_past_max_payload :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	dir := test_dir()
	defer test_dir_remove(dir)
	s: ipc.Server
	woken: bool
	if !_line_server(t, &s, dir, &woken) do return
	defer ipc.server_close(&s)
	fd := raw_dial({dir, "c"})
	defer posix.close(fd)
	long: [65]u8
	for &b in long do b = 'a'
	raw_write(fd, long[:])
	buf: [64]u8
	testing.expect_value(t, _read_to_close(fd, buf[:], 1000), "err too_large\n")
}

@(test)
test_P26_silent_line_client :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	dir := test_dir()
	defer test_dir_remove(dir)
	s: ipc.Server
	woken: bool
	if !_line_server(t, &s, dir, &woken) do return
	defer ipc.server_close(&s)
	fd := raw_dial({dir, "c"})
	defer posix.close(fd)
	buf: [64]u8
	testing.expect_value(t, _read_to_close(fd, buf[:], 1500), "err timeout\n")
}

@(test)
test_P26_line_server_full :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	dir := test_dir()
	defer test_dir_remove(dir)
	s: ipc.Server
	woken: bool
	if !_line_server(t, &s, dir, &woken) do return
	defer ipc.server_close(&s)
	holder := raw_dial({dir, "c"}) // silent: keeps the one slot until hello_ms
	defer posix.close(holder)
	fd := raw_dial({dir, "c"})
	defer posix.close(fd)
	buf: [64]u8
	testing.expect_value(t, _read_to_close(fd, buf[:], 250), "err busy\n")
}
