package main

// app_term main loop (TODO Langkah 14).
//
// Fixed per-frame order in app_frame:
//   (1) input pump  (keys -> pty, resize -> winsize + terminal_resize +
//       resize_grid + pixel resize)
//   (2) pty_drain (cap 64KB) -> parse_chunk
//   (3) cursor sync from terminal cursor + blink tick(now, focused,
//       term_visible)
//   (4) renderer_frame_auto; if the frame skipped AND the cursor changed,
//       overlay-only present (cursor quad via the reserved slot)
//   (5) exit poll -> Exited state (banner is step 15: here only the state
//       is recorded and input feeding stops via pty_write's Exited guard)
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
	if val, found := os.lookup_env(APP_SHELL_ENV, context.allocator); found {
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
		return false
	}

	// (2) Backend instance.
	a.backend = wgpu_backend.wgpu_backend_vtable()
	a.instance = a.backend.create_instance()
	if a.instance == nil {
		win.window_destroy(&a.window)
		return false
	}

	// (3) Surface.
	a.surface = gpu.Gpu_Surface(wgpu_sdl3_glue.GetSurface(wgpu.Instance(a.instance), a.window.handle))
	if rawptr(a.surface) == nil {
		a.backend.destroy_instance(a.instance)
		a.instance = nil
		win.window_destroy(&a.window)
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
		return false
	}

	// (8) Surface attach + LUT rebuild.
	win.window_update_pixel_size(&a.window)
	render.renderer_attach_surface(&a.renderer, a.surface, u32(a.window.pixel_w), u32(a.window.pixel_h))
	render.style_lut_rebuild(&a.lut, &a.terminal.grid.style_table)

	// Initial focus mirrors the live window state.
	_app_sync_focus(a)
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

// app_frame runs one frame in fixed order; false means quit requested
// (destroy-safe state, main then destroys). Nil-app returns false; a
// windowless app skips the SDL pump (headless-safe, no SDL calls).
app_frame :: proc(a: ^App) -> bool {
	if a == nil {
		return false
	}

	// (1) Input pump (keys -> pty; resize -> winsize + terminal_resize,
	// finished here with resize_grid + pixel resize). When the child is
	// Exited, pty_write refuses the bytes, so feeding stops while the SDL
	// drain (quit/resize) keeps working.
	if a.window.handle != nil {
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

	// (2) PTY drain (cap 64KB) -> parse_chunk.
	if a.pty.master >= 0 {
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

	// (5) Exit poll: record the Exited state, keep looping (banner is
	// step 15). Input feeding already stopped at pty_write.
	pty.pty_poll_exit(&a.pty)

	return !a.should_quit
}

main :: proc() {
	shell, shell_allocated := _resolve_shell()
	if shell_allocated {
		defer delete(shell)
	}
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
