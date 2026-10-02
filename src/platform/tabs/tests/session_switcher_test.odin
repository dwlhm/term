package platform_tabs_test

import "core:fmt"
import "core:mem"
import "core:strings"
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
	action, item := tabs.session_switcher_dispatch_pointer(&state, _left_click(rr.x + 4, rr.y + 4))
	testing.expect_value(t, action, tabs.Session_Switcher_Action.Switch_Tab)
	testing.expect_value(t, item.tab_idx, 12)
	tabs.session_switcher_layout(&state, 120, 90)
	testing.expect(t, state.rect.x >= 0 && state.rect.y >= 0)
	testing.expect(t, state.rect.x + state.rect.w <= 120)
	testing.expect(t, state.rect.y + state.rect.h <= 90)
	action, _ = tabs.session_switcher_dispatch_pointer(&state, _left_click(-1, -1))
	testing.expect_value(t, action, tabs.Session_Switcher_Action.Close)
}

// _switcher_with_rows builds a visible switcher whose items are given the supplied kind.
_switcher_with_rows :: proc(state: ^tabs.Session_Switcher_State, count: int, detached: []bool, persisted: []bool = nil) {
	tabs.session_switcher_init(state)
	state.visible = true
	for i in 0 ..< count {
		state.items[i].title = fmt.bprintf(state.items[i].title_buf[:], "s%d", i)
		state.items[i].cwd = "/tmp"
		state.items[i].tab_idx = i
		state.items[i].pane_count = 1
		if detached != nil {
			state.items[i].is_detached = detached[i]
			state.items[i].tab_idx = -1 if detached[i] else i
		}
		if persisted != nil do state.items[i].is_persisted = persisted[i]
	}
	state.item_count = count
	tabs.session_switcher_filter(state)
	tabs.session_switcher_layout(state, 800, 600)
}

// _left_click / _right_click build the pointer events the switcher routes on.
_left_click :: proc(x, y: f32) -> input.Input_Pointer_Event {
	return input.Input_Pointer_Event{kind = .Button_Down, button = 1, x = x, y = y}
}

_right_click :: proc(x, y: f32) -> input.Input_Pointer_Event {
	return input.Input_Pointer_Event{kind = .Button_Down, button = tabs.SESSION_SWITCHER_BUTTON_RIGHT, x = x, y = y}
}

// _press_menu_item clicks the center of a menu entry.
_press_menu_item :: proc(state: ^tabs.Session_Switcher_State, entry: tabs.Session_Switcher_Menu_Item) -> (tabs.Session_Switcher_Action, tabs.Session_Switcher_Item) {
	ir := state.menu.item_rects[int(entry)]
	return tabs.session_switcher_dispatch_pointer(state, _left_click(ir.x + ir.w * 0.5, ir.y + ir.h * 0.5))
}

// _open_menu_at right-clicks a row to open its menu at a point inside that row.
_open_menu_at :: proc(t: ^testing.T, state: ^tabs.Session_Switcher_State, row: int, px, py: f32) {
	rr := tabs.session_switcher_row_rect(state, row)
	action, _ := tabs.session_switcher_dispatch_pointer(state, _right_click(min(px, rr.x + rr.w - 2), min(py, rr.y + rr.h - 2)), 0, 800, 600)
	testing.expect_value(t, action, tabs.Session_Switcher_Action.None)
	testing.expect(t, state.menu.visible, "the row menu must be open")
}

// _expect_menu_rules right-clicks a row and asserts the entry enable rules for its kind.
_expect_menu_rules :: proc(t: ^testing.T, state: ^tabs.Session_Switcher_State, row: int, background, split, layout: bool) {
	tabs.session_switcher_menu_close(&state.menu)
	rr := tabs.session_switcher_row_rect(state, row)
	action, _ := tabs.session_switcher_dispatch_pointer(state, _right_click(rr.x + 8, rr.y + rr.h * 0.5), 0, 800, 600)
	testing.expect_value(t, action, tabs.Session_Switcher_Action.None)
	testing.expect(t, !state.menu.disabled[int(tabs.Session_Switcher_Menu_Item.Activate)], "every row kind can be activated")
	// Detach needs a single-pane tab, so it is unavailable for split panes,
	// background sessions and saved layouts alike.
	can_detach := !background && !split && !layout
	testing.expect_value(t, state.menu.disabled[int(tabs.Session_Switcher_Menu_Item.Move_To_Background)], !can_detach)
	testing.expect_value(t, state.menu.disabled[int(tabs.Session_Switcher_Menu_Item.Close)], layout)
}

@(test)
test_session_switcher_right_click_opens_menu_without_activating :: proc(t: ^testing.T) {
	state: tabs.Session_Switcher_State
	_switcher_with_rows(&state, 4, []bool{false, true, false, false})
	testing.expect(t, !state.menu.visible)

	// Right-clicking a row opens the menu on it and activates nothing.
	rr := tabs.session_switcher_row_rect(&state, 2)
	action, _ := tabs.session_switcher_dispatch_pointer(&state, _right_click(rr.x + 10, rr.y + rr.h * 0.5), 0, 800, 600)
	testing.expect_value(t, action, tabs.Session_Switcher_Action.None)
	testing.expect(t, state.menu.visible, "a right-click on a row opens its menu")
	testing.expect_value(t, state.menu.target_idx, 2)
	testing.expect_value(t, state.menu.hover_item, -1)

	// A left-click anywhere else in the card only dismisses the menu: the row under
	// the pointer is never activated as a side effect of dismissing the menu.
	action, _ = tabs.session_switcher_dispatch_pointer(&state, _left_click(rr.x + 10, rr.y + 8))
	testing.expect_value(t, action, tabs.Session_Switcher_Action.None)
	testing.expect(t, !state.menu.visible, "a click outside the menu dismisses it")
	testing.expect(t, state.visible, "dismissing the menu must not close the switcher")
}

@(test)
test_session_switcher_menu_entries_resolve_actions :: proc(t: ^testing.T) {
	state: tabs.Session_Switcher_State
	_switcher_with_rows(&state, 4, []bool{false, true, false, false})

	// Foreground tab: Activate switches, Move to Background detaches, Close terminates.
	rr := tabs.session_switcher_row_rect(&state, 0)
	action, item := tabs.session_switcher_dispatch_pointer(&state, _right_click(rr.x + 10, rr.y + 4), 0, 800, 600)
	testing.expect_value(t, action, tabs.Session_Switcher_Action.None)
	action, item = _press_menu_item(&state, .Activate)
	testing.expect_value(t, action, tabs.Session_Switcher_Action.Switch_Tab)
	testing.expect_value(t, item.tab_idx, 0)
	testing.expect(t, !state.menu.visible, "choosing an entry closes the menu")

	action, _ = tabs.session_switcher_dispatch_pointer(&state, _right_click(rr.x + 10, rr.y + 4), 0, 800, 600)
	action, item = _press_menu_item(&state, .Move_To_Background)
	testing.expect_value(t, action, tabs.Session_Switcher_Action.Detach)
	testing.expect_value(t, item.tab_idx, 0)

	// Background session: Activate attaches, Close terminates.
	br := tabs.session_switcher_row_rect(&state, 1)
	action, _ = tabs.session_switcher_dispatch_pointer(&state, _right_click(br.x + 10, br.y + 4), 0, 800, 600)
	action, item = _press_menu_item(&state, .Activate)
	testing.expect_value(t, action, tabs.Session_Switcher_Action.Attach)
	testing.expect_value(t, item.tab_idx, -1)

	// Saved layout: Activate restores, and Close is not offered at all.
	_switcher_with_rows(&state, 2, nil, []bool{false, true})
	lr := tabs.session_switcher_row_rect(&state, 1)
	action, _ = tabs.session_switcher_dispatch_pointer(&state, _right_click(lr.x + 10, lr.y + 4), 0, 800, 600)
	action, item = _press_menu_item(&state, .Activate)
	testing.expect_value(t, action, tabs.Session_Switcher_Action.Restore_Layout)
	testing.expect(t, state.menu.disabled[int(tabs.Session_Switcher_Menu_Item.Close)], "a saved layout cannot be terminated")
}

@(test)
test_session_switcher_menu_close_terminates_row :: proc(t: ^testing.T) {
	state: tabs.Session_Switcher_State
	_switcher_with_rows(&state, 3, []bool{false, true, false})
	rr := tabs.session_switcher_row_rect(&state, 0)
	_, _ = tabs.session_switcher_dispatch_pointer(&state, _right_click(rr.x + 4, rr.y + 4), 0, 800, 600)
	action, item := _press_menu_item(&state, .Close)
	testing.expect_value(t, action, tabs.Session_Switcher_Action.Terminate)
	testing.expect_value(t, item.tab_idx, 0)

	// The rest of the row still activates it.
	action, item = tabs.session_switcher_dispatch_pointer(&state, _left_click(rr.x + 4, rr.y + 4))
	testing.expect_value(t, action, tabs.Session_Switcher_Action.Switch_Tab)
	testing.expect_value(t, item.tab_idx, 0)

	// A background row closes through Terminate as well.
	br := tabs.session_switcher_row_rect(&state, 1)
	action, _ = tabs.session_switcher_dispatch_pointer(&state, _right_click(br.x + 4, br.y + 4), 0, 800, 600)
	action, item = _press_menu_item(&state, .Close)
	testing.expect_value(t, action, tabs.Session_Switcher_Action.Terminate)
	testing.expect_value(t, item.tab_idx, -1)
}

@(test)
test_session_switcher_menu_enable_rules_follow_row_kind :: proc(t: ^testing.T) {
	state: tabs.Session_Switcher_State
	_switcher_with_rows(&state, 4, []bool{false, false, true, false}, []bool{false, false, false, true})
	state.items[1].pane_count = 3

	_expect_menu_rules(t, &state, 0, false, false, false)
	_expect_menu_rules(t, &state, 1, false, true, false)
	_expect_menu_rules(t, &state, 2, true, false, false)
	_expect_menu_rules(t, &state, 3, false, false, true)

	// A disabled entry swallows the press instead of acting.
	tabs.session_switcher_menu_close(&state.menu)
	rr := tabs.session_switcher_row_rect(&state, 1)
	action, _ := tabs.session_switcher_dispatch_pointer(&state, _right_click(rr.x + 8, rr.y + 4), 0, 800, 600)
	testing.expect(t, state.menu.disabled[int(tabs.Session_Switcher_Menu_Item.Move_To_Background)])
	action, _ = _press_menu_item(&state, .Move_To_Background)
	testing.expect_value(t, action, tabs.Session_Switcher_Action.None)
	testing.expect(t, !state.menu.visible, "a disabled entry still dismisses the menu")

	// The rule reads item.pane_count, so flipping it is enough to re-enable detach.
	state.items[1].pane_count = 1
	action, _ = tabs.session_switcher_dispatch_pointer(&state, _right_click(rr.x + 8, rr.y + 4), 0, 800, 600)
	testing.expect(t, !state.menu.disabled[int(tabs.Session_Switcher_Menu_Item.Move_To_Background)])
}

@(test)
test_session_switcher_menu_labels_track_row_kind :: proc(t: ^testing.T) {
	tab_item := tabs.Session_Switcher_Item{pane_count = 1}
	background_item := tabs.Session_Switcher_Item{is_detached = true, tab_idx = -1, pane_count = 1}
	layout_item := tabs.Session_Switcher_Item{is_persisted = true, tab_idx = -1, pane_count = 1}

	testing.expect_value(t, tabs.session_switcher_menu_item_label(.Activate, &tab_item), "Switch to Tab")
	testing.expect_value(t, tabs.session_switcher_menu_item_label(.Activate, &background_item), "Attach")
	testing.expect_value(t, tabs.session_switcher_menu_item_label(.Activate, &layout_item), "Restore Layout")
	testing.expect_value(t, tabs.session_switcher_menu_item_label(.Move_To_Background, &tab_item), "Move to Background")
	testing.expect_value(t, tabs.session_switcher_menu_item_label(.Close, &tab_item), "Close Tab")
	testing.expect_value(t, tabs.session_switcher_menu_item_label(.Close, &background_item), "Terminate Session")
}

@(test)
test_session_switcher_menu_closes_on_dismissal :: proc(t: ^testing.T) {
	state: tabs.Session_Switcher_State
	_switcher_with_rows(&state, 3, nil)
	rr := tabs.session_switcher_row_rect(&state, 1)
	_open_menu_at(t, &state, 1, rr.x + 10, rr.y + 6)

	// Escape dismisses the menu without closing the card; a second Escape closes it.
	consumed, action, _ := tabs.session_switcher_dispatch_key(&state, input.Input_Event{event_type = .Key, kind = .Escape})
	testing.expect(t, consumed)
	testing.expect_value(t, action, tabs.Session_Switcher_Action.None)
	testing.expect(t, !state.menu.visible && state.visible, "Escape dismisses the menu first")
	consumed, action, _ = tabs.session_switcher_dispatch_key(&state, input.Input_Event{event_type = .Key, kind = .Escape})
	testing.expect_value(t, action, tabs.Session_Switcher_Action.Close)

	// Arrow navigation drops the menu: it targets one fixed row.
	_switcher_with_rows(&state, 3, nil)
	rr = tabs.session_switcher_row_rect(&state, 1)
	_open_menu_at(t, &state, 1, rr.x + 10, rr.y + 6)
	tabs.session_switcher_dispatch_key(&state, input.Input_Event{event_type = .Key, kind = .Arrow_Down})
	testing.expect(t, !state.menu.visible, "changing the selection dismisses the menu")

	// Re-showing and hiding the switcher drop it too.
	rr = tabs.session_switcher_row_rect(&state, 1)
	_open_menu_at(t, &state, 1, rr.x + 10, rr.y + 6)
	dummy_tabs := [2]tabs.Tab_Session{
		{id = 1, title = "Tab 1", pid = 10, cwd = "/home", is_active = true},
		{id = 2, title = "Tab 2", pid = 20, cwd = "/var", is_active = false},
	}
	tabs.session_switcher_show(&state, dummy_tabs[:], 0, nil)
	testing.expect(t, !state.menu.visible, "re-opening the switcher dismisses the menu")

	rr = tabs.session_switcher_row_rect(&state, 1)
	_open_menu_at(t, &state, 1, rr.x + 10, rr.y + 6)
	tabs.session_switcher_hide(&state)
	testing.expect(t, !state.menu.visible, "hiding the switcher dismisses the menu")

	// A secondary press on the open menu dismisses it without choosing an entry.
	_switcher_with_rows(&state, 3, nil)
	rr = tabs.session_switcher_row_rect(&state, 1)
	_open_menu_at(t, &state, 1, rr.x + 10, rr.y + 6)
	ir := state.menu.item_rects[0]
	action, _ = tabs.session_switcher_dispatch_pointer(&state, input.Input_Pointer_Event{kind = .Button_Down, button = tabs.SESSION_SWITCHER_BUTTON_RIGHT, x = ir.x + ir.w * 0.5, y = ir.y + ir.h * 0.5})
	testing.expect_value(t, action, tabs.Session_Switcher_Action.None)
	testing.expect(t, !state.menu.visible, "a secondary press only dismisses the menu")

	// Editing the query re-filters the rows, so it drops the row-targeted menu too.
	rr = tabs.session_switcher_row_rect(&state, 1)
	_open_menu_at(t, &state, 1, rr.x + 10, rr.y + 6)
	tabs.session_switcher_dispatch_key(&state, input.Input_Event{event_type = .Key, kind = .Printable, rune = 's'})
	testing.expect(t, !state.menu.visible, "typing dismisses the menu")
	testing.expect_value(t, state.query_len, 1)
}

@(test)
test_session_switcher_menu_stays_inside_the_card :: proc(t: ^testing.T) {
	state: tabs.Session_Switcher_State
	_switcher_with_rows(&state, 8, nil)
	menu := &state.menu
	for row in 0 ..< state.visible_rows {
		rr := tabs.session_switcher_row_rect(&state, row)
		// Right edge and bottom edge of the row: the menu must flip and clamp.
		points: [3][2]f32 = {
			{rr.x + rr.w - 2, rr.y + 4},
			{rr.x + 4, rr.y + rr.h - 2},
			{rr.x + rr.w - 2, rr.y + rr.h - 2},
		}
		for point in points {
			tabs.session_switcher_dispatch_pointer(&state, _right_click(point[0], point[1]), 0, 800, 600)
			testing.expect(t, menu.visible)
			testing.expect(t, menu.rect.x >= state.rect.x, "the menu never leaves the card on the left")
			testing.expect(t, menu.rect.x + menu.rect.w <= state.rect.x + state.rect.w, "the menu never leaves the card on the right")
			testing.expect(t, menu.rect.y >= state.rect.y, "the menu never leaves the card on the top")
			testing.expect(t, menu.rect.y + menu.rect.h <= state.rect.y + state.rect.h, "the menu never leaves the card on the bottom")
			testing.expect(t, menu.rect.x + menu.rect.w <= 800 && menu.rect.y + menu.rect.h <= 600, "the menu stays on-screen")
			tabs.session_switcher_menu_close(menu)
		}
	}
	// A card too narrow for the nominal menu width still yields one contained by it.
	tabs.session_switcher_menu_close(menu)
	tabs.session_switcher_layout(&state, 160, 300)
	rr := tabs.session_switcher_row_rect(&state, 0)
	tabs.session_switcher_dispatch_pointer(&state, _right_click(rr.x + rr.w - 1, rr.y + rr.h - 1), 0, 160, 300)
	testing.expect(t, menu.visible, "the squeezed card still opens its menu")
	testing.expect(t, menu.rect.w <= state.rect.w, "the menu narrows to fit a narrow card")
	testing.expect(t, menu.rect.x >= state.rect.x && menu.rect.x + menu.rect.w <= state.rect.x + state.rect.w)
	testing.expect(t, menu.rect.y >= state.rect.y && menu.rect.y + menu.rect.h <= state.rect.y + state.rect.h)
}

@(test)
test_session_switcher_pointer_path_does_not_allocate :: proc(t: ^testing.T) {
	default_alloc := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, default_alloc)
	context.allocator = mem.tracking_allocator(&track)
	defer context.allocator = default_alloc
	defer mem.tracking_allocator_destroy(&track)

	state: tabs.Session_Switcher_State
	_switcher_with_rows(&state, 6, []bool{false, true, false, false, false, false})
	rr := tabs.session_switcher_row_rect(&state, 2)
	_, _ = tabs.session_switcher_dispatch_pointer(&state, _right_click(rr.x + 10, rr.y + 6), 0, 800, 600)
	ir := state.menu.item_rects[0]
	_, _ = tabs.session_switcher_dispatch_pointer(&state, _left_click(ir.x + 2, ir.y + 2))
	_, _ = tabs.session_switcher_dispatch_pointer(&state, input.Input_Pointer_Event{kind = .Motion, x = rr.x + 4, y = rr.y + 4})
	_, _ = tabs.session_switcher_dispatch_pointer(&state, input.Input_Pointer_Event{kind = .Wheel, wheel_integer_y = -1}, 1)

	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_session_switcher_pane_count_and_footer_hints :: proc(t: ^testing.T) {
	// Tabs without a pane tree are single-pane by construction.
	state: tabs.Session_Switcher_State
	dummy_tabs := [3]tabs.Tab_Session{
		{id = 1, title = "Tab 1", pid = 10, cwd = "/home", is_active = true},
		{id = 2, title = "Tab 2", pid = 20, cwd = "/var", is_active = false},
		{id = 3, title = "Tab 3", pid = 30, cwd = "/usr", is_active = false},
	}
	tabs.session_switcher_show(&state, dummy_tabs[:], 0, nil)
	for i in 0 ..< state.item_count {
		testing.expect(t, state.items[i].pane_count == 1, "rows without a pane tree default to a single pane")
	}
	testing.expect(t, !state.menu.visible, "showing the switcher clears any stale row menu")

	// Split tabs advertise their pane count and drop the detach hint that would fail.
	split_item := tabs.Session_Switcher_Item{is_current = false, pane_count = 2}
	testing.expect_value(t, tabs.session_switcher_footer_hint(&split_item), tabs.SESSION_SWITCHER_HINT_SPLIT_TAB)
	testing.expect(t, !strings.contains(tabs.session_switcher_footer_hint(&split_item), "Background"), "a split tab cannot be detached")

	single_item := tabs.Session_Switcher_Item{is_current = true, pane_count = 1}
	testing.expect_value(t, tabs.session_switcher_footer_hint(&single_item), tabs.SESSION_SWITCHER_HINT_TAB)
	testing.expect(t, strings.contains(tabs.session_switcher_footer_hint(&single_item), "Background"), "a single-pane tab can still be detached")

	background_item := tabs.Session_Switcher_Item{is_detached = true, tab_idx = -1, pane_count = 1}
	testing.expect_value(t, tabs.session_switcher_footer_hint(&background_item), tabs.SESSION_SWITCHER_HINT_BACKGROUND)
	testing.expect(t, strings.contains(tabs.session_switcher_footer_hint(&background_item), "\u2318X"), "background rows surface the terminate shortcut")

	layout_item := tabs.Session_Switcher_Item{is_persisted = true, tab_idx = -1, pane_count = 1}
	testing.expect_value(t, tabs.session_switcher_footer_hint(&layout_item), tabs.SESSION_SWITCHER_HINT_LAYOUT)
	testing.expect(t, !strings.contains(tabs.session_switcher_footer_hint(&layout_item), "\u2715"), "saved layouts cannot be terminated")
	testing.expect(t, !strings.contains(tabs.session_switcher_footer_hint(&layout_item), "\u2318X"), "saved layouts advertise no terminate shortcut")

	// No footer hint mentions the removed per-row close affordance.
	hinted_items := [4]tabs.Session_Switcher_Item{background_item, layout_item, single_item, split_item}
	for &item in hinted_items {
		testing.expect(t, !strings.contains(tabs.session_switcher_footer_hint(&item), "\u2715"))
	}
}

@(test)
test_session_switcher_footer_lines_are_bottom_anchored :: proc(t: ^testing.T) {
	pad: f32 : 2.0
	line_h: f32 : 16.0
	hint_y := tabs.session_switcher_footer_hint_y(pad, line_h)
	message_y := tabs.session_switcher_footer_message_y(pad, line_h)

	// The hint hugs the footer's bottom edge with exactly `pad` of clearance.
	testing.expect_value(t, hint_y + line_h, tabs.SESSION_SWITCHER_FOOTER_HEIGHT - pad)
	// The message sits above the hint and the two never overlap.
	testing.expect(t, message_y + line_h + pad <= hint_y, "the message line must clear the hint line")
	testing.expect(t, message_y >= 0, "the message line must stay inside the footer band")
}

@test
test_session_switcher_no_close_glyph_in_hints :: proc(t: ^testing.T) {
	hints := []string{
		tabs.SESSION_SWITCHER_HINT_EMPTY,
		tabs.SESSION_SWITCHER_HINT_LAYOUT,
		tabs.SESSION_SWITCHER_HINT_BACKGROUND,
		tabs.SESSION_SWITCHER_HINT_SPLIT_TAB,
		tabs.SESSION_SWITCHER_HINT_TAB,
	}
	for hint in hints {
		testing.expect(t, !strings.contains(hint, "\u2715"), "the switcher copy must not advertise a close glyph")
	}
}
