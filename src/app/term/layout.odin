package term

// Uniform Window Margin, Pane Gap, & Floating Pane Geometry Engine
// Part of Tier 3 Application Shell (src/app/term/*).
// Invariant: Window Outer Margin == Inner Pane Gap == WINDOW_MARGIN.

import "base:runtime"
import "core:math"
import chrome_splits "../../core/chrome/splits"

Layout_State :: struct {
	screen_w:             f32,
	screen_h:             f32,
	mouse_y:              f32,
	is_fullscreen:        bool,
	tab_bar_hovered:      bool,
	tab_bar_hover:        Tab_Bar_Hover,
	tab_bar_force:        bool,
	tab_bar_reveal_timer: f32, // Seconds to keep tab bar visible after an action in fullscreen
	tab_bar_anim_t:       f32, // 0.0 (hidden) .. 1.0 (fully visible)
	tab_scroll_offset:    f32, // Horizontal scroll offset for tab bar
	metrics:              Visual_Metrics,
}

layout_init :: proc(l: ^Layout_State, scale: f32 = 1.0, pad_x: f32 = DEFAULT_PANE_PAD_X, pad_y: f32 = DEFAULT_PANE_PAD_Y, pane_opacity: f32 = 0.45) {
	if l == nil do return
	l.metrics = visual_metrics_make(scale, pad_x, pad_y, pane_opacity)
	l.screen_w = f32(DEFAULT_WINDOW_WIDTH) * l.metrics.scale
	l.screen_h = f32(DEFAULT_WINDOW_HEIGHT) * l.metrics.scale
	l.mouse_y = 100.0 * l.metrics.scale
	l.is_fullscreen = false
	l.tab_bar_hovered = false
	l.tab_bar_hover = {kind = .None, tab_idx = -1}
	l.tab_bar_force = false
	l.tab_bar_reveal_timer = 0.0
	l.tab_bar_anim_t = 1.0
	l.tab_scroll_offset = 0.0
}

layout_tab_bar_clamp_scroll :: proc(l: ^Layout_State, tab_count: int, pill_w: f32 = 0) {
	if l == nil do return
	g := tab_bar_geometry(l, pill_w)
	total_tabs_w := f32(tab_count) * g.tab_w + f32(max(0, tab_count - 1)) * g.tab_gap
	avail_w := max(40.0 * l.metrics.scale, g.tabs_end_x - g.tabs_x)
	max_scroll := max(0.0, total_tabs_w - avail_w)
	l.tab_scroll_offset = clamp(l.tab_scroll_offset, 0.0, max_scroll)
}

layout_tab_bar_ensure_visible :: proc(l: ^Layout_State, tab_idx: int, tab_count: int, pill_w: f32 = 0) {
	if l == nil || tab_idx < 0 do return
	g := tab_bar_geometry(l, pill_w)
	tab_left := f32(tab_idx) * (g.tab_w + g.tab_gap)
	tab_right := tab_left + g.tab_w
	avail_w := max(40.0 * l.metrics.scale, g.tabs_end_x - g.tabs_x)

	if tab_left < l.tab_scroll_offset {
		l.tab_scroll_offset = tab_left
	} else if tab_right > l.tab_scroll_offset + avail_w {
		l.tab_scroll_offset = tab_right - avail_w
	}
	layout_tab_bar_clamp_scroll(l, tab_count, pill_w)
}

layout_set_scale :: proc(l: ^Layout_State, scale: f32) {
	if l == nil do return
	prev_cell_w := l.metrics.cell_w
	prev_cell_h := l.metrics.cell_h
	prev_ui_cell_w := l.metrics.ui_cell_w
	prev_ui_cell_h := l.metrics.ui_cell_h
	prev_ui_atlas := l.metrics.ui_atlas
	prev_pad_x := l.metrics.pane_pad_x / l.metrics.scale if l.metrics.scale > 0 else DEFAULT_PANE_PAD_X
	prev_pad_y := l.metrics.pane_pad_y / l.metrics.scale if l.metrics.scale > 0 else DEFAULT_PANE_PAD_Y
	prev_pane_opacity := l.metrics.pane_opacity
	l.metrics = visual_metrics_make(scale, prev_pad_x, prev_pad_y, prev_pane_opacity)
	if prev_cell_w > 0 do l.metrics.cell_w = prev_cell_w
	if prev_cell_h > 0 do l.metrics.cell_h = prev_cell_h
	if prev_ui_cell_w > 0 do l.metrics.ui_cell_w = prev_ui_cell_w
	if prev_ui_cell_h > 0 do l.metrics.ui_cell_h = prev_ui_cell_h
	if prev_ui_atlas != nil do l.metrics.ui_atlas = prev_ui_atlas
}

layout_update :: proc(l: ^Layout_State, dt: f32) {
	if l == nil do return

	if l.tab_bar_reveal_timer > 0.0 {
		l.tab_bar_reveal_timer = max(0.0, l.tab_bar_reveal_timer - dt)
	}

	should_show := !l.is_fullscreen || (l.mouse_y <= l.metrics.auto_hide_trigger_y) || l.tab_bar_force || l.tab_bar_hovered || (l.tab_bar_reveal_timer > 0.0)
	target_t: f32 = 1.0 if should_show else 0.0

	// Smooth animation interpolation
	speed: f32 = 12.0
	if l.tab_bar_anim_t < target_t {
		l.tab_bar_anim_t = min(target_t, l.tab_bar_anim_t + speed * dt)
	} else if l.tab_bar_anim_t > target_t {
		l.tab_bar_anim_t = max(target_t, l.tab_bar_anim_t - speed * dt)
	}
}

// layout_compute_content_area returns the outer bounding rect for terminal panes
// Invariant: In windowed mode, content area strictly lives below the top tab bar.
// In fullscreen mode, content area fills the entire screen so terminal panes have full height.
layout_compute_content_area :: proc(l: ^Layout_State) -> [4]f32 {
	if l == nil do return {0, 0, 0, 0}
	m := l.metrics.window_margin
	if l.is_fullscreen {
		return {
			m,
			m,
			max(1.0, l.screen_w - 2.0 * m),
			max(1.0, l.screen_h - 2.0 * m),
		}
	}
	top_y := l.metrics.tab_bar_height
	top_gap := 4.0 * l.metrics.scale
	y := top_y + top_gap
	return {
		m,
		y,
		max(1.0, l.screen_w - 2.0 * m),
		max(1.0, l.screen_h - y - m),
	}
}

// layout_compute_tab_bar_rect returns the top bar bounds across the window header
layout_compute_tab_bar_rect :: proc(l: ^Layout_State) -> [4]f32 {
	if l == nil do return {0, 0, 0, 0}
	return {0, 0, l.screen_w, l.metrics.tab_bar_height}
}

// layout_split_tree_with_uniform_gaps distributes target_rect recursively ensuring
// the gap between adjacent child panes equals PANE_GAP (which equals WINDOW_MARGIN).
layout_split_tree_with_uniform_gaps :: proc(node: ^chrome_splits.Split_Node, target_rect: [4]f32, gap: f32 = PANE_GAP) {
	if node == nil do return
	node.rect = target_rect

	if node.kind == .Leaf do return

	x := target_rect[0]
	y := target_rect[1]
	w := target_rect[2]
	h := target_rect[3]
	ratio := chrome_splits.split_effective_ratio(node)

	if node.kind == .Horizontal {
		avail_w := max(0.0, w - gap)
		left_w := avail_w * ratio
		right_w := avail_w - left_w

		if node.left != nil {
			layout_split_tree_with_uniform_gaps(node.left, {x, y, left_w, h}, gap)
		}
		if node.right != nil {
			layout_split_tree_with_uniform_gaps(node.right, {x + left_w + gap, y, right_w, h}, gap)
		}
	} else if node.kind == .Vertical {
		avail_h := max(0.0, h - gap)
		top_h := avail_h * ratio
		bottom_h := avail_h - top_h

		if node.left != nil {
			layout_split_tree_with_uniform_gaps(node.left, {x, y, w, top_h}, gap)
		}
		if node.right != nil {
			layout_split_tree_with_uniform_gaps(node.right, {x, y + top_h + gap, w, bottom_h}, gap)
		}
	}
}
