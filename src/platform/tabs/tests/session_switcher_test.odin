package platform_tabs_test

import "core:testing"
import tabs "../"
import input "../../input"

@(test)
test_session_switcher_fuzzy_matching :: proc(t: ^testing.T) {
	// Empty query matches everything
	matched, score := tabs.session_switcher_fuzzy_match("", "terminal")
	testing.expect(t, matched)
	testing.expect_value(t, score, 0)

	// Non-matching query
	matched, score = tabs.session_switcher_fuzzy_match("xyz", "terminal")
	testing.expect(t, !matched)
	testing.expect_value(t, score, 0)

	// Case-insensitivity
	matched, score = tabs.session_switcher_fuzzy_match("ZSH", "zsh shell")
	testing.expect(t, matched)
	testing.expect(t, score > 0)

	// Subsequence match
	matched, score = tabs.session_switcher_fuzzy_match("sh", "zsh")
	testing.expect(t, matched)
	testing.expect(t, score > 0)

	// Prefix bonus check: prefix match scores higher than internal match
	matched_pre, score_pre := tabs.session_switcher_fuzzy_match("term", "terminal")
	matched_sub, score_sub := tabs.session_switcher_fuzzy_match("term", "subterminal")
	testing.expect(t, matched_pre)
	testing.expect(t, matched_sub)
	testing.expect(t, score_pre > score_sub)

	// Word boundary bonus: match right after delimiter scores higher than non-boundary
	matched_wb, score_wb := tabs.session_switcher_fuzzy_match("proj", "my_project")
	matched_nb, score_nb := tabs.session_switcher_fuzzy_match("proj", "apropos_job")
	testing.expect(t, matched_wb)
	testing.expect(t, matched_nb)
	testing.expect(t, score_wb > score_nb)
}

@(test)
test_session_switcher_filter_and_ordering :: proc(t: ^testing.T) {
	state: tabs.Session_Switcher_State
	tabs.session_switcher_init(&state)

	// Item 0: zsh
	state.items[0].title = "zsh"
	state.items[0].cwd = "/Users/dev"
	state.items[0].pid = 100
	state.items[0].is_detached = false
	state.items[0].tab_idx = 0

	// Item 1: vim (has project in path)
	state.items[1].title = "vim"
	state.items[1].cwd = "/Users/dev/project"
	state.items[1].pid = 200
	state.items[1].is_detached = false
	state.items[1].tab_idx = 1

	// Item 2: project_build (detached, prefix project in title)
	state.items[2].title = "project_build"
	state.items[2].cwd = "/tmp"
	state.items[2].pid = 300
	state.items[2].is_detached = true
	state.items[2].tab_idx = -1

	state.item_count = 3

	// Query "proj"
	copy(state.query[:], "proj")
	state.query_len = 4
	tabs.session_switcher_filter(&state)

	testing.expect_value(t, state.match_count, 2)
	// Item 2 (prefix match on title "project_build") should score higher than Item 1
	testing.expect_value(t, state.matches[0], 2)
	testing.expect_value(t, state.matches[1], 1)

	// Selection clamping: index exceeding match count is clamped
	state.selected_match_idx = 10
	tabs.session_switcher_filter(&state)
	testing.expect_value(t, state.selected_match_idx, state.match_count - 1)

	// Zero matches clamps selection to 0
	copy(state.query[:], "nonexistent_query_999")
	state.query_len = 21
	tabs.session_switcher_filter(&state)
	testing.expect_value(t, state.match_count, 0)
	testing.expect_value(t, state.selected_match_idx, 0)
}

@(test)
test_session_switcher_keyboard_navigation :: proc(t: ^testing.T) {
	state: tabs.Session_Switcher_State
	tabs.session_switcher_init(&state)
	state.visible = true

	state.items[0].title = "alpha"
	state.items[0].is_detached = false
	state.items[0].tab_idx = 0

	state.items[1].title = "beta"
	state.items[1].is_detached = false
	state.items[1].tab_idx = 1

	state.items[2].title = "gamma"
	state.items[2].is_detached = true
	state.items[2].tab_idx = -1

	state.item_count = 3
	tabs.session_switcher_filter(&state)
	testing.expect_value(t, state.match_count, 3)
	state.selected_match_idx = 0

	// 1. Up arrow wraps around to last item
	ev_up := input.Input_Event{event_type = .Key, kind = .Arrow_Up}
	consumed, action, item := tabs.session_switcher_dispatch_key(&state, ev_up)
	testing.expect(t, consumed)
	testing.expect_value(t, action, tabs.Session_Switcher_Action.None)
	testing.expect_value(t, state.selected_match_idx, 2)

	// 2. Down arrow wraps around to first item
	ev_down := input.Input_Event{event_type = .Key, kind = .Arrow_Down}
	consumed, action, item = tabs.session_switcher_dispatch_key(&state, ev_down)
	testing.expect(t, consumed)
	testing.expect_value(t, action, tabs.Session_Switcher_Action.None)
	testing.expect_value(t, state.selected_match_idx, 0)

	// Down arrow advances to 1
	consumed, action, item = tabs.session_switcher_dispatch_key(&state, ev_down)
	testing.expect_value(t, state.selected_match_idx, 1)

	// 3. Typing characters into search query
	ev_char := input.Input_Event{event_type = .Key, kind = .Printable, rune = 'a'}
	consumed, action, item = tabs.session_switcher_dispatch_key(&state, ev_char)
	testing.expect(t, consumed)
	testing.expect_value(t, state.query_len, 1)
	testing.expect_value(t, state.query[0], u8('a'))

	// 4. Backspace removes character
	ev_bs := input.Input_Event{event_type = .Key, kind = .Backspace}
	consumed, action, item = tabs.session_switcher_dispatch_key(&state, ev_bs)
	testing.expect(t, consumed)
	testing.expect_value(t, state.query_len, 0)

	// 5. Enter on active tab returns .Switch_Tab
	state.selected_match_idx = 0 // Item 0 is active
	ev_enter := input.Input_Event{event_type = .Key, kind = .Enter}
	consumed, action, item = tabs.session_switcher_dispatch_key(&state, ev_enter)
	testing.expect(t, consumed)
	testing.expect_value(t, action, tabs.Session_Switcher_Action.Switch_Tab)
	testing.expect_value(t, item.tab_idx, 0)

	// Enter on detached session returns .Attach
	state.selected_match_idx = 2 // Item 2 is detached
	consumed, action, item = tabs.session_switcher_dispatch_key(&state, ev_enter)
	testing.expect(t, consumed)
	testing.expect_value(t, action, tabs.Session_Switcher_Action.Attach)
	testing.expect_value(t, item.tab_idx, -1)

	// 6. Escape returns .Close
	ev_esc := input.Input_Event{event_type = .Key, kind = .Escape}
	consumed, action, item = tabs.session_switcher_dispatch_key(&state, ev_esc)
	testing.expect(t, consumed)
	testing.expect_value(t, action, tabs.Session_Switcher_Action.Close)

	// 7. Alt+Cmd+b detaches only an open tab
	state.selected_match_idx = 0
	ev_b := input.Input_Event{event_type = .Key, alt = true, gui = true, rune = 'b'}
	consumed, action, item = tabs.session_switcher_dispatch_key(&state, ev_b)
	testing.expect(t, consumed)
	testing.expect_value(t, action, tabs.Session_Switcher_Action.Detach)

	// 8. Ctrl+X returns .Terminate
	ev_x := input.Input_Event{event_type = .Key, ctrl = true, rune = 'x'}
	consumed, action, item = tabs.session_switcher_dispatch_key(&state, ev_x)
	testing.expect(t, consumed)
	testing.expect_value(t, action, tabs.Session_Switcher_Action.Terminate)
}

@(test)
test_session_switcher_lifecycle :: proc(t: ^testing.T) {
	state: tabs.Session_Switcher_State
	tabs.session_switcher_init(&state)
	testing.expect(t, !state.visible)
	testing.expect_value(t, state.item_count, 0)

	dummy_tabs := [2]tabs.Tab_Session{
		{id = 1, title = "Tab 1", pid = 10, cwd = "/home", is_active = true},
		{id = 2, title = "Tab 2", pid = 20, cwd = "/var", is_active = false},
	}

	tabs.session_switcher_show(&state, dummy_tabs[:], 0, nil)
	testing.expect(t, state.visible)
	testing.expect_value(t, state.item_count, 2)
	testing.expect_value(t, state.match_count, 2)
	testing.expect_value(t, state.selected_match_idx, 0)

	// Layout check
	tabs.session_switcher_layout(&state, 800, 600)
	testing.expect(t, state.rect.w > 0)
	testing.expect(t, state.rect.h > 0)
	testing.expect(t, state.rect.x >= 0)
	testing.expect(t, state.rect.y >= 0)

	// Hide
	tabs.session_switcher_hide(&state)
	testing.expect(t, !state.visible)
	testing.expect_value(t, state.query_len, 0)
}

@(test)
test_session_switcher_scrolled_row_pointer_and_viewport :: proc(t: ^testing.T) {
	state: tabs.Session_Switcher_State
	tabs.session_switcher_init(&state)
	state.visible = true
	for i in 0 ..< 20 {
		state.items[i].title = "session"
		state.items[i].tab_idx = i
	}
	state.item_count = 20
	tabs.session_switcher_filter(&state)
	tabs.session_switcher_layout(&state, 640, 480)
	for i in 0 ..< 12 {
		_, _, _ = tabs.session_switcher_dispatch_key(&state, input.Input_Event{event_type = .Key, kind = .Arrow_Down})
	}
	testing.expect(t, state.scroll_offset > 0)
	rr := tabs.session_switcher_row_rect(&state, state.selected_match_idx - state.scroll_offset)
	action, item := tabs.session_switcher_dispatch_pointer(&state, rr.x + 4, rr.y + 4, true)
	testing.expect_value(t, action, tabs.Session_Switcher_Action.Switch_Tab)
	testing.expect_value(t, item.tab_idx, 12)
	tabs.session_switcher_layout(&state, 120, 90)
	testing.expect(t, state.rect.x >= 0 && state.rect.y >= 0)
	testing.expect(t, state.rect.x + state.rect.w <= 120)
	testing.expect(t, state.rect.y + state.rect.h <= 90)
	action, _ = tabs.session_switcher_dispatch_pointer(&state, -1, -1, true)
	testing.expect_value(t, action, tabs.Session_Switcher_Action.Close)
}
