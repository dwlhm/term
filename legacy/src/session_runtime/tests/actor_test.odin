package session_runtime_test

import "core:c"
import "core:slice"
import posix "core:sys/posix"
import "core:testing"
import "core:time"
import parser "../../parser"
import pty "../../platform/pty"
import rt "../"
import termgrid "../../terminal"

@(test)
test_queue_capacity_limit_1024 :: proc(t: ^testing.T) {
	q := new(rt.Input_Queue, context.allocator)
	defer {
		rt.input_queue_destroy(q, context.allocator)
		free(q, context.allocator)
	}

	// Push 1024 items -> verify all succeed
	for i in 0..<rt.INPUT_QUEUE_CAPACITY {
		item := [4]u8{u8(i & 0xFF), u8((i >> 8) & 0xFF), 0xAA, 0x55}
		ok := rt.input_queue_push(q, item[:], context.allocator)
		testing.expect(t, ok, "push within 1024 capacity must succeed")
	}
	testing.expect_value(t, q.count, rt.INPUT_QUEUE_CAPACITY)

	// 1025th push -> verify returns false (overflow rejection)
	extra := [4]u8{0xDE, 0xAD, 0xBE, 0xEF}
	overflow_ok := rt.input_queue_push(q, extra[:], context.allocator)
	testing.expect(t, !overflow_ok, "1025th push must fail with explicit false (bounded limit 1024)")
	testing.expect_value(t, q.count, rt.INPUT_QUEUE_CAPACITY)

	// Flush to dummy pipe -> verify queue count decrements and subsequent push succeeds
	fds: [2]posix.FD
	if !testing.expect(t, posix.pipe(&fds) == .OK) do return
	defer posix.close(fds[0])
	defer posix.close(fds[1])

	dummy_pty := pty.Pty{master = int(fds[1]), state = .Running}
	written, _ := rt.input_queue_flush(q, &dummy_pty, context.allocator)
	testing.expect(t, written > 0, "flush must write bytes")
	testing.expect(t, q.count < rt.INPUT_QUEUE_CAPACITY, "queue count must decrement after flush")

	// Subsequent push succeeds
	after_ok := rt.input_queue_push(q, extra[:], context.allocator)
	testing.expect(t, after_ok, "push after flush decrements count must succeed")
}

@(test)
test_write_resumption_eagain :: proc(t: ^testing.T) {
	fds: [2]posix.FD
	if !testing.expect(t, posix.pipe(&fds) == .OK) do return
	defer posix.close(fds[0])
	defer posix.close(fds[1])

	if !testing.expect(t, posix.fcntl(fds[0], .SETFL, c.int(posix.O_NONBLOCK)) != -1) do return
	if !testing.expect(t, posix.fcntl(fds[1], .SETFL, c.int(posix.O_NONBLOCK)) != -1) do return

	dummy_pty := pty.Pty{master = int(fds[1]), state = .Running}

	q := new(rt.Input_Queue, context.allocator)
	defer {
		rt.input_queue_destroy(q, context.allocator)
		free(q, context.allocator)
	}

	// Generate 128KB payload (larger than pipe capacity to guarantee WouldBlock/EAGAIN)
	PAYLOAD_SIZE :: 131072
	payload := make([]u8, PAYLOAD_SIZE, context.allocator)
	defer delete(payload, context.allocator)
	for i in 0..<PAYLOAD_SIZE {
		payload[i] = u8((i * 17 + 23) % 256)
	}

	pushed := rt.input_queue_push(q, payload, context.allocator)
	testing.expect(t, pushed, "pushing 128KB payload must succeed")
	testing.expect_value(t, q.count, 1)

	// First flush: pipe fills up and returns WouldBlock
	written, status := rt.input_queue_flush(q, &dummy_pty, context.allocator)
	testing.expect_value(t, status, pty.Pty_Write_Status.WouldBlock)
	testing.expect(t, written > 0, "must have written partial bytes")
	testing.expect(t, written < PAYLOAD_SIZE, "must not have completed on full pipe")
	testing.expect(t, q.count == 1, "queue must retain entry on WouldBlock")

	head_entry := &q.entries[q.head]
	testing.expect(t, head_entry.offset == written, "queue entry offset must match bytes actually written")

	// Drain read end and resume flushing
	drained := make([dynamic]u8, context.allocator)
	defer delete(drained)
	read_buf: [8192]u8

	for q.count > 0 {
		for {
			nr := posix.read(fds[0], raw_data(read_buf[:]), c.size_t(len(read_buf)))
			if nr <= 0 do break
			append(&drained, ..read_buf[:int(nr)])
		}
		w, s := rt.input_queue_flush(q, &dummy_pty, context.allocator)
		written += w
		if s == .Complete {
			break
		}
		testing.expect_value(t, s, pty.Pty_Write_Status.WouldBlock)
	}

	// Final drain of remaining bytes in pipe
	for {
		nr := posix.read(fds[0], raw_data(read_buf[:]), c.size_t(len(read_buf)))
		if nr <= 0 do break
		append(&drained, ..read_buf[:int(nr)])
	}

	testing.expect(t, q.count == 0, "queue must be empty after flush completes")
	testing.expect(t, written == PAYLOAD_SIZE, "total written must match payload size")
	testing.expect(t, len(drained) == PAYLOAD_SIZE, "drained bytes count must match payload size")
	testing.expect(t, slice.equal(drained[:], payload), "resumed stream must match payload exactly: ZERO lost bytes, ZERO duplicate bytes")
}

@(test)
test_parser_reply_replication_and_isolation :: proc(t: ^testing.T) {
	a1 := new(rt.Pane_Actor, context.allocator)
	defer {
		rt.actor_destroy(a1)
		free(a1, context.allocator)
	}
	rt.actor_init(a1, 1, 1, 1, 24, 80)

	a2 := new(rt.Pane_Actor, context.allocator)
	defer {
		rt.actor_destroy(a2)
		free(a2, context.allocator)
	}
	rt.actor_init(a2, 2, 1, 1, 24, 80)

	// Position cursors (0-indexed: row 10, col 20 vs row 5, col 15)
	termgrid.terminal_move_cursor(&a1.terminal, 10, 20)
	termgrid.terminal_move_cursor(&a2.terminal, 5, 15)

	// Feed CPR query "\x1b[6n" to a1 and a2 parsers
	cpr_query := transmute([]u8)string("\x1b[6n")
	parser.parse_chunk(&a1.parser, &a1.terminal, cpr_query)
	parser.parse_chunk(&a2.parser, &a2.terminal, cpr_query)

	// Verify reply queues: a1 gets "\x1b[11;21R" (1-indexed), a2 gets "\x1b[6;16R"
	testing.expect_value(t, a1.reply_queue.count, 1)
	testing.expect_value(t, a2.reply_queue.count, 1)

	e1 := &a1.reply_queue.entries[a1.reply_queue.head]
	data1 := e1.inline_data[:e1.data_len]
	testing.expect_value(t, string(data1), "\x1b[11;21R")

	e2 := &a2.reply_queue.entries[a2.reply_queue.head]
	data2 := e2.inline_data[:e2.data_len]
	testing.expect_value(t, string(data2), "\x1b[6;16R")

	// Verify cross-isolation: neither actor received the other's reply
	testing.expect(t, string(data1) != string(data2), "actor 1 and actor 2 replies must be distinct")
}

@(test)
test_actor_real_shell_lifecycle :: proc(t: ^testing.T) {
	a := new(rt.Pane_Actor, context.allocator)
	defer {
		rt.actor_destroy(a)
		free(a, context.allocator)
	}
	rt.actor_init(a, 1, 1, 1, 24, 80)

	spawn_ok := rt.actor_spawn(a, "/bin/sh", {})
	testing.expect(t, spawn_ok, "actor_spawn /bin/sh must succeed")
	if !spawn_ok do return

	testing.expect_value(t, a.liveness, rt.Work_Liveness.VerifiedLive)

	input_ok := rt.actor_write_input(a, transmute([]u8)string("echo hello_actor\n"))
	testing.expect(t, input_ok, "actor_write_input must succeed")

	start := time.now()
	found := false
	buf: [4096]u8
	for time.since(start) < 5 * time.Second {
		n, eof := rt.actor_drain_pty(a, buf[:])
		if _terminal_contains_text(&a.terminal, "hello_actor") {
			found = true
			break
		}
		if eof do break
		if n == 0 {
			time.sleep(10 * time.Millisecond)
		}
	}
	testing.expect(t, found, "echo hello_actor must appear in terminal grid")
}

@(private="file")
_terminal_contains_text :: proc(term: ^termgrid.Terminal, needle: string) -> bool {
	if len(needle) == 0 do return true
	needle_bytes := transmute([]u8)needle
	for r in 0..<term.grid.row_count {
		col_loop: for c in 0..=(term.grid.col_count - len(needle)) {
			for i in 0..<len(needle) {
				cell := termgrid.grid_get_cell(&term.grid, r, c + i)
				if u8(cell.content) != needle_bytes[i] {
					continue col_loop
				}
			}
			return true
		}
	}
	return false
}
