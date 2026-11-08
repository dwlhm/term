package platform_ipc_contract

// P27, P28: Poll_Set. A watched fd closed under the set ends once and is
// forgotten; a watch waits for what its Fd_Want names (readable, writable, or
// nothing while paused); pokes from a signal handler never block and wake
// exactly once.

import "core:sys/posix"
import "core:testing"
import "core:time"
import ipc "../"

@(private = "file")
_Ready :: struct {
	ended, other, writable: int,
}

@(private = "file")
_count :: proc(data: rawptr, ev: ipc.Fd_Event) {
	r := (^_Ready)(data)
	switch ev {
	case .Ended:    r.ended += 1
	case .Writable: r.writable += 1
	case .Readable: r.other += 1
	}
}

// _quiet: a wait of ms with nothing due sleeps it through and calls nothing.
@(private = "file")
_quiet :: proc(t: ^testing.T, set: ^ipc.Poll_Set, r: ^_Ready, ms: i64, loc := #caller_location) {
	before := r^
	start := time.tick_now()
	ipc.poll_set_wait(set, now_ns() + ms * 1_000_000)
	testing.expectf(t, ms_since(start) >= f64(ms) * 0.9, "the wait returned after %.0f ms", ms_since(start), loc = loc)
	testing.expect(t, r^ == before, "a callback ran for an fd nobody waits on", loc = loc)
}

@(test)
test_P27_watched_fd_closed_under_the_set :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	set: ipc.Poll_Set
	if !expect_ok(t, ipc.poll_set_init(&set, 8), "poll_set_init") do return
	defer ipc.poll_set_destroy(&set)
	p: [2]posix.FD
	posix.pipe(&p)
	defer posix.close(p[1])
	r: _Ready
	_, err := ipc.poll_set_watch(&set, p[0], _count, &r)
	if !expect_ok(t, err, "poll_set_watch") do return
	posix.close(p[0])
	ipc.poll_set_wait(&set, now_ns() + 1_000_000_000)
	testing.expect_value(t, r.ended, 1)
	testing.expect_value(t, r.other, 0)
	start := time.tick_now()
	ipc.poll_set_wait(&set, now_ns() + 200_000_000)
	testing.expectf(t, ms_since(start) >= 180, "poll_set_wait returned after %.0f ms with nothing to do", ms_since(start))
	testing.expect_value(t, r.ended, 1)
}

@(test)
test_P27_watch_waits_for_writable :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	set: ipc.Poll_Set
	if !expect_ok(t, ipc.poll_set_init(&set, 8), "poll_set_init") do return
	defer ipc.poll_set_destroy(&set)
	p: [2]posix.FD
	posix.pipe(&p)
	defer { posix.close(p[0]); posix.close(p[1]) }
	r: _Ready
	id, err := ipc.poll_set_watch(&set, p[1], _count, &r, {.Writable})
	if !expect_ok(t, err, "poll_set_watch") do return
	ipc.poll_set_wait(&set, now_ns() + 1_000_000_000)
	testing.expect(t, r.writable >= 1 && r.other == 0, "an empty pipe's write end did not report Writable")
	ipc.poll_set_want(&set, id, {})
	_quiet(t, &set, &r, 200)
}

@(test)
test_P27_want_nothing_pauses_a_readable_fd :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	set: ipc.Poll_Set
	if !expect_ok(t, ipc.poll_set_init(&set, 8), "poll_set_init") do return
	defer ipc.poll_set_destroy(&set)
	p: [2]posix.FD
	posix.pipe(&p)
	defer { posix.close(p[0]); posix.close(p[1]) }
	b := u8('x')
	posix.write(p[1], &b, 1) // input waits, unread
	r: _Ready
	id, err := ipc.poll_set_watch(&set, p[0], _count, &r)
	if !expect_ok(t, err, "poll_set_watch") do return
	ipc.poll_set_want(&set, id, {})
	_quiet(t, &set, &r, 200)
	ipc.poll_set_want(&set, id, {.Readable})
	ipc.poll_set_wait(&set, now_ns() + 1_000_000_000)
	testing.expect_value(t, r.other, 1)
}

@(private = "file")
_poked: ^ipc.Poll_Set

@(private = "file")
_poke :: proc "c" (sig: posix.Signal) { ipc.poll_set_poke(_poked) }

@(test)
test_P28_ten_thousand_pokes_from_a_signal_handler :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	set: ipc.Poll_Set
	if !expect_ok(t, ipc.poll_set_init(&set, 8), "poll_set_init") do return
	defer ipc.poll_set_destroy(&set)
	_poked = &set
	old := posix.signal(.SIGUSR1, _poke)
	defer posix.signal(.SIGUSR1, old)
	for _ in 0 ..< 10_000 do posix.raise(.SIGUSR1)
	start := time.tick_now()
	ipc.poll_set_wait(&set, now_ns() + 1_000_000_000)
	testing.expectf(t, ms_since(start) < 100, "a poked set waited %.0f ms", ms_since(start))
	testing.expect(t, ipc.poll_set_woken(&set), "poll_set_woken is false after pokes")
	testing.expect(t, !ipc.poll_set_woken(&set), "poll_set_woken is true twice")
	start = time.tick_now()
	ipc.poll_set_wait(&set, now_ns() + 200_000_000)
	testing.expectf(t, ms_since(start) >= 180, "the wake was not drained: waited %.0f ms", ms_since(start))
}
