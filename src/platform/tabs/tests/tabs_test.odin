package platform_tabs_test

import "core:testing"
import tabs "../"

@(test)
test_tabs_lifecycle :: proc(t: ^testing.T) {
	state: tabs.Tab_Bar_State
	tabs.tabs_init(&state)

	testing.expect_value(t, state.visible_tab_count, 0)
	testing.expect_value(t, state.overflow_count, 0)
	testing.expect_value(t, state.scroll_offset, f32(0))

	rects: [4]tabs.Rect_f32
	titles := []string{"Tab 1", "Tab 2", "Tab 3"}
	count := tabs.tabs_layout(&state, 800, 3, rects[:], 0, titles)

	testing.expect_value(t, count, 3)
	testing.expect(t, state.visible_tab_count > 0)
	testing.expect_value(t, rects[0].h, tabs.TAB_BAR_HEIGHT)

	// Hit test tab 0
	consumed, action, idx := tabs.tabs_dispatch_pointer(
		&state, 3, rects[:],
		rects[0].x + rects[0].w * 0.5,
		tabs.TAB_BAR_HEIGHT * 0.5,
		true, 1, 1,
	)
	testing.expect_value(t, consumed, true)
	testing.expect_value(t, action, tabs.Tab_Action.Switch_Tab)
	testing.expect_value(t, idx, 0)

	// Hit new tab button
	consumed, action, _ = tabs.tabs_dispatch_pointer(
		&state, 3, rects[:],
		state.new_tab_rect.x + state.new_tab_rect.w * 0.5,
		tabs.TAB_BAR_HEIGHT * 0.5,
		true, 1, 1,
	)
	testing.expect_value(t, consumed, true)
	testing.expect_value(t, action, tabs.Tab_Action.New_Tab)

	// Animation update
	tabs.tab_bar_anim_activate(&state)
	testing.expect(t, state.anim.anim_active)
	_ = tabs.tabs_anim_update(&state, 0, 16.0, 100.0, 100.0)

	// Scroll tabs
	scrolled := tabs.tabs_scroll(&state, 1)
	// If tabs fit in 800px, scroll_max is 0 so scroll returns false
	testing.expect(t, state.scroll_offset <= state.scroll_max)
	_ = scrolled
}

@(test)
test_tabs_detached_badge :: proc(t: ^testing.T) {
	state: tabs.Tab_Bar_State
	tabs.tabs_init(&state)
	state.detached_count = 2

	rects: [4]tabs.Rect_f32
	titles := []string{"Tab 1"}
	_ = tabs.tabs_layout(&state, 800, 1, rects[:], 0, titles)

	testing.expect(t, state.detached_badge_rect.w > 0, "detached badge must have width when detached_count > 0")
	testing.expect_value(t, state.detached_badge_rect.h, tabs.TAB_BAR_HEIGHT)

	// Hit test detached badge
	consumed, action, _ := tabs.tabs_dispatch_pointer(
		&state, 1, rects[:],
		state.detached_badge_rect.x + state.detached_badge_rect.w * 0.5,
		tabs.TAB_BAR_HEIGHT * 0.5,
		true, 1, 1,
	)
	testing.expect_value(t, consumed, true)
	testing.expect_value(t, action, tabs.Tab_Action.Open_Session_Switcher)
}

@(test)
test_tabs_detached_badge_trails_strip :: proc(t: ^testing.T) {
	state: tabs.Tab_Bar_State
	tabs.tabs_init(&state)
	state.detached_count = 3

	rects: [4]tabs.Rect_f32
	titles := []string{"Tab 1", "Tab 2", "Tab 3"}
	_ = tabs.tabs_layout(&state, 800, 3, rects[:], 0, titles)

	badge := state.detached_badge_rect
	testing.expect(t, badge.w > 0, "detached badge must have width when detached_count > 0")

	// The badge is pinned to the right corner, opposite the left-anchored strip.
	testing.expect(
		t, abs((badge.x + badge.w) - state.rect.w) <= 1.0,
		"badge must end flush with the tab bar right edge",
	)

	strip_end: f32 = 0
	for i in 0 ..< 3 {
		if rects[i].w > 0 && rects[i].x + rects[i].w > strip_end do strip_end = rects[i].x + rects[i].w
	}
	testing.expect(t, badge.x > strip_end, "badge must start right of the last visible tab")

	// The drag surface stops at the badge and the strip viewport stays on the left.
	testing.expect(
		t, state.drag_rect.x + state.drag_rect.w <= badge.x + 1.0,
		"drag surface must stop where the badge begins",
	)
	testing.expect(t, abs(state.viewport_rect.x - state.left_offset) <= 1.0, "viewport must stay anchored to the strip origin")

	when ODIN_OS == .Darwin {
		testing.expect_value(t, state.left_offset, tabs.TRAFFIC_LIGHT_OFFSET_DARWIN)
	}

	// Clicking the relocated badge still opens the session switcher.
	consumed, action, _ := tabs.tabs_dispatch_pointer(
		&state, 3, rects[:],
		badge.x + badge.w * 0.5,
		tabs.TAB_BAR_HEIGHT * 0.5,
		true, 1, 1,
	)
	testing.expect_value(t, consumed, true)
	testing.expect_value(t, action, tabs.Tab_Action.Open_Session_Switcher)
}

@(test)
test_tabs_detached_badge_hidden_without_sessions :: proc(t: ^testing.T) {
	state: tabs.Tab_Bar_State
	tabs.tabs_init(&state)
	state.detached_count = 0

	rects: [4]tabs.Rect_f32
	titles := []string{"Tab 1", "Tab 2", "Tab 3"}
	_ = tabs.tabs_layout(&state, 800, 3, rects[:], 0, titles)

	badge := state.detached_badge_rect
	testing.expect_value(t, badge.x, f32(0))
	testing.expect_value(t, badge.y, f32(0))
	testing.expect_value(t, badge.w, f32(0))
	testing.expect_value(t, badge.h, f32(0))

	// With no badge the right corner is not a target.
	target, _ := tabs.tab_bar_hit_test(&state, 3, rects[:], 799.0, tabs.TAB_BAR_HEIGHT * 0.5)
	testing.expect_value(t, target, tabs.Tab_Hit_Target.None)
}
