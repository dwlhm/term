package main

// Frontend module for the terminal emulator.
// Encapsulates SDL3 window management, Metal rendering pipeline, font loading,
// and presentation of Render_State frames.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "vendor:sdl3"
import CA "vendor:darwin/QuartzCore"

import termgrid "../terminal"
import render "../render"
import gpu "../render/gpu"
import instance "../render/instance"
import metal_backend "../render/gpu/metal"
import win "../platform/window"
import pure_ui "../pinnacle_ui"
import pinnacle_wgpu "../pinnacle_ui/wgpu_adapter"
import pinnacle_app "../pinnacle_ui/adapters"

import input "../platform/input"
import pty "../platform/pty"
import config "../config"
import platform "../platform"
import platform_tabs "../platform/tabs"
import ui "../ui"

UI_MAX_INSTANCES :: ui.UI_MAX_INSTANCES
FRONTEND_CONTENT_PADDING: f32 : 4.0


// Font paths to try (in order).
FONT_PATHS :: []string{
	"assets/fonts/MapleMono-NF-Regular.ttf",
	"assets/fonts/MapleMono-Regular.ttf",
	"../assets/fonts/MapleMono-NF-Regular.ttf",
	"../assets/fonts/MapleMono-Regular.ttf",
	"~/Library/Fonts/MapleMono-NF-Regular.ttf",
	"~/Library/Fonts/MapleMono-Regular.ttf",
	"~/Library/Fonts/MesloLGS NF Regular.ttf",
	"~/Library/Fonts/JetBrainsMonoNerdFont-Regular.ttf",
	"/Library/Fonts/MesloLGS NF Regular.ttf",
	"/Applications/Raycast.app/Contents/Resources/JetBrainsMono-Regular.ttf",
	"/System/Applications/Utilities/Terminal.app/Contents/Resources/Fonts/SFMono-Terminal.ttf",
	"/System/Library/Fonts/SFNSMono.ttf",
	"/System/Library/Fonts/Monaco.ttf",
	"/System/Library/Fonts/Menlo.ttc",
	"/System/Library/Fonts/Supplemental/Courier New.ttf",
}

// Fallback font paths (in order).
FALLBACK_FONT_PATHS :: []string{
	"assets/fonts/SymbolsNerdFontMono-Regular.ttf",
	"../assets/fonts/SymbolsNerdFontMono-Regular.ttf",
	"~/Library/Fonts/SymbolsNerdFontMono-Regular.ttf",
	"/Library/Fonts/SymbolsNerdFontMono-Regular.ttf",
	"~/Library/Fonts/MesloLGS NF Regular.ttf",
	"/Library/Fonts/MesloLGS NF Regular.ttf",
	"/System/Library/Fonts/Apple Symbols.ttf",
	"/System/Library/Fonts/Supplemental/STIXGeneral.otf",
	"/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
	"/System/Library/Fonts/Menlo.ttc",
	"/System/Library/Fonts/SFNSMono.ttf",
}

// Frontend owns SDL window, Metal device/queue/surface, and Renderer state.
Frontend :: struct {
	window:                   win.Window,
	renderer:                 render.Renderer,

	use_pinnacle:             bool,
	p_engine:                 ^pure_ui.Core_Engine,
	p_gpu_adapter:            pinnacle_wgpu.WGPU_Adapter,
	p_gpu_port:               pure_ui.Renderer_Port,
	p_term_adapter:           pinnacle_app.Terminal_UI_Adapter,

	gpu_backend:              ^gpu.Gpu_Backend_VTable,
	device:                   gpu.Gpu_Device,
	queue:                    gpu.Gpu_Queue,
	surface:                  gpu.Gpu_Surface,
	instance:                 rawptr,
	executable_path:          string,
	font_path:                string,
	logical_font_size:        f32,
	physical_font_size:       f32,
	zoom_target_logical_size: f32,
	last_px_w:                i32,
	last_px_h:                i32,
	debug_frames:             bool,
}

// Window events and chrome use logical units; renderer geometry uses pixels.
frontend_content_scale :: proc(f: ^Frontend) -> f32 {
	if f == nil || f.window.width <= 0 || f.window.pixel_w <= 0 do return 1
	return f32(f.window.pixel_w) / f32(f.window.width)
}

frontend_update_padding :: proc(f: ^Frontend) {
	if f == nil do return
	if f.window.handle == nil {
		f.renderer.pad_x = 0
		f.renderer.pad_y = 0
		return
	}
	scale := frontend_content_scale(f)
	f.renderer.pad_x = FRONTEND_CONTENT_PADDING * scale
	f.renderer.pad_y = (FRONTEND_CONTENT_PADDING + platform_tabs.TAB_BAR_HEIGHT) * scale
}

// frontend_font_paths expands candidate font paths with application resource locations.
frontend_font_paths :: proc(executable_path: string, candidates: []string, allocator := context.allocator) -> []string {
	res := make([dynamic]string, allocator)
	if len(executable_path) > 0 {
		dir := filepath.dir(executable_path)
		parent := filepath.dir(dir)

		// 1. Resources/fonts
		for c in candidates {
			if strings.has_prefix(c, "assets/fonts/") {
				filename := c[len("assets/fonts/"):]
				p, _ := filepath.join({parent, "Resources/fonts", filename}, allocator)
				append(&res, p)
			}
		}

		// 2. assets/fonts
		for c in candidates {
			if strings.has_prefix(c, "assets/fonts/") {
				filename := c[len("assets/fonts/"):]
				p, _ := filepath.join({parent, "assets/fonts", filename}, allocator)
				append(&res, p)
			}
		}
	}

	for c in candidates {
		append(&res, strings.clone(c, allocator))
	}

	return res[:]
}

frontend_font_paths_destroy :: proc(paths: []string, allocator := context.allocator) {
	for p in paths {
		delete(p, allocator)
	}
	delete(paths, allocator)
}

// find_font tries to find a usable font file.
find_font :: proc(executable_path: string = "", allocator := context.allocator) -> (path: string, ok: bool) {
	exec := executable_path
	if len(exec) == 0 {
		if p, err := os.get_executable_path(context.temp_allocator); err == nil && len(p) > 0 {
			exec = p
		} else if len(os.args) > 0 && len(os.args[0]) > 0 {
			exec = os.args[0]
		}
	}

	candidates := frontend_font_paths(exec, FONT_PATHS, context.temp_allocator)
	defer frontend_font_paths_destroy(candidates, context.temp_allocator)

	for font_path in candidates {
		actual_path := font_path
		if strings.has_prefix(font_path, "~/") {
			if home, hok := os.lookup_env("HOME", context.temp_allocator); hok {
				actual_path = strings.concatenate({home, font_path[1:]}, context.temp_allocator)
			}
		}
		if data, err := os.read_entire_file(actual_path, context.allocator); err == nil {
			delete(data)
			return strings.clone(actual_path, allocator), true
		}
	}
	return "", false
}

// frontend_init initializes window, Metal backend, device, queue, surface, and renderer.
frontend_init :: proc(
	f: ^Frontend,
	title: string,
	rows, cols: int,
	cfg: ^config.Config,
	theme: termgrid.Theme,
) -> (cell_w, cell_h: f32, pad_x, pad_y: f32, ok: bool) {
	if f == nil {
		return 0, 0, 0, 0, false
	}

	window_w := i32(cols) * i32(APP_CELL_W)
	window_h := i32(rows) * i32(APP_CELL_H)
	if window_w < 1 {
		window_w = 1
	}
	if window_h < 1 {
		window_h = 1
	}

	if !win.window_init(&f.window, title, window_w, window_h) {
		fmt.eprintf("frontend_init: window_init failed\n")
		return 0, 0, 0, 0, false
	}

	when ODIN_OS == .Darwin {
		f.gpu_backend = metal_backend.create_metal_backend()
		f.instance = f.gpu_backend.create_instance()
		if f.instance == nil {
			win.window_destroy(&f.window)
			fmt.eprintf("frontend_init: create_instance failed\n")
			return 0, 0, 0, 0, false
		}

		metal_view := sdl3.Metal_CreateView(f.window.handle)
		if metal_view == nil {
			f.gpu_backend.destroy_instance(f.instance)
			f.instance = nil
			win.window_destroy(&f.window)
			fmt.eprintf("frontend_init: Metal_CreateView failed\n")
			return 0, 0, 0, 0, false
		}
		layer := (^CA.MetalLayer)(sdl3.Metal_GetLayer(metal_view))
		f.surface = gpu.Gpu_Surface(metal_backend.create_surface(layer))
		if rawptr(f.surface) == nil {
			sdl3.Metal_DestroyView(metal_view)
			f.gpu_backend.destroy_instance(f.instance)
			f.instance = nil
			win.window_destroy(&f.window)
			fmt.eprintf("frontend_init: create_surface failed\n")
			return 0, 0, 0, 0, false
		}

		f.device, f.queue = f.gpu_backend.request_device(f.instance, rawptr(f.surface))
		if rawptr(f.device) == nil || rawptr(f.queue) == nil {
			f.device = gpu.Gpu_Device(nil)
			f.queue = gpu.Gpu_Queue(nil)
			metal_backend.destroy_surface((^metal_backend.Metal_Surface)(rawptr(f.surface)))
			f.surface = gpu.Gpu_Surface(nil)
			sdl3.Metal_DestroyView(metal_view)
			f.gpu_backend.destroy_instance(f.instance)
			f.instance = nil
			win.window_destroy(&f.window)
			fmt.eprintf("frontend_init: request_device failed\n")
			return 0, 0, 0, 0, false
		}
	} else {
		#panic("Unsupported platform: Term currently only supports macOS (Metal)")
	}

	exec_path := ""
	if p, err := os.get_executable_path(context.temp_allocator); err == nil && len(p) > 0 {
		exec_path = p
	} else if len(os.args) > 0 && len(os.args[0]) > 0 {
		exec_path = os.args[0]
	}
	f.executable_path = strings.clone(exec_path, context.allocator)

	font_path, font_ok := find_font(f.executable_path)
	if !font_ok {
		f.gpu_backend.destroy_device(f.device)
		f.device = gpu.Gpu_Device(nil)
		f.queue = gpu.Gpu_Queue(nil)
		when ODIN_OS == .Darwin {
			metal_backend.destroy_surface((^metal_backend.Metal_Surface)(rawptr(f.surface)))
		}
		f.surface = gpu.Gpu_Surface(nil)
		f.gpu_backend.destroy_instance(f.instance)
		f.instance = nil
		if len(f.executable_path) > 0 {
			delete(f.executable_path)
			f.executable_path = ""
		}
		win.window_destroy(&f.window)
		fmt.eprintf("frontend_init: no usable font found\n")
		return 0, 0, 0, 0, false
	}
	f.font_path = font_path

	scale := frontend_content_scale(f)
	req_font_size := cfg.font_size if (cfg != nil && cfg.font_size > 0) else APP_FONT_SIZE
	phys_font_size := req_font_size * scale
	f.logical_font_size = req_font_size
	f.physical_font_size = phys_font_size
	f.zoom_target_logical_size = 0
	format := f.gpu_backend.get_preferred_format(rawptr(f.surface), f.device)
	screen_w := f32(f.window.pixel_w) if f.window.pixel_w > 0 else f32(window_w)
	screen_h := f32(f.window.pixel_h) if f.window.pixel_h > 0 else f32(window_h)

	fallback_candidates := frontend_font_paths(f.executable_path, FALLBACK_FONT_PATHS, context.temp_allocator)
	defer frontend_font_paths_destroy(fallback_candidates, context.temp_allocator)

	if !render.renderer_init(
		&f.renderer,
		font_path,
		phys_font_size,
		f.gpu_backend,
		f.device,
		f.queue,
		i32(rows),
		i32(cols),
		0,
		0,
		screen_w,
		screen_h,
		format,
		fallback_paths = fallback_candidates,
		theme = theme,
	) {
		f.gpu_backend.destroy_device(f.device)
		f.device = gpu.Gpu_Device(nil)
		f.queue = gpu.Gpu_Queue(nil)
		when ODIN_OS == .Darwin {
			metal_backend.destroy_surface((^metal_backend.Metal_Surface)(rawptr(f.surface)))
		}
		f.surface = gpu.Gpu_Surface(nil)
		f.gpu_backend.destroy_instance(f.instance)
		f.instance = nil
		if len(f.font_path) > 0 {
			delete(f.font_path)
			f.font_path = ""
		}
		if len(f.executable_path) > 0 {
			delete(f.executable_path)
			f.executable_path = ""
		}
		win.window_destroy(&f.window)
		fmt.eprintf("frontend_init: renderer_init failed\n")
		return 0, 0, 0, 0, false
	}

	win.window_update_pixel_size(&f.window)
	render.renderer_attach_surface(&f.renderer, f.surface, u32(f.window.pixel_w), u32(f.window.pixel_h))
	f.last_px_w = f.window.pixel_w
	f.last_px_h = f.window.pixel_h

	frontend_update_padding(f)
	needed_instances := u32(rows * cols) + UI_MAX_INSTANCES + 2
	if needed_instances > f.renderer.instances.max_instances {
		f.renderer.instances.max_instances = needed_instances
	}

	f.debug_frames = false
	if val, found := os.lookup_env_alloc(APP_DEBUG_ENV, context.allocator); found {
		f.debug_frames = (val == APP_DEBUG_VALUE)
		delete(val)
	}


	val, _ := os.lookup_env("TERM_USE_PINNACLE", context.temp_allocator); f.use_pinnacle = val == "1"
	if f.use_pinnacle {
		fmt.eprintf("🔥 PINNACLE ENGINE ARCHITECTURE ACTIVATED 🔥\n")
		p_config := pure_ui.default_config()
		p_config.max_ui_elements = u32(rows * cols) * 2 + 100
		
		f.p_gpu_port = pinnacle_wgpu.create_wgpu_port(&f.p_gpu_adapter, f.gpu_backend, f.device, f.queue, f.surface)
		f.p_engine = pure_ui.init_engine(p_config, &f.p_gpu_port)
		
		if f.p_engine != nil {
			ui_svc := pure_ui.create_ui_service(f.p_engine)
			pinnacle_app.init_terminal_adapter(&f.p_term_adapter, ui_svc, i32(rows), i32(cols), f.renderer.cell_width, f.renderer.cell_height)
		}
	}

	return f.renderer.cell_width, f.renderer.cell_height, f.renderer.pad_x, f.renderer.pad_y, true
}


// frontend_destroy unwinds GPU resources and closes window.
frontend_destroy :: proc(f: ^Frontend) {
	if f == nil {
		return
	}
	render.renderer_destroy(&f.renderer)
	if rawptr(f.surface) != nil {
		when ODIN_OS == .Darwin {
			metal_backend.destroy_surface((^metal_backend.Metal_Surface)(rawptr(f.surface)))
		}
		f.surface = gpu.Gpu_Surface(nil)
	}
	if rawptr(f.device) != nil && f.gpu_backend != nil {
		f.gpu_backend.destroy_device(f.device)
		f.device = gpu.Gpu_Device(nil)
		f.queue = gpu.Gpu_Queue(nil)
	}
	if f.instance != nil && f.gpu_backend != nil {
		f.gpu_backend.destroy_instance(f.instance)
		f.instance = nil
	}
	if len(f.font_path) > 0 {
		delete(f.font_path)
		f.font_path = ""
	}
	if len(f.executable_path) > 0 {
		delete(f.executable_path)
		f.executable_path = ""
	}
	win.window_destroy(&f.window)
}

// _app_debug_grid_dumped guards the first-nonempty-damage grid dump
_app_debug_grid_dumped: bool

_frontend_debug_dump_grid :: proc(t: ^termgrid.Terminal) {
	if t == nil {
		return
	}
	rows := t.grid.row_count
	cols := t.grid.col_count
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
			cell := termgrid.terminal_get_cell(t, r, c)
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

// frontend_render stages the cursor and presents a frame from the Render_State snapshot.
frontend_render :: proc(f: ^Frontend, state: ^Render_State) -> bool {
	if f == nil || state == nil || state.terminal == nil {
		return false
	}

	if f.use_pinnacle && f.p_engine != nil {
		pinnacle_app.update_from_damage(&f.p_term_adapter, state.terminal, &state.terminal.damage)
		pure_ui.engine_tick(f.p_engine)
		return true
	}

	// Stage cursor overlay before frame acquisition
	if state.cursor != nil && state.view != nil {
		_ = render.cursor_overlay_draw(&f.renderer, state.cursor, state.view.scrollback_offset)
	}

	// Stage interaction overlay before frame acquisition
	if state.interaction != nil && state.view != nil && state.terminal != nil {
		_ = render.interaction_overlay_draw(&f.renderer, state.interaction, state.view, state.terminal)
	}

	// Stage scrollbar overlay before frame acquisition
	if state.terminal != nil {
		total_lines := termgrid.scrollback_len(&state.terminal.scrollback) + state.terminal.grid.row_count
		visible_lines := state.terminal.grid.row_count
		offset := state.view.scrollback_offset if state.view != nil else 0
		viewport_w := f32(f.renderer.surface_w)
		viewport_h := f32(f.renderer.surface_h)
		termgrid.scrollbar_update(&state.terminal.scrollbar, total_lines, visible_lines, offset, viewport_w, viewport_h)
		_ = render.scrollbar_overlay_draw(&f.renderer, &state.terminal.scrollbar)
	}

	dbg_dmg, dbg_total := 0, 0
	if f.debug_frames || state.debug_frames {
		inp := render.strategy_estimate_inputs(&state.terminal.damage, f.renderer.rows, f.renderer.cols)
		dbg_dmg, dbg_total = inp.dirty_cells, inp.total_cells
	}

	now := platform.platform_ticks_to_ns(platform.platform_now())
	now_ns := u64(now)
	frame_ok := false
	if state.synchronized_output {
		if now_ns - state.sync_output_start_ns < APP_SYNC_OUTPUT_TIMEOUT_NS {
			// Skip calling renderer_frame for this frame (synchronized output in progress)
		} else {
			// Safety timeout reached — force presentation
			frame_ok = render.renderer_frame(&f.renderer, state.terminal, state.view)
		}
	} else {
		frame_ok = render.renderer_frame(&f.renderer, state.terminal, state.view)
	}

	if f.debug_frames || state.debug_frames {
		upload_est := u64(dbg_dmg) * 2 * u64(instance.INSTANCE_STRIDE)
		fmt.eprintf(
			"app_debug: frame dmg=%d/%d strategy=%v count=%d dirty=%v surface=%dx%d atlas_dirty=%v dirty_armed=%v present=%v upload_est=%dB\n",
			dbg_dmg,
			dbg_total,
			f.renderer.strategy,
			f.renderer.frame_count,
			f.renderer.last_dirty,
			f.renderer.surface_w,
			f.renderer.surface_h,
			f.renderer.atlas.gpu_dirty,
			f.renderer.dirty.armed,
			frame_ok,
			upload_est,
		)
		if !_app_debug_grid_dumped && dbg_dmg > 0 {
			_app_debug_grid_dumped = true
			_frontend_debug_dump_grid(state.terminal)
		}
	}

	return frame_ok
}

// frontend_set_title updates the OS window title.
frontend_set_title :: proc(f: ^Frontend, title: string) {
	if f == nil || len(title) == 0 {
		return
	}
	win.window_set_title(&f.window, title)
}

// frontend_pointer_cell converts logical window coordinates to grid cell coordinates.
frontend_pointer_cell :: proc(f: ^Frontend, grid_rows, grid_cols: int, x, y: f32) -> termgrid.Terminal_Point {
	if f == nil || grid_rows <= 0 || grid_cols <= 0 {
		return termgrid.Terminal_Point{}
	}
	cw := f.renderer.cell_width
	if cw <= 0 {
		cw = f32(APP_CELL_W)
	}
	ch := f.renderer.cell_height
	if ch <= 0 {
		ch = f32(APP_CELL_H)
	}
	pointer_x := x
	if f.window.width > 0 && f.window.pixel_w > 0 && f.window.width != f.window.pixel_w {
		pointer_x *= f32(f.window.pixel_w) / f32(f.window.width)
	}
	pointer_y := y
	if f.window.height > 0 && f.window.pixel_h > 0 && f.window.height != f.window.pixel_h {
		pointer_y *= f32(f.window.pixel_h) / f32(f.window.height)
	}
	col := 0
	if pointer_x > f.renderer.pad_x {
		col = int((pointer_x - f.renderer.pad_x) / cw)
	}
	row := 0
	if pointer_y > f.renderer.pad_y {
		row = int((pointer_y - f.renderer.pad_y) / ch)
	}
	return termgrid.Terminal_Point{
		row = clamp(row, 0, grid_rows-1),
		col = clamp(col, 0, grid_cols-1),
	}
}

// frontend_request_zoom queues a font size zoom change.
frontend_request_zoom :: proc(f: ^Frontend, pty_state: pty.Pty_State, direction: int) -> bool {
	if f == nil || pty_state == .Exited || direction == 0 {
		return false
	}
	if f.zoom_target_logical_size <= 0 {
		f.zoom_target_logical_size = f.logical_font_size
		if f.zoom_target_logical_size <= 0 {
			f.zoom_target_logical_size = APP_FONT_SIZE
		}
	}
	step := 1
	if direction < 0 {
		step = -1
	}
	next := f.zoom_target_logical_size + f32(step) * APP_FONT_ZOOM_STEP
	next = clamp(next, APP_FONT_ZOOM_MIN, APP_FONT_ZOOM_MAX)
	if next == f.zoom_target_logical_size {
		return false
	}
	f.zoom_target_logical_size = next
	return true
}

// frontend_apply_zoom applies any queued font zoom rebuild and resizes grid/PTY.
frontend_apply_zoom :: proc(
	f: ^Frontend,
	terminal: ^termgrid.Terminal,
	pty_ptr: ^pty.Pty,
) -> bool {
	if f == nil || pty_ptr == nil || pty_ptr.state == .Exited || f.zoom_target_logical_size <= 0 {
		return false
	}
	target := f.zoom_target_logical_size
	if target == f.logical_font_size {
		f.zoom_target_logical_size = 0
		return false
	}
	scale := frontend_content_scale(f)
	physical := target * scale
	fallback_candidates := frontend_font_paths(f.executable_path, FALLBACK_FONT_PATHS, context.temp_allocator)
	defer frontend_font_paths_destroy(fallback_candidates, context.temp_allocator)
	if !render.renderer_rebuild_font(
		&f.renderer,
		f.font_path,
		physical,
		fallback_candidates,
	) {
		f.zoom_target_logical_size = 0
		return false
	}
	pixel_w := f.window.pixel_w
	pixel_h := f.window.pixel_h
	if pixel_w <= 0 {
		pixel_w = i32(f.renderer.screen_w)
	}
	if pixel_h <= 0 {
		pixel_h = i32(f.renderer.screen_h)
	}
	frontend_update_padding(f)
	rows, cols := grid_dimensions_for_pixels(
		pixel_w,
		pixel_h,
		f.renderer.cell_width,
		f.renderer.cell_height,
		f.renderer.pad_x,
		f.renderer.pad_y,
	)
	if terminal != nil {
		termgrid.terminal_resize(terminal, rows, cols)
		if f.use_pinnacle { pinnacle_app.resize_terminal_adapter(&f.p_term_adapter, i32(rows), i32(cols)) } else { render.renderer_resize_grid(&f.renderer, terminal, i32(rows), i32(cols)) }
	}
	pty.pty_set_winsize(pty_ptr, rows, cols)
	if pixel_w > 0 && pixel_h > 0 {
		render.renderer_resize(&f.renderer, u32(pixel_w), u32(pixel_h))
	}
	f.logical_font_size = target
	f.physical_font_size = physical
	f.zoom_target_logical_size = 0
	return true
}

// frontend_on_resize handles window pixel size changes.
frontend_on_resize :: proc(
	f: ^Frontend,
	terminal: ^termgrid.Terminal,
	pty_ptr: ^pty.Pty,
	pixel_w, pixel_h: i32,
) -> (resized: bool) {
	if f == nil || pixel_w <= 0 || pixel_h <= 0 {
		return false
	}
	frontend_update_padding(f)
	rows, cols := grid_dimensions_for_pixels(
		pixel_w,
		pixel_h,
		f.renderer.cell_width,
		f.renderer.cell_height,
		f.renderer.pad_x,
		f.renderer.pad_y,
	)
	cur_rows := terminal.grid.row_count if terminal != nil else 0
	cur_cols := terminal.grid.col_count if terminal != nil else 0
	if rows == cur_rows && cols == cur_cols &&
	   pixel_w == f.last_px_w && pixel_h == f.last_px_h {
		return false
	}
	grid_changed := rows != cur_rows || cols != cur_cols
	if grid_changed {
		if terminal != nil {
			termgrid.terminal_resize(terminal, rows, cols)
			if f.use_pinnacle { pinnacle_app.resize_terminal_adapter(&f.p_term_adapter, i32(rows), i32(cols)) } else { render.renderer_resize_grid(&f.renderer, terminal, i32(rows), i32(cols)) }
		}
		if pty_ptr != nil {
			pty.pty_set_winsize(pty_ptr, rows, cols)
		}
	}
	render.renderer_resize(&f.renderer, u32(pixel_w), u32(pixel_h))
	f.last_px_w = pixel_w
	f.last_px_h = pixel_h
	return true
}


// frontend_apply_theme updates the renderer's theme.
frontend_apply_theme :: proc(f: ^Frontend, theme: termgrid.Theme) {
	if f == nil {
		return
	}
	f.renderer.theme = theme
}

// _frontend_clipboard_write_cb writes text to the system clipboard via SDL.
_frontend_clipboard_write_cb :: proc(user_data: rawptr, text: string) {
	if user_data == nil {
		return
	}
	f := (^Frontend)(user_data)
	win.window_set_clipboard_text(&f.window, text)
}

// _frontend_clipboard_read_cb reads text from the system clipboard via SDL.
_frontend_clipboard_read_cb :: proc(user_data: rawptr, out: []u8) -> int {
	if user_data == nil || len(out) == 0 {
		return 0
	}
	f := (^Frontend)(user_data)
	text := win.window_get_clipboard_text(&f.window)
	if len(text) == 0 {
		delete(text)
		return 0
	}
	defer delete(text)
	n := min(len(text), len(out))
	copy(out[:n], text[:n])
	return n
}
