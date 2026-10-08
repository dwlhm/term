package app_test

import "base:runtime"
import "core:os"
import "core:testing"
import app ".."
import config "../../config"
import "../../ui"
import "../../platform/input"
import termgrid "../../terminal"
import session_core "../../session_core"

make_key_event :: proc(rune_val: rune, kind: input.Input_Key_Kind = .Printable, gui: bool = false, alt: bool = false, shift: bool = false, ctrl: bool = false) -> input.Input_Event {
	return input.Input_Event{
		event_type = .Key,
		kind       = kind,
		rune       = rune_val,
		gui        = gui,
		alt        = alt,
		shift      = shift,
		ctrl       = ctrl,
		is_release = false,
	}
}

@(test)
test_multiplexer_gui_shortcut_matching :: proc(t: ^testing.T) {
	// Cmd+D -> Detach_Tab
	testing.expect(t, ui.ui_shortcut_matches(.Detach_Tab, make_key_event('d', .Printable, gui = true)))
	testing.expect(t, ui.ui_shortcut_matches(.Detach_Tab, make_key_event('D', .Printable, gui = true)))
	testing.expect(t, !ui.ui_shortcut_matches(.Detach_Tab, make_key_event('d', .Printable, gui = false)))
	testing.expect(t, !ui.ui_shortcut_matches(.Detach_Tab, make_key_event('d', .Printable, gui = true, alt = true)))
	testing.expect(t, !ui.ui_shortcut_matches(.Detach_Tab, make_key_event('d', .Printable, gui = true, shift = true)))
	testing.expect(t, !ui.ui_shortcut_matches(.Detach_Tab, make_key_event('d', .Printable, gui = true, ctrl = true)))

	// Cmd+W -> Close_Pane
	testing.expect(t, ui.ui_shortcut_matches(.Close_Pane, make_key_event('w', .Printable, gui = true)))
	testing.expect(t, ui.ui_shortcut_matches(.Close_Pane, make_key_event('W', .Printable, gui = true)))
	testing.expect(t, !ui.ui_shortcut_matches(.Close_Pane, make_key_event('w', .Printable, gui = false)))
	testing.expect(t, !ui.ui_shortcut_matches(.Close_Pane, make_key_event('w', .Printable, gui = true, shift = true)))
	testing.expect(t, !ui.ui_shortcut_matches(.Close_Pane, make_key_event('w', .Printable, gui = true, alt = true)))

	// Cmd+Shift+W -> Close_Tab
	testing.expect(t, ui.ui_shortcut_matches(.Close_Tab, make_key_event('w', .Printable, gui = true, shift = true)))
	testing.expect(t, ui.ui_shortcut_matches(.Close_Tab, make_key_event('W', .Printable, gui = true, shift = true)))
	testing.expect(t, !ui.ui_shortcut_matches(.Close_Tab, make_key_event('w', .Printable, gui = true, shift = false)))
	testing.expect(t, !ui.ui_shortcut_matches(.Close_Tab, make_key_event('w', .Printable, gui = false, shift = true)))

	// Cmd+Option+Arrows -> Spatial Pane Focus
	testing.expect(t, ui.ui_shortcut_matches(.Pane_Focus_Left, make_key_event(0, .Arrow_Left, gui = true, alt = true)))
	testing.expect(t, !ui.ui_shortcut_matches(.Pane_Focus_Left, make_key_event(0, .Arrow_Left, gui = true, alt = false)))
	testing.expect(t, ui.ui_shortcut_matches(.Pane_Focus_Right, make_key_event(0, .Arrow_Right, gui = true, alt = true)))
	testing.expect(t, !ui.ui_shortcut_matches(.Pane_Focus_Right, make_key_event(0, .Arrow_Right, gui = false, alt = true)))
	testing.expect(t, ui.ui_shortcut_matches(.Pane_Focus_Up, make_key_event(0, .Arrow_Up, gui = true, alt = true)))
	testing.expect(t, !ui.ui_shortcut_matches(.Pane_Focus_Up, make_key_event(0, .Arrow_Up, gui = true, alt = false)))
	testing.expect(t, ui.ui_shortcut_matches(.Pane_Focus_Down, make_key_event(0, .Arrow_Down, gui = true, alt = true)))
	testing.expect(t, !ui.ui_shortcut_matches(.Pane_Focus_Down, make_key_event(0, .Arrow_Down, gui = true, alt = false)))

	// Cmd+T -> New_Tab
	testing.expect(t, ui.ui_shortcut_matches(.New_Tab, make_key_event('t', .Printable, gui = true)))
	testing.expect(t, ui.ui_shortcut_matches(.New_Tab, make_key_event('T', .Printable, gui = true)))
	testing.expect(t, !ui.ui_shortcut_matches(.New_Tab, make_key_event('t', .Printable, gui = false)))

	// Labels
	testing.expect_value(t, ui.ui_shortcut_label(.Detach_Tab), "\u2318D")
	testing.expect_value(t, ui.ui_shortcut_label(.Close_Pane), "\u2318W")
	testing.expect_value(t, ui.ui_shortcut_label(.Close_Tab), "\u21E7\u2318W")
	testing.expect_value(t, ui.ui_shortcut_label(.Pane_Focus_Left), "\u2325\u2318\u2190")
	testing.expect_value(t, ui.ui_shortcut_label(.Pane_Focus_Right), "\u2325\u2318\u2192")
	testing.expect_value(t, ui.ui_shortcut_label(.Pane_Focus_Up), "\u2325\u2318\u2191")
	testing.expect_value(t, ui.ui_shortcut_label(.Pane_Focus_Down), "\u2325\u2318\u2193")
}

@(test)
test_session_detach_tab_multipane_succeeds :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	sm: app.Session_Manager
	app.session_manager_init(&sm, 8)
	reg: session_core.Session_Registry
	session_core.session_registry_init(&reg)
	sm.registry = &reg
	defer session_core.session_registry_destroy(&reg)
	defer app.session_manager_destroy(&sm)

	idx, spawned := app.session_spawn(&sm, "/bin/sleep", {"30"}, 24, 80, nil, termgrid.Theme{})
	testing.expect(t, spawned, "session_spawn must succeed")

	tab := &sm.tabs[idx]
	testing.expect(t, tab.tree.root != nil, "root pane must exist")

	b2 := new(app.Backend)
	init_ok := app.backend_init(b2, 24, 40, "/bin/sleep", {"30"}, nil, termgrid.Theme{})
	testing.expect(t, init_ok, "backend_init for second pane must succeed")

	_, split_ok := app.pane_tree_split(&tab.tree, tab.tree.root.id, .Vertical, b2)
	testing.expect(t, split_ok, "pane_tree_split must succeed")
	testing.expect(t, tab.tree.node_count > 1, "split tab must have multiple nodes")

	// Detach must succeed on multi-pane tab (no longer rejected with singleton restriction)
	detach_ok := app.session_detach_tab(&sm, idx)
	testing.expect(t, detach_ok, "detach must succeed on multi-pane tab")
	testing.expect_value(t, len(sm.tabs), 0)

	popped := session_core.session_registry_pop_latest_detached(&reg)
	if popped != nil {
		session_core.session_destroy(popped)
		free(popped)
	}
}

@(test)
test_session_detach_last_tab_closes_window_preserving_host :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a := new(app.App)
	defer free(a)
	app.session_manager_init(&a.session_mgr, 8)
	reg: session_core.Session_Registry
	session_core.session_registry_init(&reg)
	a.session_mgr.registry = &reg
	defer session_core.session_registry_destroy(&reg)
	defer app.session_manager_destroy(&a.session_mgr)
	a.config = config.config_default()
	defer config.config_destroy(&a.config)

	_, spawned := app.session_spawn(&a.session_mgr, "/bin/sleep", {"30"}, 24, 80, &a.config, termgrid.Theme{})
	testing.expect(t, spawned, "session_spawn must succeed")
	testing.expect_value(t, len(a.session_mgr.tabs), 1)
	a.session_mgr.active_idx = 0

	// Detach the sole tab via _app_detach_current_tab
	app._app_detach_current_tab(a)

	// Detaching last tab closes the GUI window (should_quit == true) per D11
	testing.expect_value(t, a.should_quit, true)
	testing.expect_value(t, len(a.session_mgr.tabs), 0)

	popped := session_core.session_registry_pop_latest_detached(&reg)
	if popped != nil {
		session_core.session_destroy(popped)
		free(popped)
	}
}

@(test)
test_multiplexer_spatial_focus_navigation :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	tree: app.Pane_Tree
	p1 := app.pane_tree_init(&tree, nil)
	app.pane_tree_layout(&tree, {0, 0, 800, 600}, 8, 16, 0, 0)

	p2, split_ok := app.pane_tree_split(&tree, p1, .Vertical, nil)
	testing.expect(t, split_ok)
	app.pane_tree_layout(&tree, {0, 0, 800, 600}, 8, 16, 0, 0)

	tree.focused_pane_id = p1
	// Navigate right to p2
	nav_right := app.pane_tree_navigate_spatially(&tree, .Vertical, true)
	testing.expect(t, nav_right)
	testing.expect_value(t, tree.focused_pane_id, p2)

	// Navigate left back to p1
	nav_left := app.pane_tree_navigate_spatially(&tree, .Vertical, false)
	testing.expect(t, nav_left)
	testing.expect_value(t, tree.focused_pane_id, p1)

	app.pane_tree_destroy(&tree)
}

@(test)
test_persistence_parse_layout_with_package_declaration :: proc(t: ^testing.T) {
	src := `package term

name = "packaged_workspace"
title = "Packaged Workspace Test"
cwd = "."
layout = Split {
	direction = .Vertical,
	ratio = 0.5,
	first = Pane { command = "ls", cwd = "." },
	second = Pane { command = "pwd", cwd = "." },
}
`
	layout, ok, err_msg := app.parse_layout_odin(src, "packaged.term.odin")
	defer app.persistence_free_layout(&layout)

	testing.expect(t, ok, "parse_layout_odin with package term must succeed")
	testing.expect_value(t, layout.name, "packaged_workspace")
	testing.expect_value(t, layout.title, "Packaged Workspace Test")
	testing.expect_value(t, layout.cwd, ".")
	testing.expect(t, layout.root != nil, "root pane must be populated")
	testing.expect(t, layout.root.is_split, "root node must be split")
}

@(test)
test_resolve_helper_binary :: proc(t: ^testing.T) {
	// A non-existent binary must not be found
	_, not_found := app.resolve_helper_binary("non_existent_helper_binary_xyz_123")
	testing.expect(t, !not_found, "non-existent binary must return false")

	// Create a temporary mock binary in current directory to verify ./<name> resolution
	temp_helper := "mock_test_helper"
	_ = os.write_entire_file(temp_helper, []u8{0x7F, 'E', 'L', 'F'})
	defer os.remove(temp_helper)

	resolved, found := app.resolve_helper_binary(temp_helper)
	testing.expect(t, found, "mock helper in current directory must be resolved")
	testing.expect_value(t, resolved, "./mock_test_helper")
}

@(test)
test_persistence_default_term_odin_parses :: proc(t: ^testing.T) {
	data, rerr := os.read_entire_file(".default.term.odin", context.temp_allocator)
	if rerr == nil {
		layout, ok, _ := app.parse_layout_odin(string(data), ".default.term.odin")
		defer app.persistence_free_layout(&layout)
		testing.expect(t, ok, "actual .default.term.odin file must parse successfully")
		testing.expect_value(t, layout.name, "default")
	}
}

@(test)
test_command_dispatcher_routing :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()

	// Verify Command_Preset enum variants exist
	testing.expect(t, app.Command_Preset.NativeV1 != app.Command_Preset.Legacy)

	// 1. Guard against nil App
	testing.expect_value(t, app.dispatch_command(nil, .Close_Pane), app.Command_Result.Failed)
	testing.expect_value(t, app.dispatch_command(nil, .New_Tab), app.Command_Result.Failed)
	testing.expect_value(t, app.dispatch_command(nil, .Detach_Tab), app.Command_Result.Failed)

	// 2. Guard against no active tab (App with 0 tabs)
	empty_app := new(app.App)
	defer free(empty_app)
	app.session_manager_init(&empty_app.session_mgr, 8)
	defer app.session_manager_destroy(&empty_app.session_mgr)

	testing.expect_value(t, app.dispatch_command(empty_app, .Close_Pane), app.Command_Result.Ignored)
	testing.expect_value(t, app.dispatch_command(empty_app, .Close_Tab), app.Command_Result.Ignored)
	testing.expect_value(t, app.dispatch_command(empty_app, .Detach_Tab), app.Command_Result.Ignored)
	testing.expect_value(t, app.dispatch_command(empty_app, .Split_Vertical), app.Command_Result.Ignored)
	testing.expect_value(t, app.dispatch_command(empty_app, .Split_Horizontal), app.Command_Result.Ignored)
	testing.expect_value(t, app.dispatch_command(empty_app, .Pane_Focus_Left), app.Command_Result.Ignored)
	testing.expect_value(t, app.dispatch_command(empty_app, .Pane_Focus_Right), app.Command_Result.Ignored)
	testing.expect_value(t, app.dispatch_command(empty_app, .Pane_Focus_Up), app.Command_Result.Ignored)
	testing.expect_value(t, app.dispatch_command(empty_app, .Pane_Focus_Down), app.Command_Result.Ignored)

	// 3. Unmapped actions fall through to Ignored
	testing.expect_value(t, app.dispatch_command(empty_app, .Zoom_In), app.Command_Result.Ignored)
	testing.expect_value(t, app.dispatch_command(empty_app, .Zoom_Out), app.Command_Result.Ignored)
	testing.expect_value(t, app.dispatch_command(empty_app, .Reload_Config), app.Command_Result.Ignored)

	// 4. Initialized mock/test App with active tab and panes
	a := new(app.App)
	defer free(a)
	app.session_manager_init(&a.session_mgr, 8)
	reg: session_core.Session_Registry
	session_core.session_registry_init(&reg)
	a.session_mgr.registry = &reg
	defer session_core.session_registry_destroy(&reg)
	defer app.session_manager_destroy(&a.session_mgr)
	a.config = config.config_default()
	defer config.config_destroy(&a.config)
	a.renderer.cell_width = 8
	a.renderer.cell_height = 16
	a.last_px_w = 800
	a.last_px_h = 600

	// Spawn initial active tab with sleep process
	idx, spawned := app.session_spawn(&a.session_mgr, "/bin/sleep", {"30"}, 24, 80, &a.config, termgrid.Theme{})
	testing.expect(t, spawned, "session_spawn for mock App must succeed")
	a.session_mgr.active_idx = idx

	// Test Toggle_Devtools
	testing.expect_value(t, app.dispatch_command(a, .Toggle_Devtools), app.Command_Result.Handled)

	// Test Attach_Session (opens session switcher)
	testing.expect_value(t, app.dispatch_command(a, .Attach_Session), app.Command_Result.Handled)
	testing.expect(t, a.session_switcher.visible, "session switcher must become visible")
	a.session_switcher.visible = false

	// Test Split_Vertical
	testing.expect_value(t, app.dispatch_command(a, .Split_Vertical), app.Command_Result.Handled)

	// Test Spatial Pane Navigation
	testing.expect_value(t, app.dispatch_command(a, .Pane_Focus_Right), app.Command_Result.Handled)
	testing.expect_value(t, app.dispatch_command(a, .Pane_Focus_Left), app.Command_Result.Handled)
	testing.expect_value(t, app.dispatch_command(a, .Pane_Focus_Down), app.Command_Result.Handled)
	testing.expect_value(t, app.dispatch_command(a, .Pane_Focus_Up), app.Command_Result.Handled)

	// Test Split_Horizontal
	testing.expect_value(t, app.dispatch_command(a, .Split_Horizontal), app.Command_Result.Handled)

	// Test Close_Pane
	testing.expect_value(t, app.dispatch_command(a, .Close_Pane), app.Command_Result.Handled)

	// Test New_Tab
	testing.expect_value(t, app.dispatch_command(a, .New_Tab), app.Command_Result.Handled)
	testing.expect_value(t, len(a.session_mgr.tabs), 2)

	// Test Close_Tab (closes or requests close on active tab)
	testing.expect_value(t, app.dispatch_command(a, .Close_Tab), app.Command_Result.Handled)

	// Test Detach_Tab (detaches active tab)
	testing.expect_value(t, app.dispatch_command(a, .Detach_Tab), app.Command_Result.Handled)

	// Pop any detached session to cleanly free it
	popped := session_core.session_registry_pop_latest_detached(&reg)
	if popped != nil {
		session_core.session_destroy(popped)
		free(popped)
	}
}

