package platform_ipc_contract

// Test environment: private socket directories, fd 0 stand-ins, clocks and
// error expectations shared by every contract test.

import "core:fmt"
import "core:os"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:time"
import ipc "../"

@(private = "file")
_dir_counter: int

// test_dir makes a fresh 0700 directory under the real path of /tmp (on
// macOS /tmp is a symlink), short enough for dir/name to fit sun_path.
test_dir :: proc() -> string {
	base: [1024]u8
	real := posix.realpath("/tmp", raw_data(base[:]))
	n := sync.atomic_add(&_dir_counter, 1)
	dir := fmt.tprintf("%s/ipcc-%d-%d", string(real), int(posix.getpid()), n)
	posix.mkdir(cstr(dir), posix.S_IRWXU)
	return dir
}

test_dir_remove :: proc(dir: string) {
	posix.chmod(cstr(dir), posix.S_IRWXU)
	os.remove_all(dir)
}

// cstr: s as a C string in temp_allocator.
cstr :: proc(s: string) -> cstring { return fmt.ctprintf("%s", s) }

sock_path :: proc(at: ipc.Endpoint) -> string { return fmt.tprintf("%s/%s", at.dir, at.name) }

exists :: proc(path: string) -> bool {
	st: posix.stat_t
	return posix.lstat(cstr(path), &st) == .OK
}

inode :: proc(path: string) -> posix.ino_t {
	st: posix.stat_t
	if posix.lstat(cstr(path), &st) != .OK do return 0
	return st.st_ino
}

is_open :: proc(fd: posix.FD) -> bool { return posix.fcntl(fd, .GETFD) != -1 }

// with_fd0_on_a_pipe runs body while fd 0 is the read end of a fresh pipe and
// checks that body left that very pipe open; then the real stdin comes back.
with_fd0_on_a_pipe :: proc(t: ^testing.T, body: proc(t: ^testing.T)) {
	saved := posix.dup(0)
	defer {
		posix.dup2(saved, 0)
		posix.close(saved)
	}
	p: [2]posix.FD
	testing.expect(t, posix.pipe(&p) == .OK)
	defer posix.close(p[1])
	testing.expect(t, posix.dup2(p[0], 0) == 0)
	posix.close(p[0])
	before: posix.stat_t
	posix.fstat(0, &before)
	body(t)
	after: posix.stat_t
	testing.expect(t, posix.fstat(0, &after) == .OK && after.st_ino == before.st_ino, "fd 0 was closed or replaced")
}

now_ns :: proc() -> i64 { return time.tick_now()._nsec }

ms_since :: proc(start: time.Tick) -> f64 { return time.duration_milliseconds(time.tick_since(start)) }

// cpu_ms: CPU time of the calling thread so far. Process time would count
// the test runner's main thread, which polls with a 1 µs sleep (≈ 1/3 CPU).
cpu_ms :: proc() -> f64 {
	ts: posix.timespec
	posix.clock_gettime(.THREAD_CPUTIME_ID, &ts)
	return f64(ts.tv_sec) * 1000 + f64(ts.tv_nsec) / 1e6
}

expect_ok :: proc(t: ^testing.T, err: ipc.Error, what: string, loc := #caller_location) -> bool {
	if err.kind == .None do return true
	testing.expectf(t, false, "%s: %v %q", what, err.kind, err.reason, loc = loc)
	return false
}

expect_kind :: proc(t: ^testing.T, err: ipc.Error, want: ipc.Error_Kind, what: string, loc := #caller_location) -> bool {
	if err.kind == want do return true
	testing.expectf(t, false, "%s: got %v %q, want %v", what, err.kind, err.reason, want, loc = loc)
	return false
}

// wait_until polls cond (on the test thread) for up to ms.
wait_until :: proc(ms: int, cond: proc(data: rawptr) -> bool, data: rawptr) -> bool {
	due := now_ns() + i64(ms) * 1_000_000
	for now_ns() < due {
		if cond(data) do return true
		time.sleep(time.Millisecond)
	}
	return cond(data)
}
