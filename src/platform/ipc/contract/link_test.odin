package platform_ipc_contract

// P32: link_listen against garbage, a HELLO that trickles in, more pending
// HELLOs than allowed, a newer peer (its Link_Down says replaced), a peer
// that just leaves, and link_drop (the listener stays). The listening side's
// memory is counted on its own allocator and must not move after link_listen.

import "core:mem"
import "core:sys/posix"
import "core:testing"
import "core:time"
import ipc "../"

@(private = "file")
_Listen :: struct {
	set:    ipc.Poll_Set,
	l:      ipc.Link,
	track:  mem.Tracking_Allocator,
	base:   i64,     // listen side bytes right after link_listen
	events: [8]u8,   // 'U' / 'D' / 'R' (Down, replaced by a newer peer) in order
	n:      int,
}

@(private = "file")
_listen_open :: proc(t: ^testing.T, ls: ^_Listen, at: ipc.Endpoint, opts: ipc.Link_Opts) -> bool {
	mem.tracking_allocator_init(&ls.track, context.allocator)
	context.allocator = mem.tracking_allocator(&ls.track)
	if !expect_ok(t, ipc.poll_set_init(&ls.set, 16), "poll_set_init") do return false
	if !expect_ok(t, ipc.link_listen(&ls.l, at, link_protocol(), &ls.set, opts), "link_listen") do return false
	ls.base = ls.track.current_memory_allocated
	return true
}

@(private = "file")
_listen_close :: proc(t: ^testing.T, ls: ^_Listen) {
	context.allocator = mem.tracking_allocator(&ls.track)
	testing.expectf(t, ls.track.current_memory_allocated == ls.base, "the listening Link grew from %d to %d bytes", ls.base, ls.track.current_memory_allocated)
	ipc.link_close(&ls.l)
	ipc.poll_set_destroy(&ls.set)
	mem.tracking_allocator_destroy(&ls.track)
}

// _Dial: the dialling side of P32, on a Poll_Set of its own.
@(private = "file")
_Dial :: struct {
	set:    ipc.Poll_Set,
	a, b:   ipc.Link,
	a_down: bool,
}

// _pump runs the listening side (and dial, when given) for ms, recording
// the listening side's Link_Up/Link_Down in order.
@(private = "file")
_pump :: proc(ls: ^_Listen, ms: int, dial: ^_Dial = nil) {
	due := now_ns() + i64(ms) * 1_000_000
	for now_ns() < due {
		{
			context.allocator = mem.tracking_allocator(&ls.track)
			ipc.poll_set_wait(&ls.set, due if dial == nil else min(due, now_ns() + 5_000_000))
			for ev in ipc.link_next(&ls.l) do _mark(ls, ev)
		}
		if dial == nil do continue
		ipc.poll_set_wait(&dial.set, now_ns())
		for ev in ipc.link_next(&dial.a) do if _, down := ev.(ipc.Link_Down); down do dial.a_down = true
		for _ in ipc.link_next(&dial.b) {}
	}
}

@(private = "file")
_mark :: proc(ls: ^_Listen, ev: ipc.Link_Event) {
	mark: u8
	#partial switch _ in ev {
	case ipc.Link_Up:   mark = 'U'
	case ipc.Link_Down: mark = 'R' if ev.(ipc.Link_Down).replaced else 'D'
	}
	if mark != 0 && ls.n < len(ls.events) do ls.events[ls.n], ls.n = mark, ls.n + 1
}

// _hung_up: fd's peer has closed (non-blocking check).
@(private = "file")
_hung_up :: proc(fd: posix.FD) -> bool {
	b: [1]u8
	return raw_wait(fd, 0) && posix.recv(fd, raw_data(b[:]), 1, {.PEEK}) <= 0
}

@(test)
test_P32_garbage_is_closed :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	dir := test_dir()
	defer test_dir_remove(dir)
	ls: _Listen
	if !_listen_open(t, &ls, {dir, "l"}, {hello_ms = 500}) do return
	defer _listen_close(t, &ls)
	fd := raw_dial({dir, "l"})
	defer posix.close(fd)
	raw_send(fd, 0xee, 7, transmute([]u8)string("not a hello"))
	_pump(&ls, 200)
	testing.expect(t, _hung_up(fd), "garbage was not closed well before hello_ms")
}

@(test)
test_P32_slow_hello_is_closed_at_hello_ms :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	dir := test_dir()
	defer test_dir_remove(dir)
	ls: _Listen
	if !_listen_open(t, &ls, {dir, "l"}, {hello_ms = 500}) do return
	defer _listen_close(t, &ls)
	fd := raw_dial({dir, "l"})
	defer posix.close(fd)
	start := time.tick_now()
	hb, fb: [128]u8
	frame := frame_bytes(fb[:], HELLO_KIND, 0, hello_body(hb[:], {0, 0, 2}, TEST_ROLE_CLIENT))
	for i in 0 ..< len(frame) {
		if _hung_up(fd) do break
		raw_write(fd, frame[i:i + 1]) // one byte per 100 ms
		_pump(&ls, 100)
	}
	ms := ms_since(start)
	testing.expect(t, _hung_up(fd), "a HELLO trickling in was never closed")
	testing.expectf(t, ms >= 500 && ms < 1000, "closed after %.0f ms, hello_ms is 500", ms)
}

@(test)
test_P32_oldest_pending_hello_yields :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	dir := test_dir()
	defer test_dir_remove(dir)
	ls: _Listen
	if !_listen_open(t, &ls, {dir, "l"}, {pending = 2}) do return
	defer _listen_close(t, &ls)
	fds: [3]posix.FD
	for &fd in fds {
		fd = raw_dial({dir, "l"}) // says nothing: HELLO still pending
		_pump(&ls, 30)
	}
	defer for fd in fds do posix.close(fd)
	_pump(&ls, 100)
	testing.expect(t, _hung_up(fds[0]), "the oldest pending peer did not yield")
	testing.expect(t, !_hung_up(fds[1]) && !_hung_up(fds[2]), "a newer pending peer was closed")
}

@(test)
test_P32_newest_peer_replaces_the_old :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	dir := test_dir()
	defer test_dir_remove(dir)
	ls: _Listen
	if !_listen_open(t, &ls, {dir, "l"}, {}) do return
	defer _listen_close(t, &ls)
	d: _Dial
	if !expect_ok(t, ipc.poll_set_init(&d.set, 8), "poll_set_init") do return
	defer ipc.poll_set_destroy(&d.set)
	defer ipc.link_close(&d.a)
	defer ipc.link_close(&d.b)
	if !expect_ok(t, ipc.link_dial(&d.a, {dir, "l"}, link_protocol(), TEST_ROLE_CLIENT, &d.set), "dial a") do return
	_pump(&ls, 100, &d)
	if !expect_ok(t, ipc.link_dial(&d.b, {dir, "l"}, link_protocol(), TEST_ROLE_CLIENT, &d.set), "dial b") do return
	_pump(&ls, 100, &d)
	testing.expect_value(t, string(ls.events[:ls.n]), "URU")
	testing.expect(t, d.a_down, "the replaced peer saw no Link_Down")
}

@(test)
test_P32_lost_peer_is_not_replaced :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	dir := test_dir()
	defer test_dir_remove(dir)
	ls: _Listen
	if !_listen_open(t, &ls, {dir, "l"}, {}) do return
	defer _listen_close(t, &ls)
	d: _Dial
	if !expect_ok(t, ipc.poll_set_init(&d.set, 8), "poll_set_init") do return
	defer ipc.poll_set_destroy(&d.set)
	if !expect_ok(t, ipc.link_dial(&d.a, {dir, "l"}, link_protocol(), TEST_ROLE_CLIENT, &d.set), "dial a") do return
	_pump(&ls, 100, &d)
	ipc.link_close(&d.a)
	_pump(&ls, 100, &d)
	testing.expect_value(t, string(ls.events[:ls.n]), "UD")
}

@(test)
test_P32_drop_keeps_listening :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	dir := test_dir()
	defer test_dir_remove(dir)
	ls: _Listen
	if !_listen_open(t, &ls, {dir, "l"}, {}) do return
	defer _listen_close(t, &ls)
	d: _Dial
	if !expect_ok(t, ipc.poll_set_init(&d.set, 8), "poll_set_init") do return
	defer ipc.poll_set_destroy(&d.set)
	defer ipc.link_close(&d.a)
	defer ipc.link_close(&d.b)
	if !expect_ok(t, ipc.link_dial(&d.a, {dir, "l"}, link_protocol(), TEST_ROLE_CLIENT, &d.set), "dial a") do return
	_pump(&ls, 100, &d)
	ipc.link_drop(&ls.l) // the caller ends it: no Link_Down for it
	_pump(&ls, 100, &d)
	testing.expect(t, d.a_down, "the dropped peer saw no Link_Down")
	if !expect_ok(t, ipc.link_dial(&d.b, {dir, "l"}, link_protocol(), TEST_ROLE_CLIENT, &d.set), "dial b") do return
	_pump(&ls, 100, &d)
	testing.expect_value(t, string(ls.events[:ls.n]), "UU")
}
