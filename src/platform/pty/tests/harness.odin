package pty_test

import "base:runtime"
import "core:testing"
import "core:time"
import pty "../"
import parser "../../../parser"
import termgrid "../../../terminal"

// Harness dimensions: 80x24, matching every other test in this package.
HARNESS_ROWS :: 24
HARNESS_COLS :: 80

// HARNESS_DRAIN_ITERS bounds the write_drain poll loop.
HARNESS_DRAIN_ITERS :: 200

// HARNESS_QUIET_MS ends the drain once the master stays silent this long.
HARNESS_QUIET_MS :: 50

// HARNESS_POLL_MS is the sleep between empty drain polls.
HARNESS_POLL_MS :: 5

// harness_spawn_cat spawns /bin/cat on an 80x24 pty.
// The caller owns the result and closes it via defer.
// On spawn failure returns a Pty with master == -1; the calling test
// must fail fast (the helper itself never fails the test).
harness_spawn_cat :: proc() -> pty.Pty {
	if p: pty.Pty; pty.pty_spawn(&p, HARNESS_ROWS, HARNESS_COLS, "/bin/cat", {}) {
		return p
	}
	return pty.Pty{master = -1, pid = -1}
}

// harness_write_drain writes the full payload via pty_write, then drains
// child output until 50ms of quiet or 200 poll iters, accumulating every
// byte read. Returns the bytes drained; the caller deletes the result
// with the same allocator.
harness_write_drain :: proc(p: ^pty.Pty, payload: []u8, allocator: runtime.Allocator) -> []u8 {
	pty.pty_write(p, payload)
	buf := make([]u8, DRAIN_FRAME_CAP)
	defer delete(buf)
	total := make([dynamic]u8)
	defer delete(total)
	quiet_ms := 0
	for _ in 0..<HARNESS_DRAIN_ITERS {
		n, eof := pty.pty_drain(p, buf, DRAIN_FRAME_CAP)
		if n > 0 {
			append(&total, ..buf[:n])
			quiet_ms = 0
			if eof {
				break
			}
		} else if eof {
			break
		} else {
			quiet_ms += HARNESS_POLL_MS
			if quiet_ms >= HARNESS_QUIET_MS {
				break
			}
			time.sleep(HARNESS_POLL_MS * time.Millisecond)
		}
	}
	out := make([]u8, len(total), allocator)
	copy(out, total[:])
	return out
}

// harness_grid_has_row reports whether row starts with want.
// Pure read: touches no parser or pty state.
harness_grid_has_row :: proc(t: ^termgrid.Terminal, row: int, want: string) -> bool {
	for i in 0..<len(want) {
		if termgrid.terminal_get_cell(t, row, i).content != u32(want[i]) {
			return false
		}
	}
	return true
}

@(test)
test_harness_hello_spells :: proc(t: ^testing.T) {
	p := harness_spawn_cat()
	testing.expect(t, p.master >= 0, "harness_spawn_cat must succeed")
	if p.master < 0 {
		return
	}
	defer _teardown(&p)
	got := harness_write_drain(&p, transmute([]u8)string("hello"), context.allocator)
	defer delete(got)
	term: termgrid.Terminal
	termgrid.terminal_init(&term, HARNESS_ROWS, HARNESS_COLS)
	defer termgrid.terminal_destroy(&term)
	ps: parser.Parser
	parser.parser_init(&ps)
	parser.parse_chunk(&ps, &term, got)
	testing.expect(t, harness_grid_has_row(&term, 0, "hello"), "drained output parsed must spell hello in row 0")
}

@(test)
test_harness_write_drain_roundtrip :: proc(t: ^testing.T) {
	p := harness_spawn_cat()
	testing.expect(t, p.master >= 0, "harness_spawn_cat must succeed")
	if p.master < 0 {
		return
	}
	defer _teardown(&p)
	payload := transmute([]u8)string("roundtrip-bytes-ok")
	got := harness_write_drain(&p, payload, context.allocator)
	defer delete(got)
	testing.expect(t, _drain_contains(got, "roundtrip-bytes-ok"), "write_drain must return the written bytes")
}
