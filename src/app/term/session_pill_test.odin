package term

import "core:testing"

import chrome_dl "../../core/chrome/draw_list"
import sess_feat "../../features/session"

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

	sess, err := sess_feat.session_create(sess_feat.Session_Config{shell = "/bin/sh", rows = 24, cols = 80})
	testing.expect(t, err == .None, "session_create failed")
	testing.expect(t, sess != nil, "session_create returned nil")
	ok := sess_feat.session_registry_detach(&reg, 1, sess)
	testing.expect(t, ok, "detach must succeed")

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