package platform_ipc_contract

// P29–P31: listeners. Closed from outside → Listener_Broken within 1 s and no
// spin; EMFILE → a 100 ms backoff, then accept again; a socket path that
// another process took over is never unlinked.

import "core:sys/posix"
import "core:testing"
import "core:time"
import ipc "../"

// listener_fd finds the listening socket bound at path among our fds: bound
// there and with no peer (macOS has no SO_ACCEPTCONN for unix sockets).
listener_fd :: proc(path: string) -> posix.FD {
	for fd in posix.FD(0) ..< 1024 {
		addr, peer: posix.sockaddr_un
		n, pn := posix.socklen_t(size_of(addr)), posix.socklen_t(size_of(peer))
		if posix.getsockname(fd, (^posix.sockaddr)(&addr), &n) != .OK || addr.sun_family != .UNIX do continue
		if string(cstring(raw_data(addr.sun_path[:]))) != path do continue
		if posix.getpeername(fd, (^posix.sockaddr)(&peer), &pn) != .OK && posix.errno() == .ENOTCONN do return fd
	}
	return -1
}

@(test)
test_P29_server_listener_closed_from_outside :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	dir := test_dir()
	defer test_dir_remove(dir)
	in_: Inline
	if !inline_open(t, &in_, {dir, "s"}) do return
	defer inline_close(&in_)
	lfd := listener_fd(sock_path({dir, "s"}))
	if !testing.expect(t, lfd >= 0, "no listening socket at the endpoint") do return
	posix.close(lfd)
	start, cpu := time.tick_now(), cpu_ms()
	ev, ok := inline_next(&in_, 1000, ipc.Server_Down)
	testing.expectf(t, ok, "no Server_Down %.0f ms after the listener was closed", ms_since(start))
	testing.expect_value(t, ev.(ipc.Server_Down).err.kind if ok else .None, ipc.Error_Kind.Listener_Broken)
	testing.expectf(t, cpu_ms() - cpu < 100, "%.0f ms of CPU until Server_Down", cpu_ms() - cpu)
	_, more := ipc.server_next(&in_.srv)
	testing.expect(t, !more, "events after Server_Down")
	_expect_idle(t, &in_.set)
}

@(test)
test_P29_link_listener_closed_from_outside :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	dir := test_dir()
	defer test_dir_remove(dir)
	set: ipc.Poll_Set
	if !expect_ok(t, ipc.poll_set_init(&set, 8), "poll_set_init") do return
	defer ipc.poll_set_destroy(&set)
	l: ipc.Link
	if !expect_ok(t, ipc.link_listen(&l, {dir, "l"}, link_protocol(), &set), "link_listen") do return
	defer ipc.link_close(&l)
	lfd := listener_fd(sock_path({dir, "l"}))
	if !testing.expect(t, lfd >= 0, "no listening socket at the endpoint") do return
	posix.close(lfd)
	start, cpu := time.tick_now(), cpu_ms()
	err := _next_link_down(&l, &set, 1000)
	expect_kind(t, err, .Listener_Broken, "Link_Down")
	testing.expectf(t, ms_since(start) <= 1000 && cpu_ms() - cpu < 100, "%.0f ms, %.0f ms CPU", ms_since(start), cpu_ms() - cpu)
	_, more := ipc.link_next(&l)
	testing.expect(t, !more, "events after Link_Down")
	_expect_idle(t, &set)
}

@(private = "file")
_next_link_down :: proc(l: ^ipc.Link, set: ^ipc.Poll_Set, ms: int) -> ipc.Error {
	due := now_ns() + i64(ms) * 1_000_000
	for now_ns() < due {
		for ev in ipc.link_next(l) do if down, ok := ev.(ipc.Link_Down); ok do return down.err
		ipc.poll_set_wait(set, due)
	}
	return {}
}

// _expect_idle: with nothing left to watch, a wait sleeps and burns no CPU.
@(private = "file")
_expect_idle :: proc(t: ^testing.T, set: ^ipc.Poll_Set, loc := #caller_location) {
	start, cpu := time.tick_now(), cpu_ms()
	ipc.poll_set_wait(set, now_ns() + 300_000_000)
	testing.expectf(t, ms_since(start) >= 280 && cpu_ms() - cpu < 30, "idle wait: %.0f ms, %.0f ms CPU", ms_since(start), cpu_ms() - cpu, loc = loc)
}

@(test)
test_P30_emfile_backs_off_then_accepts :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 20 * time.Second)
	dir := test_dir()
	defer test_dir_remove(dir)
	at := ipc.Endpoint{dir, "s"}
	pid := child_spawn("emfile", at) // a server with exactly one free fd left
	if !testing.expect(t, pid > 0, "cannot spawn the child") do return
	defer child_reap(pid)
	a: ipc.Client
	defer ipc.client_close(&a)
	ready := false
	for _ in 0 ..< 150 {
		if ready = ipc.client_open(&a, at, test_protocol(), {role = TEST_ROLE_CLIENT}).kind == .None; ready do break
		time.sleep(20 * time.Millisecond)
	}
	if !testing.expect(t, ready, "the child never served") do return
	b := inline_dial(at) // waits in the backlog: accepting it hits EMFILE
	defer posix.close(b)
	time.sleep(300 * time.Millisecond)
	w1, e1 := child_ask(&a, CHILD_ASK_WAKES)
	time.sleep(500 * time.Millisecond)
	w2, e2 := child_ask(&a, CHILD_ASK_WAKES)
	if !expect_ok(t, e1, "ask") || !expect_ok(t, e2, "ask") do return
	testing.expectf(t, w2 - w1 <= 12, "%d wakes in 500 ms under EMFILE, want about 5 (100 ms backoff)", w2 - w1)
	ipc.client_close(&a) // frees the child's one fd
	start := time.tick_now()
	testing.expect(t, inline_take_hello(b), "the waiting connection was never accepted")
	testing.expectf(t, ms_since(start) <= 400, "accepted %.0f ms after an fd was free", ms_since(start))
}

@(test)
test_P31_replaced_socket_path_is_not_unlinked :: proc(t: ^testing.T) {
	dir := test_dir()
	defer test_dir_remove(dir)
	set: ipc.Poll_Set
	if !expect_ok(t, ipc.poll_set_init(&set, 8), "poll_set_init") do return
	defer ipc.poll_set_destroy(&set)
	s: ipc.Server
	l: ipc.Link
	defer ipc.server_close(&s)
	defer ipc.link_close(&l)
	if !expect_ok(t, ipc.server_open(&s, {dir, "s"}, test_protocol(), &set), "server_open") do return
	if !expect_ok(t, ipc.link_listen(&l, {dir, "l"}, link_protocol(), &set), "link_listen") do return
	for name in ([]string{"s", "l"}) {
		path := sock_path({dir, name})
		posix.unlink(cstr(path))
		fd := raw_listen({dir, name}) // someone else's socket now
		defer posix.close(fd)
		ino := inode(path)
		if name == "s" do ipc.server_close(&s)
		else do ipc.link_close(&l)
		testing.expectf(t, exists(path) && inode(path) == ino, "closing unlinked a socket that was not ours (%s)", name)
	}
}
