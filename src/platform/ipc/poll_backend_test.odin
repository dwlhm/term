package platform_ipc

// The Poll_Set backend (private: tested from inside the package) keeps posix.poll's contract: level-triggered IN/OUT/HUP,
// NVAL for an fd that is not open, interests dropped when a round stops
// naming them, an fd number reused after close registered again.

import "core:sys/posix"
import "core:testing"
import "core:time"

@(private = "file")
_bt_pipe :: proc() -> (r, w: posix.FD) {
	fds: [2]posix.FD
	posix.pipe(&fds)
	return fds[0], fds[1]
}

@(private = "file")
_bt_write :: proc(fd: posix.FD, s: string) {
	posix.write(fd, raw_data(s), uint(len(s)))
}

@(private = "file")
_bt_drain :: proc(fd: posix.FD) -> int {
	buf: [4096]u8
	return int(posix.read(fd, &buf[0], len(buf)))
}

@(test)
test_backend_readable_is_level_triggered :: proc(t: ^testing.T) {
	p: _Backend
	testing.expect(t, _backend_init(&p, 8))
	defer _backend_destroy(&p)
	r, w := _bt_pipe()
	defer { posix.close(r); posix.close(w) }
	fds := []posix.pollfd{{fd = r, events = {.IN}}}

	testing.expect_value(t, _backend_poll(&p, fds, 0), 0)
	_bt_write(w, "abc")
	testing.expect_value(t, _backend_poll(&p, fds, 1000), 1)
	testing.expect(t, .IN in fds[0].revents)
	testing.expect_value(t, _backend_poll(&p, fds, 0), 1) // still unread: reported again
	_bt_drain(r)
	testing.expect_value(t, _backend_poll(&p, fds, 0), 0)
	testing.expect_value(t, fds[0].revents, posix.Poll_Event{})
}

@(test)
test_backend_timeout_waits_and_returns_zero :: proc(t: ^testing.T) {
	p: _Backend
	testing.expect(t, _backend_init(&p, 8))
	defer _backend_destroy(&p)
	r, w := _bt_pipe()
	defer { posix.close(r); posix.close(w) }
	fds := []posix.pollfd{{fd = r, events = {.IN}}}
	t0 := time.tick_now()
	testing.expect_value(t, _backend_poll(&p, fds, 60), 0)
	waited := time.duration_milliseconds(time.tick_since(t0))
	testing.expectf(t, waited >= 50 && waited < 1000, "waited %.0f ms", waited)
}

@(test)
test_backend_dropped_interest_is_not_reported :: proc(t: ^testing.T) {
	p: _Backend
	testing.expect(t, _backend_init(&p, 8))
	defer _backend_destroy(&p)
	r, w := _bt_pipe()
	defer { posix.close(r); posix.close(w) }
	_bt_write(w, "pending")
	fds := []posix.pollfd{{fd = r, events = {.IN}}}
	testing.expect_value(t, _backend_poll(&p, fds, 0), 1)
	fds[0].events = {} // paused: still named, nothing wanted
	testing.expect_value(t, _backend_poll(&p, fds, 0), 0)
	testing.expect_value(t, _backend_poll(&p, fds[:0], 0), 0) // not named at all
	fds[0].events = {.IN}
	testing.expect_value(t, _backend_poll(&p, fds, 0), 1) // resumed
}

@(test)
test_backend_writable_and_hangup :: proc(t: ^testing.T) {
	p: _Backend
	testing.expect(t, _backend_init(&p, 8))
	defer _backend_destroy(&p)
	sv: [2]posix.FD
	testing.expect(t, posix.socketpair(.UNIX, .STREAM, .IP, &sv) == .OK)
	defer posix.close(sv[0])
	fds := []posix.pollfd{{fd = sv[0], events = {.IN, .OUT}}}
	testing.expect_value(t, _backend_poll(&p, fds, 0), 1)
	testing.expect_value(t, fds[0].revents, posix.Poll_Event{.OUT})
	_bt_write(sv[1], "last")
	posix.close(sv[1])
	testing.expect_value(t, _backend_poll(&p, fds, 1000), 1)
	testing.expect(t, fds[0].revents >= {.IN, .HUP}, "data before the hangup is readable, the hangup reported")
}

@(test)
test_backend_pty_master_reports_output_then_hangup :: proc(t: ^testing.T) {
	p: _Backend
	testing.expect(t, _backend_init(&p, 8))
	defer _backend_destroy(&p)
	master := posix.posix_openpt({.RDWR, .NOCTTY})
	if !testing.expect(t, master >= 0, "posix_openpt") do return
	defer posix.close(master)
	posix.grantpt(master)
	posix.unlockpt(master)
	slave := posix.open(posix.ptsname(master), {.RDWR, .NOCTTY})
	if !testing.expect(t, slave >= 0, "open slave") do return
	fds := []posix.pollfd{{fd = master, events = {.IN, .OUT}}}
	testing.expect(t, _backend_poll(&p, fds, 0) == 1 && fds[0].revents == {.OUT}, "an idle master is only writable")
	_bt_write(slave, "out")
	fds[0].events = {.IN}
	testing.expect_value(t, _backend_poll(&p, fds, 1000), 1)
	testing.expect(t, .IN in fds[0].revents)
	_bt_drain(master)
	posix.close(slave)
	testing.expect_value(t, _backend_poll(&p, fds, 1000), 1)
	testing.expect(t, fds[0].revents & {.IN, .HUP} != {}, "closing the slave wakes the master")
}

@(test)
test_backend_reused_fd_number_is_registered_again :: proc(t: ^testing.T) {
	p: _Backend
	testing.expect(t, _backend_init(&p, 8))
	defer _backend_destroy(&p)
	r1, w1 := _bt_pipe()
	fds := []posix.pollfd{{fd = r1, events = {.IN}}}
	testing.expect_value(t, _backend_poll(&p, fds, 0), 0)
	posix.close(r1) // closed without telling the poller: the kernel drops its knote
	posix.close(w1)
	r2, w2 := _bt_pipe()
	defer { posix.close(r2); posix.close(w2) }
	testing.expect_value(t, r2, r1) // the lowest free number comes back
	_bt_write(w2, "new")
	testing.expect_value(t, _backend_poll(&p, fds, 1000), 1)
	testing.expect(t, .IN in fds[0].revents)
}

@(test)
test_backend_closed_fd_is_nval_and_negative_fd_skipped :: proc(t: ^testing.T) {
	p: _Backend
	testing.expect(t, _backend_init(&p, 8))
	defer _backend_destroy(&p)
	r, w := _bt_pipe()
	posix.close(r)
	posix.close(w)
	fds := []posix.pollfd{{fd = r, events = {.IN}}, {fd = -1, events = {.IN}}}
	t0 := time.tick_now()
	testing.expect_value(t, _backend_poll(&p, fds, 5000), 1)
	testing.expect(t, time.duration_milliseconds(time.tick_since(t0)) < 1000, "an invalid fd answers at once")
	testing.expect(t, .NVAL in fds[0].revents)
	testing.expect_value(t, fds[1].revents, posix.Poll_Event{})
}

@(test)
test_backend_many_fds_report_their_own_index :: proc(t: ^testing.T) {
	N :: 200
	p: _Backend
	testing.expect(t, _backend_init(&p, N))
	defer _backend_destroy(&p)
	rs, ws: [N]posix.FD
	fds: [N]posix.pollfd
	for i in 0 ..< N {
		rs[i], ws[i] = _bt_pipe()
		fds[i] = {fd = rs[i], events = {.IN}}
	}
	defer for i in 0 ..< N { posix.close(rs[i]); posix.close(ws[i]) }
	for i := 0; i < N; i += 3 do _bt_write(ws[i], "x")
	testing.expect_value(t, _backend_poll(&p, fds[:], 1000), (N + 2) / 3)
	for i in 0 ..< N do testing.expectf(t, (.IN in fds[i].revents) == (i % 3 == 0), "fd %d", i)
	// Shrink the set (every other fd gone): no stale reports from the removed ones.
	half: [N / 2]posix.pollfd
	for i in 0 ..< N / 2 do half[i] = {fd = rs[2 * i + 1], events = {.IN}}
	ready := _backend_poll(&p, half[:], 0)
	want := 0
	for i in 0 ..< N / 2 do want += 1 if (2 * i + 1) % 3 == 0 else 0
	testing.expect_value(t, ready, want)
}

@(test)
test_backend_more_fds_than_capacity_fail :: proc(t: ^testing.T) {
	p: _Backend
	testing.expect(t, _backend_init(&p, 1))
	defer _backend_destroy(&p)
	fds := []posix.pollfd{{fd = -1}, {fd = -1}}
	testing.expect_value(t, _backend_poll(&p, fds, 0), -1)
}
