package app_test

import "core:testing"
import "base:runtime"
import "core:time"
import "core:c"
import posix "core:sys/posix"
import app "../"
import input "../../platform/input"
import ui "../../ui"
import termgrid "../../terminal"
import render "../../render"
import instance "../../render/instance"
import gpu "../../render/gpu"
import platform "../../platform"

foreign import pane_libc "system:System.framework"
@(default_calling_convention="c")
foreign pane_libc {
	@(link_name="ioctl")
	pane_ioctl :: proc(fd: c.int, request: c.ulong, #c_vararg args: ..any) -> c.int ---
}
Pane_Test_Winsize :: struct {rows, cols, xpixel, ypixel: c.ushort}
PANE_TEST_GET_WINSIZE :: 0x40087468

_pane_integration_init :: proc(a: ^app.App, t: ^testing.T) -> bool {
	app.session_manager_init(&a.session_mgr, 4)
	a.renderer.cell_width = app.APP_CELL_W
	a.renderer.cell_height = app.APP_CELL_H
	a.window.pixel_w = 800
	a.window.pixel_h = 480
	a.window.is_open = true
	_, ok := app.session_spawn(&a.session_mgr, "/bin/cat", {}, 24, 80, nil, {})
	testing.expect(t, ok)
	if ok do _ = app.app_layout_panes(a)
	return ok
}

_pane_integration_destroy :: proc(a: ^app.App) {
	app.session_manager_destroy(&a.session_mgr)
	render.renderer_destroy(&a.renderer)
}

@(test)
test_pane_exact_shortcut_modifiers :: proc(t: ^testing.T) {
	canonical := input.Input_Event{event_type = .Key, kind = .Printable, rune = '\\', gui = true}
	testing.expect(t, ui.ui_shortcut_matches(.Split_Vertical, canonical))
	for invalid in ([]input.Input_Event{
		{event_type = .Key, kind = .Printable, rune = '|', gui = true},
		{event_type = .Key, kind = .Printable, rune = '\\', gui = true, ctrl = true},
		{event_type = .Key, kind = .Printable, rune = '\\', gui = true, is_release = true},
		{event_type = .Key, kind = .Printable, rune = '\\', gui = true, shift = true, alt = true},
	}) {
		testing.expect(t, !ui.ui_shortcut_matches(.Split_Vertical, invalid))
		testing.expect(t, !ui.ui_shortcut_matches(.Overflow, invalid))
	}
}

@(test)
test_pane_production_split_resize_focus_and_zoom :: proc(t: ^testing.T) {
	// Live workers use the production heap; rollback-stack test allocations cannot cross OS threads.
	context.allocator = runtime.heap_allocator()
	a := new(app.App)
	defer free(a)
	if !_pane_integration_init(a, t) do return
	defer _pane_integration_destroy(a)
	for invalid in ([]input.Input_Event{
		{event_type = .Key, kind = .Printable, rune = '|', gui = true},
		{event_type = .Key, kind = .Printable, rune = '\\', gui = true, is_release = true},
	}) {
		_, _ = app.app_dispatch_input_events(a, {invalid})
		testing.expect_value(t, a.session_mgr.tabs[0].tree.node_count, 1)
	}
	_, _ = app.app_dispatch_input_events(a, {{event_type = .Key, kind = .Printable, rune = '\\', gui = true}})
	tab := &a.session_mgr.tabs[0]
	testing.expect_value(t, tab.tree.node_count, 3)
	leaves: [app.MAX_PANE_NODES]^app.Pane_Node
	n := app.tab_leaf_panes(tab, leaves[:])
	testing.expect_value(t, n, 2)
	for _ in 0..<100 {
		ready := true
		for leaf in leaves[:n] {
			ws: Pane_Test_Winsize
			ok := pane_ioctl(c.int(leaf.backend.pty.master), PANE_TEST_GET_WINSIZE, &ws) == 0
			ready = ready && ok && int(ws.rows) == leaf.rows && int(ws.cols) == leaf.cols
		}
		if ready do break
		time.sleep(time.Millisecond)
	}
	for leaf in leaves[:n] {
		ws: Pane_Test_Winsize
		testing.expect(t, pane_ioctl(c.int(leaf.backend.pty.master), PANE_TEST_GET_WINSIZE, &ws) == 0)
		testing.expect_value(t, int(ws.rows), leaf.rows)
		testing.expect_value(t, int(ws.cols), leaf.cols)
		testing.expect(t, leaf.rect.w > 0 && leaf.rect.h > 0 && leaf.cols < 80)
	}
	_, _ = app.app_dispatch_input_events(a, {{event_type = .Key, kind = .Enter, gui = true, shift = true}})
	testing.expect_value(t, tab.tree.zoomed_pane_id, tab.tree.focused_pane_id)
	_, _ = app.app_dispatch_input_events(a, {{event_type = .Key, kind = .Printable, rune = '[', gui = true}})
	testing.expect_value(t, tab.tree.zoomed_pane_id, tab.tree.focused_pane_id)
	_, _ = app.app_dispatch_input_events(a, {{event_type = .Key, kind = .Printable, rune = '\\', gui = true}})
	testing.expect_value(t, tab.tree.zoomed_pane_id, app.Pane_Id(0))
	testing.expect_value(t, tab.tree.node_count, 5)
	testing.expect(t, !app.session_detach_tab(&a.session_mgr, 0), "unsupported detach preserves live panes")
}

@(test)
test_pane_focused_key_dispatch_and_pointer_scale :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a := new(app.App)
	defer free(a)
	if !_pane_integration_init(a, t) do return
	defer _pane_integration_destroy(a)
	_, _ = app.app_dispatch_input_events(a, {{event_type = .Key, kind = .Printable, rune = '\\', gui = true}})
	tab := &a.session_mgr.tabs[0]
	leaves: [app.MAX_PANE_NODES]^app.Pane_Node
	n := app.tab_leaf_panes(tab, leaves[:])
	for leaf in leaves[:n] { app.backend_stop_thread(leaf.backend) }
	first_pipe, second_pipe: [2]posix.FD
	testing.expect(t, posix.pipe(&first_pipe) == .OK)
	testing.expect(t, posix.pipe(&second_pipe) == .OK)
	defer { for fd in first_pipe { _ = posix.close(fd) }; for fd in second_pipe { _ = posix.close(fd) } }
	masters := [2]int{leaves[0].backend.pty.master, leaves[1].backend.pty.master}
	leaves[0].backend.pty.master = int(first_pipe[1])
	leaves[1].backend.pty.master = int(second_pipe[1])
	defer { leaves[0].backend.pty.master = masters[0]; leaves[1].backend.pty.master = masters[1] }
	_, ok := app.app_dispatch_input_events(a, {{event_type = .Key, kind = .Printable, rune = 'x'}})
	testing.expect(t, ok)
	buf: [1]u8
	testing.expect_value(t, posix.read(second_pipe[0], &buf[0], 1), 1)
	testing.expect_value(t, buf[0], u8('x'))
	poll := posix.pollfd{fd = first_pipe[0], events = {.IN}}
	testing.expect(t, posix.poll(&poll, 1, 0) == 0, "unfocused pane receives no key bytes")
	leaf := app.pane_tree_find_pane(&tab.tree, tab.tree.focused_pane_id)
	for scale in ([]f32{1, 2}) {
		a.window.width = i32(f32(a.window.pixel_w)/scale)
		point := app.app_pointer_cell(a, (leaf.rect.x+f32(3)*a.renderer.cell_width)/scale, (leaf.rect.y+f32(2)*a.renderer.cell_height)/scale)
		testing.expect_value(t, point.row, 2)
		testing.expect_value(t, point.col, 3)
	}
}

@(test)
test_pane_search_async_query_and_focus_noop :: proc(t: ^testing.T) {
	a := new(app.App)
	defer free(a)
	_bare_app(a)
	defer _bare_destroy(a)
	a.front_interaction.search_len = 1
	a.front_interaction.search_query[0] = 'a'
	a.search_bar.query_len = 2
	a.search_bar.query[0] = 'a'
	a.search_bar.query[1] = 'b'
	// Pretend worker exists only while borrowing an initialized front snapshot.
	a.thread = cast(type_of(a.thread))(uintptr(1))
	app.app_sync_search_bar(a)
	a.thread = nil
	testing.expect_value(t, string(a.search_bar.query[:a.search_bar.query_len]), "ab")
	a.focus_requested = true
	testing.expect(t, app.app_dispatch_backend(&a.backend, app.UI_Event{type = .Focus, focused = true}))
	testing.expect_value(t, a.event_queue.count, 0)
}

@(test)
test_pane_extra_modifiers_dispatch_does_not_split :: proc(t: ^testing.T) {
	a := new(app.App)
	defer free(a)
	app.session_manager_init(&a.session_mgr, 2)
	defer app.session_manager_destroy(&a.session_mgr)
	resize(&a.session_mgr.tabs, 1)
	a.session_mgr.active_idx = 0
	b := &a.session_mgr.tabs[0].backend
	b.pty.master = -1
	b.pty.pid = -1
	b.wake_pipe_r = -1
	b.wake_pipe_w = -1
	termgrid.terminal_init(&b.terminal, 24, 80)
	_ = app.pane_tree_init(&a.session_mgr.tabs[0].tree, b)
	_, _ = app.app_dispatch_input_events(a, {{event_type = .Key, kind = .Printable, rune = '\\', gui = true, ctrl = true}})
	testing.expect_value(t, a.session_mgr.tabs[0].tree.node_count, 1)
}
