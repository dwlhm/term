package main

import "core:fmt"
import "core:math"
import "core:strings"
import "vendor:sdl3"
import win "../platform/window"
import "../platform/input"
import platform_tabs "../platform/tabs"
import "../render"
import inter "../interaction"
import platform "../platform"
import "../ui"
import pty "../platform/pty"
import platform_chrome "../platform/chrome"
import termgrid "../terminal"
import graphics "../graphics"

PANE_RESIZE_STEP :: f32(0.05)
PANE_INACTIVE_DIM :: f32(0.78)
PANE_EDGE_EPSILON: f32 : 0.5

_app_active_tab :: proc(a: ^App) -> ^Tab_Session {
	if a == nil || a.session_mgr.active_idx < 0 || a.session_mgr.active_idx >= len(a.session_mgr.tabs) do return nil
	return &a.session_mgr.tabs[a.session_mgr.active_idx]
}

// Every UI mutation crosses the same boundary
// Paste ownership transfers only on acceptance.
_app_dispatch_backend :: proc(b: ^Backend, ev: UI_Event) -> bool {
	if b == nil do return false
	if ev.type == .Focus && b.focus_requested == ev.focused do return true
	if backend_is_threaded(b) {
		ok := backend_push_event(b, ev)
		if ok && ev.type == .Focus do b.focus_requested = ev.focused
		return ok
	}
	if ev.type == .Focus do b.focus_requested = ev.focused
	backend_handle_ui_event(b, ev)
	return true
}

_app_pane_padding :: proc(a: ^App) -> f32 {
	return FRONTEND_CONTENT_PADDING * frontend_content_scale(&a.frontend) if a.window.handle != nil else 0
}

_app_layout_panes :: proc(a: ^App) -> bool {
	if a == nil do return false
	pw := a.window.pixel_w if a.window.pixel_w > 0 else a.last_px_w
	ph := a.window.pixel_h if a.window.pixel_h > 0 else a.last_px_h
	if pw <= 0 || ph <= 0 do return false
	frontend_update_padding(&a.frontend)
	rows, cols := grid_dimensions_for_pixels(pw, ph, a.renderer.cell_width, a.renderer.cell_height, a.renderer.pad_x, a.renderer.pad_y)
	tab := _app_active_tab(a)
	if tab == nil {
		b := app_active_backend(a)
		if b == nil || b.terminal.grid.row_count <= 0 || b.terminal.grid.col_count <= 0 do return false
		if a.renderer.rows != i32(rows) || a.renderer.cols != i32(cols) do render.renderer_resize_grid(&a.renderer, nil, i32(rows), i32(cols))
		grid_pixel_w, grid_pixel_h := grid_pixel_extent_for_cells(rows, cols, a.renderer.cell_width, a.renderer.cell_height)
		if b.terminal.grid.row_count == rows && b.terminal.grid.col_count == cols && b.pty.pixel_w == grid_pixel_w && b.pty.pixel_h == grid_pixel_h do return false
		return _app_dispatch_backend(b, UI_Event{type = .Resize, rows = rows, cols = cols, pixel_w = pw, pixel_h = ph, grid_pixel_w = i32(grid_pixel_w), grid_pixel_h = i32(grid_pixel_h)})
	}
	if tab.tree.root == nil do return false
	pad := _app_pane_padding(a)
	top := a.renderer.pad_y - pad
	pane_tree_layout(&tab.tree, platform_tabs.Rect_f32{x = 0, y = top, w = f32(pw), h = max(f32(0), f32(ph)-top)}, a.renderer.cell_width, a.renderer.cell_height, pad, pad)
	leaves: [MAX_PANE_NODES]^Pane_Node
	n := tab_leaf_panes(tab, leaves[:])
	if n == 1 {
		// Preserve the original singleton's tabbar/padding subtraction.
		leaves[0].rows = rows
		leaves[0].cols = cols
	}
	capacity_rows, capacity_cols := rows, cols
	if n > 1 {
		capacity_rows = max(rows, int(math.ceil(f32(ph)/max(f32(1), a.renderer.cell_height))))
		capacity_cols = max(cols, int(math.ceil(f32(pw)/max(f32(1), a.renderer.cell_width))))
	}
	if a.renderer.rows != i32(capacity_rows) || a.renderer.cols != i32(capacity_cols) {
		render.renderer_resize_grid(&a.renderer, nil, i32(capacity_rows), i32(capacity_cols))
	}
	changed := false
	for leaf in leaves[:n] {
		if leaf.rect.w <= 0 || leaf.rect.h <= 0 || leaf.backend == nil do continue
		grid_pixel_w, grid_pixel_h := grid_pixel_extent_for_cells(leaf.rows, leaf.cols, a.renderer.cell_width, a.renderer.cell_height)
		if leaf.rows == leaf.dispatched_rows && leaf.cols == leaf.dispatched_cols && grid_pixel_w == leaf.dispatched_pixel_w && grid_pixel_h == leaf.dispatched_pixel_h do continue
		if _app_dispatch_backend(leaf.backend, UI_Event{type = .Resize, rows = leaf.rows, cols = leaf.cols, pixel_w = i32(leaf.rect.w), pixel_h = i32(leaf.rect.h), grid_pixel_w = i32(grid_pixel_w), grid_pixel_h = i32(grid_pixel_h)}) {
			leaf.dispatched_rows = leaf.rows
			leaf.dispatched_cols = leaf.cols
			leaf.dispatched_pixel_w = grid_pixel_w
			leaf.dispatched_pixel_h = grid_pixel_h
			changed = true
		}
	}
	if changed do a.renderer.full_redraw_pending = true
	return changed
}

_app_spawn_pane_backend :: proc(a: ^App, init_rows: int = 0, init_cols: int = 0, cwd: string = "") -> ^Backend {
	if a == nil do return nil
	shell, shell_allocated := _resolve_shell()
	defer if shell_allocated { delete(shell) }
	shell_argv := _resolve_shell_argv(shell)
	rows := init_rows if init_rows > 0 else APP_DEFAULT_ROWS
	cols := init_cols if init_cols > 0 else APP_DEFAULT_COLS
	cfg := a.config
	if len(cwd) > 0 do cfg.working_directory = cwd
	b := new(Backend)
	pixel_w, pixel_h := grid_pixel_extent_for_cells(rows, cols, a.renderer.cell_width, a.renderer.cell_height)
	if !backend_init(b, rows, cols, shell, shell_argv, &cfg, a.renderer.theme, pixel_w, pixel_h) {
		free(b)
		return nil
	}
	backend_set_clipboard_callbacks(b, &a.frontend, _frontend_clipboard_write_cb, _frontend_clipboard_read_cb)
	backend_set_notify_data_ready(b, a, _app_on_backend_data_ready)
	if !backend_start_thread(b) {
		fmt.eprintln("split pane rejected: backend worker could not start")
		backend_destroy(b)
		free(b)
		return nil
	}
	return b
}

_app_split_pane :: proc(a: ^App, direction: Split_Direction) -> bool {
	tab := _app_active_tab(a)
	if tab == nil do return false
	if a.frontend.use_pinnacle {
		fmt.eprintln("split pane rejected: experimental Pinnacle renderer supports one terminal")
		return false
	}
	_ = _app_layout_panes(a)
	leaf := pane_tree_find_pane(&tab.tree, tab.tree.focused_pane_id)
	if leaf == nil do return false
	if tab.tree.node_count + 2 > MAX_PANE_NODES || (direction == .Vertical && leaf.cols < MIN_COLS*2) || (direction == .Horizontal && leaf.rows < MIN_ROWS*2) {
		fmt.eprintln("split pane rejected: minimum pane dimensions or node limit")
		return false
	}
	previous := leaf.backend
	cwd := leaf.backend.cwd
	live_cwd: [4096]u8
	if cwd_len := pty.pty_working_directory(&leaf.backend.pty, live_cwd[:]); cwd_len > 0 {
		cwd = string(live_cwd[:cwd_len])
	}
	b := _app_spawn_pane_backend(a, leaf.rows, leaf.cols, cwd)
	if b == nil {
		fmt.eprintln("split pane rejected: shell spawn failed")
		return false
	}
	_, ok := pane_tree_split(&tab.tree, leaf.id, direction, b)
	if !ok {
		backend_destroy(b)
		free(b)
		fmt.eprintln("split pane rejected: pane layout cannot satisfy split")
		return false
	}
	tab.tree.zoomed_pane_id = 0
	_app_pane_focus_changed(a, previous)
	_ = _app_layout_panes(a)
	return true
}

_app_pane_focus_changed :: proc(a: ^App, previous: ^Backend) {
	if previous != nil do _ = _app_dispatch_backend(previous, UI_Event{type = .Focus, focused = false})
	if a.window.handle != nil {
		_app_sync_focus(a)
	} else {
		_ = _app_dispatch_backend(app_active_backend(a), UI_Event{type = .Focus, focused = true})
	}
	_app_resync_tab_modals(a)
	_app_sync_search_bar(a, true)
	a.hud_active = false
	_app_sync_title(a)
	a.renderer.full_redraw_pending = true
}

_app_dispatch_pane_shortcut :: proc(a: ^App, ev: input.Input_Event) -> bool {
	tab := _app_active_tab(a)
	if ui.ui_shortcut_matches(.Split_Vertical, ev) {
		_ = _app_split_pane(a, .Vertical)
		return true
	}
	if ui.ui_shortcut_matches(.Split_Horizontal, ev) {
		_ = _app_split_pane(a, .Horizontal)
		return true
	}
	if tab == nil do return false
	previous := app_active_backend(a)
	handled := true
	if ui.ui_shortcut_matches(.Pane_Prev, ev) {
		_ = pane_tree_cycle_focus(&tab.tree, false)
	} else if ui.ui_shortcut_matches(.Pane_Next, ev) {
		_ = pane_tree_cycle_focus(&tab.tree, true)
	} else if ui.ui_shortcut_matches(.Pane_Equalize, ev) {
		_ = pane_tree_equalize(&tab.tree)
	} else if ui.ui_shortcut_matches(.Pane_Zoom, ev) {
		pane_tree_toggle_zoom(&tab.tree, tab.tree.focused_pane_id)
	} else if ui.ui_shortcut_matches(.Pane_Resize_Left, ev) {
		_ = pane_tree_resize_active(&tab.tree, .Vertical, -PANE_RESIZE_STEP)
	} else if ui.ui_shortcut_matches(.Pane_Resize_Right, ev) {
		_ = pane_tree_resize_active(&tab.tree, .Vertical, PANE_RESIZE_STEP)
	} else if ui.ui_shortcut_matches(.Pane_Resize_Up, ev) {
		_ = pane_tree_resize_active(&tab.tree, .Horizontal, -PANE_RESIZE_STEP)
	} else if ui.ui_shortcut_matches(.Pane_Resize_Down, ev) {
		_ = pane_tree_resize_active(&tab.tree, .Horizontal, PANE_RESIZE_STEP)
	} else {
		handled = false
	}
	if handled {
		if previous != app_active_backend(a) {
			if tab.tree.zoomed_pane_id != 0 do tab.tree.zoomed_pane_id = tab.tree.focused_pane_id
			_app_pane_focus_changed(a, previous)
		}
		_ = _app_layout_panes(a)
		a.renderer.full_redraw_pending = true
	}
	return handled
}

_app_route_pane_pointer :: proc(a: ^App, p: input.Input_Pointer_Event) -> bool {
	tab := _app_active_tab(a)
	if tab == nil do return false
	tree := &tab.tree
	scale := frontend_content_scale(&a.frontend)
	x, y := p.x*scale, p.y*scale
	if tree.divider_dragging {
		if p.kind == .Button_Up {
			pane_tree_divider_drag_end(tree)
		} else if p.kind == .Motion {
			pos := x if tree.divider_hover.direction == .Vertical else y
			if pane_tree_divider_drag_update(tree, pos) {
				_ = _app_layout_panes(a)
				a.renderer.full_redraw_pending = true
			}
		}
		return true
	}
	leaf, divider := pane_tree_hit_test(tree, x, y)
	if p.kind == .Button_Down && p.button == 1 {
		if divider != nil {
			pos := x if divider.direction == .Vertical else y
			pane_tree_divider_drag_begin(tree, divider, pos)
			return true
		}
		if leaf != nil && leaf.id != tree.focused_pane_id {
			previous := app_active_backend(a)
			tree.focused_pane_id = leaf.id
			_app_pane_focus_changed(a, previous)
		}
	}
	if p.kind == .Motion && tree.divider_hover != divider {
		tree.divider_hover = divider
		a.renderer.full_redraw_pending = true
	}
	return false
}

_app_image_focus_hit :: proc(a: ^App, p: input.Input_Pointer_Event) -> (hit: inter.Image_Focus_Hit, namespace: u64, ok: bool) {
	if a == nil do return {}, 0, false
	tab := _app_active_tab(a)
	if tab == nil do return {}, 0, false
	scale := frontend_content_scale(&a.frontend)
	px, py := p.x * scale, p.y * scale
	pad := _app_pane_padding(a)
	leaves: [MAX_PANE_NODES]^Pane_Node
	n := tab_leaf_panes(tab, leaves[:])
	for leaf in leaves[:n] {
		if leaf == nil || leaf.backend == nil || leaf.rect.w <= 0 || leaf.rect.h <= 0 do continue
		if px < leaf.rect.x || py < leaf.rect.y || px >= leaf.rect.x + leaf.rect.w || py >= leaf.rect.y + leaf.rect.h do continue
		if px < leaf.rect.x + pad || py < leaf.rect.y + pad || px >= leaf.rect.x + leaf.rect.w - pad || py >= leaf.rect.y + leaf.rect.h - pad do continue
		b := leaf.backend
		threaded := backend_is_threaded(b)
		if threaded do backend_lock_render(b)
		t := &b.front_terminal if threaded else &b.terminal
		defer if threaded { backend_unlock_render(b) }
		// Alt-screen applications retain the existing terminal mouse policy unless
		// Shift explicitly opts into the GUI interaction layer.
		if t.is_alt_screen && !p.shift do return {}, 0, false
		store := termgrid.terminal_graphics_active(t)
		local_x := px - leaf.rect.x - pad
		local_y := py - leaf.rect.y - pad
		hit, hit_ok := inter.interaction_hit_test_image(store, local_x, local_y, a.renderer.cell_width, a.renderer.cell_height)
		if hit_ok do return hit, t.graphics_namespace, true
		return {}, 0, false
	}
	return {}, 0, false
}

_app_image_focus_contains :: proc(a: ^App, p: input.Input_Pointer_Event) -> bool {
	if a == nil || !a.image_focus.active do return false
	b := app_active_backend(a)
	if b == nil do return false
	threaded := backend_is_threaded(b)
	if threaded do backend_lock_render(b)
	defer if threaded { backend_unlock_render(b) }
	t := &b.front_terminal if threaded else &b.terminal
	if t.graphics_namespace != a.image_focus.namespace do return false
	store := termgrid.terminal_graphics_active(t)
	image := graphics.store_find_image(store, a.image_focus.image_id, 0)
	if image == nil || !image.used || image.generation != a.image_focus.generation || image.frame_count <= 0 || image.current_frame < 0 || image.current_frame >= image.frame_count do return false
	frame := &image.frames[image.current_frame]
	focused := a.image_focus
	inter.image_focus_clamp_for_view(&focused, a.renderer.screen_w, a.renderer.screen_h, f32(frame.width), f32(frame.height))
	rect, ok := inter.image_focus_rect(focused, a.renderer.screen_w, a.renderer.screen_h, f32(frame.width), f32(frame.height))
	if !ok do return false
	scale := frontend_content_scale(&a.frontend)
	x, y := p.x * scale, p.y * scale
	return x >= rect[0] && y >= rect[1] && x < rect[0] + rect[2] && y < rect[1] + rect[3]
}

_app_tab_has_running_processes :: proc(tab: ^Tab_Session) -> bool {
	leaves: [MAX_PANE_NODES]^Pane_Node
	n := tab_leaf_panes(tab, leaves[:])
	for leaf in leaves[:n] {
		if leaf.backend != nil && pty.pty_has_running_processes(&leaf.backend.pty) do return true
	}
	return false
}

// Arrays borrow locked worker snapshots only for the duration of one publication.
App_Pane_Frame :: struct {
	leaves: [MAX_PANE_NODES]^Pane_Node,
	states: [MAX_PANE_NODES]Render_State,
	viewports: [MAX_PANE_NODES]render.Pane_Viewport,
	locked: [MAX_PANE_NODES]^Backend,
	count, lock_count, active: int,
}

// _pane_divider_edges reports which of the focused leaf's four edges are
// occupied by a divider, as a ui.PANE_EDGE_* bitmask. Edges that face the window
// frame or the tab bar are never marked, so the accent outline stays on the
// interior seams only.
_pane_divider_edges :: proc(rect: ui.Rect_f32, dividers: []ui.Pane_Divider) -> u8 {
	edges: u8 = 0
	if len(dividers) == 0 || rect.w <= 0 || rect.h <= 0 do return edges
	eps := PANE_EDGE_EPSILON
	for div in dividers {
		vertical := div.w <= div.h
		if vertical {
			// Divider column must sit exactly on a vertical leaf edge and
			// overlap the leaf vertically.
			overlap := min(rect.y + rect.h, div.y + div.h) - max(rect.y, div.y)
			if overlap <= 0 do continue
			if abs((div.x + div.w) - rect.x) <= eps do edges |= ui.PANE_EDGE_LEFT
			if abs(div.x - (rect.x + rect.w)) <= eps do edges |= ui.PANE_EDGE_RIGHT
		} else {
			overlap := min(rect.x + rect.w, div.x + div.w) - max(rect.x, div.x)
			if overlap <= 0 do continue
			if abs((div.y + div.h) - rect.y) <= eps do edges |= ui.PANE_EDGE_TOP
			if abs(div.y - (rect.y + rect.h)) <= eps do edges |= ui.PANE_EDGE_BOTTOM
		}
	}
	return edges
}

_app_present :: proc(a: ^App) -> bool {
	if a == nil do return false
	// Every frame rebuilds each UI layer from scratch. Pane chrome stages after
	// _app_stage_ui; layers make that order irrelevant, but the reset still has
	// to happen before anything stages so an early-out path cannot inherit the
	// previous frame's quads.
	render.renderer_ui_reset(&a.renderer)
	_app_stage_ui(a) // Layout and dispatch run before borrowing worker snapshots.
	frame: App_Pane_Frame
	defer for b in frame.locked[:frame.lock_count] { backend_unlock_render(b) }
	if tab := _app_active_tab(a); tab != nil {
		n := tab_leaf_panes(tab, frame.leaves[:])
		pad := _app_pane_padding(a)
		for leaf in frame.leaves[:n] {
			if leaf.backend == nil || leaf.rect.w <= 0 || leaf.rect.h <= 0 do continue
			b := leaf.backend
			if backend_is_threaded(b) {
				backend_lock_render(b)
				frame.locked[frame.lock_count] = b
				frame.lock_count += 1
			}
			i := frame.count
			frame.states[i] = backend_get_render_state(b)
			state := &frame.states[i]
			state.debug_frames = a.debug_frames
			active := leaf.id == tab.tree.focused_pane_id
			if active do frame.active = i
			frame.viewports[i] = render.Pane_Viewport{
				terminal = state.terminal, view = state.view,
				x = leaf.rect.x+pad, y = leaf.rect.y+pad, w = max(f32(0), leaf.rect.w-2*pad), h = max(f32(0), leaf.rect.h-2*pad),
				clip_rect = {leaf.rect.x, leaf.rect.y, leaf.rect.x+leaf.rect.w, leaf.rect.y+leaf.rect.h},
				rows = state.terminal.grid.row_count, cols = state.terminal.grid.col_count,
				is_active = active, dim_factor = 1 if active else PANE_INACTIVE_DIM,
			}
			if !active && state.cursor != nil && state.cursor.visible && state.view.scrollback_offset == 0 {
				cur := termgrid.terminal_get_cursor(state.terminal)
				cx := leaf.rect.x+pad+f32(cur.col)*a.renderer.cell_width
				cy := leaf.rect.y+pad+f32(cur.row)*a.renderer.cell_height
				if cx+a.renderer.cell_width <= leaf.rect.x+leaf.rect.w && cy+a.renderer.cell_height <= leaf.rect.y+leaf.rect.h {
					ui.ui_stage_hollow_cursor(&a.renderer, cx, cy, a.renderer.cell_width, a.renderer.cell_height)
				}
			}
			frame.count += 1
		}
		dividers: [MAX_PANE_NODES]ui.Pane_Divider
		dn := 0
		if tab.tree.zoomed_pane_id == 0 {
			for &node, i in tab.tree.nodes {
				if !tab.tree.node_in_use[i] || node.kind != .Split || node.first == nil do continue
				div := ui.Pane_Divider{is_hovered = &node == tab.tree.divider_hover}
				if node.direction == .Vertical {
					div.x = node.first.rect.x+node.first.rect.w
					div.y = node.rect.y
					div.w = DIVIDER_SIZE
					div.h = node.rect.h
				} else {
					div.x = node.rect.x
					div.y = node.first.rect.y+node.first.rect.h
					div.w = node.rect.w
					div.h = DIVIDER_SIZE
				}
				dividers[dn] = div
				dn += 1
			}
		}
		active := pane_tree_find_pane(&tab.tree, tab.tree.focused_pane_id)
		if active != nil {
			active_edges := _pane_divider_edges(active.rect, dividers[:dn])
			ui.ui_stage_pane_chrome(&a.renderer, &a.ui_theme, dividers[:dn], active.rect, active_edges, tab.tree.node_count > 1)
		}
	} else {
		b := app_active_backend(a)
		if b == nil do return false
		if backend_is_threaded(b) {
			backend_lock_render(b)
			frame.locked[0] = b
			frame.lock_count = 1
		}
		frame.states[0] = backend_get_render_state(b)
		frame.count = 1
	}
	if frame.count == 0 do return false
	now_ns := u64(platform.platform_ticks_to_ns(platform.platform_now()))
	for state in frame.states[:frame.count] {
		if state.synchronized_output && now_ns >= state.sync_output_start_ns && now_ns-state.sync_output_start_ns < APP_SYNC_OUTPUT_TIMEOUT_NS {
			a.renderer.full_redraw_pending = true
			a.has_deferred_render = true
			return false
		}
	}
	panes := frame.viewports[:frame.count] if _app_active_tab(a) != nil else nil
	ok := frontend_render(&a.frontend, &frame.states[frame.active], panes, &a.image_focus)
	if !ok {
		a.renderer.full_redraw_pending = true
		a.has_deferred_render = true
	}
	return ok
}

_app_sync_search_bar :: proc(a: ^App, adopt_query: bool = false) {
	b := app_active_backend(a)
	if b == nil do return
	if backend_is_threaded(b) do backend_lock_render(b)
	defer if backend_is_threaded(b) { backend_unlock_render(b) }
	s := &b.front_interaction if backend_is_threaded(b) else &b.interaction
	query := string(s.search_query[:clamp(s.search_len, 0, len(s.search_query))])
	if !adopt_query && query != string(a.search_bar.query[:a.search_bar.query_len]) do return
	a.search_bar.is_invalid_regex = b.front_search_invalid_regex if backend_is_threaded(b) else b.search_invalid_regex
	a.search_bar.match_count = s.search_match_count
	a.search_bar.match_idx = s.search_match_idx
	if adopt_query do a.search_bar.query_len = copy(a.search_bar.query[:], s.search_query[:clamp(s.search_len, 0, len(s.search_query))])
}

_app_search_action :: proc(a: ^App, action: platform_chrome.Search_Action) {
	if action == .None do return
	if action == .Close do a.search_bar.visible = false
	ev := UI_Event{type = .Search, search_action = action, case_sensitive = a.search_bar.case_sensitive, use_regex = a.search_bar.use_regex, whole_word = a.search_bar.whole_word}
	ev.query_len = copy(ev.query[:], a.search_bar.query[:a.search_bar.query_len])
	_ = _app_dispatch_backend(app_active_backend(a), ev)
	if !backend_is_threaded(app_active_backend(a)) do _app_sync_search_bar(a)
	a.renderer.full_redraw_pending = true
}

_app_send_paste :: proc(b: ^Backend, text: string) -> bool {
	owned := strings.clone(text)
	if _app_dispatch_backend(b, UI_Event{type = .Paste, text = owned}) do return true
	delete(owned)
	return false
}

// Public entry points support the same production flow in headless integration tests.
app_layout_panes :: _app_layout_panes
app_present :: _app_present
app_pointer_cell :: _app_pointer_cell

app_sync_search_bar :: _app_sync_search_bar
app_dispatch_backend :: _app_dispatch_backend

_app_send_theme :: proc(b: ^Backend, theme: termgrid.Theme) -> bool {
	owned := new(termgrid.Theme)
	owned^ = theme
	if _app_dispatch_backend(b, UI_Event{type = .Theme, theme = owned}) do return true
	free(owned)
	return false
}

_app_backend_pending_damage :: proc(b: ^Backend) -> bool {
	if b == nil do return false
	if backend_is_threaded(b) do backend_lock_render(b)
	defer if backend_is_threaded(b) { backend_unlock_render(b) }
	terminal := &b.front_terminal if backend_is_threaded(b) else &b.terminal
	return _damage_cells(terminal) > 0
}

_app_has_pending_damage :: proc(a: ^App) -> bool {
	if tab := _app_active_tab(a); tab != nil {
		leaves: [MAX_PANE_NODES]^Pane_Node
		n := tab_leaf_panes(tab, leaves[:])
		for leaf in leaves[:n] {
			if leaf.rect.w > 0 && leaf.rect.h > 0 && _app_backend_pending_damage(leaf.backend) do return true
		}
		return false
	}
	return _app_backend_pending_damage(app_active_backend(a))
}
app_has_pending_damage :: _app_has_pending_damage

// Derive native feedback once per main-thread frame from the authoritative layout.
_app_sync_pane_cursor :: proc(a: ^App) {
	if a == nil || a.window.handle == nil do return
	shape := win.Pointer_Cursor.Default
	defer _ = win.window_set_pointer_cursor(&a.window, shape)
	if a.should_quit || sdl3.GetMouseFocus() != a.window.handle || .INPUT_FOCUS not_in sdl3.GetWindowFlags(a.window.handle) do return
	if a.confirm_dialog.visible || a.tab_menu.visible || a.tab_overflow.visible || a.tab_rename.active || a.tab_drag.phase != .Idle do return
	tab := _app_active_tab(a)
	if tab == nil || tab.tree.root == nil || tab.tree.node_count <= 1 || tab.tree.zoomed_pane_id != 0 do return
	x, y: f32
	_ = sdl3.GetMouseState(&x, &y)
	if a.search_bar.visible && platform_tabs.point_in_rect(x, y, a.search_bar.rect) do return
	divider := tab.tree.divider_hover if tab.tree.divider_dragging else nil
	if !tab.tree.divider_dragging {
		scale := frontend_content_scale(&a.frontend)
		_, divider = pane_tree_hit_test(&tab.tree, x*scale, y*scale)
	}
	if divider != nil do shape = .Resize_EW if divider.direction == .Vertical else .Resize_NS
}
