package term

// Tab Bar Geometry & Hit Testing (single source for render, cursor, hover and click)
// Part of Tier 3 Application Shell (src/app/term/*).

Tab_Bar_Hover_Kind :: enum u8 {
	None,
	Tab,
	Tab_Close,
	Session_Pill,
	New_Tab,
	Overview,
}

Tab_Bar_Hover :: struct {
	kind:    Tab_Bar_Hover_Kind,
	tab_idx: int,
}

Tab_Bar_Geometry :: struct {
	bar_h:          f32,
	offset_y:       f32, // fullscreen slide-in offset (≤ 0)
	alpha:          f32, // fullscreen fade factor
	interactive:    bool,
	tab_y, tab_h:   f32,
	tab_w, tab_gap: f32,
	tabs_x:         f32, // first tab origin
	tabs_end_x:     f32, // tabs are clipped to [tabs_x, tabs_end_x]
	btn_w:          f32,
	overview_x:     f32,
	new_tab_x:      f32,
	pill_rect:      [4]f32, // zero width when no background session exists
}

// tab_bar_geometry computes the tab bar layout. pill_w is the width of the
// background-session pill (0 hides it); the pill sits left of [+] and the
// tab strip ends before it.
tab_bar_geometry :: proc(layout: ^Layout_State, pill_w: f32 = 0) -> Tab_Bar_Geometry {
	s := layout.metrics.scale
	g: Tab_Bar_Geometry
	g.bar_h = layout.metrics.tab_bar_height
	g.offset_y = -(1.0 - layout.tab_bar_anim_t) * (g.bar_h + 6.0 * s) if layout.is_fullscreen else 0.0
	g.alpha = layout.tab_bar_anim_t if layout.is_fullscreen else 1.0
	g.interactive = !layout.is_fullscreen || layout.tab_bar_anim_t > 0.5
	g.tab_h = 26.0 * s
	g.tab_y = (g.bar_h - g.tab_h) * 0.5 + g.offset_y
	g.tab_w = 164.0 * s
	g.tab_gap = 6.0 * s
	right_margin := max(8.0 * s, layout.metrics.window_margin)
	g.tabs_x = right_margin if layout.is_fullscreen else (layout.metrics.traffic_clearance + 6.0 * s)
	g.btn_w = g.tab_h

	btn_gap := 6.0 * s
	g.overview_x = layout.screen_w - right_margin - g.btn_w
	g.new_tab_x = g.overview_x - btn_gap - g.btn_w
	right_edge := g.new_tab_x
	if pill_w > 0 {
		g.pill_rect = {g.new_tab_x - 8.0 * s - pill_w, g.tab_y, pill_w, g.tab_h}
		right_edge = g.pill_rect[0]
	}
	g.tabs_end_x = right_edge - 8.0 * s
	return g
}

tab_bar_point_in :: proc "contextless" (r: [4]f32, x, y: f32) -> bool {
	return r[2] > 0 && x >= r[0] && x <= r[0] + r[2] && y >= r[1] && y <= r[1] + r[3]
}

// tab_bar_close_rect returns the concentric circular close button rect for a tab item
// and reports whether it fits inside the visible tab strip.
// Concentric radii: outer tab_h = 26 (r_out = 13), inner close_d = 18 (r_in = 9), pad = 4 -> 9 + 4 = 13.
tab_bar_close_rect :: proc "contextless" (g: Tab_Bar_Geometry, scale, tab_item_x, draw_x, draw_r: f32) -> (rect: [4]f32, visible: bool) {
	pad := 4.0 * scale
	close_d := g.tab_h - 2.0 * pad
	cx := tab_item_x + g.tab_w - pad - close_d
	cy := g.tab_y + pad
	draw_w := draw_r - draw_x
	visible = (cx + close_d <= draw_r + 0.5) && (draw_w >= 44.0 * scale)
	return {cx, cy, close_d, close_d}, visible
}

// tab_bar_hit_test resolves which interactive top-bar element contains (mx, my).
tab_bar_hit_test :: proc(layout: ^Layout_State, tab_count: int, pill_w, mx, my: f32) -> (hover: Tab_Bar_Hover, in_bar: bool) {
	hover = {kind = .None, tab_idx = -1}
	if layout == nil do return hover, false
	g := tab_bar_geometry(layout, pill_w)
	if !g.interactive || my < 0 || my > (g.bar_h + g.offset_y) {
		return hover, false
	}
	if tab_bar_point_in({g.overview_x, g.tab_y, g.btn_w, g.tab_h}, mx, my) {
		return {kind = .Overview, tab_idx = -1}, true
	}
	if tab_bar_point_in({g.new_tab_x, g.tab_y, g.btn_w, g.tab_h}, mx, my) {
		return {kind = .New_Tab, tab_idx = -1}, true
	}
	if tab_bar_point_in(g.pill_rect, mx, my) {
		return {kind = .Session_Pill, tab_idx = -1}, true
	}
	s := layout.metrics.scale
	for i in 0..<tab_count {
		tab_item_x := g.tabs_x + f32(i) * (g.tab_w + g.tab_gap) - layout.tab_scroll_offset
		draw_x := max(g.tabs_x, tab_item_x)
		draw_r := min(g.tabs_end_x, tab_item_x + g.tab_w)
		if draw_x >= draw_r do continue
		if tab_bar_point_in({draw_x, g.tab_y, draw_r - draw_x, g.tab_h}, mx, my) {
			close_r, has_close := tab_bar_close_rect(g, s, tab_item_x, draw_x, draw_r)
			if has_close && tab_bar_point_in(close_r, mx, my) {
				return {kind = .Tab_Close, tab_idx = i}, true
			}
			return {kind = .Tab, tab_idx = i}, true
		}
	}
	return hover, true
}
