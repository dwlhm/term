package terminal_tests

// A paint with history replaces the receiver's scrollback; one without keeps it.

import "core:fmt"
import "core:testing"
import term "../"

@(private = "file")
_numbered :: proc(t: ^term.Terminal, prefix: string, n: int) {
	for i in 0 ..< n do term.terminal_feed_string(t, fmt.tprintf("%s%d\r\n", prefix, i))
}

@test
test_paint_with_history_replaces_scrollback :: proc(t: ^testing.T) {
	src, dst: term.Terminal
	term.terminal_init(&src, 4, 20)
	term.terminal_init(&dst, 4, 20)
	defer term.terminal_destroy(&src)
	defer term.terminal_destroy(&dst)
	_numbered(&src, "new", 40)
	_numbered(&dst, "old", 30) // what a viewer saw before it fell behind

	out: [dynamic]u8
	defer delete(out)
	term.terminal_paint(&src, &out, 10)
	term.terminal_feed_bytes(&dst, out[:])

	testing.expect_value(t, dst.grid.history_count, 10)
	_paint_expect_rows_equal(t, &src, &dst, &src.grid, &dst.grid, -10, 4)
}

@test
test_paint_without_history_keeps_scrollback :: proc(t: ^testing.T) {
	src, dst: term.Terminal
	term.terminal_init(&src, 4, 20)
	term.terminal_init(&dst, 4, 20)
	defer term.terminal_destroy(&src)
	defer term.terminal_destroy(&dst)
	_numbered(&src, "new", 40)
	_numbered(&dst, "old", 30)
	before := dst.grid.history_count

	out: [dynamic]u8
	defer delete(out)
	term.terminal_paint(&src, &out, 0)
	term.terminal_feed_bytes(&dst, out[:])

	// The screen is replaced, the history the viewer already had stays as it was.
	testing.expect_value(t, dst.grid.history_count, before)
	_paint_expect_rows_equal(t, &src, &dst, &src.grid, &dst.grid, 0, 4)
	ref: term.Terminal
	term.terminal_init(&ref, 4, 20)
	defer term.terminal_destroy(&ref)
	_numbered(&ref, "old", 30)
	_paint_expect_rows_equal(t, &ref, &dst, &ref.grid, &dst.grid, -before, 0)
}
