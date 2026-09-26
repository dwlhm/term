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
