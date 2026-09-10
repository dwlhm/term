package main

// app_term main loop (TODO Langkah 15).
//
// Fixed per-frame order in app_frame:
//   (1) input: Running -> input pump (keys -> pty, resize -> winsize +
//       terminal_resize + resize_grid + pixel resize); Exited ->
//       window_poll_input routed per key via app_handle_exited_key
//       (R relaunch, Q/Esc quit, rest ignored), drain skipped
//   (1b) window_get_size vs last_px -> app_on_resize (both states)
//   (2) pty_drain (cap 64KB, Running only) -> parse_chunk
//   (3) cursor sync from terminal cursor + blink tick(now, focused,
//       term_visible)
//   (4) renderer_frame_auto; if the frame skipped AND the cursor changed,
//       overlay-only present (cursor quad via the reserved slot)
//   (5) exit poll; Running->Exited transition shows the exit banner once
//
// Shell decision: $SHELL when set and non-empty, /bin/sh fallback.
// The choice is documented at _resolve_shell.

import "core:fmt"
import "core:mem"
import "core:os"

import "vendor:sdl3"
import "vendor:wgpu"
import wgpu_sdl3_glue "vendor:wgpu/sdl3glue"

import termgrid "../terminal"
import parser "../parser"
import render "../render"
import gpu "../render/gpu"
import instance "../render/instance"
import wgpu_backend "../render/gpu/wgpu"
import platform "../platform"
import win "../platform/window"
import input "../platform/input"
import pty "../platform/pty"

// APP_DEFAULT_ROWS/COLS is the initial grid size (80x24).
APP_DEFAULT_ROWS :: 24
APP_DEFAULT_COLS :: 80

// APP_DRAIN_CAP caps one frame's pty_drain at 64KB. Unread bytes stay in
// the kernel buffer for the next frame.
APP_DRAIN_CAP :: 65536

// APP_CELL_W/H is the cell size in pixels. Must match the renderer's cell
// metrics and the input pump's fallback grid math, or the grid and the
// window drift apart.
APP_CELL_W :: 16
APP_CELL_H :: 16

// APP_FONT_SIZE is the requested font size in pixels.
APP_FONT_SIZE :: f32(16)

// APP_TITLE is the window title.
APP_TITLE :: "Term"

// APP_SHELL_FALLBACK is the shell when $SHELL is unset or empty.
APP_SHELL_FALLBACK :: "/bin/sh"

// APP_SHELL_ENV is the environment variable naming the login shell.
APP_SHELL_ENV :: "SHELL"

// APP_BANNER_EXIT_FMT is the one-shot exit banner; %d is the exit code.
APP_BANNER_EXIT_FMT :: "[ process exited (%d) - press R to relaunch, Q to quit ]"

// APP_BANNER_FAIL is the banner kept on screen when a relaunch fails.
APP_BANNER_FAIL :: "[ relaunch failed - press R to retry, Q to quit ]"

// Font paths to try (in order).
FONT_PATHS :: []string{
	"/System/Library/Fonts/Menlo.ttc",
	"/System/Library/Fonts/Supplemental/Courier New.ttf",
}

// App owns every subsystem handle of the running terminal.
App :: struct {
	window:      win.Window,
	terminal:    termgrid.Terminal,
	parser:      parser.Parser,
	renderer:    render.Renderer,
	lut:         render.Style_LUT,
	pty:         pty.Pty,
	cursor:      render.Cursor_Overlay,
	focused:     bool,
	should_quit: bool,
	// prog/argv are the child spec for (re)launch, stored as-is with
	// caller-owned static lifetime (never freed or cloned by App).
	prog:         string,
	argv:         []string,
	// banner_shown gates the exit-banner rewrite: true once the banner
	// for the current Exited episode is on the grid.
	banner_shown: bool,
	// last_px_w/h is the last window size consumed by app_on_resize.
	last_px_w:   i32,
	last_px_h:   i32,
	// GPU plumbing (plan-silent detail: the handles must live for the app
	// lifetime so app_destroy can unwind in exact reverse order).
	backend:     ^gpu.Gpu_Backend_VTable,
	device:      gpu.Gpu_Device,
	queue:       gpu.Gpu_Queue,
	surface:     gpu.Gpu_Surface,
	instance:    rawptr,
}

// find_font tries to find a usable font file.
find_font :: proc() -> (path: string, ok: bool) {
	for font_path in FONT_PATHS {
		if data, err := os.read_entire_file(font_path, context.allocator); err == nil {
			delete(data)
			return font_path, true
		}
	}
	return "", false
}

// _resolve_shell returns $SHELL when set and non-empty, else the fallback.
// The returned string is allocated only when $SHELL is used; the caller
// frees it exactly in that case (see main).
_resolve_shell :: proc() -> (shell: string, allocated: bool) {
	if val, found := os.lookup_env_alloc(APP_SHELL_ENV, context.allocator); found {
		if len(val) > 0 {
			return val, true
		}
		delete(val)
	}
	return APP_SHELL_FALLBACK, false
}

// app_init builds every subsystem in order: window -> backend/device ->
// renderer -> terminal -> parser -> pty_spawn(prog) -> lut rebuild.
// Failure unwinds in reverse (no leaks, no half-init) and returns false.
// The pty fds are pre-parked (-1) so every failure prefix is drain-safe.
app_init :: proc(a: ^App, rows, cols: int, prog: string, argv: []string) -> bool {
	if a == nil {
		return false
	}
	a.pty.master = -1
	a.pty.pid = -1
	if len(prog) == 0 {
		return false
	}
	a.focused = true
	a.should_quit = false
	a.prog = prog
	a.argv = argv
	a.banner_shown = false
	a.last_px_w = 0
	a.last_px_h = 0

	// (1) Window.
	window_w := i32(cols) * i32(APP_CELL_W)
	window_h := i32(rows) * i32(APP_CELL_H)
	if window_w < 1 {
		window_w = 1
	}
	if window_h < 1 {
		window_h = 1
	}
	if !win.window_init(&a.window, APP_TITLE, window_w, window_h) {
		fmt.eprintf("app_init: window_init failed\n")
		return false
	}

	// (2) Backend instance.
	a.backend = wgpu_backend.wgpu_backend_vtable()
	a.instance = a.backend.create_instance()
	if a.instance == nil {
		win.window_destroy(&a.window)
		fmt.eprintf("app_init: create_instance failed\n")
		return false
	}

	// (3) Surface.
	a.surface = gpu.Gpu_Surface(wgpu_sdl3_glue.GetSurface(wgpu.Instance(a.instance), a.window.handle))
	if rawptr(a.surface) == nil {
		a.backend.destroy_instance(a.instance)
		a.instance = nil
		win.window_destroy(&a.window)
		fmt.eprintf("app_init: GetSurface failed\n")
		return false
	}

	// (4) Device + queue.
	a.device, a.queue = a.backend.request_device(a.instance, rawptr(a.surface))
	if rawptr(a.device) == nil || rawptr(a.queue) == nil {
		a.device = gpu.Gpu_Device(nil)
		a.queue = gpu.Gpu_Queue(nil)
		wgpu.SurfaceRelease(wgpu.Surface(rawptr(a.surface)))
		a.surface = gpu.Gpu_Surface(nil)
		a.backend.destroy_instance(a.instance)
		a.instance = nil
		win.window_destroy(&a.window)
		fmt.eprintf("app_init: request_device failed\n")
		return false
	}

	// (5) Renderer.
	font_path, font_ok := find_font()
	if !font_ok {
		a.backend.destroy_device(a.device)
		a.device = gpu.Gpu_Device(nil)
		a.queue = gpu.Gpu_Queue(nil)
		wgpu.SurfaceRelease(wgpu.Surface(rawptr(a.surface)))
		a.surface = gpu.Gpu_Surface(nil)
		a.backend.destroy_instance(a.instance)
		a.instance = nil
		win.window_destroy(&a.window)
		fmt.eprintf("app_init: no usable font found\n")
		return false
	}
	format := a.backend.get_preferred_format(rawptr(a.surface), a.device)
	if !render.renderer_init(
		&a.renderer,
		font_path,
		APP_FONT_SIZE,
		a.backend,
		a.device,
		a.queue,
		i32(rows),
		i32(cols),
		f32(APP_CELL_W),
		f32(APP_CELL_H),
		f32(window_w),
		f32(window_h),
		format,
	) {
		a.backend.destroy_device(a.device)
		a.device = gpu.Gpu_Device(nil)
		a.queue = gpu.Gpu_Queue(nil)
		wgpu.SurfaceRelease(wgpu.Surface(rawptr(a.surface)))
		a.surface = gpu.Gpu_Surface(nil)
		a.backend.destroy_instance(a.instance)
		a.instance = nil
		win.window_destroy(&a.window)
		fmt.eprintf("app_init: renderer_init failed\n")
		return false
	}

	// (6) Terminal + parser (infallible: make() panics on OOM).
	termgrid.terminal_init(&a.terminal, rows, cols)
	parser.parser_init(&a.parser)

	// (7) PTY child.
	if !pty.pty_spawn(&a.pty, rows, cols, prog, argv) {
		termgrid.terminal_destroy(&a.terminal)
		render.renderer_destroy(&a.renderer)
		a.backend.destroy_device(a.device)
		a.device = gpu.Gpu_Device(nil)
		a.queue = gpu.Gpu_Queue(nil)
		wgpu.SurfaceRelease(wgpu.Surface(rawptr(a.surface)))
		a.surface = gpu.Gpu_Surface(nil)
		a.backend.destroy_instance(a.instance)
		a.instance = nil
		win.window_destroy(&a.window)
		fmt.eprintf("app_init: pty_spawn failed for '%s'\n", prog)
		return false
	}

	// (8) Surface attach + LUT rebuild.
	win.window_update_pixel_size(&a.window)
	render.renderer_attach_surface(&a.renderer, a.surface, u32(a.window.pixel_w), u32(a.window.pixel_h))
	render.style_lut_rebuild(&a.lut, &a.terminal.grid.style_table)

	// Initial focus mirrors the live window state.
	_app_sync_focus(a)
	a.last_px_w, a.last_px_h = win.window_get_size(&a.window)
	return true
}

// app_destroy tears down in exact reverse order: pty_close,
// renderer/terminal/window, then GPU handles. Only valid after a
// successful app_init (partial prefixes unwind inside app_init).
app_destroy :: proc(a: ^App) {
	if a == nil {
		return
	}
	pty.pty_close(&a.pty)
	render.renderer_destroy(&a.renderer)
	termgrid.terminal_destroy(&a.terminal)
	parser.parser_destroy(&a.parser)
	if rawptr(a.surface) != nil {
		wgpu.SurfaceRelease(wgpu.Surface(rawptr(a.surface)))
		a.surface = gpu.Gpu_Surface(nil)
	}
	if rawptr(a.device) != nil && a.backend != nil {
		a.backend.destroy_device(a.device)
		a.device = gpu.Gpu_Device(nil)
		a.queue = gpu.Gpu_Queue(nil)
	}
	if a.instance != nil && a.backend != nil {
		a.backend.destroy_instance(a.instance)
		a.instance = nil
	}
	win.window_destroy(&a.window)
}

// _app_sync_focus mirrors the live SDL input-focus state into a.focused
// (parks the blink via tick). Flag polling (not event translation) keeps
// the SDL pump ownership single: input_pump stays the only event drain.
_app_sync_focus :: proc(a: ^App) {
	if a == nil || a.window.handle == nil {
		return
	}
	flags := sdl3.GetWindowFlags(a.window.handle)
	a.focused = .INPUT_FOCUS in flags
}

// _app_apply_resize runs the renderer side of a resize the input pump
// already started (pump did winsize + terminal_resize): resize_grid then
// pixel resize. Grid dims come from the live terminal; pixel size from
// the window. Degenerate pixel sizes skip the pixel step only.
_app_apply_resize :: proc(a: ^App) {
	rows := a.terminal.grid.row_count
	cols := a.terminal.grid.col_count
	if rows > 0 && cols > 0 {
		render.renderer_resize_grid(&a.renderer, &a.terminal, i32(rows), i32(cols))
	}
	if a.window.pixel_w > 0 && a.window.pixel_h > 0 {
		render.renderer_resize(&a.renderer, u32(a.window.pixel_w), u32(a.window.pixel_h))
	}
}

// _app_mark_cursor_dirty marks the cursor cell with its live generation
// for the blink-off erase path. Returns false when the position is not
// addressable (stale after shrink, uninitialized grid).
_app_mark_cursor_dirty :: proc(a: ^App, row, col: int) -> bool {
	g := &a.terminal.grid
	if g.row_count <= 0 || g.col_count <= 0 || len(g.rows) == 0 {
		return false
	}
	if row < 0 || row >= g.row_count || col < 0 || col >= g.col_count {
		return false
	}
	phys := (g.origin + row) & g.mask
	if phys < 0 || phys >= len(g.rows) {
		return false
	}
	termgrid.damage_mark_cell(&a.terminal.damage, row, col, g.rows[phys].generation)
	return true
}

// _app_present_overlay presents one overlay-only frame: the staged cursor
// quad (reserved slot max_instances-1) is uploaded through the ring and
// drawn with count 1 over the retained surface contents (Load, never
// Clear). Nil-backend safe: returns false without touching the GPU.
_app_present_overlay :: proc(a: ^App) -> bool {
	r := &a.renderer
	if r.backend == nil || rawptr(r.device) == nil || rawptr(r.queue) == nil {
		return false
	}
	if rawptr(r.surface) == nil {
		return false
	}
	if rawptr(r.instances.bg_pipeline) == nil {
		return false
	}
	if r.instances.max_instances == 0 || len(r.instances.instance_data) == 0 {
		return false
	}
	slot := r.instances.max_instances - 1
	if u64(slot) >= u64(len(r.instances.instance_data)) {
		return false
	}
	staging := render.upload_ring_get_staging(&r.upload_ring)
	if u64(len(staging)) < instance.INSTANCE_STRIDE {
		return false
	}
	mem.copy(raw_data(staging), &r.instances.instance_data[slot], int(instance.INSTANCE_STRIDE))
	ring_slot := render.upload_ring_current_slot(&r.upload_ring)
	render.upload_ring_submit(&r.upload_ring, instance.INSTANCE_STRIDE)
	buffer := render.upload_ring_get_buffer(&r.upload_ring, ring_slot)
	if rawptr(buffer) == nil {
		return false
	}
	texture, view, _ := r.backend.get_surface_texture(rawptr(r.surface))
	if rawptr(view) == nil {
		if rawptr(texture) != nil {
			r.backend.release_surface_texture(texture, view)
		}
		if r.surface_w != 0 && r.surface_h != 0 {
			r.backend.configure_surface(rawptr(r.surface), r.device, r.format, r.surface_w, r.surface_h)
		}
		return false
	}
	encoder := r.backend.create_command_encoder(r.device)
	pass := r.backend.begin_render_pass(encoder, view, {0, 0, 0, 1}, .Load)
	r.backend.render_set_pipeline(pass, r.instances.bg_pipeline)
	r.backend.render_set_bind_group(pass, 0, r.instances.bind_group_bg)
	r.backend.render_set_vertex_buffer(pass, 0, buffer, 0)
	r.backend.render_draw(pass, instance.QUAD_VERTEX_COUNT, 1)
	r.backend.end_render_pass(pass)
	cmd := r.backend.finish_command_buffer(encoder)
	r.backend.submit(r.queue, cmd)
	r.backend.present_surface(rawptr(r.surface))
	r.backend.release_surface_texture(texture, view)
	return true
}

// App_Exit_Action is the per-key decision while the child is Exited.
App_Exit_Action :: enum {
	None,
	Relaunch,
	Quit,
}

// app_handle_exited_key routes one input event while the child is Exited.
// Printable 'r'/'R' relaunches, Printable 'q'/'Q' and Escape quit;
// every other kind (incl Ctrl/Alt/arrows) is ignored. No App param:
// the caller applies the returned action.
app_handle_exited_key :: proc(ev: input.Input_Event) -> App_Exit_Action {
	#partial switch ev.kind {
	case .Printable:
		if ev.rune == 'r' || ev.rune == 'R' {
			return .Relaunch
		}
		if ev.rune == 'q' || ev.rune == 'Q' {
			return .Quit
		}
		return .None
	case .Escape:
		return .Quit
	case:
		return .None
	}
}

// _app_write_banner_text draws s on the bottom row (truncated to the grid
// width) and latches banner_shown. Shared writer behind app_show_banner
// and app_show_banner_fail.
_app_write_banner_text :: proc(a: ^App, s: string) {
	if a == nil {
		return
	}
	rows := a.terminal.grid.row_count
	cols := a.terminal.grid.col_count
	if rows <= 0 || cols <= 0 {
		a.banner_shown = true
		return
	}
	text := s
	if len(text) > cols {
		text = text[:cols]
	}
	termgrid.terminal_move_cursor(&a.terminal, rows - 1, 0)
	termgrid.terminal_put_string(&a.terminal, text)
	a.banner_shown = true
}

// app_show_banner draws the one-shot exit banner with the live exit code
// on the bottom row. Called ONLY on the Running->Exited transition (the
// caller checks the previous state); later Exited frames must not rewrite.
app_show_banner :: proc(a: ^App) {
	if a == nil {
		return
	}
	buf: [160]u8
	s := fmt.bprintf(buf[:], APP_BANNER_EXIT_FMT, a.pty.exit_code)
	_app_write_banner_text(a, s)
}

// app_show_banner_fail draws the relaunch-failed banner, keeping the
// Exited state so a retry stays possible.
app_show_banner_fail :: proc(a: ^App) {
	_app_write_banner_text(a, APP_BANNER_FAIL)
}

// app_relaunch closes the dead pty and spawns a fresh child from the
// stored prog/argv at the live grid size. On success the grid is cleared,
// the cursor homed, the parser reset, and banner_shown cleared (the LUT
// is untouched: it auto-rebuilds on count mismatch in frame). On spawn
// failure the Exited state is kept with the FAIL banner and false is
// returned so the caller can offer a retry.
app_relaunch :: proc(a: ^App) -> bool {
	if a == nil {
		return false
	}
	pty.pty_close(&a.pty)
	rows := a.terminal.grid.row_count
	cols := a.terminal.grid.col_count
	if !pty.pty_spawn(&a.pty, rows, cols, a.prog, a.argv) {
		app_show_banner_fail(a)
		return false
	}
	termgrid.terminal_erase_display(&a.terminal, .Entire)
	termgrid.terminal_move_cursor(&a.terminal, 0, 0)
	parser.parser_init(&a.parser)
	a.banner_shown = false
	return true
}

// app_on_resize applies one window size in pixels: pixel dims -> grid
// dims -> terminal_resize + renderer_resize_grid + renderer pixel resize
// + pty_set_winsize. Degenerate (<= 0) sizes and same-dims+same-px calls
// are no-ops returning false with zero syscalls; otherwise the new px
// size is stored and true is returned.
app_on_resize :: proc(a: ^App, pixel_w: i32, pixel_h: i32) -> (resized: bool) {
	if a == nil {
		return false
	}
	if pixel_w <= 0 || pixel_h <= 0 {
		return false
	}
	cols := int(pixel_w) / APP_CELL_W
	rows := int(pixel_h) / APP_CELL_H
	if cols < 1 {
		cols = 1
	}
	if rows < 1 {
		rows = 1
	}
	if rows == a.terminal.grid.row_count && cols == a.terminal.grid.col_count &&
	   pixel_w == a.last_px_w && pixel_h == a.last_px_h {
		return false
	}
	termgrid.terminal_resize(&a.terminal, rows, cols)
	render.renderer_resize_grid(&a.renderer, &a.terminal, i32(rows), i32(cols))
	render.renderer_resize(&a.renderer, u32(pixel_w), u32(pixel_h))
	pty.pty_set_winsize(&a.pty, rows, cols)
	a.last_px_w = pixel_w
	a.last_px_h = pixel_h
	return true
}

// app_frame runs one frame in fixed order; false means quit requested
// (destroy-safe state, main then destroys). Nil-app returns false; a
// windowless app skips the SDL pump (headless-safe, no SDL calls).
app_frame :: proc(a: ^App) -> bool {
	if a == nil {
		return false
	}

	// (1) Input. Running keeps the existing input_pump path (keys ->
	// pty; resize -> winsize + terminal_resize, finished here with
	// resize_grid + pixel resize). Exited skips input_pump and the drain:
	// window_poll_input events route per key (R relaunch, Q/Esc quit)
	// while the close button still quits via is_open.
	if a.window.handle != nil {
		if a.pty.state == .Exited {
			evs: [input.INPUT_PUMP_MAX_EVENTS]input.Input_Event
			n := input.window_poll_input(&a.window, evs[:], input.INPUT_PUMP_MAX_EVENTS)
			for i in 0..<n {
				switch app_handle_exited_key(evs[i]) {
				case .Relaunch:
					_ = app_relaunch(a)
				case .Quit:
					a.should_quit = true
				case .None:
				}
			}
			if !a.window.is_open {
				a.should_quit = true
				return false
			}
			_app_sync_focus(a)
		} else {
			quit, resized, _ := input.input_pump(&a.window, &a.pty, &a.terminal)
			if quit {
				a.should_quit = true
				return false
			}
			if resized {
				_app_apply_resize(a)
			}
			_app_sync_focus(a)
		}
		// (1b) Live window size vs last_px -> app_on_resize (both
		// states; same-dims+same-px is a no-op inside).
		if gw, gh := win.window_get_size(&a.window); gw != a.last_px_w || gh != a.last_px_h {
			_ = app_on_resize(a, gw, gh)
		}
	}

	// (2) PTY drain (cap 64KB) -> parse_chunk. Skipped while Exited.
	if a.pty.state == .Running && a.pty.master >= 0 {
		drain_buf: [APP_DRAIN_CAP]u8
		if n, _ := pty.pty_drain(&a.pty, drain_buf[:], APP_DRAIN_CAP); n > 0 {
			parser.parse_chunk(&a.parser, &a.terminal, drain_buf[:n])
		}
	}

	// (3) Cursor sync from the terminal cursor + blink tick.
	cur := termgrid.terminal_get_cursor(&a.terminal)
	render.cursor_overlay_sync(&a.cursor, cur.row, cur.col)
	now := platform.platform_ticks_to_ns(platform.platform_now())
	cursor_changed := render.cursor_overlay_tick(&a.cursor, now, a.focused, cur.visible)

	// (4) Render. On a damage present with a lit cursor the quad rides in
	// a second (overlay) present in the same frame; on a skipped frame
	// with a toggled-ON cursor the overlay-only present fires with the
	// journal untouched. A toggled-OFF cursor cannot erase overlay-only
	// (Load preserves ghost pixels), so it erases via one damaged cell +
	// a full frame.
	if render.renderer_frame_auto(&a.renderer, &a.terminal, &a.lut) {
		if render.cursor_overlay_draw(&a.renderer, &a.cursor) {
			_app_present_overlay(a)
		}
	} else if cursor_changed {
		if render.cursor_overlay_draw(&a.renderer, &a.cursor) {
			_app_present_overlay(a)
		} else if _app_mark_cursor_dirty(a, cur.row, cur.col) {
			if render.renderer_frame_auto(&a.renderer, &a.terminal, &a.lut) {
				if render.cursor_overlay_draw(&a.renderer, &a.cursor) {
					_app_present_overlay(a)
				}
			}
		}
	}

	// (5) Exit poll: record the Exited state, keep looping. The banner
	// draws exactly once, on the Running->Exited transition.
	was_running := a.pty.state == .Running
	pty.pty_poll_exit(&a.pty)
	if was_running && a.pty.state == .Exited {
		app_show_banner(a)
	}

	return !a.should_quit
}

main :: proc() {
	shell, shell_allocated := _resolve_shell()
	defer if shell_allocated { delete(shell) }
	fmt.printf("Term: starting %s (%dx%d)\n", shell, APP_DEFAULT_COLS, APP_DEFAULT_ROWS)

	app: App
	if !app_init(&app, APP_DEFAULT_ROWS, APP_DEFAULT_COLS, shell, nil) {
		fmt.println("ERROR: app_init failed")
		return
	}
	defer app_destroy(&app)

	for app_frame(&app) {
	}
	fmt.println("Term: quit")
}
