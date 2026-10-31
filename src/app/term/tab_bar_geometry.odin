package term

// Tab Bar Geometry (single source for render, cursor and click hit tests)
// Part of Tier 3 Application Shell (src/app/term/*).

Tab_Bar_Geometry :: struct {
	bar_h:        f32,
	offset_y:     f32, // fullscreen slide-in offset (≤ 0)
	alpha:        f32, // fullscreen fade factor
	interactive:  bool,
	tab_y, tab_h: f32,
	tab_w, tab_gap: f32,
	tabs_x:       f32, // first tab origin
	tabs_end_x:   f32, // tabs are clipped to [tabs_x, tabs_end_x]
	btn_w:        f32,
	overview_x:   f32,
	new_tab_x:    f32,
	pill_rect:    [4]f32, // zero width when no background session exists
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
	g.tab_h = 22.0 * s
	g.tab_y = (g.bar_h - g.tab_h) * 0.5 + g.offset_y
	g.tab_w = 140.0 * s
	g.tab_gap = 6.0 * s
	g.tabs_x = (12.0 * s) if layout.is_fullscreen else (layout.metrics.traffic_clearance + 6.0 * s)
	g.btn_w = g.tab_h

	btn_gap := 4.0 * s
	g.overview_x = layout.screen_w - 12.0 * s - g.btn_w
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
