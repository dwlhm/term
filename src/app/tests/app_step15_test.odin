package app_test

// TODO Langkah 15 app_term tests: exit-banner once, exit-key routing,
// relaunch cycle/failure, and the window_get_size -> app_on_resize chain.
// Headless notes: key routing and banner tests need no SDL; relaunch and
// resize tests use _bare_app (nil-backend renderer, parked pty) plus live
// pty_spawn for the cycle test. Renderer grid allocations from the resize
// chain are torn down explicitly (_s15_renderer_teardown).

import "core:testing"
import "core:time"
import posix "core:sys/posix"

import app "../"
import termgrid "../../terminal"
import render "../../render"
import tile "../../render/tile"
import input "../../platform/input"
import pty "../../platform/pty"

// _s15_row_has_prefix reports whether row starts with want (ASCII fast
// path stores the rune value directly in the content handle).
_s15_row_has_prefix :: proc(t: ^termgrid.Terminal, row: int, want: string) -> bool {
	if row < 0 || row >= t.grid.row_count {
		return false
	}
	if len(want) > t.grid.col_count {
		return false
	}
	phys := (t.grid.origin + row) & t.grid.mask
	if phys < 0 || phys >= len(t.grid.rows) {
		return false
	}
	for i in 0..<len(want) {
		if u32(t.grid.rows[phys].cells[i].content) != u32(want[i]) {
			return false
		}
	}
	return true
}

// _s15_renderer_teardown frees grid-state allocations a resize chain made
// on a nil-backend renderer (compiled frames, tile map, upload ring).
_s15_renderer_teardown :: proc(a: ^app.App) {
	r := &a.renderer
	render.upload_ring_destroy(&r.upload_ring)
	render.dirty_upload_destroy(&r.dirty)
	tile.tile_map_destroy(&r.tile_map)
	render.render_compiler_destroy_v2(&r.compiled_v2)
	render.render_compiler_destroy(&r.compiled)
	if r.instances.instance_data != nil {
		delete(r.instances.instance_data)
		r.instances.instance_data = nil
	}
}

// _s15_poll_until polls pty_poll_exit until the child is reaped or the
// budget runs out.
_s15_poll_until :: proc(p: ^pty.Pty) -> bool {
	for _ in 0..<200 {
		if pty.pty_poll_exit(p) {
			return true
		}
		time.sleep(5 * time.Millisecond)
	}
	return false
}

// _s15_kill sends SIGTERM to a live child; failures are ignored because
// the child may already have exited on its own.
_s15_kill :: proc(p: ^pty.Pty) {
	if p.pid > 0 {
		posix.kill(posix.pid_t(p.pid), .SIGTERM)
	}
}

@(test)
test_s15_exited_key_routing :: proc(t: ^testing.T) {
	// 7 vectors, no SDL: r/R relaunch, q/Q + Escape quit, rest ignored.
	vectors := [7]struct {
		ev:   input.Input_Event,
		want: app.App_Exit_Action,
	}{
		{ev = input.Input_Event{kind = .Printable, rune = 'r'}, want = .Relaunch},
		{ev = input.Input_Event{kind = .Printable, rune = 'R'}, want = .Relaunch},
		{ev = input.Input_Event{kind = .Printable, rune = 'q'}, want = .Quit},
		{ev = input.Input_Event{kind = .Printable, rune = 'Q'}, want = .Quit},
		{ev = input.Input_Event{kind = .Escape}, want = .Quit},
		{ev = input.Input_Event{kind = .Printable, rune = 'x'}, want = .None},
		{ev = input.Input_Event{kind = .Arrow_Up}, want = .None},
	}
	for v in vectors {
		got := app.app_handle_exited_key(v.ev)
		testing.expect(t, got == v.want, "exit-key vector must route")
	}
}

@(test)
test_s15_banner_once :: proc(t: ^testing.T) {
	a: app.App
	_bare_app(&a)
	defer _bare_destroy(&a)

	a.pty.exit_code = 3
	app.app_show_banner(&a)
	testing.expect(t, a.banner_shown, "banner must latch banner_shown")
	last := a.terminal.grid.row_count - 1
	testing.expect(t, _s15_row_has_prefix(&a.terminal, last, "[ process exited (3)"), "bottom row must carry the exit banner")

	// Second call rewrites the same text (transition gate in frame keeps
	// it to one write per Exited episode).
	app.app_show_banner(&a)
	testing.expect(t, a.banner_shown, "banner flag must stay latched")
	testing.expect(t, _s15_row_has_prefix(&a.terminal, last, "[ process exited (3)"), "banner text must survive the rewrite")
}

@(test)
test_s15_relaunch_cycle :: proc(t: ^testing.T) {
	a: app.App
	_bare_app(&a)
	defer _bare_destroy(&a)

	a.prog = "/bin/cat"
	a.argv = nil
	if !pty.pty_spawn(&a.pty, APP_TEST_ROWS, APP_TEST_COLS, a.prog, a.argv) {
		testing.expect(t, false, "pty_spawn(/bin/cat) must succeed")
		return
	}
	old_pid := a.pty.pid

	termgrid.terminal_put_string(&a.terminal, "stale")
	_s15_kill(&a.pty)
	if !_s15_poll_until(&a.pty) {
		testing.expect(t, false, "poll must reap the killed child")
		pty.pty_close(&a.pty)
		return
	}
	testing.expect(t, a.pty.state == .Exited, "killed child must poll Exited")

	app.app_show_banner(&a)
	testing.expect(t, a.banner_shown, "exited episode must latch the banner")

	testing.expect(t, app.app_relaunch(&a), "relaunch must succeed")
	testing.expect(t, a.pty.state == .Running, "relaunched child must be Running")
	testing.expect(t, a.pty.pid != old_pid, "relaunch must spawn a new pid")
	testing.expect(t, !a.banner_shown, "relaunch must clear the banner latch")
	cur := termgrid.terminal_get_cursor(&a.terminal)
	testing.expect(t, cur.row == 0 && cur.col == 0, "cursor must be home after relaunch")
	testing.expect(t, !_s15_row_has_prefix(&a.terminal, 0, "stale"), "grid must be cleared by relaunch")

	_s15_kill(&a.pty)
	_s15_poll_until(&a.pty)
	pty.pty_close(&a.pty)
}

@(test)
test_s15_relaunch_fail :: proc(t: ^testing.T) {
	a: app.App
	_bare_app(&a)
	defer _bare_destroy(&a)

	a.prog = "/nonexistent/term-step15-bad-prog"
	a.argv = nil
	a.pty.state = .Exited
	testing.expect(t, !app.app_relaunch(&a), "bad prog must fail relaunch")
	testing.expect(t, a.pty.state == .Exited, "failed relaunch must keep Exited")
	testing.expect(t, a.banner_shown, "failed relaunch must show the FAIL banner")
	last := a.terminal.grid.row_count - 1
	testing.expect(t, _s15_row_has_prefix(&a.terminal, last, "[ relaunch failed"), "bottom row must carry the FAIL banner")
}

@(test)
test_s15_resize_noop :: proc(t: ^testing.T) {
	a: app.App
	_bare_app(&a)
	defer _bare_destroy(&a)

	px_w := i32(APP_TEST_COLS * app.APP_CELL_W)
	px_h := i32(APP_TEST_ROWS * app.APP_CELL_H)
	a.last_px_w = px_w
	a.last_px_h = px_h
	testing.expect(t, !app.app_on_resize(&a, px_w, px_h), "same dims+px must be a no-op false")
	testing.expect(t, !app.app_on_resize(&a, 0, px_h), "degenerate px_w must be false untouched")
	testing.expect(t, !app.app_on_resize(&a, px_w, -1), "degenerate px_h must be false untouched")
	testing.expect(t, a.terminal.grid.row_count == APP_TEST_ROWS && a.terminal.grid.col_count == APP_TEST_COLS, "no-op resizes must leave dims")
}

@(test)
test_s15_resize_chain :: proc(t: ^testing.T) {
	a: app.App
	_bare_app(&a)
	defer _bare_destroy(&a)
	defer _s15_renderer_teardown(&a)

	termgrid.terminal_put_string(&a.terminal, "hi")
	px_w := i32(100 * app.APP_CELL_W)
	px_h := i32(30 * app.APP_CELL_H)
	testing.expect(t, app.app_on_resize(&a, px_w, px_h), "bigger dims must resize true")
	testing.expect(t, a.terminal.grid.row_count == 30 && a.terminal.grid.col_count == 100, "terminal dims must follow the resize")
	testing.expect(t, a.renderer.rows == 30 && a.renderer.cols == 100, "renderer grid dims must follow the resize")
	testing.expect(t, a.last_px_w == px_w && a.last_px_h == px_h, "last_px must store the applied size")
	testing.expect(t, _row_matches(&a.terminal, 0, "hi"), "terminal content must survive the resize")
}
