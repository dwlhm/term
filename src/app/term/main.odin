package term

// Term Production Coordinator Shell (<260 lines)
// Part of Tier 3 Application Shell (src/app/term/*).
// Invariant: Anti-God Module, Zero Monolithic Logic.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:time"
import "vendor:sdl3"

import helper "../../cmd/harness_helper"
import contract "../../core/render/contract"
import wgpu_backend "../../core/platform/gpu/wgpu"
import chrome_splits "../../core/chrome/splits"
import tabs_feat "../../features/tabs"
import mux_feat "../../features/multiplexer"
import sess_feat "../../features/session"
import terminal_grid "../../core/terminal/grid"

VERSION: string : "2.1.0"

Term_App :: struct {
	window:        helper.Window,
	surface:       rawptr,
	device:        contract.Gpu_Device,
	queue:         contract.Gpu_Queue,
	format:        contract.Gpu_Format,
	running:       bool,
	time_elapsed:  f32,

	layout:        Layout_State,
	font_ctx:      Font_Context,
	glyph_atlas:   Glyph_Atlas_Manager,
	emoji_atlas:   Emoji_Atlas_Manager,
	term_view:     Terminal_View,
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
	// First initialize window with standard logical bounds to query display DPI
	if !helper.window_init(&app.window, "Term", 1280, 800) {
		return false
	}

	helper.window_update_pixel_size(&app.window)
	scale := app.window.pixel_ratio
	layout_init(&app.layout, scale)

	// In high-DPI (Retina), render surface and composition textures use full backing pixels
	app.layout.screen_w = f32(app.window.pixel_w)
	app.layout.screen_h = f32(app.window.pixel_h)

	wgpu_backend.init_wgpu_driver()
	instance := contract.create_instance()
	app.surface = wgpu_backend.create_surface(instance, app.window.handle)
	app.device, app.queue = contract.request_device(instance, app.surface)
	app.format = contract.get_preferred_format(app.surface, app.device)

	contract.configure_surface(app.surface, app.device, app.format, u32(app.layout.screen_w), u32(app.layout.screen_h))

	// Initialize font context with DPI-scaled pixel size (32px on 2x Retina, 16px on 1x)
	font_size := 16.0 * scale
	font_context_init(&app.font_ctx, font_size)
	if app.font_ctx.has_font && app.font_ctx.rasterizer.metrics.cell_width > 0 {
		app.layout.metrics.cell_w = app.font_ctx.rasterizer.metrics.cell_width
		app.layout.metrics.cell_h = app.font_ctx.rasterizer.metrics.cell_height
	}
	if !glyph_atlas_init(&app.glyph_atlas, &app.font_ctx) do return false
	if !glyph_atlas_upload(&app.glyph_atlas, app.device, app.queue) do return false
	if !emoji_atlas_init(&app.emoji_atlas, font_size) do return false
	if !emoji_atlas_upload(&app.emoji_atlas, app.device, app.queue) do return false

	if !terminal_view_init(&app.term_view, app.device, app.queue, app.format, app.glyph_atlas.atlas.gpu_view, app.emoji_atlas.gpu_view) do return false
	if !chrome_view_init(&app.chrome_view, app.device, app.queue, app.format, u32(app.layout.screen_w), u32(app.layout.screen_h)) do return false
	if !composer_view_init(&app.composer, app.device, app.queue, app.format, app.layout.screen_w, app.layout.screen_h) do return false

	mouse_init(&app.mouse, app.layout.metrics.cell_w, app.layout.metrics.cell_h, app.layout.metrics.pane_pad_x, app.layout.metrics.pane_pad_y)
	cursor_init(&app.cursor)
	clipboard_init(&app.clipboard)
	command_center_init(&app.cmd_center)

	tabs_feat.tabs_manager_init(&app.tabs_mgr, layout_compute_tab_bar_rect(&app.layout))
	mux_feat.multiplexer_init(&app.mux)

	// Create initial terminal pane & tab strictly inside content_area (below top bar!)
	shell := os.get_env("SHELL", context.temp_allocator)
	if len(shell) == 0 do shell = "/bin/sh"

	content_area := layout_compute_content_area(&app.layout)
	term_cols := max(20, int((content_area[2] - 2.0 * app.layout.metrics.pane_pad_x) / app.layout.metrics.cell_w))
	term_rows := max(10, int((content_area[3] - 2.0 * app.layout.metrics.pane_pad_y) / app.layout.metrics.cell_h))
	p_term, err := mux_feat.multiplexer_create_terminal_pane(&app.mux, {shell = shell, rows = term_rows, cols = term_cols})
	if err != .None do return false

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
			sess_feat.session_write_string(p.session, fmt.tprintfln("%s\n", initial_cmd))
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
	glyph_atlas_destroy(&app.glyph_atlas)
	emoji_atlas_destroy(&app.emoji_atlas)
	font_context_destroy(&app.font_ctx)
	helper.window_destroy(&app.window)
}

app_execute_action :: proc(app: ^Term_App, act: Action_Id) {
	#partial switch act {
	case .Command_Center_Toggle:
		command_center_toggle(&app.cmd_center)
	case .Tab_New:
		shell := os.get_env("SHELL", context.temp_allocator)
		if len(shell) == 0 do shell = "/bin/sh"
		new_p, _ := mux_feat.multiplexer_create_terminal_pane(&app.mux, {shell = shell, rows = 24, cols = 80})
		tabs_feat.tabs_manager_create_tab(&app.tabs_mgr, "Shell", new_p)
		mux_feat.multiplexer_focus_pane(&app.mux, new_p)
		app.layout.tab_bar_force = true
	case .Tab_Close:
		act_idx, _ := tabs_feat.tabs_manager_get_active(&app.tabs_mgr)
		if act_idx >= 0 do tabs_feat.tabs_manager_close_tab(&app.tabs_mgr, act_idx)
	case .Tab_Next:
		cnt := len(app.tabs_mgr.entries)
		if cnt > 0 {
			next_idx := (app.tabs_mgr.model.active_idx + 1) % cnt
			tabs_feat.tabs_manager_select_tab(&app.tabs_mgr, next_idx)
		}
		app.layout.tab_bar_force = true
	case .Tab_Prev:
		cnt := len(app.tabs_mgr.entries)
		if cnt > 0 {
			prev_idx := (app.tabs_mgr.model.active_idx - 1 + cnt) % cnt
			tabs_feat.tabs_manager_select_tab(&app.tabs_mgr, prev_idx)
		}
		app.layout.tab_bar_force = true
	case .Tab_Select_1, .Tab_Select_2, .Tab_Select_3, .Tab_Select_4, .Tab_Select_5, .Tab_Select_6, .Tab_Select_7, .Tab_Select_8, .Tab_Select_9:
		idx := int(act) - int(Action_Id.Tab_Select_1)
		tabs_feat.tabs_manager_select_tab(&app.tabs_mgr, idx)
		app.layout.tab_bar_force = true
	case .Pane_Split_Right:
		shell := os.get_env("SHELL", context.temp_allocator)
		if len(shell) == 0 do shell = "/bin/sh"
		new_p, _ := mux_feat.multiplexer_create_terminal_pane(&app.mux, {shell = shell, rows = 24, cols = 80})
		_, active_tab := tabs_feat.tabs_manager_get_active(&app.tabs_mgr)
		if active_tab != nil && active_tab.split_tree != nil {
			chrome_splits.split_node_split(active_tab.split_tree, .Horizontal, 0.5, new_p)
			mux_feat.multiplexer_focus_pane(&app.mux, new_p)
		}
	case .Pane_Split_Down:
		shell := os.get_env("SHELL", context.temp_allocator)
		if len(shell) == 0 do shell = "/bin/sh"
		new_p, _ := mux_feat.multiplexer_create_terminal_pane(&app.mux, {shell = shell, rows = 24, cols = 80})
		_, active_tab := tabs_feat.tabs_manager_get_active(&app.tabs_mgr)
		if active_tab != nil && active_tab.split_tree != nil {
			chrome_splits.split_node_split(active_tab.split_tree, .Vertical, 0.5, new_p)
			mux_feat.multiplexer_focus_pane(&app.mux, new_p)
		}
	case .Pane_Focus_Next:
		mux_feat.multiplexer_cycle_focus(&app.mux)
	case .Pane_Toggle_Zoom:
		p := mux_feat.multiplexer_get_focused_pane(&app.mux)
		if p != nil do mux_feat.multiplexer_toggle_zoom(&app.mux, p.id)
	case .Clipboard_Copy:
		p := mux_feat.multiplexer_get_focused_pane(&app.mux)
		if p != nil && p.session != nil {
			_ = clipboard_copy_selection(&app.clipboard, p.session, app.mouse.selection)
		}
	case .Clipboard_Paste:
		p := mux_feat.multiplexer_get_focused_pane(&app.mux)
		if p != nil && p.session != nil {
			_ = clipboard_paste(p.session)
		}
	case .Scroll_Page_Up:
		p := mux_feat.multiplexer_get_focused_pane(&app.mux)
		if p != nil && p.session != nil {
			page := max(1, p.session.term.rows - 2)
			p.session.scroll_offset = clamp(p.session.scroll_offset + page, 0, p.session.term.grid.history_count)
		}
	case .Scroll_Page_Down:
		p := mux_feat.multiplexer_get_focused_pane(&app.mux)
		if p != nil && p.session != nil {
			page := max(1, p.session.term.rows - 2)
			p.session.scroll_offset = clamp(p.session.scroll_offset - page, 0, p.session.term.grid.history_count)
		}
	case .Scroll_Line_Up:
		p := mux_feat.multiplexer_get_focused_pane(&app.mux)
		if p != nil && p.session != nil {
			p.session.scroll_offset = clamp(p.session.scroll_offset + 3, 0, p.session.term.grid.history_count)
		}
	case .Scroll_Line_Down:
		p := mux_feat.multiplexer_get_focused_pane(&app.mux)
		if p != nil && p.session != nil {
			p.session.scroll_offset = clamp(p.session.scroll_offset - 3, 0, p.session.term.grid.history_count)
		}
	case .Scroll_To_Top:
		p := mux_feat.multiplexer_get_focused_pane(&app.mux)
		if p != nil && p.session != nil {
			p.session.scroll_offset = p.session.term.grid.history_count
		}
	case .Scroll_To_Bottom:
		p := mux_feat.multiplexer_get_focused_pane(&app.mux)
		if p != nil && p.session != nil {
			p.session.scroll_offset = 0
		}
	case .Scroll_Clear:
		p := mux_feat.multiplexer_get_focused_pane(&app.mux)
		if p != nil && p.session != nil {
			terminal_grid.grid_clear_history(&p.session.term.grid)
			p.session.scroll_offset = 0
			sess_feat.session_write_string(p.session, "\x0c") // Form feed / clear
		}
	case .App_Quit:
		app.running = false
	}
}

app_process_events :: proc(app: ^Term_App) {
	ev: sdl3.Event
	for sdl3.PollEvent(&ev) {
		#partial switch ev.type {
		case .QUIT:
			app.running = false
		case .WINDOW_RESIZED, .WINDOW_PIXEL_SIZE_CHANGED:
			helper.window_update_pixel_size(&app.window)
			scale := app.window.pixel_ratio
			layout_set_scale(&app.layout, scale)

			// Rendering pipeline is fully in pixel space.
			app.layout.screen_w = f32(app.window.pixel_w)
			app.layout.screen_h = f32(app.window.pixel_h)
			contract.configure_surface(app.surface, app.device, app.format, u32(app.window.pixel_w), u32(app.window.pixel_h))
			composer_view_resize(&app.composer, app.layout.screen_w, app.layout.screen_h)
			chrome_view_resize(&app.chrome_view, u32(app.layout.screen_w), u32(app.layout.screen_h))

			app.mouse.cell_w = app.layout.metrics.cell_w
			app.mouse.cell_h = app.layout.metrics.cell_h
			app.mouse.pad_x = app.layout.metrics.pane_pad_x
			app.mouse.pad_y = app.layout.metrics.pane_pad_y

		case .MOUSE_MOTION:
			// SDL3 reports mouse coordinates in logical (point) space on Retina.
			// All geometry (pane.rect, tab bar rects) is in pixel space.
			// Scale by pixel_ratio to bring mouse into pixel space.
			ratio := app.window.pixel_ratio
			app.layout.mouse_y = f32(ev.motion.y) * ratio
			pane := mux_feat.multiplexer_get_focused_pane(&app.mux)
			pane_rect := pane.rect if pane != nil else [4]f32{0, 0, 0, 0}
			mouse_on_motion(&app.mouse, {f32(ev.motion.x) * ratio, f32(ev.motion.y) * ratio}, pane_rect)
		case .MOUSE_BUTTON_DOWN:
			// Scale SDL3 logical coords to pixel space (see MOUSE_MOTION comment).
			ratio := app.window.pixel_ratio
			mx := f32(ev.button.x) * ratio
			my := f32(ev.button.y) * ratio

			// Click on tab pills
			scale := app.layout.metrics.scale
			bar_h := app.layout.metrics.tab_bar_height
			tab_w := 160.0 * scale
			tab_gap := 6.0 * scale
			tabs_x := app.layout.metrics.traffic_clearance + 6.0 * scale
			if my >= 0 && my <= bar_h {
				for i in 0..<len(app.tabs_mgr.entries) {
					tab_x := tabs_x + f32(i) * (tab_w + tab_gap)
					if mx >= tab_x && mx <= tab_x + tab_w {
						if mx >= tab_x + tab_w - 24.0 * scale {
							tabs_feat.tabs_manager_close_tab(&app.tabs_mgr, i)
						} else {
							tabs_feat.tabs_manager_select_tab(&app.tabs_mgr, i)
						}
						break
					}
				}
				// Click on [+] button
				plus_x := tabs_x + f32(len(app.tabs_mgr.entries)) * (tab_w + tab_gap)
				btn_w := 28.0 * scale
				if mx >= plus_x && mx <= plus_x + btn_w {
					app_execute_action(app, .Tab_New)
				}
			}

			// Focus clicked pane & start selection
			for &p in app.mux.panes {
				if mouse_is_in_rect({mx, my}, p.rect) {
					mux_feat.multiplexer_focus_pane(&app.mux, p.id)
					mouse_on_button_down(&app.mouse, {mx, my}, u8(ev.button.button), p.id, p.rect, int(ev.button.clicks))
					break
				}
			}
		case .MOUSE_BUTTON_UP:
			mouse_on_button_up(&app.mouse, u8(ev.button.button))
		case .MOUSE_WHEEL:
			ratio := app.window.pixel_ratio
			mx := ev.wheel.mouse_x * ratio
			my := ev.wheel.mouse_y * ratio

			target_pane: ^mux_feat.Pane_Entry = nil
			for &p in app.mux.panes {
				if mouse_is_in_rect({mx, my}, p.rect) {
					target_pane = &p
					break
				}
			}
			if target_pane == nil {
				target_pane = mux_feat.multiplexer_get_focused_pane(&app.mux)
			}

			if target_pane != nil && target_pane.session != nil {
				sess := target_pane.session
				lines := int(ev.wheel.y * 3.0)
				if lines == 0 {
					if ev.wheel.y > 0 do lines = 1
					else if ev.wheel.y < 0 do lines = -1
				}

				if sess.term.parser.in_alt_screen {
					// In alternate screen (less, vim, man, nano), stream cursor keys to PTY
					up_key := "\x1bOA" if sess.term.parser.cursor_key_mode else "\x1b[A"
					down_key := "\x1bOB" if sess.term.parser.cursor_key_mode else "\x1b[B"
					if lines > 0 {
						for _ in 0..<lines {
							sess_feat.session_write_string(sess, up_key)
						}
					} else if lines < 0 {
						for _ in 0..<(-lines) {
							sess_feat.session_write_string(sess, down_key)
						}
					}
				} else {
					// In normal screen (shell CLI output), scroll viewport into scrollback history
					max_history := sess.term.grid.history_count
					sess.scroll_offset = clamp(sess.scroll_offset + lines, 0, max_history)
				}
			}
		case .TEXT_INPUT:
			if app.cmd_center.visible {
				command_center_handle_text(&app.cmd_center, string(ev.text.text))
			} else {
				p := mux_feat.multiplexer_get_focused_pane(&app.mux)
				if p != nil && p.session != nil {
					p.session.scroll_offset = 0 // Auto-scroll to bottom on input
					sess_feat.session_write_string(p.session, string(ev.text.text))
				}
			}
		case .KEY_DOWN:
			if app.cmd_center.visible {
				act, handled := command_center_handle_key(&app.cmd_center, ev.key.key)
				if act != .None do app_execute_action(app, act)
				if handled do continue
			}

			act, ok := keymap_evaluate(ev.key.key, ev.key.mod)
			if ok {
				app_execute_action(app, act)
			} else {
				res, encoded := input_encode_key(ev.key.key, ev.key.mod)
				if encoded {
					p := mux_feat.multiplexer_get_focused_pane(&app.mux)
					if p != nil && p.session != nil {
						p.session.scroll_offset = 0 // Auto-scroll to bottom on input
						_, _ = sess_feat.session_write(p.session, res.bytes[:res.len])
					}
				}
			}
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

		layout_update(&app.layout, dt)
		app_process_events(app)
		_ = mux_feat.multiplexer_drain_all(&app.mux)

		// Sync layout with uniform margin == pane gap
		content_area := layout_compute_content_area(&app.layout)
		_, active_tab := tabs_feat.tabs_manager_get_active(&app.tabs_mgr)
		if active_tab != nil && active_tab.split_tree != nil {
			layout_split_tree_with_uniform_gaps(active_tab.split_tree, content_area, app.layout.metrics.pane_gap)
			mux_feat.multiplexer_sync_split_rects(&app.mux, active_tab.split_tree)
		}

		// Winsize PTY synchronization
		for &pane in app.mux.panes {
			if pane.kind == .Terminal && pane.session != nil && pane.rect[2] > 20 && pane.rect[3] > 20 {
				cols := max(10, int((pane.rect[2] - 2.0 * app.layout.metrics.pane_pad_x) / app.layout.metrics.cell_w))
				rows := max(4, int((pane.rect[3] - 2.0 * app.layout.metrics.pane_pad_y) / app.layout.metrics.cell_h))
				if cols != pane.session.term.cols || rows != pane.session.term.rows {
					sess_feat.session_resize(pane.session, u16(cols), u16(rows))
				}
			}
		}

		// Render frame presentation
		tex, view, _ := contract.get_surface_texture(app.surface)
		if rawptr(view) != nil {
			term_layer, chrome_layer := composer_view_acquire_layers(&app.composer, app.layout.screen_w, app.layout.screen_h)

			if term_layer != nil {
				for &pane in app.mux.panes {
					if pane.kind == .Terminal && pane.session != nil && pane.rect[2] > 10 {
						terminal_view_render_pane(&app.term_view, pane.session, pane.rect, pane.is_focused, &app.mouse, app.time_elapsed, term_layer.view, &app.glyph_atlas, &app.emoji_atlas, app.layout.metrics, app.layout.screen_w, app.layout.screen_h)
					}
				}
			}

			if chrome_layer != nil {
				chrome_view_build_and_render(&app.chrome_view, &app.layout, &app.tabs_mgr, &app.mux, &app.cmd_center, &app.cursor, app.time_elapsed, chrome_layer.view)
			}

			composer_view_composite_and_present(&app.composer, app.surface, view)
			contract.release_surface_texture(tex, view)
		}

		time.sleep(8 * time.Millisecond) // 120Hz pace
	}
}

main :: proc() {
	cmd := ""
	for i := 1; i < len(os.args); i += 1 {
		arg := os.args[i]
		if arg == "-v" || arg == "--version" {
			fmt.printfln("Term %s (Modern Floating Card Compositor Architecture)", VERSION)
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
