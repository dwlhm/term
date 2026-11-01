package feature_holder_tests

import "core:sys/posix"
import "core:testing"
import "core:time"
import holder ".."
import ipc "../../../platform/ipc"

// A core that never reads: the holder's queue stays bounded and the program
// is throttled (it blocks on its full PTY instead of filling memory).
@(test)
test_stalled_core_throttles_program :: proc(t: ^testing.T) {
	f := fixture_start()
	c := client_connect(f.path)
	c.keep = false
	client_spawn(c, 1, {"/usr/bin/yes"})
	time.sleep(1500 * time.Millisecond) // never read meanwhile
	client_signal(c, 1, .SIGSTOP)
	time.sleep(100 * time.Millisecond)
	quiet := 0
	for quiet < 10 && !c.closed {
		before := c.bytes
		client_pump(c, 50)
		quiet = quiet + 1 if c.bytes == before else 0
	}
	limit := holder.HOLDER_CTL_CAP + 4 << 20 // + socket and PTY buffers
	testing.expectf(t, c.bytes > 1 << 20, "yes produced output (%d bytes)", c.bytes)
	testing.expectf(t, c.bytes <= limit, "backlog bounded: %d bytes > %d", c.bytes, limit)
	testing.expect(t, !c.closed, "a slow core is throttled, not dropped")
	client_signal(c, 1, .SIGKILL)
	client_close(c)
	testing.expect_value(t, fixture_stop(f), 0)
}

@(test)
test_oversize_frame_closes_conn :: proc(t: ^testing.T) {
	f := fixture_start()
	c := client_connect(f.path)
	testing.expect(t, client_wait_kind(c, ipc.MSG_WELCOME, 0, 3000) >= 0, "WELCOME")
	hdr: [ipc.STREAM_HEADER]u8
	ipc.stream_put_header(hdr[:], ipc.MSG_INPUT, 1, 0)
	hdr[5], hdr[6], hdr[7], hdr[8] = 0xff, 0xff, 0xff, 0x7f // len > STREAM_MAX_PAYLOAD
	posix.send(c.conn.fd, &hdr[0], len(hdr), {})
	for _ in 0..<40 do if !c.closed do client_pump(c, 50)
	testing.expect(t, c.closed, "oversize frame closes the link")
	client_close(c)
	testing.expect(t, fixture_running(f), "holder survives")
	expect_new_core_works(t, f)
	testing.expect_value(t, fixture_stop(f), 0)
}

@(test)
test_garbage_and_bad_requests :: proc(t: ^testing.T) {
	f := fixture_start()
	// A connection whose first frame is not HELLO is closed.
	g := client_connect_raw(f.path)
	junk := [?]u8{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}
	posix.send(g, &junk[0], len(junk), {})
	testing.expect(t, wait_eof(g), "garbage connection closed")
	posix.close(g)

	c := client_connect(f.path)
	argc0: [8]u8 // SPAWN with argc = 0
	client_send(c, ipc.MSG_SPAWN, 1, argc0[:])
	testing.expect(t, client_wait_kind(c, ipc.MSG_SPAWN_FAILED, 1, 3000) >= 0, "bad SPAWN answered")
	client_send(c, 250, 0) // unknown kind
	for _ in 0..<40 do if !c.closed do client_pump(c, 50)
	testing.expect(t, c.closed, "unknown message closes the link")
	client_close(c)
	expect_new_core_works(t, f)
	testing.expect_value(t, fixture_stop(f), 0)
}

@(test)
test_drain_exits_when_empty :: proc(t: ^testing.T) {
	f := fixture_start()
	c := client_connect(f.path)
	client_spawn(c, 1, {"/bin/sleep", "30"})
	testing.expect(t, client_wait_kind(c, ipc.MSG_SPAWNED, 1, 3000) >= 0, "SPAWNED")
	client_send(c, ipc.MSG_DRAIN, 0)
	client_spawn(c, 2, {"/bin/sleep", "30"})
	testing.expect(t, client_wait_kind(c, ipc.MSG_SPAWN_FAILED, 2, 3000) >= 0, "no new session while draining")
	client_send(c, ipc.MSG_RELEASE, 1)
	testing.expect(t, client_wait_kind(c, ipc.MSG_BYE, 0, 3000) >= 0, "BYE once empty")
	for _ in 0..<100 do if fixture_running(f) do time.sleep(20 * time.Millisecond)
	testing.expect(t, !fixture_running(f), "drained holder exits")
	client_close(c)
	testing.expect_value(t, fixture_stop(f), 0)
}

expect_new_core_works :: proc(t: ^testing.T, f: ^Fixture) {
	c := client_connect(f.path)
	testing.expect(t, c != nil && client_wait_kind(c, ipc.MSG_WELCOME, 0, 3000) >= 0, "a new core is welcomed")
	if c != nil do client_close(c)
}

client_connect_raw :: proc(path: string) -> posix.FD {
	fd := posix.socket(.UNIX, .STREAM)
	addr: posix.sockaddr_un
	ipc.ipc_fill_sockaddr(path, &addr)
	posix.connect(fd, (^posix.sockaddr)(&addr), size_of(addr))
	return fd
}

wait_eof :: proc(fd: posix.FD) -> bool {
	pfd := posix.pollfd{fd = fd, events = {.IN}}
	if posix.poll(&pfd, 1, 3000) <= 0 do return false
	b: [16]u8
	return posix.recv(fd, &b[0], len(b), {}) <= 0
}
