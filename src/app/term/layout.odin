package term

// Uniform Window Margin, Pane Gap, & Floating Pane Geometry Engine
// Part of Tier 3 Application Shell (src/app/term/*).
// Invariant: Window Outer Margin == Inner Pane Gap == WINDOW_MARGIN.

import "base:runtime"
import "core:math"
import chrome_splits "../../core/chrome/splits"

Layout_State :: struct {
	screen_w:         f32,
	screen_h:         f32,
	mouse_y:          f32,
	tab_bar_hovered:  bool,
	tab_bar_force:    bool,
	tab_bar_anim_t:   f32, // 0.0 (hidden) .. 1.0 (fully visible)
	metrics:          Visual_Metrics,
}

layout_init :: proc(l: ^Layout_State, scale: f32 = 1.0, pad_x: f32 = DEFAULT_PANE_PAD_X, pad_y: f32 = DEFAULT_PANE_PAD_Y) {
	if l == nil do return
	l.metrics = visual_metrics_make(scale, pad_x, pad_y)
	l.screen_w = f32(DEFAULT_WINDOW_WIDTH) * l.metrics.scale
	l.screen_h = f32(DEFAULT_WINDOW_HEIGHT) * l.metrics.scale
	l.mouse_y = 100.0 * l.metrics.scale
	l.tab_bar_hovered = false
	l.tab_bar_force = false
	l.tab_bar_anim_t = 1.0 // Start visible, then auto-hide
}

layout_set_scale :: proc(l: ^Layout_State, scale: f32) {
	if l == nil do return
	prev_cell_w := l.metrics.cell_w
	prev_cell_h := l.metrics.cell_h
	prev_pad_x := l.metrics.pane_pad_x / l.metrics.scale if l.metrics.scale > 0 else DEFAULT_PANE_PAD_X
	prev_pad_y := l.metrics.pane_pad_y / l.metrics.scale if l.metrics.scale > 0 else DEFAULT_PANE_PAD_Y
	l.metrics = visual_metrics_make(scale, prev_pad_x, prev_pad_y)
	if prev_cell_w > 0 do l.metrics.cell_w = prev_cell_w
	if prev_cell_h > 0 do l.metrics.cell_h = prev_cell_h
}

layout_update :: proc(l: ^Layout_State, dt: f32) {
	if l == nil do return

	should_show := (l.mouse_y <= l.metrics.auto_hide_trigger_y) || l.tab_bar_force || l.tab_bar_hovered
	target_t: f32 = 1.0 if should_show else 0.0

	// Smooth animation interpolation
	speed: f32 = 10.0
	if l.tab_bar_anim_t < target_t {
		l.tab_bar_anim_t = min(target_t, l.tab_bar_anim_t + speed * dt)
	} else if l.tab_bar_anim_t > target_t {
		l.tab_bar_anim_t = max(target_t, l.tab_bar_anim_t - speed * dt)
	}
}

// layout_compute_content_area returns the outer bounding rect for terminal panes
// Invariant: Content area strictly lives below the top tab bar.
layout_compute_content_area :: proc(l: ^Layout_State) -> [4]f32 {
	if l == nil do return {0, 0, 0, 0}
	m := l.metrics.window_margin
	top_y := l.metrics.tab_bar_height
	return {
		m,
		top_y + m,
		max(1.0, l.screen_w - 2.0 * m),
		max(1.0, l.screen_h - top_y - 2.0 * m),
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
