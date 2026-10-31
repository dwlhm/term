package term

// Term Production Coordinator Shell (<260 lines)
// Part of Tier 3 Application Shell (src/app/term/*).
// Invariant: Anti-God Module, Zero Monolithic Logic.

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "vendor:sdl3"

import plat_win "../../platform/window"
import plat_clip "../../platform/clipboard"
import plat_font "../../platform/font"
import plat_pty "../../platform/pty"
import plat_ipc "../../platform/ipc"
import contract "../../core/render/contract"
import damage "../../core/terminal/damage"
import chrome_render "../../core/render/chrome"
import wgpu_backend "../../platform/gpu/wgpu"
import tabs_feat "../../features/tabs"
import mux_feat "../../features/multiplexer"
import sess_feat "../../features/session"
import telemetry "../../features/telemetry"

VERSION: string : "2.1.1"

Term_App :: struct {
	config:        App_Config,
	window:        plat_win.Window,
	surface:       rawptr,
	instance:      rawptr,
	device:        contract.Gpu_Device,
	queue:         contract.Gpu_Queue,
	format:        contract.Gpu_Format,
	running:       bool,
	role:          Instance_Role,
	window_hidden: bool, // set by app_request_hide; rendering and blink ticks stop while true
	quit_requested: bool, // atomic; set by the signal thread, consumed by app_run
	signals:       Signal_Router,
	control:       ^plat_ipc.Ipc_Server, // nil unless Primary with a bound control socket
	time_elapsed:  f32,
	start_time:    time.Time,

	layout:            Layout_State,
	text_atlas:        plat_font.Text_Atlas,
	current_font_size: f32,
	term_view:         Terminal_View,
	chrome_view:   Chrome_View,
	composer:      Composer_View,
	mouse:         Mouse_State,
	cursor:        Cursor_State,
	clipboard:     Clipboard_Bridge,
	search:        Search_State,
	cmd_center:    Command_Center_State,

	tabs_mgr:      tabs_feat.Tabs_Manager,
	mux:           mux_feat.Multiplexer,
	diag:          Diagnostics,
	sync_output:   Sync_Output_State,
	session_reg:   sess_feat.Session_Registry,
	last_title_sync: time.Time,
	window_focused:            bool,
	pty_wakeup_pending:        bool,
	last_frame_acquire_failed: bool,
	in_event_watch:  bool,
	resize_pending:  bool,
	// Set when a key event was already encoded byte-exactly (Alt/Option combos),
	// so the follow-up TEXT_INPUT for the same keystroke is not sent twice.
	suppress_text_input: bool,
	scroll_speed:  f32,
	default_cwd:   string,
	hyperlink_openable_bg: [4]f32,
	hyperlink_blocked_bg:  [4]f32,
	drop_effect:           Drop_Effect_State,
}

app_apply_config :: proc(app: ^Term_App, opts: Cli_Options = {}) {
	if app == nil do return

	app.scroll_speed = config_resolve_scroll_multiplier(&app.config)
	if opts.scroll_speed_override > 0.0 {
		app.scroll_speed = opts.scroll_speed_override
	}
	app.hyperlink_openable_bg, app.hyperlink_blocked_bg = config_resolve_hyperlink_colors(&app.config)
	drop_effect_set_enabled(&app.drop_effect, config_resolve_drop_animation(&app.config))

	scale := app.window.pixel_ratio if app.window.pixel_ratio > 0 else 1.0
	pad_x, pad_y := config_resolve_padding(&app.config)
	app.layout.metrics.pane_pad_x = pad_x * scale
	app.layout.metrics.pane_pad_y = pad_y * scale
	app.mouse.pad_x = app.layout.metrics.pane_pad_x
	app.mouse.pad_y = app.layout.metrics.pane_pad_y

	blur_enabled := config_resolve_window_blur(&app.config)
	if opts.blur_override == 1 do blur_enabled = false
	else if opts.blur_override == 2 do blur_enabled = true

	opacity := config_resolve_window_opacity(&app.config)
	if opts.opacity_override >= 0.0 do opacity = clamp(opts.opacity_override, 0.0, 1.0)

	pane_opacity := config_resolve_pane_opacity(&app.config, opts.opacity_override, blur_enabled)
	if opts.pane_opacity_override >= 0.0 do pane_opacity = clamp(opts.pane_opacity_override, 0.0, 1.0)
	app.layout.metrics.pane_opacity = pane_opacity

	wgpu_backend.surface_set_transparent(app.surface, blur_enabled)
	when ODIN_OS == .Darwin {
		plat_win.platform_setup_window_vibrancy(app.window.handle, blur_enabled)
	}

	clear_col: [4]f64
	if blur_enabled {
		clear_col = {0.05, 0.06, 0.08, f64(opacity)}
	} else {
		clear_col = {0.05, 0.06, 0.08, 1.0}
	}
	composer_view_set_clear_color(&app.composer, clear_col)

	base_font_size := config_resolve_effective_font_size(&app.config)
	app_apply_font_size(app, base_font_size)

	// Theme Palette overrides
	if palette, has_palette := config_resolve_theme_palette(&app.config); has_palette {
		theme_apply_palette(palette)
		for &pane in app.mux.panes {
			if pane.kind == .Terminal && pane.session != nil {
				damage.damage_mark_all(&pane.session.term.damage)
			}
		}
	}

	// Custom Font reload if path changed
	if custom_font, ok := config_resolve_font_path(&app.config); ok {
		if custom_font != app.text_atlas.font_ctx.active_path {
			app_apply_custom_font(app, custom_font, base_font_size)
		}
	}

	app_sync_layout_and_winsize(app)
	app.layout.tab_bar_reveal_timer = 2.0
}

app_apply_custom_font :: proc(app: ^Term_App, font_path: string, size: f32) -> bool {
	if app == nil || len(font_path) == 0 do return false
	scale := app.window.pixel_ratio if app.window.pixel_ratio > 0 else 1.0
	font_size := size * scale

	err: plat_font.Font_Error
	if !plat_font.font_rasterizer_init(&app.text_atlas.font_ctx.rasterizer, font_path, font_size, &err) {
		return false
	}
	if len(app.text_atlas.font_ctx.active_path) > 0 {
		delete(app.text_atlas.font_ctx.active_path)
	}
	app.text_atlas.font_ctx.active_path = strings.clone(font_path)
	if app.text_atlas.font_ctx.rasterizer.metrics.cell_width > 0 {
		app.text_atlas.cell_w = app.text_atlas.font_ctx.rasterizer.metrics.cell_width
		app.text_atlas.cell_h = app.text_atlas.font_ctx.rasterizer.metrics.cell_height
		app.layout.metrics.cell_w = app.text_atlas.cell_w
		app.layout.metrics.cell_h = app.text_atlas.cell_h
		app.mouse.cell_w = app.text_atlas.cell_w
		app.mouse.cell_h = app.text_atlas.cell_h
	}

	plat_font.glyph_atlas_clear_and_prewarm(&app.text_atlas.glyph_atlas)
	_ = plat_font.text_atlas_upload(&app.text_atlas, app.device, app.queue)
	chrome_view_set_atlas(&app.chrome_view, app.text_atlas.glyph_view, app.text_atlas.cell_w, app.text_atlas.cell_h)

	for &pane in app.mux.panes {
		if pane.kind == .Terminal && pane.session != nil {
			damage.damage_mark_all(&pane.session.term.damage)
		}
	}
	return true
}

app_init :: proc(app: ^Term_App, opts: Cli_Options = {}) -> bool {
	diagnostics_init(&app.diag, opts)
	app.role = app_resolve_role(opts)
	app.config = config_load()
	app.default_cwd = app_resolve_initial_cwd(&app.config, opts)
	win_w, win_h := config_resolve_window_dimensions(&app.config)

	// First initialize window with user-configured bounds (or default 1280x800)
	if !plat_win.window_init(&app.window, "Term", win_w, win_h) {
		return false
	}

	plat_win.window_update_pixel_size(&app.window)
	scale := app.window.pixel_ratio
	pad_x, pad_y := config_resolve_padding(&app.config)
	blur_enabled := config_resolve_window_blur(&app.config)
	if opts.blur_override == 1 do blur_enabled = false
	else if opts.blur_override == 2 do blur_enabled = true

	pane_opacity := config_resolve_pane_opacity(&app.config, opts.opacity_override, blur_enabled)
	if opts.pane_opacity_override >= 0.0 do pane_opacity = clamp(opts.pane_opacity_override, 0.0, 1.0)
	layout_init(&app.layout, scale, pad_x, pad_y, pane_opacity)

	// In high-DPI (Retina), render surface and composition textures use full backing pixels
	app.layout.screen_w = f32(app.window.pixel_w)
	app.layout.screen_h = f32(app.window.pixel_h)

	wgpu_backend.init_wgpu_driver()
	app.instance = contract.create_instance()
	app.surface = wgpu_backend.create_surface(app.instance, app.window.handle)

	app.device, app.queue = contract.request_device(app.instance, app.surface)
	app.format = contract.get_preferred_format(app.surface, app.device)

	contract.configure_surface(app.surface, app.device, app.format, u32(app.layout.screen_w), u32(app.layout.screen_h))

	// Initialize text atlas with DPI-scaled pixel size
	base_font_size := config_resolve_effective_font_size(&app.config)
	app.current_font_size = base_font_size
	font_size := base_font_size * scale
	if !plat_font.text_atlas_init(&app.text_atlas, font_size) do return false
	if !plat_font.text_atlas_upload(&app.text_atlas, app.device, app.queue) do return false
	app.layout.metrics.cell_w = app.text_atlas.cell_w
	app.layout.metrics.cell_h = app.text_atlas.cell_h

	if !terminal_view_init(&app.term_view, app.device, app.queue, app.format, app.text_atlas.glyph_view, app.text_atlas.emoji_view) do return false
	if !chrome_view_init(&app.chrome_view, app.device, app.queue, app.format, u32(app.layout.screen_w), u32(app.layout.screen_h)) do return false
	chrome_view_set_atlas(&app.chrome_view, app.text_atlas.glyph_view, app.text_atlas.cell_w, app.text_atlas.cell_h)
	if !composer_view_init(&app.composer, app.device, app.queue, app.format, app.layout.screen_w, app.layout.screen_h) do return false

	mouse_init(&app.mouse, app.layout.metrics.cell_w, app.layout.metrics.cell_h, app.layout.metrics.pane_pad_x, app.layout.metrics.pane_pad_y)
	cursor_init(&app.cursor)
	clipboard_init(&app.clipboard, plat_clip.clipboard_set_text, plat_clip.clipboard_get_text, plat_clip.clipboard_has_text)
	command_center_init(&app.cmd_center)
	drop_effect_init(&app.drop_effect, config_resolve_drop_animation(&app.config))

	app_apply_config(app, opts)

	tabs_feat.tabs_manager_init(&app.tabs_mgr, layout_compute_tab_bar_rect(&app.layout))
	mux_feat.multiplexer_init(&app.mux)
	sess_feat.session_registry_init(&app.session_reg)

	// Create initial terminal pane & tab strictly inside content_area (below top bar!)
	content_area := layout_compute_content_area(&app.layout)
	term_cols := max(20, int((content_area[2] - 2.0 * app.layout.metrics.pane_pad_x) / app.layout.metrics.cell_w))
	term_rows := max(10, int((content_area[3] - 2.0 * app.layout.metrics.pane_pad_y) / app.layout.metrics.cell_h))
	p_term, ok := app_spawn_terminal_pane(app, term_rows, term_cols)
	if !ok do return false

	tabs_feat.tabs_manager_create_tab(&app.tabs_mgr, "Shell", p_term)
	mux_feat.multiplexer_focus_pane(&app.mux, p_term)

	// Partition split tree with content_area immediately so frame 0 has exact geometry
	if len(app.tabs_mgr.entries) > 0 && app.tabs_mgr.entries[0].split_tree != nil {
		layout_split_tree_with_uniform_gaps(app.tabs_mgr.entries[0].split_tree, content_area, app.layout.metrics.pane_gap)
		mux_feat.multiplexer_sync_split_rects(&app.mux, app.tabs_mgr.entries[0].split_tree)
	}

	if len(opts.initial_cmd) > 0 {
		p := mux_feat.multiplexer_get_pane(&app.mux, p_term)
		if p != nil && p.session != nil {
			sess_feat.session_write_string(p.session, fmt.tprintf("%s\n", opts.initial_cmd))
		}
	}

	app.running = true
	app.window_focused = true
	app.start_time = time.now()
	plat_pty.pty_set_wakeup_callback(app_pty_wakeup_callback, app)
	_ = signals_start(&app.signals, app)
	_ = sdl3.AddEventWatch(app_event_watch, app)
	return true
}

app_destroy :: proc(app: ^Term_App) {
	if app == nil do return
	app.running = false
	plat_pty.pty_set_wakeup_callback(nil, nil)
	signals_stop(&app.signals)
	sdl3.RemoveEventWatch(app_event_watch, app)

	// Immediately hide the native window so clicking the red traffic light or pressing Cmd+Q
	// gives instant visual closure before GPU and PTY teardown runs.
	if app.window.handle != nil {
		_ = sdl3.HideWindow(app.window.handle)
		sdl3.PumpEvents()
	}

	sess_feat.session_registry_destroy(&app.session_reg)
	diagnostics_shutdown(app)
	mux_feat.multiplexer_destroy(&app.mux)
	tabs_feat.tabs_manager_destroy(&app.tabs_mgr)

	// Drain any in-flight GPU work before releasing textures, views, and surface.
	if contract.wait_for_idle != nil && rawptr(app.device) != nil {
		_ = contract.wait_for_idle(app.device)
	}

	composer_view_destroy(&app.composer)
	chrome_view_destroy(&app.chrome_view)
	terminal_view_destroy(&app.term_view)
	plat_font.text_atlas_destroy(&app.text_atlas)

	// Tear down the GPU backend in reverse acquisition order. The queue is owned
	// by the device and released together with it.
	wgpu_backend.destroy_surface(app.surface)
	app.surface = nil
	if contract.destroy_device != nil && rawptr(app.device) != nil {
		contract.destroy_device(app.device)
		app.device = contract.Gpu_Device(nil)
	}
	if contract.destroy_instance != nil {
		contract.destroy_instance(app.instance)
		app.instance = nil
	}

	plat_win.window_destroy(&app.window)
	app_cleanup_mouse_cursors()
}

// app_sync_resize_increments keeps continuous 1-point window sizing enabled so
// macOS zoom/maximize, fullscreen, and third-party window managers never hit
// AppKit _zoomToScreen constraint loops; pane_grid_pad centers sub-cell space.
app_sync_resize_increments :: proc(app: ^Term_App) {
	if app == nil || app.window.handle == nil do return
	plat_win.platform_set_resize_increments(app.window.handle, 1.0, 1.0)
}

app_apply_font_size :: proc(app: ^Term_App, new_size: f32) {
	if app == nil || new_size <= 0 do return
	app.current_font_size = new_size
	scale := app.window.pixel_ratio if app.window.pixel_ratio > 0 else 1.0
	font_size := new_size * scale

	if !plat_font.text_atlas_set_pixel_size(&app.text_atlas, font_size, app.device, app.queue) do return
	app.layout.metrics.cell_w = app.text_atlas.cell_w
	app.layout.metrics.cell_h = app.text_atlas.cell_h
	app.mouse.cell_w = app.text_atlas.cell_w
	app.mouse.cell_h = app.text_atlas.cell_h
	chrome_view_set_atlas(&app.chrome_view, app.text_atlas.glyph_view, app.text_atlas.cell_w, app.text_atlas.cell_h)

	for &pane in app.mux.panes {
		if pane.kind == .Terminal && pane.session != nil {
			damage.damage_mark_all(&pane.session.term.damage)
		}
	}
	app_sync_resize_increments(app)
	app.layout.tab_bar_reveal_timer = 2.0
}

app_adjust_font_size :: proc(app: ^Term_App, delta: f32) {
	if app == nil do return
	new_size := clamp(app.current_font_size + delta, 8.0, 32.0)
	if new_size == app.current_font_size do return
	app_apply_font_size(app, new_size)
}

app_reset_font_size :: proc(app: ^Term_App) {
	if app == nil do return
	base_size := config_resolve_effective_font_size(&app.config)
	app_apply_font_size(app, base_size)
}

app_run :: proc(app: ^Term_App) {
	last_time := time.now()
	for app.running {
		if intrinsics.atomic_load(&app.quit_requested) {
			app_request_quit(app)
			break
		}
		has_pending := mux_feat.multiplexer_has_pending_data(&app.mux)
		events_dirty := app_process_events(app, has_pending)
		if !app.running do break

		now := time.now()
		dt := f32(time.duration_seconds(time.diff(last_time, now)))
		last_time = now
		app.time_elapsed = f32(time.duration_seconds(time.diff(app.start_time, now)))
		term_dirty := events_dirty

		layout_update(&app.layout, dt)
		drop_effect_update(&app.drop_effect, dt)

		drained := mux_feat.multiplexer_drain_all(&app.mux)
		telemetry.telemetry_add_drain(&app.diag.tel, drained)
		if drained > 0 do term_dirty = true

		reaped := app_reap_dead_sessions(app)
		if reaped do term_dirty = true
		if !app.running do break

		if app_sync_layout_and_winsize(app, drained > 0) do term_dirty = true
		diagnostics_poll(app)

		bg_drained := sess_feat.session_registry_drain_all(&app.session_reg)
		if sess_feat.session_registry_poll(&app.session_reg, bg_drained > 0) {
			chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
			term_dirty = true
		}

		now_ns := u64(time.duration_nanoseconds(time.diff(app.start_time, now)))
		if term_dirty {
			cursor_reset_blink(&app.cursor, now_ns)
		}
		cursor_damaged := app_sync_cursor_layer(app, now_ns)
		needs_frame := term_dirty || cursor_damaged || app_needs_animation(app) || app.composer.sched.force_next || app.composer.sched.damage_pending

		// Render only on real change, cursor toggle, or active animation; stay parked otherwise.
		if needs_frame && !app.window_hidden && !app_sync_output_hold(app, now) {
			frame_start := time.tick_now()
			app_render_frame(app, term_dirty)
			telemetry.telemetry_end_frame(&app.diag.tel, u64(time.tick_since(frame_start)))
		}

		free_all(context.temp_allocator)
	}
}

main :: proc() {
	_ = signals_block_quit_set()
	opts, should_continue := app_parse_cli_args(os.args)
	if !should_continue do return

	app := new(Term_App)
	defer free(app)

	if !app_init(app, opts) {
		fmt.eprintln("Failed to initialize Term application")
		app_destroy(app) // Release whatever was initialized before the failure.
		os.exit(1)
	}
	defer app_destroy(app)

	app_run(app)
}
