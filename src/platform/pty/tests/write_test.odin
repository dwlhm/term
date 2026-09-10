package pty_test

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
