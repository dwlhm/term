package main

// app_term main loop (TODO Langkah 15).
//
// Fixed per-frame order in app_frame:
//   (1) input: window_poll_input -> app_dispatch_input_events (keys -> pty,
//       local actions -> app, pointer -> view/capture, resize -> app resize);
//       Exited -> routed per key via app_handle_exited_key
//       (R relaunch, Q/Esc quit, rest ignored), drain skipped
//   (1b) window_get_size vs last_px -> app_on_resize (both states)
//   (2) pty_drain (cap 64KB, Running only) -> parse_chunk
//   (3) cursor sync from terminal cursor + blink tick(now, focused,
//       term_visible), then stage the cursor before rendering
//   (4) renderer_frame composes the staged cursor into the acquired
//       surface and presents the successful frame exactly once
//   (5) exit poll; Running->Exited transition shows the exit banner once
//
// Shell decision: $SHELL when set and non-empty, /bin/sh fallback.
// The choice is documented at _resolve_shell.

import "base:runtime"
import "core:fmt"
import "core:time"

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

// APP_FRAME_INTERVAL_MS bounds the time spent polling when no event is ready
// and caps the render cadence while the child continuously produces output.
APP_FRAME_INTERVAL_MS :: 8

// APP_CELL_W/H is the cell size in pixels. Must match the renderer's cell
// metrics and the input pump's fallback grid math, or the grid and the
// window drift apart.
APP_CELL_W :: 8
APP_CELL_H :: 16

// APP_FONT_SIZE is the requested font size in pixels.
APP_FONT_SIZE :: f32(13)

// APP_FONT_ZOOM_* bounds the logical font size requested by local zoom.
APP_FONT_ZOOM_MIN :: f32(8)
APP_FONT_ZOOM_MAX :: f32(32)
APP_FONT_ZOOM_STEP :: f32(1)

// APP_TITLE is the window title.
APP_TITLE :: "Term"

// APP_SHELL_FALLBACK is the shell when $SHELL is unset or empty.
APP_SHELL_FALLBACK :: "/bin/sh"

// APP_SHELL_ENV is the environment variable naming the login shell.
APP_SHELL_ENV :: "SHELL"

// APP_DEBUG_ENV gates frame diagnostics; APP_DEBUG_VALUE enables them.
// The flag is cached once at init (zero per-frame env lookups when unset).
APP_DEBUG_ENV :: "TERM_DEBUG"
APP_DEBUG_VALUE :: "1"

// APP_BANNER_EXIT_FMT is the one-shot exit banner; %d is the exit code.
APP_BANNER_EXIT_FMT :: "[ process exited (%d) - press R to relaunch, Q to quit ]"

// APP_BANNER_FAIL is the banner kept on screen when a relaunch fails.
APP_BANNER_FAIL :: "[ relaunch failed - press R to retry, Q to quit ]"

// Font paths to try (in order).
FONT_PATHS :: []string{
	"/System/Library/Fonts/Menlo.ttc",
	"/System/Library/Fonts/Supplemental/Courier New.ttf",
}

// Fallback font paths (in order).
FALLBACK_FONT_PATHS :: []string{
	"/System/Library/Fonts/Apple Symbols.ttf",
	"/System/Library/Fonts/SFNSMono.ttf",
	"/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
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
	view:        termgrid.Terminal_View,
	focused:     bool,
	should_quit: bool,
	font_path:   string,
	logical_font_size:  f32,
	physical_font_size: f32,
	zoom_target_logical_size: f32,
	view_generation: u64,
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
	// debug_frames gates TERM_DEBUG=1 frame diagnostics (init dump +
	// per-frame line + first-damage grid dump). Cached once in app_init;
	// when false the only per-frame cost is one bool check.
	debug_frames: bool,
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
	a.view = termgrid.Terminal_View{}
	a.font_path = ""
	a.logical_font_size = APP_FONT_SIZE
	a.physical_font_size = APP_FONT_SIZE
	a.zoom_target_logical_size = 0
	a.view_generation = 0
	a.prog = prog
	a.argv = argv
	a.banner_shown = false
	a.last_px_w = 0
	a.last_px_h = 0
	// TERM_DEBUG gate, cached once (precedent: os.lookup_env_alloc in
	// _resolve_shell). Only the exact value "1" enables diagnostics.
	a.debug_frames = false
	if val, found := os.lookup_env_alloc(APP_DEBUG_ENV, context.allocator); found {
		a.debug_frames = (val == APP_DEBUG_VALUE)
		delete(val)
	}

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
	a.font_path = font_path
	scale := f32(1.0)
	if a.window.width > 0 {
		scale = f32(a.window.pixel_w) / f32(a.window.width)
	}
	phys_font_size := APP_FONT_SIZE * scale
	a.logical_font_size = APP_FONT_SIZE
	a.physical_font_size = phys_font_size
	format := a.backend.get_preferred_format(rawptr(a.surface), a.device)
	screen_w := f32(a.window.pixel_w) if a.window.pixel_w > 0 else f32(window_w)
	screen_h := f32(a.window.pixel_h) if a.window.pixel_h > 0 else f32(window_h)
	if !render.renderer_init(
		&a.renderer,
		font_path,
		phys_font_size,
		a.backend,
		a.device,
		a.queue,
		i32(rows),
		i32(cols),
		0,
		0,
		screen_w,
		screen_h,
		format,
		fallback_paths = FALLBACK_FONT_PATHS,
		theme = termgrid.THEME_CATPPUCCIN_MOCHA,
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

	cw := a.renderer.cell_width
	if cw <= 0 {
		cw = 8
	}
	ch := a.renderer.cell_height
	if ch <= 0 {
		ch = 16
	}
	avail_w := int(a.window.pixel_w) - int(2 * a.renderer.pad_x)
	avail_h := int(a.window.pixel_h) - int(2 * a.renderer.pad_y)
	if avail_w < int(cw) {
		avail_w = int(cw)
	}
	if avail_h < int(ch) {
		avail_h = int(ch)
	}
	init_cols := avail_w / int(cw)
	init_rows := avail_h / int(ch)
	if init_cols < 1 {
		init_cols = 1
	}
	if init_rows < 1 {
		init_rows = 1
	}

	// (6) Terminal + parser (infallible: make() panics on OOM).
	termgrid.terminal_init(
		&a.terminal,
		init_rows,
		init_cols,
		theme = termgrid.THEME_CATPPUCCIN_MOCHA,
	)
	parser.parser_init(&a.parser)
	render.renderer_resize_grid(&a.renderer, &a.terminal, i32(init_rows), i32(init_cols))

	// (7) PTY child.
	if !pty.pty_spawn(&a.pty, init_rows, init_cols, prog, argv) {
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
	a.last_px_w = a.window.pixel_w
	a.last_px_h = a.window.pixel_h
	// Init dump (once, TERM_DEBUG=1 only): proves GPU resources exist.
	// Atlas valid count is a read-only scan of the slot metadata.
	if a.debug_frames {
		valid := 0
		for i in 0..<len(a.renderer.atlas.slots) {
			if a.renderer.atlas.slots[i].valid {
				valid += 1
			}
		}
		fmt.eprintf(
			"app_debug: init rows=%d cols=%d atlas_valid=%d/%d surface=%dx%d strategy=%v font='%s'\n",
			a.terminal.grid.row_count,
			a.terminal.grid.col_count,
			valid,
			len(a.renderer.atlas.slots),
			a.renderer.surface_w,
			a.renderer.surface_h,
			a.renderer.strategy,
			font_path,
		)
	}
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
// window_poll_input as the only SDL event drain.
_app_sync_focus :: proc(a: ^App) {
	if a == nil || a.window.handle == nil {
		return
	}
	flags := sdl3.GetWindowFlags(a.window.handle)
	a.focused = .INPUT_FOCUS in flags
}

_app_grid_for_pixels :: proc(
	pixel_w, pixel_h: i32,
	cell_w, cell_h, pad_x, pad_y: f32,
) -> (rows, cols: int) {
	cw := int(cell_w)
	if cw <= 0 {
		cw = APP_CELL_W
	}
	ch := int(cell_h)
	if ch <= 0 {
		ch = APP_CELL_H
	}
	avail_w := int(pixel_w) - int(2 * pad_x)
	avail_h := int(pixel_h) - int(2 * pad_y)
	if avail_w < cw {
		avail_w = cw
	}
	if avail_h < ch {
		avail_h = ch
	}
	cols = avail_w / cw
	rows = avail_h / ch
	if cols < 1 {
		cols = 1
	}
	if rows < 1 {
		rows = 1
	}
	return rows, cols
}

_app_pointer_cell :: proc(a: ^App, x, y: f32) -> termgrid.Terminal_Point {
	if a == nil || a.terminal.grid.row_count <= 0 || a.terminal.grid.col_count <= 0 {
		return termgrid.Terminal_Point{}
	}
	cw := a.renderer.cell_width
	if cw <= 0 {
		cw = f32(APP_CELL_W)
	}
	ch := a.renderer.cell_height
	if ch <= 0 {
		ch = f32(APP_CELL_H)
	}
	pointer_x := x
	if a.window.width > 0 && a.window.pixel_w > 0 && a.window.width != a.window.pixel_w {
		pointer_x *= f32(a.window.pixel_w) / f32(a.window.width)
	}
	pointer_y := y
	if a.window.height > 0 && a.window.pixel_h > 0 && a.window.height != a.window.pixel_h {
		pointer_y *= f32(a.window.pixel_h) / f32(a.window.height)
	}
	col := 0
	if pointer_x > a.renderer.pad_x {
		col = int((pointer_x - a.renderer.pad_x) / cw)
	}
	row := 0
	if pointer_y > a.renderer.pad_y {
		row = int((pointer_y - a.renderer.pad_y) / ch)
	}
	return termgrid.Terminal_Point{
		row = clamp(row, 0, a.terminal.grid.row_count-1),
		col = clamp(col, 0, a.terminal.grid.col_count-1),
	}
}

_app_pointer_point :: proc(a: ^App, x, y: f32) -> termgrid.Terminal_Point {
	viewport := _app_pointer_cell(a, x, y)
	return termgrid.terminal_view_point_from_viewport(
		&a.terminal,
		&a.view,
		viewport,
	)
}

_app_pointer_wheel_delta :: proc(pointer: input.Input_Pointer_Event) -> int {
	delta := pointer.wheel_integer_y
	if delta == 0 {
		if pointer.wheel_y > 0 {
			delta = 1
		} else if pointer.wheel_y < 0 {
			delta = -1
		}
	}
	if pointer.wheel_flipped {
		delta = -delta
	}
	return int(delta)
}

_app_pointer_selection_changed :: proc(a: ^App, point: termgrid.Terminal_Point, anchor: bool) -> bool {
	if a == nil {
		return false
	}
	changed := false
	if anchor {
		changed = !a.view.selection.active ||
			a.view.selection.anchor != point ||
			a.view.selection.focus != point
		a.view.selection.active = true
		a.view.selection.anchor = point
		a.view.selection.focus = point
	} else if a.view.selection.active {
		changed = a.view.selection.focus != point
		a.view.selection.focus = point
	}
	if changed {
		a.view_generation += 1
	}
	return changed
}

_app_route_pointer :: proc(a: ^App, pointer: input.Input_Pointer_Event) -> bool {
	if a == nil {
		return false
	}
	switch pointer.kind {
	case .Wheel:
		delta := _app_pointer_wheel_delta(pointer)
		old_offset := a.view.scrollback_offset
		_ = termgrid.terminal_view_scroll(&a.view, &a.terminal, delta)
		if old_offset != a.view.scrollback_offset {
			a.view_generation += 1
		}
	case .Button_Down:
		if pointer.button != 1 {
			return true
		}
		point := _app_pointer_point(a, pointer.x, pointer.y)
		_ = _app_pointer_selection_changed(a, point, true)
		_ = win.window_capture_mouse(&a.window, true)
	case .Motion:
		if a.view.selection.active && a.view.selection.anchor != a.view.selection.focus && !pointer.primary_down {
			return true
		}
		if a.view.selection.active && pointer.primary_down {
			point := _app_pointer_point(a, pointer.x, pointer.y)
			_ = _app_pointer_selection_changed(a, point, false)
		}
	case .Button_Up:
		if pointer.button != 1 {
			return true
		}
		if a.view.selection.active {
			point := _app_pointer_point(a, pointer.x, pointer.y)
			_ = _app_pointer_selection_changed(a, point, false)
		}
		_ = win.window_capture_mouse(&a.window, false)
	}
	return true
}

_app_copy_selection :: proc(a: ^App) -> bool {
	if a == nil {
		return false
	}
	copied := termgrid.terminal_view_copy(&a.terminal, &a.view)
	defer delete(copied)
	if len(copied) == 0 {
		return false
	}
	return win.window_set_clipboard_text(&a.window, copied)
}

_app_request_zoom :: proc(a: ^App, direction: int) -> bool {
	if a == nil || a.pty.state == .Exited || direction == 0 {
		return false
	}
	if a.zoom_target_logical_size <= 0 {
		a.zoom_target_logical_size = a.logical_font_size
		if a.zoom_target_logical_size <= 0 {
			a.zoom_target_logical_size = APP_FONT_SIZE
		}
	}
	step := 1
	if direction < 0 {
		step = -1
	}
	next := a.zoom_target_logical_size + f32(step) * APP_FONT_ZOOM_STEP
	next = clamp(next, APP_FONT_ZOOM_MIN, APP_FONT_ZOOM_MAX)
	if next == a.zoom_target_logical_size {
		return false
	}
	a.zoom_target_logical_size = next
	return true
}

_app_apply_zoom :: proc(a: ^App) -> bool {
	if a == nil || a.pty.state == .Exited || a.zoom_target_logical_size <= 0 {
		return false
	}
	target := a.zoom_target_logical_size
	if target == a.logical_font_size {
		a.zoom_target_logical_size = 0
		return false
	}
	scale := f32(1)
	if a.window.width > 0 && a.window.pixel_w > 0 {
		scale = f32(a.window.pixel_w) / f32(a.window.width)
	}
	physical := target * scale
	if !render.renderer_rebuild_font(
		&a.renderer,
		a.font_path,
		physical,
		FALLBACK_FONT_PATHS,
	) {
		a.zoom_target_logical_size = 0
		return false
	}
	pixel_w := a.window.pixel_w
	pixel_h := a.window.pixel_h
	if pixel_w <= 0 {
		pixel_w = i32(a.renderer.screen_w)
	}
	if pixel_h <= 0 {
		pixel_h = i32(a.renderer.screen_h)
	}
	rows, cols := _app_grid_for_pixels(
		pixel_w,
		pixel_h,
		a.renderer.cell_width,
		a.renderer.cell_height,
		a.renderer.pad_x,
		a.renderer.pad_y,
	)
	termgrid.terminal_resize(&a.terminal, rows, cols)
	render.renderer_resize_grid(&a.renderer, &a.terminal, i32(rows), i32(cols))
	pty.pty_set_winsize(&a.pty, rows, cols)
	if pixel_w > 0 && pixel_h > 0 {
		render.renderer_resize(&a.renderer, u32(pixel_w), u32(pixel_h))
	}
	a.logical_font_size = target
	a.physical_font_size = physical
	a.zoom_target_logical_size = 0
	return true
}

app_dispatch_input_events :: proc(a: ^App, evs: []input.Input_Event) -> (quit: bool, ok: bool) {
	if a == nil {
		return true, false
	}
	key_evs: [input.INPUT_PUMP_MAX_EVENTS]input.Input_Event
	key_count := 0
	ok = true
	for ev in evs {
		switch ev.event_type {
		case .Key:
			if a.pty.state == .Exited {
				switch app_handle_exited_key(ev) {
				case .Relaunch:
					_ = app_relaunch(a)
				case .Quit:
					a.should_quit = true
				case .None:
				}
			} else if key_count < len(key_evs) {
				key_evs[key_count] = ev
				key_count += 1
			}
		case .Local:
			switch ev.action {
			case .Copy:
				if !_app_copy_selection(a) {
					ok = false
				}
			case .Zoom_In:
				_ = _app_request_zoom(a, 1)
			case .Zoom_Out:
				_ = _app_request_zoom(a, -1)
			case .None:
			}
		case .Pointer:
			if !_app_route_pointer(a, ev.pointer) {
				ok = false
			}
		}
	}
	if key_count > 0 {
		ok = input.input_pump_events(&a.pty, key_evs[:key_count]) && ok
	}
	quit = a.should_quit || !a.window.is_open
	return quit, ok
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
	a.last_px_w = a.window.pixel_w
	a.last_px_h = a.window.pixel_h
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

// _app_debug_grid_dumped guards the first-nonempty-damage grid dump
// (once per process; package-level so App gains only the specified
// debug_frames field).
_app_debug_grid_dumped: bool

// _app_debug_dump_grid prints the first 3 grid rows as text via
// terminal_get_cell (read-only; proves bytes reached the grid in the LIVE
// app vs headless tests). Non-printable content renders as '?', blank as
// ' '. Rows are truncated at 127 cells.
_app_debug_dump_grid :: proc(a: ^App) {
	if a == nil {
		return
	}
	rows := a.terminal.grid.row_count
	cols := a.terminal.grid.col_count
	if rows > 3 {
		rows = 3
	}
	for r in 0..<rows {
		buf: [128]u8
		n := 0
		for c in 0..<cols {
			if n >= len(buf) - 1 {
				break
			}
			cell := termgrid.terminal_get_cell(&a.terminal, r, c)
			ch := u8('?')
			if cell.content == 0 || cell.content == 0x20 {
				ch = u8(' ')
			} else if cell.content >= 0x20 && cell.content < 0x7F {
				ch = u8(cell.content)
			}
			buf[n] = ch
			n += 1
		}
		fmt.eprintf("app_debug: grid row %d: '%s'\n", r, string(buf[:n]))
	}
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
	rows, cols := _app_grid_for_pixels(
		pixel_w,
		pixel_h,
		a.renderer.cell_width,
		a.renderer.cell_height,
		a.renderer.pad_x,
		a.renderer.pad_y,
	)
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

	// (1) Input. One SDL drain feeds the app dispatcher. Running keys are
	// encoded to the pty, local actions stay in the app, and pointer events
	// update the view. Exited keys retain app_handle_exited_key semantics.
	if a.window.handle != nil {
		evs: [input.INPUT_PUMP_MAX_EVENTS]input.Input_Event
		n := input.window_poll_input(&a.window, evs[:], input.INPUT_PUMP_MAX_EVENTS)
		quit, _ := app_dispatch_input_events(a, evs[:n])
		if quit {
			a.should_quit = true
			return false
		}
		_app_sync_focus(a)
		// (1b) Live window size vs last_px -> app_on_resize (both
		// states; same-dims+same-px is a no-op inside).
		if a.window.pixel_w != a.last_px_w || a.window.pixel_h != a.last_px_h {
			_ = app_on_resize(a, a.window.pixel_w, a.window.pixel_h)
		}
		_ = _app_apply_zoom(a)
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
	position_changed := a.cursor.row != cur.row || a.cursor.col != cur.col
	old_cursor_row := a.cursor.row
	old_cursor_col := a.cursor.col
	render.cursor_overlay_sync(&a.cursor, cur.row, cur.col)
	now := platform.platform_ticks_to_ns(platform.platform_now())
	cursor_changed := render.cursor_overlay_tick(&a.cursor, now, a.focused, cur.visible)

	// Frame diagnostics pre-scan (TERM_DEBUG=1 only): read-only damage
	// estimate via strategy_estimate_inputs, which never takes or clears.
	// The take/skip discipline inside renderer_frame is undisturbed.
	dbg_dmg, dbg_total := 0, 0
	if a.debug_frames {
		inp := render.strategy_estimate_inputs(&a.terminal.damage, a.renderer.rows, a.renderer.cols)
		dbg_dmg, dbg_total = inp.dirty_cells, inp.total_cells
	}

	// (4) Render. Stage the cursor before the selected renderer path so the
	// renderer can compose it into the same acquired surface. A cursor blink
	// transition marks its cell, making a no-damage scene renderable without a
	// second acquisition or present. Every successful renderer frame owns the
	// single present for the frame.
	_ = render.cursor_overlay_draw(&a.renderer, &a.cursor)
	if cursor_changed {
		_ = _app_mark_cursor_dirty(a, old_cursor_row, old_cursor_col)
		_ = _app_mark_cursor_dirty(a, cur.row, cur.col)
	}
	if position_changed {
		_ = _app_mark_cursor_dirty(a, old_cursor_row, old_cursor_col)
		_ = _app_mark_cursor_dirty(a, cur.row, cur.col)
	}
	frame_ok := render.renderer_frame(&a.renderer, &a.terminal, &a.view)

	// Per-frame line (TERM_DEBUG=1 only): dmg>0 + present=false =
	// present-fail; dmg==0 + present=false = healthy skip; dmg>0 +
	// present=true with a black screen = 0-instances/GPU path (see the
	// grid dump + S5 audit). Exact bg/glyph counts are frame-locals
	// inside renderer_frame_v2 (_prepare_instances_v2 return) and are not
	// persisted, so upload_est bounds one frame at 2 instances (bg+glyph)
	// per dirty cell; atlas_dirty/dirty_armed disambiguate stale uploads.
	if a.debug_frames {
		upload_est := u64(dbg_dmg) * 2 * u64(instance.INSTANCE_STRIDE)
		fmt.eprintf(
			"app_debug: frame dmg=%d/%d strategy=%v count=%d dirty=%v surface=%dx%d atlas_dirty=%v dirty_armed=%v present=%v upload_est=%dB\n",
			dbg_dmg,
			dbg_total,
			a.renderer.strategy,
			a.renderer.frame_count,
			a.renderer.last_dirty,
			a.renderer.surface_w,
			a.renderer.surface_h,
			a.renderer.atlas.gpu_dirty,
			a.renderer.dirty.armed,
			frame_ok,
			upload_est,
		)
		if !_app_debug_grid_dumped && dbg_dmg > 0 {
			_app_debug_grid_dumped = true
			_app_debug_dump_grid(a)
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

	app := new(App, runtime.heap_allocator())
	if !app_init(app, APP_DEFAULT_ROWS, APP_DEFAULT_COLS, shell, nil) {
		free(app, runtime.heap_allocator())
		fmt.println("ERROR: app_init failed")
		return
	}
	defer {
		app_destroy(app)
		free(app, runtime.heap_allocator())
	}

	for app_frame(app) {
		time.sleep(APP_FRAME_INTERVAL_MS * time.Millisecond)
	}
	fmt.println("Term: quit")
}
