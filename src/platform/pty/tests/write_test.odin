package pty_test

import "core:c"
import posix "core:sys/posix"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import pty "../"

// WRITE_LINE_COUNT x WRITE_LINE_LEN builds the 64KB sustained payload.
WRITE_LINE_COUNT :: 1024

// WRITE_LINE_LEN is the per-line length including the trailing newline.
WRITE_LINE_LEN :: 64

// _Write_Drain carries the shared state between the test body (writer)
// and the background drain thread (reader). total is only appended by
// the drain thread; the test body reads it under mu after join, or
// polls marker sightings under mu while the thread runs.
_Write_Drain :: struct {
	p:     ^pty.Pty,
	mu:    sync.Mutex,
	stop:  bool,
	total: [dynamic]u8,
}

// _write_drain_proc collects child output until stop is set or EOF.
// It exists so a sustained large write never deadlocks: without a
// concurrent reader the master output buffer (line-discipline echo plus
// cat output) fills, the child stops reading, and the writer stalls.
_write_drain_proc :: proc(t: ^thread.Thread) {
	st := (^_Write_Drain)(t.data)
	buf := make([]u8, DRAIN_FRAME_CAP)
	defer delete(buf)
	for {
		sync.mutex_lock(&st.mu)
		stop := st.stop
		sync.mutex_unlock(&st.mu)
		if stop {
			return
		}
		n, eof := pty.pty_drain(st.p, buf, DRAIN_FRAME_CAP)
		if n > 0 {
			sync.mutex_lock(&st.mu)
			append(&st.total, ..buf[:n])
			sync.mutex_unlock(&st.mu)
		}
		if eof {
			return
		}
		if n == 0 {
			time.sleep(time.Millisecond)
		}
	}
}

// _write_saw reports under lock whether needle arrived so far.
_write_saw :: proc(st: ^_Write_Drain, needle: string) -> bool {
	sync.mutex_lock(&st.mu)
	defer sync.mutex_unlock(&st.mu)
	return _drain_contains(st.total[:], needle)
}

// _write_line fills dst (len WRITE_LINE_LEN) with "WLINE-%04d" padded with
// "." and terminated by "\n".
_write_line :: proc(dst: []u8, idx: int) {
	assert(len(dst) == WRITE_LINE_LEN)
	n := copy(dst, "WLINE-")
	d := idx
	div := 1000
	for _ in 0..<4 {
		dst[n] = u8('0' + d / div)
		n += 1
		d %= div
		div /= 10
	}
	for n < WRITE_LINE_LEN - 1 {
		dst[n] = '.'
		n += 1
	}
	dst[WRITE_LINE_LEN - 1] = '\n'
}

@(test)
test_write_cat_echo :: proc(t: ^testing.T) {
	p: pty.Pty
	ok := pty.pty_spawn(&p, 24, 80, "/bin/cat", {})
	testing.expect(t, ok, "pty_spawn /bin/cat must succeed")
	if !ok {
		return
	}
	defer _teardown(&p)
	wrote := pty.pty_write(&p, transmute([]u8)string("echo hi\n"))
	testing.expect(t, wrote, "pty_write of a small payload must succeed")
	got, found, _ := _drain_until(&p, "echo hi", DRAIN_FRAME_CAP)
	defer delete(got)
	testing.expect(t, found, "child must respond with the written bytes")
}

@(test)
test_write_large_completes :: proc(t: ^testing.T) {
	// A single 64KB pty_write forces the short-write loop (and possibly
	// the EAGAIN/poll path): the master buffer cannot take it in one go.
	// A background drain thread keeps the child consuming throughout.
	p: pty.Pty
	ok := pty.pty_spawn(&p, 24, 80, "/bin/cat", {})
	testing.expect(t, ok, "pty_spawn /bin/cat must succeed")
	if !ok {
		return
	}
	defer _teardown(&p)
	payload := make([]u8, WRITE_LINE_COUNT * WRITE_LINE_LEN)
	defer delete(payload)
	for i in 0..<WRITE_LINE_COUNT {
		_write_line(payload[i * WRITE_LINE_LEN:(i + 1) * WRITE_LINE_LEN], i)
	}
	st := _Write_Drain{p = &p, total = make([dynamic]u8)}
	defer delete(st.total)
	thr := thread.create(_write_drain_proc)
	thr.data = &st
	thread.start(thr)
	wrote := pty.pty_write(&p, payload)
	testing.expect(t, wrote, "large write must loop to completion")
	saw_last := false
	for _ in 0..<DRAIN_POLL_ITERS {
		if _write_saw(&st, "WLINE-1023") {
			saw_last = true
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	sync.mutex_lock(&st.mu)
	st.stop = true
	sync.mutex_unlock(&st.mu)
	thread.join(thr)
	thread.destroy(thr)
	testing.expect(t, _drain_contains(st.total[:], "WLINE-0000"), "first line of the large payload must come back")
	testing.expect(t, saw_last, "last line of the large payload must come back")
}

@(test)
test_write_empty_true :: proc(t: ^testing.T) {
	p: pty.Pty
	ok := pty.pty_spawn(&p, 24, 80, "/bin/cat", {})
	testing.expect(t, ok, "pty_spawn /bin/cat must succeed")
	if !ok {
		return
	}
	defer _teardown(&p)
	testing.expect(t, pty.pty_write(&p, {}), "empty write must be a no-op true")
}

@(test)
test_write_rejects_bad_pty :: proc(t: ^testing.T) {
	payload := transmute([]u8)string("hi\n")
	testing.expect(t, !pty.pty_write(nil, payload), "nil Pty must fail")
	bad := pty.Pty{master = -1, pid = -1, state = .Running}
	testing.expect(t, !pty.pty_write(&bad, payload), "negative master must fail")
	exited: pty.Pty
	ok := pty.pty_spawn(&exited, 24, 80, "/bin/cat", {})
	testing.expect(t, ok, "pty_spawn /bin/cat must succeed")
	if !ok {
		return
	}
	defer _teardown(&exited)
	exited.state = .Exited
	testing.expect(t, !pty.pty_write(&exited, payload), "Exited state must fail without a syscall")
}

// A payload larger than pipe capacity forces a positive prefix followed by
// EAGAIN without a consuming thread or timing assumptions.
@(test)
test_write_counted_resumes_exact_suffix :: proc(t: ^testing.T) {
	fds: [2]posix.FD
	if !testing.expect(t, posix.pipe(&fds) == .OK) do return
	defer posix.close(fds[0])
	defer posix.close(fds[1])
	if !testing.expect(t, posix.fcntl(fds[1], .SETFL, c.int(posix.O_NONBLOCK)) != -1) do return
	if !testing.expect(t, posix.fcntl(fds[0], .SETFL, c.int(posix.O_NONBLOCK)) != -1) do return
	payload := make([]u8, WRITE_LINE_COUNT * WRITE_LINE_COUNT)
	defer delete(payload)
	for i in 0..<len(payload) do payload[i] = u8(i % 251)
	p := pty.Pty{master = int(fds[1]), state = .Running}
	first := pty.pty_write_counted(&p, payload)
	testing.expect(t, first.status == .WouldBlock && first.errno == .EAGAIN)
	testing.expect(t, first.bytes_written > 0 && first.bytes_written < len(payload))
	blocked := pty.pty_write_counted(&p, payload[first.bytes_written:])
	testing.expect(t, blocked.status == .WouldBlock && blocked.bytes_written == 0)
	got := make([dynamic]u8)
	defer delete(got)
	buf: [WRITE_LINE_COUNT]u8
	offset := first.bytes_written
	for rounds := 0; rounds < len(payload) && len(got) < len(payload); rounds += 1 {
		for {
			n := posix.read(fds[0], raw_data(buf[:]), c.size_t(len(buf)))
			if n < 0 {
				testing.expect(t, posix.errno() == .EAGAIN)
				break
			}
			if n == 0 do break
			append(&got, ..buf[:int(n)])
		}
		if offset < len(payload) {
			result := pty.pty_write_counted(&p, payload[offset:])
			offset += result.bytes_written
			testing.expect(t, result.status == .WouldBlock || result.status == .Complete)
			testing.expect(t, (result.status == .Complete) == (offset == len(payload)))
		}
	}
	testing.expect(t, offset == len(payload) && len(got) == len(payload))
	testing.expect(t, string(got[:]) == string(payload), "resuming must neither replay nor omit bytes")
	testing.expect(t, pty.pty_write_counted(&p, {}).status == .Complete)
	testing.expect(t, pty.pty_write_counted(&p, {}).bytes_written == 0)
}

@(test)
test_write_counted_rejects_closed :: proc(t: ^testing.T) {
	data := transmute([]u8)string("counted")
	testing.expect(t, pty.pty_write_counted(nil, data).status == .Closed)
	testing.expect(t, pty.pty_write_counted(nil, {}).status == .Closed)
	bad := pty.Pty{master = -1, state = .Running}
	testing.expect(t, pty.pty_write_counted(&bad, data).errno == .EBADF)
	exited := pty.Pty{master = 0, state = .Exited}
	result := pty.pty_write_counted(&exited, data)
	testing.expect(t, result.status == .Closed && result.bytes_written == 0)
}

@(test)
test_write_counted_invalid_descriptor_errno :: proc(t: ^testing.T) {
	fds: [2]posix.FD
	if !testing.expect(t, posix.pipe(&fds) == .OK) do return
	defer posix.close(fds[0])
	posix.close(fds[1])
	p := pty.Pty{master = int(fds[1]), state = .Running}
	result := pty.pty_write_counted(&p, transmute([]u8)string("closed fd"))
	testing.expect(t, result.status == .Closed && result.errno == .EBADF && result.bytes_written == 0)
}
