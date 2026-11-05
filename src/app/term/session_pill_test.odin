package term

import "core:testing"

import atlas "../../core/render/atlas"
import chrome_dl "../../core/chrome/draw_list"
import sess_feat "../../features/session"
import tabs_feat "../../features/tabs"

@test
test_pill_label_and_width :: proc(t: ^testing.T) {
	reg: sess_feat.Session_Registry
	sess_feat.session_registry_init(&reg)
	defer sess_feat.session_registry_destroy(&reg)

	buf: [64]u8
	label := session_pill_label(&reg, buf[:])
	testing.expect_value(t, label, "")

	layout: Layout_State
	layout_init(&layout, 2.0, 8, 8, 1.0)
	testing.expect_value(t, session_pill_width(&layout, &reg), f32(0))

	ok := sess_feat.session_registry_apply_row(&reg, {id = 1, state = .Busy, title = "make"}, false)
	testing.expect(t, ok, "a background row must be mirrored")

	label = session_pill_label(&reg, buf[:])
	testing.expect_value(t, label, "1 background")
	testing.expect(t, session_pill_width(&layout, &reg) > 0, "width must be > 0")

	entry := sess_feat.session_registry_find(&reg, 1)
	testing.expect(t, entry != nil, "entry must exist")
	if entry != nil {
		entry.attention = true
	}

	label = session_pill_label(&reg, buf[:])
	testing.expect_value(t, label, "1 background · 1 new")
}

@test
test_geometry_pill_slot :: proc(t: ^testing.T) {
	layout: Layout_State
	layout_init(&layout, 2.0, 8, 8, 1.0)
	layout.screen_w = 2560

	g0 := tab_bar_geometry(&layout, 0)
	testing.expect_value(t, g0.pill_rect[2], f32(0))
	testing.expect_value(t, g0.tabs_end_x, g0.new_tab_x - 16.0)
	// Right edge of overview button aligns with window_margin (8 * scale = 16)
	testing.expect_value(t, g0.overview_x + g0.btn_w, layout.screen_w - layout.metrics.window_margin)

	g1 := tab_bar_geometry(&layout, 120)
	testing.expect_value(t, g1.pill_rect[0] + g1.pill_rect[2], g1.new_tab_x - 16.0)
	testing.expect_value(t, g1.tabs_end_x, g1.pill_rect[0] - 16.0)
}

@test
test_pill_emit_noop_without_sessions :: proc(t: ^testing.T) {
	layout: Layout_State
	layout_init(&layout, 2.0, 8, 8, 1.0)
	layout.screen_w = 2560

	dl: chrome_dl.Ui_Draw_List
	chrome_dl.ui_draw_list_init(&dl)
	defer chrome_dl.ui_draw_list_destroy(&dl)

	g := tab_bar_geometry(&layout, 0)
	session_pill_emit(&dl, &layout, g, nil, false)
	testing.expect_value(t, len(dl.commands), 0)
}

@test
test_layout_set_scale_preserves_ui_atlas_metrics :: proc(t: ^testing.T) {
	dummy_atlas: atlas.Atlas
	layout: Layout_State
	layout_init(&layout, 1.0, 8, 8, 0.45)
	layout.metrics.ui_cell_w = 29.0
	layout.metrics.ui_cell_h = 48.0
	layout.metrics.ui_atlas = &dummy_atlas

	layout_set_scale(&layout, 2.0)
	testing.expect_value(t, layout.metrics.ui_cell_w, f32(29.0))
	testing.expect_value(t, layout.metrics.ui_cell_h, f32(48.0))
	testing.expect_value(t, layout.metrics.ui_atlas, &dummy_atlas)
}

@test
test_tab_bar_hit_test_targets :: proc(t: ^testing.T) {
	layout: Layout_State
	layout_init(&layout, 2.0, 8, 8, 0.45)
	layout.screen_w = 2560

	pill_w: f32 = 160.0
	g := tab_bar_geometry(&layout, pill_w)
	cy := g.tab_y + g.tab_h * 0.5

	h_tab0, in_bar0 := tab_bar_hit_test(&layout, 2, pill_w, g.tabs_x + 24.0, cy)
	testing.expect(t, in_bar0, "must be inside bar")
	testing.expect_value(t, h_tab0.kind, Tab_Bar_Hover_Kind.Tab)
	testing.expect_value(t, h_tab0.tab_idx, 0)

	close_r0, has_close0 := tab_bar_close_rect(g, layout.metrics.scale, g.tabs_x, g.tabs_x, g.tabs_x + g.tab_w)
	testing.expect(t, has_close0, "full tab must have close rect")
	h_close0, _ := tab_bar_hit_test(&layout, 2, pill_w, close_r0[0] + close_r0[2] * 0.5, cy)
	testing.expect_value(t, h_close0.kind, Tab_Bar_Hover_Kind.Tab_Close)
	testing.expect_value(t, h_close0.tab_idx, 0)

	h_pill, _ := tab_bar_hit_test(&layout, 2, pill_w, g.pill_rect[0] + 10.0, cy)
	testing.expect_value(t, h_pill.kind, Tab_Bar_Hover_Kind.Session_Pill)

	h_plus, _ := tab_bar_hit_test(&layout, 2, pill_w, g.new_tab_x + g.btn_w * 0.5, cy)
	testing.expect_value(t, h_plus.kind, Tab_Bar_Hover_Kind.New_Tab)

	h_ov, _ := tab_bar_hit_test(&layout, 2, pill_w, g.overview_x + g.btn_w * 0.5, cy)
	testing.expect_value(t, h_ov.kind, Tab_Bar_Hover_Kind.Overview)
}

@test
test_tab_bar_hover_reveals_inactive_close :: proc(t: ^testing.T) {
	layout: Layout_State
	layout_init(&layout, 2.0, 8, 8, 0.45)
	layout.screen_w = 2560

	tabs: tabs_feat.Tabs_Manager
	tabs_feat.tabs_manager_init(&tabs, layout_compute_tab_bar_rect(&layout))
	defer tabs_feat.tabs_manager_destroy(&tabs)
	tabs_feat.tabs_manager_create_tab(&tabs, "~/project/term", 1)
	tabs_feat.tabs_manager_create_tab(&tabs, "~/project/term", 2)

	dl: chrome_dl.Ui_Draw_List
	chrome_dl.ui_draw_list_init(&dl)
	defer chrome_dl.ui_draw_list_destroy(&dl)

	tab_bar_view_emit(&dl, &layout, &tabs, nil, nil)
	close_count_idle := 0
	for cmd in dl.commands do if cmd.kind == .Text_Run && cmd.text == "✕" do close_count_idle += 1
	testing.expect_value(t, close_count_idle, 1)

	chrome_dl.ui_draw_list_clear(&dl)
	layout.tab_bar_hover = {kind = .Tab, tab_idx = 1}
	tab_bar_view_emit(&dl, &layout, &tabs, nil, nil)
	close_count_hovered := 0
	for cmd in dl.commands do if cmd.kind == .Text_Run && cmd.text == "✕" do close_count_hovered += 1
	testing.expect_value(t, close_count_hovered, 2)

	chrome_dl.ui_draw_list_clear(&dl)
	layout.tab_bar_hover = {kind = .Tab_Close, tab_idx = 0}
	tab_bar_view_emit(&dl, &layout, &tabs, nil, nil)
	has_tip_label, has_tip_keycap, has_shadow := false, false, false
	for cmd in dl.commands {
		if cmd.kind == .Text_Run && cmd.text == "Close Tab" do has_tip_label = true
		if cmd.kind == .Text_Run && cmd.text == "⌘W" do has_tip_keycap = true
		if cmd.kind == .Shadow do has_shadow = true
	}
	testing.expect(t, has_tip_label && has_tip_keycap && !has_shadow, "close button hover must emit shadowless compact tooltip")
}

@test
test_tab_bar_edge_and_clipped_states :: proc(t: ^testing.T) {
	layout: Layout_State
	layout_init(&layout, 2.0, 8, 8, 0.45)
	layout.screen_w = 2560

	// 1. Non-interactive fullscreen slide-out ignores clicks/hovers
	layout.is_fullscreen = true
	layout.tab_bar_anim_t = 0.2
	h_fs, in_fs := tab_bar_hit_test(&layout, 3, 0, 200, 10)
	testing.expect(t, !in_fs, "partially hidden fullscreen bar must not intercept pointer")
	testing.expect_value(t, h_fs.kind, Tab_Bar_Hover_Kind.None)

	// 2. Scroll clamping with negative or excessive offset and clipped tab close guard
	layout.is_fullscreen = false
	layout.tab_bar_anim_t = 1.0
	layout.tab_scroll_offset = -500.0
	layout_tab_bar_clamp_scroll(&layout, 2, 0)
	testing.expect_value(t, layout.tab_scroll_offset, f32(0.0))

	g := tab_bar_geometry(&layout, 0)
	// Scroll tab 0 almost completely off the left edge (only 30px visible < 44*scale)
	layout.tab_scroll_offset = g.tab_w - 30.0
	draw_x := max(g.tabs_x, g.tabs_x - layout.tab_scroll_offset)
	draw_r := min(g.tabs_end_x, g.tabs_x - layout.tab_scroll_offset + g.tab_w)
	_, has_close := tab_bar_close_rect(g, layout.metrics.scale, g.tabs_x - layout.tab_scroll_offset, draw_x, draw_r)
	testing.expect(t, !has_close, "narrow clipped tab sliver must suppress close hit area")
	h_sliver, _ := tab_bar_hit_test(&layout, 2, 0, g.tabs_x + 15.0, g.tab_y + g.tab_h * 0.5)
	testing.expect_value(t, h_sliver.kind, Tab_Bar_Hover_Kind.Tab)
	testing.expect_value(t, h_sliver.tab_idx, 0)
}