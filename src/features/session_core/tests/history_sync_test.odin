package feature_session_core_tests

// A viewer that skipped output (overflow, or attached before the tail) gets a
// paint without history first, and its full history once output settles.

import "core:fmt"
import "core:strings"
import "core:testing"
import core ".."
import terminal "../../../core/terminal"

// More than STREAM_MAX_PENDING (4 MiB) of "L<n>\r\n": an unread viewer overflows.
@(private = "file")
FLOOD_LINES :: 700_000

@(private = "file")
SETTLED :: max(i64) // a clock past every settle deadline

@(private = "file")
_output_lines :: proc(r: ^Rig, from, to: int) {
	b := strings.builder_make(context.temp_allocator)
	for i in from ..< to {
		fmt.sbprintf(&b, "L%d\r\n", i)
		if strings.builder_len(b) < 32 << 10 && i + 1 < to do continue
		core.core_session_output(r.c, r.s, b.buf[:])
		strings.builder_reset(&b)
	}
}

@(private = "file")
_row_text :: proc(t: ^terminal.Terminal, r: int) -> string {
	row := terminal.terminal_get_row(t, r)
	if row == nil do return "<none>"
	b := strings.builder_make(context.temp_allocator)
	for c in row.cells do if c.char > ' ' do strings.write_rune(&b, c.char)
	return strings.to_string(b)
}

// _expect_same_history: the viewer holds the core's last `h` history rows and its screen.
@(private = "file")
_expect_same_history :: proc(t: ^testing.T, core_t, view: ^terminal.Terminal, h: int) {
	testing.expect_value(t, view.grid.history_count, h)
	for r in -h ..< core_t.rows {
		if !testing.expectf(t, _row_text(view, r) == _row_text(core_t, r), "row %d: viewer %q core %q", r, _row_text(view, r), _row_text(core_t, r)) do return
	}
}

@(private = "file")
_view_make :: proc() -> ^terminal.Terminal {
	v := new(terminal.Terminal)
	terminal.terminal_init(v, 24, 80)
	return v
}

@(private = "file")
_view_free :: proc(v: ^terminal.Terminal) {
	terminal.terminal_destroy(v)
	free(v)
}

@(test)
test_overflowed_viewer_gets_its_history_once_output_settles :: proc(t: ^testing.T) {
	r: Rig
	testing.expect(t, rig_make(&r) && rig_attach(&r, 500) == 0, "rig")
	defer rig_destroy(&r)
	view := _view_make()
	defer _view_free(view)
	_output_lines(&r, 0, 1000)
	rig_deliver(&r, 0, view)
	// The viewer reads nothing until it overflows; output stops soon after the repaint.
	n := 1000
	for ; !r.s.attaches[0].stale && n < FLOOD_LINES; n += 10_000 do _output_lines(&r, n, n + 10_000)
	_output_lines(&r, n, n + 100)
	rig_deliver(&r, 0, view)
	core_t := &r.s.sess.term
	testing.expect(t, r.s.attaches[0].stale, "the overflow repaint carried no history")
	testing.expect(t, _row_text(view, -500) != _row_text(core_t, -500), "the viewer's history has a gap before the resync")

	core.core_settle_due(r.c, SETTLED)
	rig_deliver(&r, 0, view)
	testing.expect(t, !r.s.attaches[0].stale, "resynced")
	_expect_same_history(t, core_t, view, 500)
	testing.expect_value(t, r.s.settle_due_ns, i64(0))
}

@(test)
test_only_the_stale_viewer_is_resynced :: proc(t: ^testing.T) {
	r: Rig
	testing.expect(t, rig_make(&r) && rig_attach(&r, 500) == 0 && rig_attach(&r, 500) == 1, "rig")
	defer rig_destroy(&r)
	for from := 0; from < FLOOD_LINES; from += 50_000 {
		_output_lines(&r, from, from + 50_000)
		rig_deliver(&r, 1) // viewer 1 keeps up, viewer 0 reads nothing
	}
	rig_deliver(&r, 0)
	testing.expect(t, r.s.attaches[0].stale && !r.s.attaches[1].stale, "only the overflowed viewer is stale")
	core.core_settle_due(r.c, SETTLED)
	testing.expect(t, rig_deliver(&r, 0) > 0, "the stale viewer gets its resync")
	testing.expect_value(t, rig_deliver(&r, 1), 0)
}

@(test)
test_resync_waits_for_parser_ground :: proc(t: ^testing.T) {
	r: Rig
	testing.expect(t, rig_make(&r) && rig_attach(&r, 100) == 0, "rig")
	defer rig_destroy(&r)
	view := _view_make()
	defer _view_free(view)
	_output_lines(&r, 0, FLOOD_LINES)
	// A title longer than the relay holds passes through: the parser is mid-OSC.
	title := strings.concatenate({"\x1b]2;", strings.repeat("x", 600, context.temp_allocator)}, context.temp_allocator)
	core.core_session_output(r.c, r.s, transmute([]u8)title)
	testing.expect(t, !terminal.terminal_parser_at_ground(&r.s.sess.term), "mid-sequence")
	rig_deliver(&r, 0, view)
	core.core_settle_due(r.c, SETTLED)
	testing.expect(t, r.s.attaches[0].stale, "no paint in the middle of a sequence")
	testing.expect(t, r.s.settle_due_ns != 0, "settle is armed again")

	core.core_session_output(r.c, r.s, transmute([]u8)string("\x07done\r\n"))
	core.core_settle_due(r.c, SETTLED)
	rig_deliver(&r, 0, view)
	testing.expect(t, !r.s.attaches[0].stale, "resynced at ground")
	_expect_same_history(t, &r.s.sess.term, view, 100)
}

@(test)
test_detached_or_historyless_viewer_is_not_resynced :: proc(t: ^testing.T) {
	r: Rig
	testing.expect(t, rig_make(&r) && rig_attach(&r, 100) == 0 && rig_attach(&r, 0) == 1, "rig")
	defer rig_destroy(&r)
	_output_lines(&r, 0, FLOOD_LINES)
	rig_deliver(&r, 1)
	testing.expect(t, !r.s.attaches[1].stale, "a viewer that asked for no history has nothing to resync")
	core.core_detach(r.c, r.s, &r.s.attaches[0], true)
	core.core_settle_due(r.c, SETTLED)
	testing.expect_value(t, r.s.settle_due_ns, i64(0))
	testing.expect_value(t, rig_deliver(&r, 1), 0)
}
