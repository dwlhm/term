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
test_tabs_detached_badge_leads_strip :: proc(t: ^testing.T) {
	state: tabs.Tab_Bar_State
	tabs.tabs_init(&state)
	state.detached_count = 3

	rects: [4]tabs.Rect_f32
	titles := []string{"Tab 1", "Tab 2", "Tab 3"}
	_ = tabs.tabs_layout(&state, 800, 3, rects[:], 0, titles)

	badge := state.detached_badge_rect
	testing.expect(t, badge.w > 0, "detached badge must have width when detached_count > 0")

	// The badge sits at the left edge and the strip starts right after it.
	strip_x := rects[0].x
	for i in 1 ..< 3 {
		if rects[i].w > 0 && rects[i].x < strip_x do strip_x = rects[i].x
	}
	testing.expect(t, badge.x < strip_x, "badge must start left of the first tab")
	testing.expect(t, abs(strip_x - (badge.x + badge.w)) <= 1.0, "tab strip must start where the badge ends")
	testing.expect(t, abs(strip_x - state.left_offset) <= 1.0, "left_offset must track the strip origin")

	when ODIN_OS == .Darwin {
		testing.expect(t, abs(badge.x - tabs.TRAFFIC_LIGHT_OFFSET_DARWIN) <= 1.0, "badge must sit at the traffic-light offset")
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

	// With no detached sessions the badge collapses and the strip returns to the
	// plain traffic-light offset.
	state.detached_count = 0
	_ = tabs.tabs_layout(&state, 800, 3, rects[:], 0, titles)
	testing.expect_value(t, state.detached_badge_rect.w, f32(0))
	testing.expect_value(t, rects[0].x, state.left_offset)
	when ODIN_OS == .Darwin {
		testing.expect_value(t, rects[0].x, tabs.TRAFFIC_LIGHT_OFFSET_DARWIN)
	}
}
