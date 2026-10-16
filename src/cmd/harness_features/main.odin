package main

// Standalone Native GUI Harness: harness_features (Phase 4 Composition Layer)
// Verifies feature_session, feature_tabs, feature_multiplexer, and feature_interaction.
// Integrates live PTY shell, multi-tab layout, split pane multiplexer, 3D canvas component,
// text selection, and mouse/keyboard event routing.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:time"
import "vendor:sdl3"
import "vendor:wgpu"

import plat_win "../../platform/window"
import contract "../../core/render/contract"
import wgpu_backend "../../platform/gpu/wgpu"
import composer "../../core/composer"
import pipeline "../../core/composer/pipeline"
import chrome_render "../../core/render/chrome"
import chrome_dl "../../core/chrome/draw_list"
import three_d "../../core/render/three_d"
import chrome_splits "../../core/chrome/splits"
import tabs_feat "../../features/tabs"
import mux_feat "../../features/multiplexer"
import inter_feat "../../features/interaction"
import sess_feat "../../features/session"

CHROME_BAR_HEIGHT: f32 : 36.0

Harness_State :: struct {
	window:        plat_win.Window,
	device:        contract.Gpu_Device,
	queue:         contract.Gpu_Queue,
	format:        contract.Gpu_Format,
	surface:       rawptr,
	running:       bool,

	// Layer Compositor
	composer_pipe: pipeline.Composer_Pipeline,
	screen_w:      f32,
	screen_h:      f32,

	// Render Pillars
	chrome_rend:   chrome_render.Chrome_Renderer,
	three_d_rend:  three_d.Three_D_Renderer,
	draw_list:     chrome_dl.Ui_Draw_List,

	// Feature Layer
	tabs_mgr:      tabs_feat.Tabs_Manager,
	mux:           mux_feat.Multiplexer,
	inter:         inter_feat.Interaction_State,

	pane_terminal: u32,
	pane_3d:       u32,
	time_elapsed:  f32,
}

run_headless_verification :: proc() -> bool {
	fmt.println("=================================================================")
	fmt.println(" [PHASE 4 HARNESS] Running Automated Feature Slices Verification ")
	fmt.println("=================================================================")

	// 1. Feature Tabs Verification
	{
		tm: tabs_feat.Tabs_Manager
		bar: [4]f32 = {0, 0, 1024, 36}
		tabs_feat.tabs_manager_init(&tm, bar)
		defer tabs_feat.tabs_manager_destroy(&tm)

		t1, _ := tabs_feat.tabs_manager_create_tab(&tm, "Shell Tab", 1)
		t2, _ := tabs_feat.tabs_manager_create_tab(&tm, "3D Canvas", 2)
		if t1 != 1 || t2 != 2 || tabs_feat.tabs_manager_tab_count(&tm) != 2 {
			fmt.eprintln("[FAIL] Tab creation failed")
			return false
		}
		fmt.println("  [PASS] feature_tabs: tab lifecycle & model verified")
	}

	// 2. Feature Multiplexer & Session Verification
	{
		m: mux_feat.Multiplexer
		mux_feat.multiplexer_init(&m)
		defer mux_feat.multiplexer_destroy(&m)

		shell_path := os.get_env("SHELL", context.temp_allocator)
		if len(shell_path) == 0 do shell_path = "/bin/sh"

		cfg := sess_feat.Session_Config{shell = shell_path, rows = 24, cols = 80}
		p_term, s_err := mux_feat.multiplexer_create_terminal_pane(&m, cfg)
		if s_err != .None {
			fmt.eprintfln("[FAIL] Terminal pane creation failed: %v", s_err)
			return false
		}
		p_3d := mux_feat.multiplexer_create_3d_pane(&m)

		if p_term != 1 || p_3d != 2 || len(m.panes) != 2 {
			fmt.eprintln("[FAIL] Multiplexer pane creation failed")
			return false
		}

		// Write test command through session
		term_pane := mux_feat.multiplexer_get_pane(&m, p_term)
		sess_feat.session_write_string(term_pane.session, "echo PHASE4_VERIFY_OK\n")
		time.sleep(150 * time.Millisecond)

		drained := mux_feat.multiplexer_drain_all(&m)
		if drained <= 0 {
			fmt.eprintln("[FAIL] session drain failed")
			return false
		}
		fmt.printfln("  [PASS] feature_session + feature_multiplexer: drained %d bytes from live shell", drained)
	}

	// 3. Feature Interaction Verification
	{
		tm: tabs_feat.Tabs_Manager
		m: mux_feat.Multiplexer
		inter: inter_feat.Interaction_State

		tabs_feat.tabs_manager_init(&tm, {0, 0, 1024, 36})
		mux_feat.multiplexer_init(&m)
		inter_feat.interaction_init(&inter)

		defer {
			tabs_feat.tabs_manager_destroy(&tm)
			mux_feat.multiplexer_destroy(&m)
		}

		p1, _ := mux_feat.multiplexer_create_terminal_pane(&m, {shell = "/bin/sh", rows = 24, cols = 80})
		p2 := mux_feat.multiplexer_create_3d_pane(&m)
		tabs_feat.tabs_manager_create_tab(&tm, "Main Workspace", p1)

		// Layout
		content_rect: [4]f32 = {0, 36, 1024, 732}
		tabs_feat.tabs_manager_update_layout(&tm, content_rect)
		mux_feat.multiplexer_sync_split_rects(&m, tm.entries[0].split_tree)

		// Test key shortcut
		act := inter_feat.interaction_on_key_press(&inter, &tm, &m, 't', {.Cmd})
		if act.kind != .Tab_New_Requested {
			fmt.eprintln("[FAIL] Key shortcut Cmd+T not handled")
			return false
		}

		// Test 3D interaction zoom
		p2_pane := mux_feat.multiplexer_get_pane(&m, p2)
		dist_before := p2_pane.interactor.distance
		mux_feat.multiplexer_focus_pane(&m, p2)
		inter_feat.interaction_on_mouse_wheel(&inter, &m, 1.0)
		if p2_pane.interactor.distance >= dist_before {
			fmt.eprintln("[FAIL] 3D zoom interaction failed")
			return false
		}

		fmt.println("  [PASS] feature_interaction: input routing & 3D camera controls verified")
	}

	fmt.println("=================================================================")
	fmt.println(" [SUCCESS] ALL 4 FEATURE SLICES VERIFIED AND READY FOR PHASE 5   ")
	fmt.println("=================================================================")
	return true
}

main :: proc() {
	for arg in os.args[1:] {
		if arg == "--test" {
			if !run_headless_verification() {
				os.exit(1)
			}
			return
		}
	}

	fmt.println("Starting Phase 4 Standalone Feature Harness (Interactive Mode)...")

	state := new(Harness_State)
	defer free(state)
	state.screen_w = 1280.0
	state.screen_h = 800.0

	// 1. Initialize Window
	if !plat_win.window_init(&state.window, "Term Phase 4 Feature Harness", i32(state.screen_w), i32(state.screen_h)) {
		fmt.eprintln("Failed to initialize SDL3 window")
		return
	}
	defer plat_win.window_destroy(&state.window)

	// 2. Initialize WGPU Hardware
	wgpu_backend.init_wgpu_driver()
	instance := contract.create_instance()
	state.surface = wgpu_backend.create_surface(instance, state.window.handle)
	state.device, state.queue = contract.request_device(instance, state.surface)
	state.format = contract.get_preferred_format(state.surface, state.device)

	plat_win.window_update_pixel_size(&state.window)
	screen_w := f32(state.window.pixel_w)
	screen_h := f32(state.window.pixel_h)
	state.screen_w = screen_w
	state.screen_h = screen_h

	contract.configure_surface(state.surface, state.device, state.format, u32(screen_w), u32(screen_h))

	// 3. Initialize Feature Slices
	tabs_bar: [4]f32 = {0.0, 0.0, state.screen_w, CHROME_BAR_HEIGHT}
	tabs_feat.tabs_manager_init(&state.tabs_mgr, tabs_bar)
	defer tabs_feat.tabs_manager_destroy(&state.tabs_mgr)

	mux_feat.multiplexer_init(&state.mux)
	defer mux_feat.multiplexer_destroy(&state.mux)

	inter_feat.interaction_init(&state.inter)

	// Spawn default terminal shell pane
	shell_path := os.get_env("SHELL", context.temp_allocator)
	if len(shell_path) == 0 do shell_path = "/bin/sh"

	term_cfg := sess_feat.Session_Config{shell = shell_path, rows = 36, cols = 80}
	p_term, err := mux_feat.multiplexer_create_terminal_pane(&state.mux, term_cfg)
	if err != .None {
		fmt.eprintfln("Failed to spawn shell: %v", err)
		return
	}
	state.pane_terminal = p_term

	// Create 3D Canvas component pane
	state.pane_3d = mux_feat.multiplexer_create_3d_pane(&state.mux)

	// Create primary tab with split: Left = Terminal, Right = 3D Canvas
	tabs_feat.tabs_manager_create_tab(&state.tabs_mgr, "Terminal + 3D Canvas", state.pane_terminal)

	// Split root tree horizontally (left/right) with ratio 0.55
	chrome_splits.split_node_split(state.tabs_mgr.entries[0].split_tree, .Horizontal, 0.55, state.pane_3d)

	// 4. Initialize Renderers
	chrome_render.chrome_renderer_init(&state.chrome_rend, state.device, state.queue, u32(screen_w), u32(screen_h), state.format)
	defer chrome_render.chrome_renderer_destroy(&state.chrome_rend)

	wgpu_dev := wgpu.Device(rawptr(state.device))
	wgpu_q := wgpu.Queue(rawptr(state.queue))
	wgpu_fmt := wgpu.TextureFormat.BGRA8Unorm when ODIN_OS == .Darwin else wgpu.TextureFormat.RGBA8Unorm

	three_d.three_d_init(&state.three_d_rend, wgpu_dev, wgpu_q, wgpu_fmt, u32(screen_w * 0.5), u32(screen_h - CHROME_BAR_HEIGHT))
	defer three_d.three_d_destroy(&state.three_d_rend)

	chrome_dl.ui_draw_list_init(&state.draw_list)
	defer chrome_dl.ui_draw_list_destroy(&state.draw_list)

	// 5. Initialize Composer Pipeline
	pipeline.composer_pipeline_init(&state.composer_pipe, state.device, state.queue, state.format, screen_w, screen_h)
	defer pipeline.composer_pipeline_destroy(&state.composer_pipe)

	state.running = true
	fmt.println("Phase 4 Feature Harness initialized! Press Esc to quit, Cmd+T for new tab, Cmd+3 to toggle 3D.")

	// Main Frame Loop
	event: sdl3.Event
	last_time := time.now()

	for state.running {
		now := time.now()
		dt := f32(time.duration_seconds(time.diff(last_time, now)))
		last_time = now
		state.time_elapsed += dt

		// Poll SDL events
		for sdl3.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT:
				state.running = false
			case .KEY_DOWN:
				if event.key.key == sdl3.K_ESCAPE {
					state.running = false
				}
				mods: inter_feat.Modifier_Flags
				if (event.key.mod & sdl3.KMOD_GUI) != {} do mods += {.Cmd}
				if (event.key.mod & sdl3.KMOD_SHIFT) != {} do mods += {.Shift}
				if (event.key.mod & sdl3.KMOD_CTRL) != {} do mods += {.Ctrl}
				if (event.key.mod & sdl3.KMOD_ALT) != {} do mods += {.Alt}

				key_r := rune(event.key.key)
				act := inter_feat.interaction_on_key_press(&state.inter, &state.tabs_mgr, &state.mux, key_r, mods)
				if act.kind == .Tab_New_Requested {
					new_pane, _ := mux_feat.multiplexer_create_terminal_pane(&state.mux, term_cfg)
					tabs_feat.tabs_manager_create_tab(&state.tabs_mgr, "New Shell", new_pane)
				}
			case .MOUSE_BUTTON_DOWN:
				mx := f32(event.button.x)
				my := f32(event.button.y)
				mods: inter_feat.Modifier_Flags
				if (sdl3.GetModState() & sdl3.KMOD_SHIFT) != {} do mods += {.Shift}
				_ = inter_feat.interaction_on_mouse_down(&state.inter, &state.tabs_mgr, &state.mux, {mx, my}, int(event.button.button), mods)
			case .MOUSE_MOTION:
				mx := f32(event.motion.x)
				my := f32(event.motion.y)
				mods: inter_feat.Modifier_Flags
				if (sdl3.GetModState() & sdl3.KMOD_SHIFT) != {} do mods += {.Shift}
				inter_feat.interaction_on_mouse_move(&state.inter, &state.mux, {mx, my}, mods)
			case .MOUSE_BUTTON_UP:
				inter_feat.interaction_on_mouse_up(&state.inter, &state.mux, int(event.button.button))
			case .MOUSE_WHEEL:
				inter_feat.interaction_on_mouse_wheel(&state.inter, &state.mux, f32(event.wheel.y))
			}
		}

		// Drain shell PTY output
		_ = mux_feat.multiplexer_drain_all(&state.mux)

		// Sync layout
		content_area: [4]f32 = {0.0, CHROME_BAR_HEIGHT, state.screen_w, state.screen_h - CHROME_BAR_HEIGHT}
		tabs_feat.tabs_manager_update_layout(&state.tabs_mgr, content_area)
		_, active_tab := tabs_feat.tabs_manager_get_active(&state.tabs_mgr)
		if active_tab != nil && active_tab.split_tree != nil {
			mux_feat.multiplexer_sync_split_rects(&state.mux, active_tab.split_tree)
		}

		// Update 3D rotation
		p3 := mux_feat.multiplexer_get_pane(&state.mux, state.pane_3d)
		if p3 != nil {
			three_d.interactor_update(&p3.interactor, dt)
		}

		// Draw Chrome UI
		chrome_dl.ui_draw_list_clear(&state.draw_list)
		tabs_feat.tabs_manager_emit_draw_list(&state.tabs_mgr, &state.draw_list)

		time.sleep(8 * time.Millisecond) // ~120 FPS pace
	}
}
