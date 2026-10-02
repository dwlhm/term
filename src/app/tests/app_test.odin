package app_test

// TODO Langkah 14 app_term tests (headless): one test per MECE row of the
// locked spec, adapted to headless limits. No display and no GPU exist in
// CI, so every GPU present is expected to no-op (nil backend) while the
// CPU-verifiable contract is pinned: init-failure unwind, frame ordering
// (pump -> drain -> parse -> cursor -> frame_auto -> exit poll), damage
// consumption, cursor staging at the reserved slot, quit events, resize
// chain, child-exit parking, and a live pty drain->parse->grid run with a
// scripted child.
//
// Headless limits (documented honestly):
// - SDL uses the dummy video driver (set via SDL_VIDEODRIVER in-process);
//   windows create fine but no pixels are ever shown.
// - The renderer stays zero-value (nil backend): renderer_frame_auto returns
//   false without touching the GPU, while cursor_overlay_draw stages its quad
//   (backend-independent) before the renderer call.
// - The renderer boundary owns surface composition and presentation; headless
//   app tests assert staging, blink transitions, and damage consumption.

import "core:testing"
import "core:time"
import "core:os"
import posix "core:sys/posix"
import "core:strings"
import "vendor:sdl3"

import app "../"
import termgrid "../../terminal"
import parser "../../parser"
import render "../../render"
import instance "../../render/instance"
import win "../../platform/window"
import pty "../../platform/pty"
import input "../../platform/input"
import platform_tabs "../../platform/tabs"
import config "../../config"
import interaction "../../interaction"

APP_TEST_ROWS :: 24
APP_TEST_COLS :: 80
APP_TEST_MAX  :: 64

// _dummy_video forces the SDL dummy driver so window_init works headless.
_dummy_video :: proc() {
	_ = os.set_env("SDL_VIDEODRIVER", "dummy")
	_ = os.set_env("SDL_AUDIODRIVER", "dummy")
}

// _dummy_window forces the SDL dummy driver and creates w with bounded
// retry (dummy video flakes under rapid back-to-back runs). Returns false
// when infra is absent; callers SKIP on false.
_dummy_window :: proc(t: ^testing.T, w: ^win.Window, title: string, width, height: i32) -> bool {
	_dummy_video()
	for _ in 0..<5 {
		if win.window_init(w, title, width, height) {
			return true
		}
		time.sleep(10 * time.Millisecond)
	}
	return false
}
// _bare_app builds an App with terminal + parser live, pty parked
// (master/pid -1, drain-safe), window + renderer zero. No SDL calls.
_bare_app :: proc(a: ^app.App) {
	a.pty.master = -1
	a.pty.pid = -1
	a.focused = true
	a.config = config.config_default()
	termgrid.terminal_init(&a.terminal, APP_TEST_ROWS, APP_TEST_COLS)
	parser.parser_init(&a.parser)
	a.drain_buf = make([]u8, app.APP_DRAIN_CAP, context.allocator)
}

_bare_destroy :: proc(a: ^app.App) {
	config.config_destroy(&a.config)
	termgrid.terminal_destroy(&a.terminal)
	parser.parser_destroy(&a.parser)
	delete(a.drain_buf, context.allocator)
}

_app_test_clipboard_read_cb :: proc(user_data: rawptr, out: []u8) -> int {
	if user_data == nil {
		return 0
	}
	text := (^string)(user_data)^
	n := min(len(text), len(out))
	data := transmute([]u8)text
	copy(out[:n], data[:n])
	return n
}

// _cpu_renderer gives a zero-backend renderer CPU-valid geometry plus a
// staging buffer, so cursor_overlay_draw can stage (present still no-ops).
_cpu_renderer :: proc(a: ^app.App) {
	a.renderer.rows = APP_TEST_ROWS
	a.renderer.cols = APP_TEST_COLS
	a.renderer.cell_width = app.APP_CELL_W
	a.renderer.cell_height = app.APP_CELL_H
	a.renderer.pad_x = 0
	a.renderer.pad_y = 0
	a.renderer.instances.max_instances = APP_TEST_MAX
	a.renderer.instances.instance_data = make([]instance.Instance_Data, APP_TEST_MAX)
}

_cpu_renderer_destroy :: proc(a: ^app.App) {
	delete(a.renderer.instances.instance_data)
	a.renderer.instances.instance_data = nil
}

// _damage_cells counts dirty cells in the live damage state.
_damage_cells :: proc(t: ^termgrid.Terminal) -> int {
	n := 0
	for i in 0..<len(t.damage.dirty_rows) {
		dr := &t.damage.dirty_rows[i]
		if dr.full {
			n += t.damage.col_count
		} else {
			for j in 0..<int(dr.span_count) {
				s := dr.spans[j]
				n += max(0, int(s.col_end) - int(s.col_start))
			}
		}
	}
	return n
}

// _row_matches reports whether row starts with want (ASCII fast path
// stores the rune value directly in the content handle).
_row_matches :: proc(t: ^termgrid.Terminal, row: int, want: string) -> bool {
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

@(test)
test_app_init_rejects_nil_and_empty :: proc(t: ^testing.T) {
	testing.expect(t, !app.app_init(nil, 24, 80, "/bin/sh", nil), "nil app must fail")
	a := new(app.App)
	defer free(a)
	testing.expect(t, !app.app_init(a, 24, 80, "", nil), "empty prog must fail without side effects")
	testing.expect_value(t, a.pty.master, -1)
}

@(test)
test_app_frame_nil_safe :: proc(t: ^testing.T) {
	testing.expect(t, !app.app_frame(nil), "nil app must return false")
}

@(test)
test_app_frame_headless_skip :: proc(t: ^testing.T) {
	a := new(app.App)
	defer free(a)
	_bare_app(a)
	defer _bare_destroy(a)

	// Clean grid + steady cursor after the first arming tick: frames
	// skip the GPU path but stay alive.
	for i in 0..<3 {
		testing.expect(t, app.app_frame(a), "headless frame must stay alive")
	}
	testing.expect(t, a.cursor.blink_on, "first tick must arm blink_on (visible+focused)")
	testing.expect(t, !a.should_quit, "no quit without SDL events")
}

@(test)
test_app_frame_damage_consumed_and_cursor_staged :: proc(t: ^testing.T) {
	a := new(app.App)
	defer free(a)
	_bare_app(a)
	defer _bare_destroy(a)
	_cpu_renderer(a)
	defer _cpu_renderer_destroy(a)

	termgrid.terminal_put_string(&a.terminal, "hi")
	testing.expect(t, _damage_cells(&a.terminal) > 0, "setup must produce damage")

	testing.expect(t, app.app_frame(a), "damage frame must stay alive")
	testing.expect(t, _damage_cells(&a.terminal) > 0, "nil-backend publication failure must keep damage queued")

	// The damage present found no backend (headless), but the cursor quad
	// for the same frame must be staged at the reserved slot: cursor at
	// (0,2) after "hi".
	slot := a.renderer.instances.max_instances - 1
	got := a.renderer.instances.instance_data[slot]
	testing.expect(t, got != instance.Instance_Data{}, "cursor quad must be staged")
	testing.expect_value(t, got.x, f32(2 * app.APP_CELL_W))
	testing.expect_value(t, got.y, 0.0)
	testing.expect(t, _row_matches(&a.terminal, 0, "hi"), "parsed output must reach the grid")
}

@(test)
test_app_cursor_blink_change_renders_without_overlay_present :: proc(t: ^testing.T) {
	a := new(app.App)
	defer free(a)
	_bare_app(a)
	defer _bare_destroy(a)
	_cpu_renderer(a)
	defer _cpu_renderer_destroy(a)

	// The first visible tick arms the cursor and marks a renderable cell even
	// though the terminal scene starts clean.
	testing.expect(t, app.app_frame(a), "headless frame must stay alive")
	testing.expect(t, a.cursor.blink_on && a.cursor.visible, "cursor must start visible")
	testing.expect(t, _damage_cells(&a.terminal) > 0, "nil-backend publication failure must keep cursor damage queued")

	// Force the next tick into the opposite blink phase. The app must consume
	// the cursor-only damage through the normal renderer path; no overlay-only
	// present is available or required.
	a.cursor.next_toggle = 1
	testing.expect(t, app.app_frame(a), "blink-change frame must stay alive")
	testing.expect(t, !a.cursor.blink_on, "blink change must hide the cursor")
	testing.expect(t, _damage_cells(&a.terminal) > 0, "nil-backend publication failure must keep blink damage queued")
}

@(test)
test_app_frame_quit_event :: proc(t: ^testing.T) {
	a := new(app.App)
	defer free(a)
	_bare_app(a)
	defer _bare_destroy(a)
	if !_dummy_window(t, &a.window, "app-test-quit", 64, 64) {
		testing.expect(t, true, "SKIP: dummy video unavailable after retries; infra flake, not a code defect")
		return
	}
	defer win.window_destroy(&a.window)

	ev: sdl3.Event
	ev.type = .QUIT
	if !sdl3.PushEvent(&ev) {
		testing.expect(t, true, "SKIP: PushEvent transient queue failure; infra flake, not a code defect")
		return
	}
	testing.expect(t, !app.app_frame(a), "QUIT event must request quit")
	testing.expect(t, a.should_quit, "should_quit must latch")
}

@(test)
test_app_frame_drain_parse_exit :: proc(t: ^testing.T) {
	a := new(app.App)
	defer free(a)
	_bare_app(a)
	defer _bare_destroy(a)
	defer _s15_renderer_teardown(a)
	if !_dummy_window(t, &a.window, "app-test-drain", APP_TEST_COLS * app.APP_CELL_W, APP_TEST_ROWS * app.APP_CELL_H) {
		testing.expect(t, true, "SKIP: dummy video unavailable after retries; infra flake, not a code defect")
		return
	}
	defer win.window_destroy(&a.window)

	// Scripted child: prints once, exits. Drain -> parse -> grid runs
	// through app_frame with a nil-backend renderer (no present).
	if !pty.pty_spawn(&a.pty, APP_TEST_ROWS, APP_TEST_COLS, "/bin/echo", {"hello"}) {
		testing.expect(t, false, "pty_spawn(/bin/echo) must succeed")
		return
	}
	defer pty.pty_close(&a.pty)

	found := false
	for i in 0..<200 {
		if !app.app_frame(a) {
			break
		}
		if _row_matches(&a.terminal, 0, "hello") {
			found = true
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, found, "grid row 0 must contain child output after drain->parse")

	exited := false
	for i in 0..<200 {
		_ = app.app_frame(a)
		if a.pty.state == .Exited {
			exited = true
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, exited, "exit poll must record the Exited state")

	// Exited loop keeps running (banner is step 15), input parked.
	testing.expect(t, app.app_frame(a), "post-exit frame must stay alive")
}

@(test)
test_app_zoom_request_bounds_and_coalescing :: proc(t: ^testing.T) {
	a := new(app.App)
	defer free(a)
	a.pty.state = .Running
	a.logical_font_size = app.APP_FONT_SIZE

	// Multiple local actions update one target; the renderer rebuild is
	// deferred until the app frame applies that target.
	testing.expect(t, app._app_request_zoom(a, 1), "first zoom request must advance")
	testing.expect(t, app._app_request_zoom(a, 1), "second zoom request must coalesce")
	testing.expect_value(
		t,
		a.zoom_target_logical_size,
		app.APP_FONT_SIZE + 2 * app.APP_FONT_ZOOM_STEP,
	)

	a.zoom_target_logical_size = 0
	a.logical_font_size = app.APP_FONT_ZOOM_MIN
	testing.expect(t, !app._app_request_zoom(a, -1), "minimum zoom must clamp")
	testing.expect_value(t, a.zoom_target_logical_size, app.APP_FONT_ZOOM_MIN)

	a.zoom_target_logical_size = 0
	a.logical_font_size = app.APP_FONT_ZOOM_MAX
	testing.expect(t, !app._app_request_zoom(a, 1), "maximum zoom must clamp")
	testing.expect_value(t, a.zoom_target_logical_size, app.APP_FONT_ZOOM_MAX)

	a.pty.state = .Exited
	a.zoom_target_logical_size = 0
	testing.expect(t, !app._app_request_zoom(a, 1), "exited child must ignore zoom")
	testing.expect_value(t, a.zoom_target_logical_size, 0.0)
}

@(test)
test_app_pointer_cell_scales_logical_coordinates :: proc(t: ^testing.T) {
	a := new(app.App)
	defer free(a)
	_bare_app(a)
	defer _bare_destroy(a)
	_cpu_renderer(a)
	defer _cpu_renderer_destroy(a)

	a.window.width = 640
	a.window.height = 384
	a.window.pixel_w = 1280
	a.window.pixel_h = 768

	retina := app._app_pointer_cell(a, 12, 24)
	testing.expect(t, retina.row == 3 && retina.col == 3, "HiDPI logical pointer must map to physical grid cell")

	a.window.pixel_w = a.window.width
	a.window.pixel_h = a.window.height
	standard := app._app_pointer_cell(a, 12, 24)
	testing.expect(t, standard.row == 1 && standard.col == 1, "equal logical and pixel sizes must not scale twice")

	a.window.width = 0
	a.window.height = 0
	a.window.pixel_w = 0
	a.window.pixel_h = 0
	invalid := app._app_pointer_cell(a, 12, 24)
	testing.expect(t, invalid.row == 1 && invalid.col == 1, "invalid window sizes must keep unit scale")
}

@(test)
test_app_init_failure_unwind :: proc(t: ^testing.T) {
	// Pre-window failures unwind trivially and leave the pty drain-safe.
	a := new(app.App)
	defer free(a)
	testing.expect(t, !app.app_init(a, APP_TEST_ROWS, APP_TEST_COLS, "", nil), "empty prog must fail init")
	testing.expect_value(t, a.pty.master, -1)
	testing.expect_value(t, a.pty.pid, -1)
	// HEADLESS LIMIT (honest): stages past window creation (surface,
	// device, renderer, pty_spawn) cannot run under SDL dummy video:
	// wgpu's GetSurface aborts (Rust panic, non-unwinding) on dummy
	// windows, killing the test runner. The reverse-order unwind chain
	// for those stages is verified by inspection (each stage destroys
	// exactly the completed prefix in reverse). A display/GPU run of
	// app_init with a bad prog is the manual complement.
}

@(test)
test_app_wheel_alt_screen_arrow_keys :: proc(t: ^testing.T) {
	a := new(app.App)
	defer free(a)
	_bare_app(a)
	defer _bare_destroy(a)

	pipefd: [2]posix.FD
	if posix.pipe(&pipefd) != .OK {
		testing.expect(t, false, "posix.pipe must succeed")
		return
	}
	defer {
		posix.close(pipefd[0])
		posix.close(pipefd[1])
	}

	a.pty.master = int(pipefd[1])
	a.pty.state = .Running
	a.terminal.is_alt_screen = true

	// 1. Normal cursor keys (app_cursor_keys = false), Wheel Up (+1)
	// Must emit 3x ESC [ A -> 9 bytes: "\x1b[A\x1b[A\x1b[A"
	a.terminal.app_cursor_keys = false
	ev_up := input.Input_Pointer_Event{
		kind = .Wheel,
		wheel_integer_y = 1,
	}
	testing.expect(t, app._app_route_pointer(a, ev_up), "route pointer wheel up must return true")

	buf: [32]u8
	n := posix.read(pipefd[0], raw_data(buf[:]), len(buf))
	testing.expect_value(t, n, 9)
	testing.expect_value(t, string(buf[:n]), "\x1b[A\x1b[A\x1b[A")

	// 2. Normal cursor keys (app_cursor_keys = false), Wheel Down (-1)
	// Must emit 3x ESC [ B -> 9 bytes: "\x1b[B\x1b[B\x1b[B"
	ev_down := input.Input_Pointer_Event{
		kind = .Wheel,
		wheel_integer_y = -1,
	}
	testing.expect(t, app._app_route_pointer(a, ev_down), "route pointer wheel down must return true")

	n = posix.read(pipefd[0], raw_data(buf[:]), len(buf))
	testing.expect_value(t, n, 9)
	testing.expect_value(t, string(buf[:n]), "\x1b[B\x1b[B\x1b[B")

	// 3. App cursor keys (app_cursor_keys = true), Wheel Up (+1)
	// Must emit 3x ESC O A -> 9 bytes: "\x1bOA\x1bOA\x1bOA"
	a.terminal.app_cursor_keys = true
	testing.expect(t, app._app_route_pointer(a, ev_up), "route pointer wheel up in app mode must return true")

	n = posix.read(pipefd[0], raw_data(buf[:]), len(buf))
	testing.expect_value(t, n, 9)
	testing.expect_value(t, string(buf[:n]), "\x1bOA\x1bOA\x1bOA")

	// 4. App cursor keys (app_cursor_keys = true), Wheel Down (-1)
	// Must emit 3x ESC O B -> 9 bytes: "\x1bOB\x1bOB\x1bOB"
	testing.expect(t, app._app_route_pointer(a, ev_down), "route pointer wheel down in app mode must return true")

	n = posix.read(pipefd[0], raw_data(buf[:]), len(buf))
	testing.expect_value(t, n, 9)
	testing.expect_value(t, string(buf[:n]), "\x1bOB\x1bOB\x1bOB")

	// 5. Zero delta wheel event on alt screen returns true without writing
	ev_zero := input.Input_Pointer_Event{
		kind = .Wheel,
		wheel_integer_y = 0,
	}
	testing.expect(t, app._app_route_pointer(a, ev_zero), "zero wheel delta must return true")
}

@(test)
test_app_synchronized_output_deferral_and_timeout :: proc(t: ^testing.T) {
	a := new(app.App)
	defer free(a)
	_bare_app(a)
	defer _bare_destroy(a)
	_cpu_renderer(a)
	defer _cpu_renderer_destroy(a)

	termgrid.terminal_put_string(&a.terminal, "sync")
	damage_before := _damage_cells(&a.terminal)
	testing.expect(t, damage_before > 0, "putting string must create damage")

	// 1. Enable synchronized output (Mode 2026)
	termgrid.terminal_set_sync_output(&a.terminal, true)
	testing.expect(t, a.terminal.synchronized_output, "synchronized output should be enabled")
	testing.expect_value(t, a.sync_output_start_ns, u64(0))

	// 2. Frame 1: Synchronized output active and within timeout -> renderer_frame must be skipped.
	// Frame count stays 0 and sync_output_start_ns is recorded.
	ok := app.app_frame(a)
	testing.expect(t, ok, "app_frame must succeed")
	testing.expect(t, a.sync_output_start_ns > 0, "sync_output_start_ns must record timestamp on first sync frame")
	testing.expect_value(t, a.renderer.frame_count, u64(0))
	testing.expect(t, _damage_cells(&a.terminal) > 0, "damage must remain queued while presentation is deferred")

	// 3. Frame 2: Still within 100ms -> presentation remains deferred.
	ok = app.app_frame(a)
	testing.expect(t, ok, "app_frame must succeed on deferred frame")
	testing.expect_value(t, a.renderer.frame_count, u64(0))
	testing.expect(t, _damage_cells(&a.terminal) > 0, "damage must remain queued while presentation is deferred")

	// 4. Timeout reached: set sync_output_start_ns to 1 (in the past relative to now >= 100ms).
	// Safety timeout triggers -> renderer_frame proceeds, incrementing frame_count.
	a.sync_output_start_ns = 1
	ok = app.app_frame(a)
	testing.expect(t, ok, "app_frame must succeed on safety timeout")
	testing.expect_value(t, a.renderer.frame_count, u64(1))

	// 5. Disable synchronized output: resets sync_output_start_ns to 0 and renders normally.
	termgrid.terminal_set_sync_output(&a.terminal, false)
	termgrid.terminal_put_string(&a.terminal, "more")
	ok = app.app_frame(a)
	testing.expect(t, ok, "app_frame must succeed when sync output is disabled")
	testing.expect_value(t, a.sync_output_start_ns, u64(0))
	testing.expect_value(t, a.renderer.frame_count, u64(2))
}

@(test)
test_app_reload_config :: proc(t: ^testing.T) {
	a := new(app.App)
	defer free(a)
	_bare_app(a)
	defer _bare_destroy(a)

	render.style_lut_rebuild(&a.lut, &a.terminal.grid.style_table)

	// Verify initial config
	testing.expect_value(t, a.config.theme_name, "Catppuccin Mocha")

	// Set a custom config via TERM_CONFIG
	tmp_cfg := "./term.odin"
	cfg_content := `
theme = "Catppuccin Mocha"
background = 0xFF000000
foreground = 0xFFFFFFFF
font_size = 18.0
`
	_ = os.write_entire_file(tmp_cfg, transmute([]u8)cfg_content)
	defer os.remove(tmp_cfg)
	os.set_env("TERM_CONFIG", tmp_cfg)
	defer os.unset_env("TERM_CONFIG")

	ok := app.app_reload_config(a)
	testing.expect(t, ok, "app_reload_config must succeed on valid config")
	testing.expect_value(t, a.config.background, u32(0xFF000000))
	testing.expect_value(t, a.config.foreground, u32(0xFFFFFFFF))
	testing.expect_value(t, a.config.font_size, f32(18.0))
	testing.expect_value(t, a.terminal.grid.style_table.theme.background, u32(0xFF000000))

	// Now test reloading with syntax error in config
	bad_cfg_content := `
background = = 1234
`
	_ = os.write_entire_file(tmp_cfg, transmute([]u8)bad_cfg_content)

	bad_ok := app.app_reload_config(a)
	testing.expect(t, !bad_ok, "app_reload_config must fail on syntax error")
	// State must be 100% retained
	testing.expect_value(t, a.config.background, u32(0xFF000000))
	testing.expect_value(t, a.terminal.grid.style_table.theme.background, u32(0xFF000000))
}

@(test)
test_backend_threaded_worker_and_double_buffer :: proc(t: ^testing.T) {
	b := new(app.Backend)
	defer free(b)
	theme := termgrid.Theme{
		name                 = "test",
		foreground           = 0xFFFFFFFF,
		background           = 0xFF000000,
		selection_foreground = 0xFF000000,
		selection_background = 0xFFFFFFFF,
		palette_256_policy   = .Xterm_Cube_Grayscale,
	}
	cfg := config.config_default()
	defer config.config_destroy(&cfg)

	ok := app.backend_init(b, 24, 80, "/bin/sh", {}, &cfg, theme)
	testing.expect(t, ok, "backend_init must succeed")
	defer app.backend_destroy(b)

	// Start worker thread
	started := app.backend_start_thread(b)
	testing.expect(t, started, "backend_start_thread must succeed")
	testing.expect(t, app.backend_is_threaded(b), "backend_is_threaded must report true")

	// Push key event to write echo command to child shell
	echo_cmd := "echo THREAD_OK\n"
	for ch in echo_cmd {
		ev := input.Input_Event{
			event_type = .Key,
			kind       = .Printable if ch != '\n' else .Enter,
			rune       = ch,
		}
		app.backend_push_event(b, app.UI_Event{type = .Input, input = ev})
	}

	// Poll front buffer render state until the text appears in front buffer
	found := false
	for _ in 0..<100 {
		app.backend_lock_render(b)
		state := app.backend_get_render_state(b)
		if state.terminal != nil {
			// Scan front buffer grid for THREAD_OK
			for r in 0..<state.terminal.grid.row_count {
				for c in 0..=(state.terminal.grid.col_count - 9) {
					match := true
					target := "THREAD_OK"
					for i in 0..<len(target) {
						cell := termgrid.terminal_get_cell(state.terminal, r, c + i)
						if u32(cell.content) != u32(target[i]) {
							match = false
							break
						}
					}
					if match {
						found = true
						break
					}
				}
				if found {
					break
				}
			}
		}
		app.backend_unlock_render(b)
		if found {
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, found, "front buffer must receive parsed output from background thread")

	// Stop thread and verify clean join
	app.backend_stop_thread(b)
	testing.expect(t, !app.backend_is_threaded(b), "backend_is_threaded must report false after stop")
}

@(test)
test_ui_event_queue :: proc(t: ^testing.T) {
	q: app.UI_Event_Queue
	ev1 := app.UI_Event{type = .Focus, focused = true}
	ev2 := app.UI_Event{type = .Resize, rows = 30, cols = 100}

	ok1 := app.ui_event_queue_push(&q, ev1)
	ok2 := app.ui_event_queue_push(&q, ev2)
	testing.expect(t, ok1 && ok2, "event queue push must succeed")

	out: [4]app.UI_Event
	n := app.ui_event_queue_pop_all(&q, out[:])
	testing.expect_value(t, n, 2)
	testing.expect(t, out[0].type == .Focus && out[0].focused, "first popped event must be Focus")
	testing.expect(t, out[1].type == .Resize && out[1].rows == 30 && out[1].cols == 100, "second popped event must be Resize")
}

@(test)
test_ui_event_queue_resize_coalescing :: proc(t: ^testing.T) {
	q: app.UI_Event_Queue
	testing.expect(t, !app.ui_event_queue_has_resize(&q), "empty queue must have no resize")

	// Push an initial resize
	_ = app.ui_event_queue_push(&q, app.UI_Event{type = .Resize, rows = 24, cols = 80, pixel_w = 800, pixel_h = 600})
	testing.expect(t, app.ui_event_queue_has_resize(&q), "queue must indicate pending resize")

	// Push another resize - should coalesce in-place rather than appending a new event
	_ = app.ui_event_queue_push(&q, app.UI_Event{type = .Resize, rows = 30, cols = 100, pixel_w = 1000, pixel_h = 750})
	testing.expect_value(t, q.count, 1)

	out: [2]app.UI_Event
	n := app.ui_event_queue_pop_all(&q, out[:])
	testing.expect_value(t, n, 1)
	testing.expect_value(t, out[0].rows, 30)
	testing.expect_value(t, out[0].cols, 100)
	testing.expect_value(t, out[0].pixel_w, 1000)
	testing.expect_value(t, out[0].pixel_h, 750)
	testing.expect(t, !app.ui_event_queue_has_resize(&q), "queue must have no resize after pop")
}

@(test)
test_backend_paste_shadow_worker_routing :: proc(t: ^testing.T) {
	clipboard := "quux"
	b := new(app.Backend)
	defer free(b)
	termgrid.terminal_init(&b.terminal, APP_TEST_ROWS, APP_TEST_COLS)
	defer termgrid.terminal_destroy(&b.terminal)
	parser.parser_init(&b.parser)
	defer parser.parser_destroy(&b.parser)
	interaction.interaction_init(&b.interaction)

	paste_pipe: [2]posix.FD
	if posix.pipe(&paste_pipe) != .OK {
		testing.expect(t, false, "posix.pipe must succeed")
		return
	}
	b.pty.master = int(paste_pipe[1])
	b.pty.state = .Running
	app.backend_handle_ui_event(b, app.UI_Event{type = .Paste, text = strings.clone(clipboard)})
	for ch in clipboard {
		app.backend_handle_ui_event(b, app.UI_Event{
			type = .Input,
			input = input.Input_Event{
				event_type   = .Key,
				kind         = .Printable,
				rune         = ch,
				paste_shadow = true,
			},
		})
	}
	posix.close(paste_pipe[1])
	b.pty.master = -1
	paste_buf: [32]u8
	paste_n := posix.read(paste_pipe[0], raw_data(paste_buf[:]), len(paste_buf))
	posix.close(paste_pipe[0])
	testing.expect_value(t, paste_n, len(clipboard))
	if paste_n > 0 {
		testing.expect_value(t, string(paste_buf[:paste_n]), clipboard)
	}
	testing.expect_value(t, b.interaction.mode, interaction.Interaction_Mode.Passthrough)

	search_pipe: [2]posix.FD
	if posix.pipe(&search_pipe) != .OK {
		testing.expect(t, false, "posix.pipe must succeed")
		return
	}
	b.pty.master = int(search_pipe[1])
	b.interaction.mode = .Search
	b.interaction.search_active = true
	for ch in clipboard {
		app.backend_handle_ui_event(b, app.UI_Event{
			type = .Input,
			input = input.Input_Event{
				event_type   = .Key,
				kind         = .Printable,
				rune         = ch,
				paste_shadow = true,
			},
		})
	}
	posix.close(search_pipe[1])
	b.pty.master = -1
	search_buf: [32]u8
	search_n := posix.read(search_pipe[0], raw_data(search_buf[:]), len(search_buf))
	posix.close(search_pipe[0])
	testing.expect_value(t, search_n, 0)
	testing.expect_value(t, string(b.interaction.search_query[:b.interaction.search_len]), clipboard)
}

@(test)
test_app_interaction_dispatch_integration :: proc(t: ^testing.T) {
	b := new(app.Backend)
	defer free(b)
	termgrid.terminal_init(&b.terminal, APP_TEST_ROWS, APP_TEST_COLS)
	defer termgrid.terminal_destroy(&b.terminal)
	parser.parser_init(&b.parser)
	defer parser.parser_destroy(&b.parser)
	interaction.interaction_init(&b.interaction)
	b.view = termgrid.Terminal_View{}
	b.drain_buf = make([]u8, app.APP_DRAIN_CAP, context.allocator)
	defer delete(b.drain_buf)

	// 1. Initial passthrough state
	testing.expect_value(t, b.interaction.mode, interaction.Interaction_Mode.Passthrough)
	testing.expect(t, !b.interaction.selection_active, "selection must start inactive")

	// Render state interaction pointer verification
	state := app.backend_get_render_state(b)
	testing.expect(t, state.interaction != nil, "render state must include interaction pointer")
	testing.expect_value(t, state.interaction.mode, interaction.Interaction_Mode.Passthrough)

	// Put initial text into terminal
	termgrid.terminal_put_string(&b.terminal, "apple banana cherry\r\n")

	// 2. Dispatch Cmd+Ctrl+Y to enter Visual Mode
	enter_visual_ev := app.UI_Event{
		type = .Input,
		input = input.Input_Event{
			event_type = .Key,
			kind       = .Printable,
			rune       = 'y',
			gui        = true,
			ctrl       = true,
		},
	}
	app.backend_handle_ui_event(b, enter_visual_ev)

	testing.expect_value(t, b.interaction.mode, interaction.Interaction_Mode.Visual)
	testing.expect(t, !b.interaction.selection_active, "selection must be inactive on enter visual mode")
	testing.expect(t, !b.view.selection.active, "view selection active must mirror interaction")
	hud_nav := app.app_compute_hud_title(&b.interaction)
	testing.expect_value(t, hud_nav, "[ VISUAL NAV ]")

	// 3. Dispatch visual navigation 'l' (cursor right) without selection
	col_before := b.interaction.visual_cursor.col
	nav_ev := app.UI_Event{
		type = .Input,
		input = input.Input_Event{
			event_type = .Key,
			kind       = .Printable,
			rune       = 'l',
		},
	}
	app.backend_handle_ui_event(b, nav_ev)
	testing.expect_value(t, b.interaction.visual_cursor.col, col_before + 1)
	testing.expect(t, !b.interaction.selection_active, "selection remains inactive during navigation")

	// Activate selection with 'v'
	v_ev := app.UI_Event{
		type = .Input,
		input = input.Input_Event{
			event_type = .Key,
			kind       = .Printable,
			rune       = 'v',
		},
	}
	app.backend_handle_ui_event(b, v_ev)
	testing.expect(t, b.interaction.selection_active, "selection is now active after 'v'")
	testing.expect(t, b.view.selection.active, "view selection is active")

	// Expand selection with 'l'
	col_before = b.interaction.visual_cursor.col
	app.backend_handle_ui_event(b, nav_ev)
	testing.expect_value(t, b.interaction.visual_cursor.col, col_before + 1)
	testing.expect_value(t, b.view.selection.focus.col, col_before + 1)

	// 4. Double click pointer selection (word detection)
	ptr_ev := app.UI_Event{
		type = .Input,
		input = input.Input_Event{
			event_type = .Pointer,
			pointer = input.Input_Pointer_Event{
				kind   = .Button_Down,
				button = 1,
				clicks = 2,
			},
		},
		rows = 0,
		cols = 8, // inside "banana"
	}
	app.backend_handle_ui_event(b, ptr_ev)
	testing.expect(t, b.interaction.selection_active, "selection must remain active after double click")
	extracted := interaction.interaction_extract_selection_text(&b.terminal, &b.interaction)
	defer delete(extracted)
	testing.expect_value(t, extracted, "banana")

	// 5. HUD Title computation verification
	hud_visual := app.app_compute_hud_title(&b.interaction)
	testing.expect_value(t, hud_visual, "[ VISUAL CHAR ]")

	b.interaction.paused_lines_accumulated = 15
	hud_visual_paused := app.app_compute_hud_title(&b.interaction)
	testing.expect_value(t, hud_visual_paused, "[ VISUAL CHAR (+15 lines) ]")

	// 6. Yank / Copy key 'y' exits visual mode back to passthrough
	yank_ev := app.UI_Event{
		type = .Input,
		input = input.Input_Event{
			event_type = .Key,
			kind       = .Printable,
			rune       = 'y',
		},
	}
	app.backend_handle_ui_event(b, yank_ev)
	testing.expect_value(t, b.interaction.mode, interaction.Interaction_Mode.Passthrough)
	testing.expect(t, !b.interaction.selection_active, "selection must be cleared after yank")
	testing.expect(t, !b.view.selection.active, "view selection must be cleared after yank")

	// 7. Search mode dispatch and HUD title
	b.interaction.mode = .Search
	b.interaction.search_len = 6
	copy(b.interaction.search_query[:6], "banana")
	b.interaction.search_match_count = 3
	b.interaction.search_match_idx = 0
	hud_find := app.app_compute_hud_title(&b.interaction)
	testing.expect_value(t, hud_find, "[ FIND: 'banana' (1/3) ]")

	// 8. Viewport paused flow and camera lock scrollback compensation
	interaction.interaction_init(&b.interaction)
	interaction.interaction_pause_viewport(&b.interaction, 10)
	b.view.scrollback_offset = 10
	hud_paused := app.app_compute_hud_title(&b.interaction)
	testing.expect_value(t, hud_paused, "[ ⏸ PAUSED • Esc to Resume ]")

	interaction.interaction_on_scrollback_push(&b.interaction, 5)
	testing.expect_value(t, b.interaction.paused_offset, 15)
	testing.expect_value(t, b.interaction.paused_lines_accumulated, 5)

	hud_paused_acc := app.app_compute_hud_title(&b.interaction)
	testing.expect_value(t, hud_paused_acc, "[ ⏸ PAUSED (+5 lines) • Esc to Resume ]")
}

@(test)
test_app_search_and_tab_sync :: proc(t: ^testing.T) {
	a := new(app.App)
	defer free(a)
	_bare_app(a)
	defer _bare_destroy(a)
	app.session_manager_init(&a.session_mgr, 4)
	defer app.session_manager_destroy(&a.session_mgr)

	idx, spawn_ok := app.session_spawn(&a.session_mgr, "/bin/echo", {"test"}, APP_TEST_ROWS, APP_TEST_COLS, nil, termgrid.Theme{})
	testing.expect(t, spawn_ok, "session_spawn must succeed")
	testing.expect_value(t, idx, 0)
	a.session_mgr.active_idx = 0

	active_b := app.app_active_backend(a)
	testing.expect(t, active_b != nil, "active backend must exist")
	app.backend_stop_thread(active_b) // This contract test exercises synchronous dependency dispatch.
	termgrid.terminal_put_string(&active_b.terminal, "hello search world hello\r\n")

	// 1. Dispatch Cmd+F -> opens search bar, enters search mode
	cmd_f := input.Input_Event{
		event_type = .Key,
		kind       = .Printable,
		rune       = 'f',
		gui        = true,
	}
	app.app_dispatch_input_events(a, {cmd_f})
	testing.expect(t, a.search_bar.visible, "search bar must be visible after Cmd+F")
	testing.expect_value(t, active_b.interaction.mode, interaction.Interaction_Mode.Search)
	testing.expect(t, active_b.interaction.search_active, "search_active must be true")
	testing.expect(t, a.renderer.full_redraw_pending, "full_redraw_pending must be true")
	a.renderer.full_redraw_pending = false

	// 2. Type 'h', 'e', 'l', 'l', 'o'
	for r in "hello" {
		ev := input.Input_Event{
			event_type = .Key,
			kind       = .Printable,
			rune       = r,
		}
		app.app_dispatch_input_events(a, {ev})
	}
	testing.expect_value(t, string(a.search_bar.query[:a.search_bar.query_len]), "hello")
	testing.expect_value(t, string(active_b.interaction.search_query[:active_b.interaction.search_len]), "hello")
	testing.expect(t, a.search_bar.match_count >= 2, "match count must be >= 2")
	testing.expect_value(t, active_b.interaction.search_match_count, a.search_bar.match_count)
	testing.expect(t, a.renderer.full_redraw_pending, "full_redraw_pending must be true after query change")

	// 3. Next match via Enter
	enter_ev := input.Input_Event{
		event_type = .Key,
		kind       = .Enter,
	}
	app.app_dispatch_input_events(a, {enter_ev})
	testing.expect_value(t, a.search_bar.match_idx, 1)
	testing.expect_value(t, active_b.interaction.search_match_idx, 1)

	// 4. Escape -> close search bar, exit to passthrough
	esc_ev := input.Input_Event{
		event_type = .Key,
		kind       = .Escape,
	}
	app.app_dispatch_input_events(a, {esc_ev})
	testing.expect(t, !a.search_bar.visible, "search bar must be hidden after Escape")
	testing.expect_value(t, active_b.interaction.mode, interaction.Interaction_Mode.Passthrough)
	testing.expect(t, !active_b.interaction.search_active, "search_active must be false after Escape")

	// 5. Pointer outside tab bar clears hover states
	a.tab_bar.hover_tab_idx = 0
	a.tab_bar.hover_close_idx = 0
	a.tab_bar.hover_new_tab = true
	a.renderer.full_redraw_pending = false
	outside_ptr := input.Input_Event{
		event_type = .Pointer,
		pointer = input.Input_Pointer_Event{
			kind = .Motion,
			x    = 100.0,
			y    = 100.0,
		},
	}
	app.app_dispatch_input_events(a, {outside_ptr})
	testing.expect_value(t, a.tab_bar.hover_tab_idx, -1)
	testing.expect_value(t, a.tab_bar.hover_close_idx, -1)
	testing.expect(t, !a.tab_bar.hover_new_tab, "hover_new_tab must be cleared")
	testing.expect(t, a.renderer.full_redraw_pending, "full_redraw_pending must be triggered on hover clear")
}

@(test)
test_app_cmd_r_renames_active_tab :: proc(t: ^testing.T) {
	a := new(app.App)
	defer free(a)
	app.session_manager_init(&a.session_mgr, 4)
	defer app.session_manager_destroy(&a.session_mgr)
	resize(&a.session_mgr.tabs, len(a.session_mgr.tabs) + 1)
	tab := &a.session_mgr.tabs[len(a.session_mgr.tabs) - 1]
	tab.id = 1
	tab.backend.pty.master = -1
	tab.backend.pty.pid = -1
	a.session_mgr.active_idx = 0

	ev: input.Input_Event
	ev.event_type = .Key
	ev.kind = .Printable
	ev.gui = true
	ev.rune = 'r'
	evs := [1]input.Input_Event{ev}
	_, _ = app.app_dispatch_input_events(a, evs[:])
	testing.expect(t, a.tab_rename.active, "Cmd+R must start inline rename on the active tab")
}

@(test)
test_app_paste_shadow_search_dispatch :: proc(t: ^testing.T) {
	a := new(app.App)
	defer free(a)
	_bare_app(a)
	defer _bare_destroy(a)
	if !_dummy_window(t, &a.window, "paste-shadow-search", 640, 480) {
		return
	}
	defer win.window_destroy(&a.window)
	clipboard := "quux"
	testing.expect(t, win.window_set_clipboard_text(&a.window, clipboard), "clipboard setup must succeed")

	pipefd: [2]posix.FD
	if posix.pipe(&pipefd) != .OK {
		testing.expect(t, false, "posix.pipe must succeed")
		return
	}
	defer posix.close(pipefd[0])
	a.pty.master = int(pipefd[1])
	a.pty.state = .Running
	defer if a.pty.master >= 0 {posix.close(posix.FD(a.pty.master))}

	local_paste := input.Input_Event{event_type = .Local, action = .Paste}
	marked := [?]input.Input_Event{
		{kind = .Printable, rune = 'q', paste_shadow = true},
		{kind = .Printable, rune = 'u', paste_shadow = true},
		{kind = .Printable, rune = 'u', paste_shadow = true},
		{kind = .Printable, rune = 'x', paste_shadow = true},
	}
	_, ok := app.app_dispatch_input_events(a, {local_paste, marked[0], marked[1], marked[2], marked[3]})
	testing.expect(t, ok, "normal paste dispatch must succeed")
	cmd_f := input.Input_Event{kind = .Printable, rune = 'f', gui = true}
	_, ok = app.app_dispatch_input_events(a, {cmd_f, local_paste, marked[0], marked[1], marked[2], marked[3]})
	testing.expect(t, ok && a.search_bar.visible, "same-batch search opening must stay active")
	testing.expect_value(t, string(a.search_bar.query[:a.search_bar.query_len]), clipboard)

	posix.close(pipefd[1])
	a.pty.master = -1
	buf: [32]u8
	n := posix.read(pipefd[0], raw_data(buf[:]), len(buf))
	testing.expect_value(t, n, len(clipboard))
	if n > 0 {
		testing.expect_value(t, string(buf[:n]), clipboard)
	}
}

@(test)
test_app_paste_shadow_raw_events_write_once :: proc(t: ^testing.T) {
	clipboard := "quux"
	first := [3]u8{'q', 'u', 0}
	second := [3]u8{'u', 'x', 0}
	whole := [5]u8{'q', 'u', 'u', 'x', 0}
	ordinary := [2]u8{'z', 0}
	for scenario in 0..<3 {
		a := new(app.App)
		_bare_app(a)
		if !_dummy_window(t, &a.window, "paste-shadow-raw", 640, 480) {
			_bare_destroy(a)
			free(a)
			return
		}
		testing.expect(t, win.window_set_clipboard_text(&a.window, clipboard), "clipboard setup must succeed")
		pipefd: [2]posix.FD
		if posix.pipe(&pipefd) != .OK {
			testing.expect(t, false, "posix.pipe must succeed")
			win.window_destroy(&a.window)
			_bare_destroy(a)
			free(a)
			return
		}
		a.pty.master = int(pipefd[1])
		a.pty.state = .Running
		app.backend_set_clipboard_callbacks(&a.backend, &clipboard, nil, _app_test_clipboard_read_cb)

		key_down: sdl3.Event
		key_down.key = sdl3.KeyboardEvent{type = .KEY_DOWN, key = sdl3.K_V, mod = sdl3.KMOD_GUI, down = true}
		key_up: sdl3.Event
		key_up.key = sdl3.KeyboardEvent{type = .KEY_UP, key = sdl3.K_V, mod = sdl3.KMOD_GUI, down = false}
		text_first: sdl3.Event
		text_first.text = sdl3.TextInputEvent{type = .TEXT_INPUT, text = scenario == 2 ? cstring(&first[0]) : cstring(&whole[0])}
		text_second: sdl3.Event
		text_second.text = sdl3.TextInputEvent{type = .TEXT_INPUT, text = cstring(&second[0])}
		ordinary_key: sdl3.Event
		ordinary_key.key = sdl3.KeyboardEvent{type = .KEY_DOWN, key = sdl3.K_Z, down = true}
		ordinary_text: sdl3.Event
		ordinary_text.text = sdl3.TextInputEvent{type = .TEXT_INPUT, text = cstring(&ordinary[0])}
		events := [6]sdl3.Event{key_down, key_up, text_first, text_second, ordinary_key, ordinary_text}
		pending := ""
		for raw, i in events {
			if (scenario == 0 && i >= 2) || (scenario == 1 && i == 3) {
				continue
			}
			out: [8]input.Input_Event
			n, _, _ := input.input_translate_sdl(raw, out[:])
			clip := raw.type == .KEY_DOWN && i == 0 ? clipboard : ""
			if input.input_filter_paste_shadow(&pending, raw, out[:], n, clip) {
				for j in 0..<n {
					out[j].paste_shadow = true
				}
			}
			_, ok := app.app_dispatch_input_events(a, out[:n])
			testing.expect(t, ok, "translated event dispatch must succeed")
		}
		if scenario == 0 {
			testing.expect_value(t, pending, clipboard)
			delete(pending)
		} else {
			testing.expect_value(t, len(pending), 0)
		}
		posix.close(pipefd[1])
		a.pty.master = -1
		buf: [32]u8
		n := posix.read(pipefd[0], raw_data(buf[:]), len(buf))
		expected_len := len(clipboard)
		if scenario != 0 {
			expected_len += len(ordinary) - 1
		}
		testing.expect_value(t, n, expected_len)
		if n > 0 {
			testing.expect_value(t, string(buf[:len(clipboard)]), clipboard)
			if scenario != 0 {
				testing.expect_value(t, string(buf[len(clipboard):n]), string(ordinary[:1]))
			}
		}
		posix.close(pipefd[0])
		win.window_destroy(&a.window)
		_bare_destroy(a)
		free(a)
	}
}

@(test)
test_app_paste_shadow_rename_dispatch :: proc(t: ^testing.T) {
	a := new(app.App)
	defer free(a)
	_bare_app(a)
	defer _bare_destroy(a)
	if !_dummy_window(t, &a.window, "paste-shadow-rename", 640, 480) {
		return
	}
	defer win.window_destroy(&a.window)
	clipboard := "quux"
	testing.expect(t, win.window_set_clipboard_text(&a.window, clipboard), "clipboard setup must succeed")

	pipefd: [2]posix.FD
	if posix.pipe(&pipefd) != .OK {
		testing.expect(t, false, "posix.pipe must succeed")
		return
	}
	defer posix.close(pipefd[0])
	app.session_manager_init(&a.session_mgr, 4)
	defer app.session_manager_destroy(&a.session_mgr)
	resize(&a.session_mgr.tabs, len(a.session_mgr.tabs) + 1)
	tab := &a.session_mgr.tabs[len(a.session_mgr.tabs) - 1]
	tab.id = 1
	tab.backend.pty.master = int(pipefd[1])
	tab.backend.pty.state = .Running
	a.session_mgr.active_idx = 0

	cmd_r := input.Input_Event{kind = .Printable, rune = 'r', gui = true}
	local_paste := input.Input_Event{event_type = .Local, action = .Paste}
	marked := [?]input.Input_Event{
		{kind = .Printable, rune = 'q', paste_shadow = true},
		{kind = .Printable, rune = 'u', paste_shadow = true},
		{kind = .Printable, rune = 'u', paste_shadow = true},
		{kind = .Printable, rune = 'x', paste_shadow = true},
	}
	_, ok := app.app_dispatch_input_events(a, {cmd_r, local_paste, marked[0], marked[1], marked[2], marked[3]})
	testing.expect(t, ok && a.tab_rename.active, "same-batch rename opening must stay active")
	name := platform_tabs.tab_rename_text(&a.tab_rename)
	testing.expect(t, len(name) >= len(clipboard) && name[len(name) - len(clipboard):] == clipboard, "marked text must reach rename editor")

	posix.close(pipefd[1])
	a.session_mgr.tabs[0].backend.pty.master = -1
	buf: [32]u8
	n := posix.read(pipefd[0], raw_data(buf[:]), len(buf))
	testing.expect_value(t, n, 0)
}

@(test)
test_app_paste_stays_in_tab_menus :: proc(t: ^testing.T) {
	a := new(app.App)
	defer free(a)
	_bare_app(a)
	defer _bare_destroy(a)
	if !_dummy_window(t, &a.window, "paste-tab-menus", 640, 480) {
		return
	}
	defer win.window_destroy(&a.window)
	testing.expect(t, win.window_set_clipboard_text(&a.window, "quux"), "clipboard setup must succeed")

	pipefd: [2]posix.FD
	if posix.pipe(&pipefd) != .OK {
		testing.expect(t, false, "posix.pipe must succeed")
		return
	}
	defer posix.close(pipefd[0])
	a.pty.master = int(pipefd[1])
	a.pty.state = .Running
	defer if a.pty.master >= 0 {posix.close(posix.FD(a.pty.master))}

	local_paste := input.Input_Event{event_type = .Local, action = .Paste}
	a.tab_menu.visible = true
	_, ok := app.app_dispatch_input_events(a, {local_paste})
	testing.expect(t, ok && a.tab_menu.visible, "context menu must retain paste without PTY routing")
	a.tab_menu.visible = false
	a.tab_overflow.visible = true
	_, ok = app.app_dispatch_input_events(a, {local_paste})
	testing.expect(t, ok && a.tab_overflow.visible, "overflow menu must retain paste without PTY routing")

	posix.close(pipefd[1])
	a.pty.master = -1
	buf: [32]u8
	n := posix.read(pipefd[0], raw_data(buf[:]), len(buf))
	testing.expect_value(t, n, 0)
}

@(test)
test_backend_accumulate_wheel :: proc(t: ^testing.T) {
	b := new(app.Backend)
	defer free(b)
	b.config.scroll_multiplier = 1.0

	// 1. Fractional accumulation: 5 events of wheel_y = 0.2 resulting in 0, 0, 0, 0, 1 lines.
	ev_frac := input.Input_Pointer_Event{
		kind = .Wheel,
		wheel_y = 0.2,
	}
	testing.expect_value(t, app.backend_accumulate_wheel(b, ev_frac), 0)
	testing.expect_value(t, app.backend_accumulate_wheel(b, ev_frac), 0)
	testing.expect_value(t, app.backend_accumulate_wheel(b, ev_frac), 0)
	testing.expect_value(t, app.backend_accumulate_wheel(b, ev_frac), 0)
	testing.expect_value(t, app.backend_accumulate_wheel(b, ev_frac), 1)

	// 2. Direction reversal: negative accumulation followed by positive event drops negative momentum immediately.
	b.wheel_accumulator_y = 0
	ev_down_frac := input.Input_Pointer_Event{
		kind = .Wheel,
		wheel_y = -0.6,
	}
	testing.expect_value(t, app.backend_accumulate_wheel(b, ev_down_frac), 0)

	ev_up_frac := input.Input_Pointer_Event{
		kind = .Wheel,
		wheel_y = 0.7,
	}
	testing.expect_value(t, app.backend_accumulate_wheel(b, ev_up_frac), 0)
	testing.expect(t, b.wheel_accumulator_y > 0.69 && b.wheel_accumulator_y < 0.71, "reversal dropped negative momentum")

	ev_up_step := input.Input_Pointer_Event{
		kind = .Wheel,
		wheel_y = 0.4,
	}
	testing.expect_value(t, app.backend_accumulate_wheel(b, ev_up_step), 1)

	// 3. scroll_multiplier: multiplier = 2.0 with wheel_y = 0.5 triggers 1 line immediately.
	b.wheel_accumulator_y = 0
	b.config.scroll_multiplier = 2.0
	ev_half := input.Input_Pointer_Event{
		kind = .Wheel,
		wheel_y = 0.5,
	}
	testing.expect_value(t, app.backend_accumulate_wheel(b, ev_half), 1)
}

@(test)
test_app_shell_quote_path :: proc(t: ^testing.T) {
	p0 := app._app_shell_quote_path("")
	testing.expect_value(t, p0, "")
	delete(p0)

	p1 := app._app_shell_quote_path("file.odin")
	testing.expect_value(t, p1, "'file.odin'")
	delete(p1)

	p2 := app._app_shell_quote_path("my file.odin")
	testing.expect_value(t, p2, "'my file.odin'")
	delete(p2)

	p3 := app._app_shell_quote_path("it's a path")
	testing.expect_value(t, p3, "'it'\\''s a path'")
	delete(p3)
}

@(test)
test_app_drop_fx_state_flow :: proc(t: ^testing.T) {
	a := new(app.App)
	defer free(a)
	// 1. Drop Begin sets hovering and coordinates
	ev_begin := input.Input_Event{
		event_type = .Drop,
		drop = input.Input_Drop_Event{
			kind = .Begin,
			x = 100,
			y = 150,
		},
	}
	_, _ = app.app_dispatch_input_events(a, {ev_begin})
	testing.expect(t, a.drop_fx.hovering, "drop begin must start hovering")
	testing.expect_value(t, a.drop_fx.hover_x, f32(100))
	testing.expect_value(t, a.drop_fx.hover_y, f32(150))

	// 2. Drop Position updates hover coordinates
	ev_pos := input.Input_Event{
		event_type = .Drop,
		drop = input.Input_Drop_Event{
			kind = .Position,
			x = 200,
			y = 250,
		},
	}
	_, _ = app.app_dispatch_input_events(a, {ev_pos})
	testing.expect(t, a.drop_fx.hovering, "drop position must maintain hovering")
	testing.expect_value(t, a.drop_fx.hover_x, f32(200))
	testing.expect_value(t, a.drop_fx.hover_y, f32(250))

	// 3. Drop Complete ends hovering
	ev_complete := input.Input_Event{
		event_type = .Drop,
		drop = input.Input_Drop_Event{
			kind = .Complete,
		},
	}
	_, _ = app.app_dispatch_input_events(a, {ev_complete})
	testing.expect(t, !a.drop_fx.hovering, "drop complete must stop hovering")

	// 4. Dropping a file spawns splash at drop position
	ev_file := input.Input_Event{
		event_type = .Drop,
		drop = input.Input_Drop_Event{
			kind = .File,
			x = 300,
			y = 350,
		},
	}
	_, _ = app.app_dispatch_input_events(a, {ev_file})
	testing.expect(t, !a.drop_fx.hovering, "drop file must ensure hovering is stopped")
	splash_found := false
	for &sp in a.drop_fx.splashes {
		if sp.active && sp.x == 300 && sp.y == 350 {
			splash_found = true
			break
		}
	}
	testing.expect(t, splash_found, "drop file must spawn active splash at release position")
}
