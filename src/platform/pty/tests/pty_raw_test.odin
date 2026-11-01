package platform_pty_tests

import "core:c"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"
import pty "../"

// read_until reads master_fd until want appears, EOF or the timeout.
@(private = "file")
read_until :: proc(fd: i32, want: string, timeout_ms: int) -> string {
	out := make([dynamic]u8, context.temp_allocator)
	buf: [4096]u8
	deadline := time.tick_now()._nsec + i64(timeout_ms) * 1_000_000
	for time.tick_now()._nsec < deadline && !strings.contains(string(out[:]), want) {
		pfd := posix.pollfd{fd = posix.FD(fd), events = {.IN}}
		if posix.poll(&pfd, 1, 50) <= 0 do continue
		n := posix.read(posix.FD(fd), &buf[0], len(buf))
		if n <= 0 && posix.errno() != .EAGAIN do break
		if n > 0 do append(&out, ..buf[:n])
	}
	return string(out[:])
}

@(test)
test_spawn_raw_env_override_and_hangup :: proc(t: ^testing.T) {
	cfg := pty.Pty_Config{shell = "/bin/sh", argv = {"-c", "echo T=$TERM X=$HOLDER_X; sleep 30"}, cols = 80, rows = 24}
	master, pid, err := pty.pty_spawn_raw(cfg, {"TERM=dumb", "HOLDER_X=1"})
	testing.expect_value(t, err, pty.Pty_Error.None)
	out := read_until(master, "X=1", 3000)
	testing.expectf(t, strings.contains(out, "T=dumb X=1"), "extra_env overrides TERM: %q", out)
	flags := posix.fcntl(posix.FD(master), .GETFL)
	testing.expect(t, flags & c.int(posix.O_NONBLOCK) != 0, "master is non-blocking")

	pty.pty_hangup(master, pid)
	reaped := false
	for _ in 0..<100 {
		status: c.int
		r := posix.waitpid(posix.pid_t(pid), &status, {.NOHANG})
		if r == posix.pid_t(pid) || r < 0 {
			reaped = true
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, reaped, "hung-up child exits")
}

@(test)
test_foreground_info_by_fd :: proc(t: ^testing.T) {
	cfg := pty.Pty_Config{shell = "/bin/sh", argv = {"-c", "echo ready; exec sleep 30"}, cwd = "/tmp", cols = 80, rows = 24}
	master, pid, err := pty.pty_spawn_raw(cfg, nil)
	testing.expect_value(t, err, pty.Pty_Error.None)
	defer pty.pty_hangup(master, pid)
	read_until(master, "ready", 3000)
	time.sleep(100 * time.Millisecond)
	name_buf, cwd_buf: [256]u8
	pgid, name, cwd := pty.pty_foreground_info(master, name_buf[:], cwd_buf[:])
	testing.expect_value(t, pgid, pid)
	testing.expectf(t, name == "sleep", "foreground name: %q", name)
	testing.expectf(t, strings.has_suffix(cwd, "/tmp"), "foreground cwd: %q", cwd)
	testing.expect(t, pty.pty_set_size(master, 100, 40, 0, 0), "TIOCSWINSZ by fd")
}
