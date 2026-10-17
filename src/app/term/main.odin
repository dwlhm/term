package term

// Term Production Coordinator Shell (<260 lines)
// Part of Tier 3 Application Shell (src/app/term/*).
// Invariant: Anti-God Module, Zero Monolithic Logic.

import "core:fmt"
import "core:os"
import "core:time"

import plat_win "../../platform/window"
import plat_clip "../../platform/clipboard"
import plat_font "../../platform/font"
import contract "../../core/render/contract"
import damage "../../core/terminal/damage"
import wgpu_backend "../../platform/gpu/wgpu"
import tabs_feat "../../features/tabs"
import mux_feat "../../features/multiplexer"
import sess_feat "../../features/session"

VERSION: string : "2.1.0"

Term_App :: struct {
	config:        App_Config,
	window:        plat_win.Window,
	surface:       rawptr,
	instance:      rawptr,
	device:        contract.Gpu_Device,
	queue:         contract.Gpu_Queue,
	format:        contract.Gpu_Format,
	running:       bool,
	time_elapsed:  f32,

	layout:            Layout_State,
	text_atlas:        plat_font.Text_Atlas,
	current_font_size: f32,
	term_view:         Terminal_View,
	chrome_view:   Chrome_View,
	composer:      Composer_View,
	mouse:         Mouse_State,
	cursor:        Cursor_State,
	clipboard:     Clipboard_Bridge,
	cmd_center:    Command_Center_State,

	tabs_mgr:      tabs_feat.Tabs_Manager,
	mux:           mux_feat.Multiplexer,
}

app_init :: proc(app: ^Term_App, initial_cmd: string = "") -> bool {
	app.config = config_load()
	win_w, win_h := config_resolve_window_dimensions(&app.config)

	// First initialize window with user-configured bounds (or default 1280x800)
	if !plat_win.window_init(&app.window, "Term", win_w, win_h) {
		return false
	}

	plat_win.window_update_pixel_size(&app.window)
	scale := app.window.pixel_ratio
	pad_x, pad_y := config_resolve_padding(&app.config)
	layout_init(&app.layout, scale, pad_x, pad_y)

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
	if !composer_view_init(&app.composer, app.device, app.queue, app.format, app.layout.screen_w, app.layout.screen_h) do return false

	mouse_init(&app.mouse, app.layout.metrics.cell_w, app.layout.metrics.cell_h, app.layout.metrics.pane_pad_x, app.layout.metrics.pane_pad_y)
	cursor_init(&app.cursor)
	clipboard_init(&app.clipboard, plat_clip.clipboard_set_text, plat_clip.clipboard_get_text, plat_clip.clipboard_has_text)
	command_center_init(&app.cmd_center)

	tabs_feat.tabs_manager_init(&app.tabs_mgr, layout_compute_tab_bar_rect(&app.layout))
	mux_feat.multiplexer_init(&app.mux)

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

	if len(initial_cmd) > 0 {
		p := mux_feat.multiplexer_get_pane(&app.mux, p_term)
		if p != nil && p.session != nil {
			sess_feat.session_write_string(p.session, fmt.tprintf("%s\n", initial_cmd))
		}
	}

	app.running = true
	return true
}

app_destroy :: proc(app: ^Term_App) {
	if app == nil do return
	mux_feat.multiplexer_destroy(&app.mux)
	tabs_feat.tabs_manager_destroy(&app.tabs_mgr)
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

	for &pane in app.mux.panes {
		if pane.kind == .Terminal && pane.session != nil {
			damage.damage_mark_all(&pane.session.term.damage)
		}
	}
	app.layout.tab_bar_force = true
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
		now := time.now()
		dt := f32(time.duration_seconds(time.diff(last_time, now)))
		last_time = now
		app.time_elapsed += dt

		layout_update(&app.layout, dt)
		dirty := app_process_events(app)
		if !app.running do break

		if mux_feat.multiplexer_drain_all(&app.mux) > 0 do dirty = true

		if app_sync_layout_and_winsize(app) do dirty = true

		// Render only on real change or active animation; stay idle otherwise.
		if dirty || app_needs_animation(app) {
			app_render_frame(app)
		}
	}
}

// app_parse_cli_args parses command-line arguments.
// Returns should_continue = false if the application handled -v or -h and should terminate.
app_parse_cli_args :: proc(args: []string) -> (initial_cmd: string, should_continue: bool) {
	for i := 1; i < len(args); i += 1 {
		arg := args[i]
		if arg == "-v" || arg == "--version" {
			fmt.printfln("Term %s (Modern Floating Card Compositor Architecture)", VERSION)
			return "", false
		} else if arg == "-h" || arg == "--help" {
			fmt.println("Usage: term [options]")
			fmt.println("  -e <cmd>        Execute command in initial shell")
			fmt.println("  -v, --version   Print version information")
			fmt.println("  -h, --help      Show help")
			return "", false
		} else if arg == "-e" && i + 1 < len(args) {
			initial_cmd = args[i + 1]
			i += 1
		}
	}
	return initial_cmd, true
}

main :: proc() {
	cmd, should_continue := app_parse_cli_args(os.args)
	if !should_continue do return

	app := new(Term_App)
	defer free(app)

	if !app_init(app, cmd) {
		fmt.eprintln("Failed to initialize Term application")
		app_destroy(app) // Release whatever was initialized before the failure.
		os.exit(1)
	}
	defer app_destroy(app)

	app_run(app)
}
