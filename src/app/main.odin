package main

// Term Production Coordinator Shell (<300 lines)
// Part of Tier 3 Application Shell (app_*).
// Coordinates OS bootstrap, CLI args, features, and frame presentation.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:time"
import "vendor:sdl3"
import "vendor:wgpu"

import helper "../cmd/harness_helper"
import contract "../core/render/contract"
import wgpu_backend "../core/platform/gpu/wgpu"
import atlas "../core/render/atlas"
import terminal_instance "../core/render/terminal/instance"
import pipeline "../core/composer/pipeline"
import chrome_render "../core/render/chrome"
import chrome_dl "../core/chrome/draw_list"
import chrome_splits "../core/chrome/splits"
import three_d "../core/render/three_d"
import tabs_feat "../features/tabs"
import mux_feat "../features/multiplexer"
import inter_feat "../features/interaction"
import sess_feat "../features/session"

VERSION: string : "2.0.0"
CHROME_BAR_HEIGHT: f32 : 38.0

Term_App :: struct {
	window:         helper.Window,
	device:         contract.Gpu_Device,
	queue:          contract.Gpu_Queue,
	format:         contract.Gpu_Format,
	surface:        rawptr,
	running:        bool,
	screen_w:       f32,
	screen_h:       f32,
	time_elapsed:   f32,

	composer_pipe:  pipeline.Composer_Pipeline,
	chrome_rend:    chrome_render.Chrome_Renderer,
	three_d_rend:   three_d.Three_D_Renderer,
	draw_list:      chrome_dl.Ui_Draw_List,

	atlas:          atlas.Atlas,
	inst_rend:      terminal_instance.Instance_Renderer,
	glyph_pipeline: contract.Gpu_RenderPipeline,
	glyph_layout:   contract.Gpu_BindGroupLayout,
	bg_pipeline:    contract.Gpu_RenderPipeline,
	bg_layout:      contract.Gpu_BindGroupLayout,

	tabs_mgr:       tabs_feat.Tabs_Manager,
	mux:            mux_feat.Multiplexer,
	inter:          inter_feat.Interaction_State,

	primary_pane:   u32,
	threed_pane:    u32,
}

app_init :: proc(app: ^Term_App, initial_cmd: string = "") -> bool {
	app.screen_w = 1280.0
	app.screen_h = 800.0

	if !helper.window_init(&app.window, "Term", i32(app.screen_w), i32(app.screen_h)) {
		return false
	}

	wgpu_backend.init_wgpu_driver()
	instance := contract.create_instance()
	app.surface = wgpu_backend.create_surface(instance, app.window.handle)
	app.device, app.queue = contract.request_device(instance, app.surface)
	app.format = contract.get_preferred_format(app.surface, app.device)

	helper.window_update_pixel_size(&app.window)
	app.screen_w = f32(app.window.pixel_w)
	app.screen_h = f32(app.window.pixel_h)
	contract.configure_surface(app.surface, app.device, app.format, u32(app.screen_w), u32(app.screen_h))

	bar_rect: [4]f32 = {78.0, 0.0, app.screen_w - 78.0, CHROME_BAR_HEIGHT}
	tabs_feat.tabs_manager_init(&app.tabs_mgr, bar_rect)
	mux_feat.multiplexer_init(&app.mux)
	inter_feat.interaction_init(&app.inter, cell_w = CELL_WIDTH, cell_h = CELL_HEIGHT)

	shell := os.get_env("SHELL", context.temp_allocator)
	if len(shell) == 0 do shell = "/bin/sh"

	term_cols := max(20, int((app.screen_w - 24.0) / CELL_WIDTH))
	term_rows := max(10, int((app.screen_h - CHROME_BAR_HEIGHT - 16.0) / CELL_HEIGHT))
	cfg := sess_feat.Session_Config{shell = shell, rows = term_rows, cols = term_cols}
	p_term, err := mux_feat.multiplexer_create_terminal_pane(&app.mux, cfg)
	if err != .None do return false
	app.primary_pane = p_term

	app.threed_pane = mux_feat.multiplexer_create_3d_pane(&app.mux)
	tabs_feat.tabs_manager_create_tab(&app.tabs_mgr, "Terminal", app.primary_pane)
	chrome_splits.split_node_split(app.tabs_mgr.entries[0].split_tree, .Horizontal, 0.65, app.threed_pane)
	mux_feat.multiplexer_focus_pane(&app.mux, app.primary_pane)
	mux_feat.multiplexer_toggle_zoom(&app.mux, app.primary_pane) // Default full screen terminal

	if len(initial_cmd) > 0 {
		p := mux_feat.multiplexer_get_pane(&app.mux, app.primary_pane)
		if p != nil && p.session != nil {
			sess_feat.session_write_string(p.session, fmt.tprintfln("%s\n", initial_cmd))
		}
	}

	chrome_render.chrome_renderer_init(&app.chrome_rend, app.device, app.queue, u32(app.screen_w), u32(app.screen_h), app.format)
	wgpu_dev := wgpu.Device(rawptr(app.device))
	wgpu_q := wgpu.Queue(rawptr(app.queue))
	wgpu_fmt := wgpu.TextureFormat.BGRA8Unorm when ODIN_OS == .Darwin else wgpu.TextureFormat.RGBA8Unorm
	three_d.three_d_init(&app.three_d_rend, wgpu_dev, wgpu_q, wgpu_fmt, u32(app.screen_w * 0.35), u32(app.screen_h - CHROME_BAR_HEIGHT))
	chrome_dl.ui_draw_list_init(&app.draw_list)
	pipeline.composer_pipeline_init(&app.composer_pipe, app.device, app.queue, app.format, app.screen_w, app.screen_h)

	if !init_terminal_renderer(app) do return false

	app.running = true
	return true
}

app_destroy :: proc(app: ^Term_App) {
	if app == nil do return
	destroy_terminal_renderer(app)
	pipeline.composer_pipeline_destroy(&app.composer_pipe)
	chrome_dl.ui_draw_list_destroy(&app.draw_list)
	three_d.three_d_destroy(&app.three_d_rend)
	chrome_render.chrome_renderer_destroy(&app.chrome_rend)
	mux_feat.multiplexer_destroy(&app.mux)
	tabs_feat.tabs_manager_destroy(&app.tabs_mgr)
	helper.window_destroy(&app.window)
}

app_process_events :: proc(app: ^Term_App) {
	event: sdl3.Event
	for sdl3.PollEvent(&event) {
		#partial switch event.type {
		case .QUIT:
			app.running = false
		case .WINDOW_RESIZED, .WINDOW_PIXEL_SIZE_CHANGED:
			helper.window_update_pixel_size(&app.window)
			app.screen_w = f32(app.window.pixel_w)
			app.screen_h = f32(app.window.pixel_h)
			contract.configure_surface(app.surface, app.device, app.format, u32(app.screen_w), u32(app.screen_h))
			pipeline.composer_pipeline_resize(&app.composer_pipe, app.screen_w, app.screen_h)
			chrome_render.chrome_renderer_resize(&app.chrome_rend, u32(app.screen_w), u32(app.screen_h))
			app.tabs_mgr.model.bar_rect = {78.0, 0.0, app.screen_w - 78.0, CHROME_BAR_HEIGHT}
		case .TEXT_INPUT:
			p := mux_feat.multiplexer_get_focused_pane(&app.mux)
			if p != nil && p.session != nil {
				txt := string(event.text.text)
				sess_feat.session_write_string(p.session, txt)
			}
		case .KEY_DOWN:
			app_handle_key(app, event.key.key, event.key.mod)
		case .MOUSE_BUTTON_DOWN:
			mx := f32(event.button.x)
			my := f32(event.button.y)

			// Clicked New Tab Button [+]
			tab_cnt := f32(len(app.tabs_mgr.entries))
			btn_plus_x := 82.0 + tab_cnt * (160.0 + 4.0) + 4.0
			if my >= 7.0 && my <= 31.0 && mx >= btn_plus_x && mx <= btn_plus_x + 24.0 {
				shell := os.get_env("SHELL", context.temp_allocator)
				if len(shell) == 0 do shell = "/bin/sh"
				new_cols := max(20, int((app.screen_w - 24.0) / CELL_WIDTH))
				new_rows := max(10, int((app.screen_h - CHROME_BAR_HEIGHT - 16.0) / CELL_HEIGHT))
				new_p, _ := mux_feat.multiplexer_create_terminal_pane(&app.mux, {shell = shell, rows = new_rows, cols = new_cols})
				tabs_feat.tabs_manager_create_tab(&app.tabs_mgr, "Shell", new_p)
			}

			// Clicked 3D Toggle Pill (Top-Right)
			if my >= 7.0 && my <= 31.0 && mx >= app.screen_w - 116.0 && mx <= app.screen_w - 12.0 {
				mux_feat.multiplexer_toggle_zoom(&app.mux, app.primary_pane)
			}

			// Clicked 3D Header Close Button [x]
			p3 := mux_feat.multiplexer_get_pane(&app.mux, app.threed_pane)
			if p3 != nil && p3.rect[2] > 50 {
				close_3d_x := p3.rect[0] + p3.rect[2] - 28.0
				if my >= p3.rect[1] + 4.0 && my <= p3.rect[1] + 24.0 && mx >= close_3d_x && mx <= close_3d_x + 24.0 {
					mux_feat.multiplexer_toggle_zoom(&app.mux, app.primary_pane)
				}
			}

			mods: inter_feat.Modifier_Flags
			if (sdl3.GetModState() & sdl3.KMOD_SHIFT) != {} do mods += {.Shift}
			_ = inter_feat.interaction_on_mouse_down(&app.inter, &app.tabs_mgr, &app.mux, {mx, my}, int(event.button.button), mods)
		case .MOUSE_MOTION:
			mods: inter_feat.Modifier_Flags
			if (sdl3.GetModState() & sdl3.KMOD_SHIFT) != {} do mods += {.Shift}
			inter_feat.interaction_on_mouse_move(&app.inter, &app.mux, {f32(event.motion.x), f32(event.motion.y)}, mods)
		case .MOUSE_BUTTON_UP:
			inter_feat.interaction_on_mouse_up(&app.inter, &app.mux, int(event.button.button))
		case .MOUSE_WHEEL:
			inter_feat.interaction_on_mouse_wheel(&app.inter, &app.mux, f32(event.wheel.y))
		}
	}
}

app_run :: proc(app: ^Term_App) {
	last_time := time.now()
	for app.running {
		now := time.now()
		dt := f32(time.duration_seconds(time.diff(last_time, now)))
		last_time = now
		app.time_elapsed += dt

		app_process_events(app)
		_ = mux_feat.multiplexer_drain_all(&app.mux)

		content_area: [4]f32 = {0.0, CHROME_BAR_HEIGHT, app.screen_w, app.screen_h - CHROME_BAR_HEIGHT}
		tabs_feat.tabs_manager_update_layout(&app.tabs_mgr, content_area)
		_, active_tab := tabs_feat.tabs_manager_get_active(&app.tabs_mgr)
		if active_tab != nil && active_tab.split_tree != nil {
			mux_feat.multiplexer_sync_split_rects(&app.mux, active_tab.split_tree)
		}

		for &pane in app.mux.panes {
			if pane.kind == .Terminal && pane.session != nil && pane.rect[2] > 20 && pane.rect[3] > 20 {
				cols := max(10, int((pane.rect[2] - 24.0) / CELL_WIDTH))
				rows := max(4, int((pane.rect[3] - 16.0) / CELL_HEIGHT))
				if cols != pane.session.term.cols || rows != pane.session.term.rows {
					sess_feat.session_resize(pane.session, u16(cols), u16(rows))
				}
			}
		}

		p3 := mux_feat.multiplexer_get_pane(&app.mux, app.threed_pane)
		if p3 != nil && p3.rect[2] > 50 do three_d.interactor_update(&p3.interactor, dt)

		app_render_frame(app)
		time.sleep(8 * time.Millisecond) // 120 Hz pace
	}
}

main :: proc() {
	cmd := ""
	for i := 1; i < len(os.args); i += 1 {
		arg := os.args[i]
		if arg == "-v" || arg == "--version" {
			fmt.printfln("Term %s (OS-Style Layer Compositor Architecture)", VERSION)
			return
		} else if arg == "-h" || arg == "--help" {
			fmt.println("Usage: term [options]")
			fmt.println("  -e <cmd>        Execute command in initial shell")
			fmt.println("  -v, --version   Print version information")
			fmt.println("  -h, --help      Show help")
			return
		} else if arg == "-e" && i + 1 < len(os.args) {
			cmd = os.args[i + 1]
			i += 1
		}
	}

	app := new(Term_App)
	defer free(app)

	if !app_init(app, cmd) {
		fmt.eprintln("Failed to initialize Term application")
		os.exit(1)
	}
	defer app_destroy(app)

	app_run(app)
}
