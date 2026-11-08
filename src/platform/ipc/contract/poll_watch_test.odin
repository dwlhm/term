package platform_ipc_contract

// P39 (K11): client_poll waits on one non-IPC fd as well, like a call's
// Call_Opts.watch. Once the fd is readable, on_watch runs and client_poll
// returns (nil, no error), so a caller that waits with no request in flight
// (a runner's t.ask on a terminal) still reads stdin at once.

import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"
import ipc "../"

@(private = "file")
_Watched :: struct {
	calls: int,
	at:    i64,
}

@(private = "file")
_written_at: i64 // atomic

// _write_later writes one byte to fd after 100 ms.
@(private = "file")
_write_later :: proc(fd: posix.FD) {
	time.sleep(100 * time.Millisecond)
	sync.atomic_store(&_written_at, now_ns())
	b := u8('x')
	posix.write(fd, &b, 1)
}

@(test)
test_P39_poll_returns_when_its_watch_fd_is_readable :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	dir := test_dir()
	defer test_dir_remove(dir)
	fs: Fake_Server // never sends anything
	if !fake_open(t, &fs, {dir, "s"}) do return
	defer fake_close(&fs)
	c: ipc.Client
	if !open_client(t, &c, {dir, "s"}) do return
	defer ipc.client_close(&c)
	p: [2]posix.FD
	if !testing.expect(t, posix.pipe(&p) == .OK, "pipe") do return
	defer for fd in p do posix.close(fd)
	w: _Watched
	on_watch :: proc(data: rawptr) {
		w := (^_Watched)(data)
		w.calls += 1
		w.at = now_ns()
	}
	writer := thread.create_and_start_with_poly_data(p[1], _write_later, context)
	defer thread.destroy(writer)
	defer thread.join(writer)
	ev, err := ipc.client_poll(&c, 3 * time.Second, p[0], on_watch, &w)
	expect_kind(t, err, .None, "client_poll")
	testing.expect(t, ev == nil, "client_poll returned an event, but only the watch fd moved")
	testing.expectf(t, w.calls == 1, "on_watch ran %d times", w.calls)
	ms := f64(w.at - sync.atomic_load(&_written_at)) / 1e6
	testing.expectf(t, w.calls == 1 && ms <= 50, "on_watch ran %.1f ms after the write", ms)
}

@(test)
test_P39_poll_without_a_watch_still_times_out :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	dir := test_dir()
	defer test_dir_remove(dir)
	fs: Fake_Server
	if !fake_open(t, &fs, {dir, "s"}) do return
	defer fake_close(&fs)
	c: ipc.Client
	if !open_client(t, &c, {dir, "s"}) do return
	defer ipc.client_close(&c)
	start := time.tick_now()
	_, err := ipc.client_poll(&c, 200 * time.Millisecond)
	expect_kind(t, err, .Timeout, "client_poll")
	testing.expectf(t, ms_since(start) >= 180 && ms_since(start) <= 400, "timed out after %.0f ms", ms_since(start))
}
