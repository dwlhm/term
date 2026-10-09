package app_test

import "base:runtime"
import "core:c"
import posix "core:sys/posix"
import "core:testing"
import app "../"
import parser "../../parser"

@(test)
test_parser_origins_survive_tab_reorder_and_compaction :: proc(t: ^testing.T) {
	sm := new(app.Session_Manager)
	defer free(sm)
	_seeded_manager(sm, 3, 0)
	defer app.session_manager_destroy(sm)
	readers: [3]posix.FD
	reader_count := 0
	defer {
		for reader in readers[:reader_count] do posix.close(reader)
	}
	for i in 0..<len(sm.tabs) {
		b := &sm.tabs[i].backend
		b.pty.master = -1
		b.pty.pid = -1
		b.wake_pipe_r = -1
		b.wake_pipe_w = -1
	}
	for i in 0..<len(sm.tabs) {
		fds: [2]posix.FD
		if !testing.expect(t, posix.pipe(&fds) == .OK) do return
		readers[i] = fds[0]
		reader_count += 1
		_ = posix.fcntl(fds[0], .SETFL, c.int(posix.O_NONBLOCK))
		b := &sm.tabs[i].backend
		b.pty.master = int(fds[1])
		b.pty.state = .Running
		b.parser.response_context_cb = app._backend_response_cb
		b.parser.response_user_data = b
		b.parser.clipboard_context_cb = app._backend_clipboard_cb
		b.parser.clipboard_user_data = b
		b.parser.graphics_user_data = b
		b.parser.clipboard_read_user_data = b
	}
	testing.expect(t, app.session_reorder_tab(sm, 0, 2))
	// Remove the first slot to force another move of every surviving backend.
	testing.expect(t, app.session_close_tab(sm, 0))
	for i in 0..<len(sm.tabs) {
		tab := sm.tabs[i]
		b := &tab.backend
		testing.expect(t, b.parser.response_user_data == rawptr(b))
		testing.expect(t, b.parser.clipboard_user_data == rawptr(b))
		testing.expect(t, b.parser.graphics_user_data == rawptr(b))
		testing.expect(t, b.parser.clipboard_read_user_data == rawptr(b))
		payload := []u8{u8('0' + tab.id)}
		parser.parser_emit_response(&b.parser, payload)
		parser.parser_emit_clipboard(&b.parser, payload)
		received: [1]u8
		n := posix.read(readers[int(tab.id) - 1], raw_data(received[:]), c.size_t(len(received)))
		testing.expect(t, n == 1 && received[0] == payload[0], "reply must reach the same session after storage moves")
		clipboard, ok := app.backend_take_pending_clipboard(b)
		defer delete(clipboard, runtime.heap_allocator())
		testing.expect(t, ok && clipboard == string(payload), "clipboard origin must follow the stable tab")
	}
}
