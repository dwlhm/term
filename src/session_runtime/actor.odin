package session_runtime

import "base:runtime"
import "core:c"
import "core:slice"
import "core:strings"
import posix "core:sys/posix"
import "core:time"
import parser "../parser"
import pty "../platform/pty"
import termgrid "../terminal"

INPUT_QUEUE_CAPACITY :: 1024
INPUT_INLINE_BYTES :: 256

Input_Queue_Entry :: struct {
	inline_data: [INPUT_INLINE_BYTES]u8,
	data_len:    int,
	heap_data:   []u8,
	offset:      int,
}

Input_Queue :: struct {
	entries: [INPUT_QUEUE_CAPACITY]Input_Queue_Entry,
	head:    int,
	tail:    int,
	count:   int,
}

input_queue_push :: proc(q: ^Input_Queue, data: []u8, allocator: runtime.Allocator) -> bool {
	if q == nil do return false
	if q.count >= INPUT_QUEUE_CAPACITY do return false

	e := &q.entries[q.tail]
	if e.heap_data != nil {
		delete(e.heap_data, allocator)
		e.heap_data = nil
	}
	e.offset = 0

	if len(data) <= INPUT_INLINE_BYTES {
		copy(e.inline_data[:], data)
		e.data_len = len(data)
		e.heap_data = nil
	} else {
		e.heap_data = make([]u8, len(data), allocator)
		copy(e.heap_data, data)
		e.data_len = 0
	}

	q.tail = (q.tail + 1) % INPUT_QUEUE_CAPACITY
	q.count += 1
	return true
}

input_queue_flush :: proc(q: ^Input_Queue, p: ^pty.Pty, allocator: runtime.Allocator) -> (written_total: int, status: pty.Pty_Write_Status) {
	if q == nil do return 0, .Closed
	for q.count > 0 {
		e := &q.entries[q.head]
		total_len := len(e.heap_data) if e.heap_data != nil else e.data_len
		if e.offset >= total_len {
			if e.heap_data != nil {
				delete(e.heap_data, allocator)
				e.heap_data = nil
			}
			e.data_len = 0
			e.offset = 0
			q.head = (q.head + 1) % INPUT_QUEUE_CAPACITY
			q.count -= 1
			continue
		}

		pending := e.heap_data[e.offset:] if e.heap_data != nil else e.inline_data[e.offset:e.data_len]
		res := pty.pty_write_counted(p, pending)
		e.offset += res.bytes_written
		written_total += res.bytes_written

		if res.status == .WouldBlock {
			return written_total, .WouldBlock
		}
		if res.status == .Closed || res.status == .Error {
			return written_total, res.status
		}

		total_len = len(e.heap_data) if e.heap_data != nil else e.data_len
		if e.offset >= total_len {
			if e.heap_data != nil {
				delete(e.heap_data, allocator)
				e.heap_data = nil
			}
			e.data_len = 0
			e.offset = 0
			q.head = (q.head + 1) % INPUT_QUEUE_CAPACITY
			q.count -= 1
		}
	}
	return written_total, .Complete
}

input_queue_destroy :: proc(q: ^Input_Queue, allocator: runtime.Allocator) {
	if q == nil do return
	for q.count > 0 {
		e := &q.entries[q.head]
		if e.heap_data != nil {
			delete(e.heap_data, allocator)
			e.heap_data = nil
		}
		e.data_len = 0
		e.offset = 0
		q.head = (q.head + 1) % INPUT_QUEUE_CAPACITY
		q.count -= 1
	}
	q.head = 0
	q.tail = 0
	q.count = 0
}

Pane_Actor :: struct {
	pane_id:      Pane_ID,
	incarnation:  Pane_Incarnation,
	workspace_id: Workspace_ID,
	pty:          pty.Pty,
	parser:       parser.Parser,
	terminal:     termgrid.Terminal,
	input_queue:  Input_Queue,
	reply_queue:  Input_Queue,
	liveness:     Work_Liveness,
	allocator:    runtime.Allocator,
}

_actor_response_cb :: proc(user_data: rawptr, data: []u8) {
	a := (^Pane_Actor)(user_data)
	if a == nil do return
	_ = input_queue_push(&a.reply_queue, data, a.allocator)
}

actor_init :: proc(
	a: ^Pane_Actor,
	pane_id: Pane_ID,
	incarnation: Pane_Incarnation,
	ws: Workspace_ID,
	rows, cols: int,
	allocator := context.allocator,
) {
	if a == nil do return
	a^ = Pane_Actor{}
	a.pane_id = pane_id
	a.incarnation = incarnation
	a.workspace_id = ws
	a.allocator = allocator
	a.pty.master = -1
	a.pty.pid = -1
	termgrid.terminal_init(&a.terminal, rows, cols, allocator)
	parser.parser_init(&a.parser)
	a.parser.response_context_cb = _actor_response_cb
	a.parser.response_user_data = a
	a.liveness = .VerifiedLive
}

actor_spawn :: proc(
	a: ^Pane_Actor,
	prog: string,
	argv: []string = {},
	cwd: string = "",
	pixel_w: int = 0,
	pixel_h: int = 0,
) -> bool {
	if a == nil do return false
	rows := a.terminal.grid.row_count
	cols := a.terminal.grid.col_count
	ok := pty.pty_spawn(&a.pty, rows, cols, prog, argv, cwd, pixel_w, pixel_h)
	if ok {
		a.liveness = .VerifiedLive
	} else {
		a.liveness = .Uncertain
	}
	return ok
}

actor_start :: proc(
	a: ^Pane_Actor,
	rows, cols: int,
	prog: string,
	argv: []string = nil,
	cwd: string = "",
) -> bool {
	if a == nil do return false
	allocator := a.allocator if a.allocator.procedure != nil else context.allocator
	effective_rows := rows if rows > 0 else 24
	effective_cols := cols if cols > 0 else 80
	incarnation := a.incarnation if a.incarnation != 0 else Pane_Incarnation(1)
	actor_init(a, a.pane_id, incarnation, a.workspace_id, effective_rows, effective_cols, allocator)

	effective_prog := prog
	effective_argv := argv
	split_argv: [dynamic]string
	defer delete(split_argv)
	if len(argv) == 0 && strings.contains(prog, " ") {
		parts := strings.split(prog, " ", context.temp_allocator)
		if len(parts) > 0 {
			effective_prog = parts[0]
			for p in parts[1:] {
				if len(p) > 0 {
					append(&split_argv, p)
				}
			}
			effective_argv = split_argv[:]
		}
	}
	if len(effective_argv) == 0 {
		if strings.contains(effective_prog, "zsh") {
			effective_argv = []string{"--no-rcs"}
		} else if strings.contains(effective_prog, "bash") {
			effective_argv = []string{"--norc", "--noprofile"}
		}
	}
	return actor_spawn(a, effective_prog, effective_argv, cwd)
}

actor_write_input :: proc(a: ^Pane_Actor, data: []u8) -> bool {
	if a == nil do return false
	if !input_queue_push(&a.input_queue, data, a.allocator) {
		return false
	}
	_, _ = actor_flush_input(a)
	return true
}

actor_flush_input :: proc(a: ^Pane_Actor) -> (int, pty.Pty_Write_Status) {
	if a == nil do return 0, .Closed
	return input_queue_flush(&a.input_queue, &a.pty, a.allocator)
}

actor_flush_replies :: proc(a: ^Pane_Actor) -> (int, pty.Pty_Write_Status) {
	if a == nil do return 0, .Closed
	return input_queue_flush(&a.reply_queue, &a.pty, a.allocator)
}

actor_drain_pty :: proc(a: ^Pane_Actor, buf: []u8) -> (n: int, eof: bool) {
	if a == nil do return 0, true
	n, eof = pty.pty_drain(&a.pty, buf, len(buf))
	if n > 0 {
		parser.parse_chunk(&a.parser, &a.terminal, buf[:n])
		_, _ = actor_flush_replies(a)
	}
	if eof {
		pty.pty_poll_exit(&a.pty)
		if a.pty.state == .Exited {
			a.liveness = .Completed
		} else {
			a.liveness = .Uncertain
		}
	}
	return n, eof
}

actor_destroy :: proc(a: ^Pane_Actor) {
	if a == nil do return
	if a.pty.master >= 0 {
		pty.pty_close(&a.pty)
	}
	if a.pty.pid > 0 && a.pty.state != .Exited {
		if !pty.pty_poll_exit(&a.pty) {
			posix.kill(posix.pid_t(a.pty.pid), .SIGKILL)
			status: c.int
			posix.waitpid(posix.pid_t(a.pty.pid), &status, posix.Wait_Flags{})
			a.pty.state = .Exited
		}
	}
	input_queue_destroy(&a.input_queue, a.allocator)
	input_queue_destroy(&a.reply_queue, a.allocator)
	parser.parser_destroy(&a.parser)
	termgrid.terminal_destroy(&a.terminal, a.allocator)
}
