package pty_test

import "core:testing"
import "core:time"
import pty "../"
import parser "../../../parser"
import tg "../../../terminal"

// DRAIN_POLL_ITERS bounds every wait loop: 500 x 10ms = 5s max per test.
DRAIN_POLL_ITERS :: 500

// DRAIN_FRAME_CAP mirrors the per-frame cap callers pass as max_bytes.
DRAIN_FRAME_CAP :: 65536

// _drain_contains reports whether haystack holds needle.
_drain_contains :: proc(haystack: []u8, needle: string) -> bool {
	if len(needle) == 0 || len(haystack) < len(needle) {
		return false
	}
	for i in 0..=(len(haystack) - len(needle)) {
		if string(haystack[i:i + len(needle)]) == needle {
			return true
		}
	}
	return false
}

// _drain_until collects child output until needle appears, EOF, or timeout.
// Returns the bytes collected and whether needle was seen.
_drain_until :: proc(p: ^pty.Pty, needle: string, cap_bytes: int) -> (got: [dynamic]u8, found: bool, eof: bool) {
	got = make([dynamic]u8)
	buf := make([]u8, cap_bytes)
	defer delete(buf)
	for _ in 0..<DRAIN_POLL_ITERS {
		n, done := pty.pty_drain(p, buf, cap_bytes)
		if n > 0 {
			append(&got, ..buf[:n])
			if _drain_contains(got[:], needle) {
				return got, true, false
			}
		}
		if done {
			return got, _drain_contains(got[:], needle), true
		}
		if n == 0 {
			time.sleep(10 * time.Millisecond)
		}
	}
	found = _drain_contains(got[:], needle)
	return got, found, false
}

@(test)
test_drain_echo_bytes :: proc(t: ^testing.T) {
	p: pty.Pty
	ok := pty.pty_spawn(&p, 24, 80, "/bin/echo", {"hello"})
	testing.expect(t, ok, "pty_spawn /bin/echo must succeed")
	if !ok {
		return
	}
	defer _teardown(&p)
	got, found, _ := _drain_until(&p, "hello", DRAIN_FRAME_CAP)
	defer delete(got)
	testing.expect(t, found, "drain must return child output containing hello")
}

@(test)
test_drain_empty_is_eagain :: proc(t: ^testing.T) {
	// /bin/cat with no input produces no output: the master has nothing
	// to report and the nonblocking read must surface EAGAIN, not block.
	p: pty.Pty
	ok := pty.pty_spawn(&p, 24, 80, "/bin/cat", {})
	testing.expect(t, ok, "pty_spawn /bin/cat must succeed")
	if !ok {
		return
	}
	defer _teardown(&p)
	buf := make([]u8, DRAIN_FRAME_CAP)
	defer delete(buf)
	n, eof := pty.pty_drain(&p, buf, DRAIN_FRAME_CAP)
	testing.expect(t, n == 0, "empty master must read 0 bytes")
	testing.expect(t, !eof, "empty master must not report EOF")
}

@(test)
test_drain_eof_after_child_exit :: proc(t: ^testing.T) {
	// /usr/bin/true exits immediately with no output: once the child is gone
	// the master read reports EOF (0) or EIO, never EAGAIN forever.
	p: pty.Pty
	ok := pty.pty_spawn(&p, 24, 80, "/usr/bin/true", {})
	testing.expect(t, ok, "pty_spawn /usr/bin/true must succeed")
	if !ok {
		return
	}
	defer _teardown(&p)
	buf := make([]u8, DRAIN_FRAME_CAP)
	defer delete(buf)
	saw_eof := false
	for _ in 0..<DRAIN_POLL_ITERS {
		_, eof := pty.pty_drain(&p, buf, DRAIN_FRAME_CAP)
		if eof {
			saw_eof = true
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, saw_eof, "exited child must surface EOF on the master")
}

@(test)
test_drain_pump_mutates_grid :: proc(t: ^testing.T) {
	// Pump demonstration: drain -> parse_chunk -> grid spells hello.
	p: pty.Pty
	ok := pty.pty_spawn(&p, 24, 80, "/bin/echo", {"hello"})
	testing.expect(t, ok, "pty_spawn /bin/echo must succeed")
	if !ok {
		return
	}
	defer _teardown(&p)
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)
	ps: parser.Parser
	parser.parser_init(&ps)
	buf := make([]u8, DRAIN_FRAME_CAP)
	defer delete(buf)
	spells := false
	for _ in 0..<DRAIN_POLL_ITERS {
		n, eof := pty.pty_drain(&p, buf, DRAIN_FRAME_CAP)
		if n > 0 {
			parser.parse_chunk(&ps, &term, buf[:n])
		}
		want := "hello"
		match := true
		for i in 0..<len(want) {
			cell := tg.terminal_get_cell(&term, 0, i)
			if cell.content != u32(want[i]) {
				match = false
				break
			}
		}
		if match {
			spells = true
			break
		}
		if eof {
			break
		}
		if n == 0 {
			time.sleep(10 * time.Millisecond)
		}
	}
	testing.expect(t, spells, "pumped output must spell hello in row 0")
}

@(test)
test_drain_split_utf8_completes :: proc(t: ^testing.T) {
	// A multibyte rune split across two drain-sized chunks: the parser
	// must hold the partial lead byte and complete on the next chunk.
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)
	ps: parser.Parser
	parser.parser_init(&ps)
	// U+00E9 split into its two UTF-8 bytes across chunk boundaries.
	parser.parse_chunk(&ps, &term, []u8{0xC3})
	cell := tg.terminal_get_cell(&term, 0, 0)
	testing.expect(t, cell.content != 0x00E9, "partial lead byte must not complete yet")
	parser.parse_chunk(&ps, &term, []u8{0xA9})
	cell = tg.terminal_get_cell(&term, 0, 0)
	testing.expect(t, cell.content == 0x00E9, "second chunk must complete the rune")
}

@(test)
test_drain_split_csi_completes :: proc(t: ^testing.T) {
	// A CSI sequence split across two chunks: partial params held, then
	// dispatched when the final byte arrives; following text still prints.
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)
	ps: parser.Parser
	parser.parser_init(&ps)
	parser.parse_chunk(&ps, &term, []u8{0x1b, '[', '3'})
	parser.parse_chunk(&ps, &term, []u8{'1', 'm', 'X'})
	cell := tg.terminal_get_cell(&term, 0, 0)
	testing.expect(t, cell.content == 'X', "text after split CSI must print at origin")
}

@(test)
test_drain_honors_small_buffer :: proc(t: ^testing.T) {
	// A caller buffer smaller than the available output: drain fills only
	// what fits and the remainder arrives on subsequent calls.
	p: pty.Pty
	ok := pty.pty_spawn(&p, 24, 80, "/bin/echo", {"hello"})
	testing.expect(t, ok, "pty_spawn /bin/echo must succeed")
	if !ok {
		return
	}
	defer _teardown(&p)
	small := make([]u8, 2)
	defer delete(small)
	total := make([dynamic]u8)
	defer delete(total)
	capped := false
	for _ in 0..<DRAIN_POLL_ITERS {
		n, eof := pty.pty_drain(&p, small, len(small))
		testing.expect(t, n <= len(small), "drain must never exceed caller buffer")
		if n > 0 {
			if n == len(small) {
				capped = true
			}
			append(&total, ..small[:n])
			if _drain_contains(total[:], "hello") {
				break
			}
		}
		if eof {
			break
		}
		if n == 0 {
			time.sleep(10 * time.Millisecond)
		}
	}
	testing.expect(t, _drain_contains(total[:], "hello"), "small-buffer drain must still deliver all output")
	testing.expect(t, capped, "at least one drain must fill the small buffer")
}
