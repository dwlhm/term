package ui_test

import "core:testing"
import "core:strings"
import "core:time"
import posix "core:sys/posix"

import ui "../"
import termgrid "../../terminal"
import inter "../../interaction"
import input "../../platform/input"
import render "../../render"
import instance "../../render/instance"
import app "../../app"

@test
test_tab_bar_layout_and_hit_test :: proc(t: ^testing.T) {
	state: ui.Tab_Bar_State
	ui.tab_bar_init(&state)

	tab_rects: [16]ui.Rect_f32

	// 1. Single tab on wide window (1000px): must clamp to TAB_MAX_W (220px)
	n := ui.tab_bar_layout(&state, 1000.0, 1, tab_rects[:])
	testing.expect_value(t, n, 1)
	testing.expect_value(t, tab_rects[0].w, ui.TAB_MAX_W)
	testing.expect_value(t, tab_rects[0].h, ui.TAB_BAR_HEIGHT)

	// 2. Many tabs fit the available width with the new-tab button reserved.
	n = ui.tab_bar_layout(&state, 800.0, 10, tab_rects[:])
	testing.expect_value(t, n, 10)
	testing.expect(t, tab_rects[0].w < ui.TAB_MIN_W)
	testing.expect(t, state.new_tab_rect.x + state.new_tab_rect.w <= state.rect.w)

	// 3. Hit-testing: tab item, close button, new tab button, and outside
	n = ui.tab_bar_layout(&state, 1000.0, 3, tab_rects[:])
	tab_x := tab_rects[0].x
	tab_w := tab_rects[0].w

	// Center of Tab 0 -> Tab_Item
	target, idx := ui.tab_bar_hit_test(&state, 3, tab_rects[:3], tab_x + 20.0, 16.0)
	testing.expect_value(t, target, ui.Tab_Hit_Target.Tab_Item)
	testing.expect_value(t, idx, 0)

	// Right edge of Tab 0 -> Btn_Close
	target, idx = ui.tab_bar_hit_test(&state, 3, tab_rects[:3], tab_x + tab_w - 10.0, 16.0)
	testing.expect_value(t, target, ui.Tab_Hit_Target.Btn_Close)
	testing.expect_value(t, idx, 0)

	// Right next to the last tab -> Btn_New_Tab
	last_tab := tab_rects[2]
	target, idx = ui.tab_bar_hit_test(&state, 3, tab_rects[:3], last_tab.x + last_tab.w + 10.0, 16.0)
	testing.expect_value(t, target, ui.Tab_Hit_Target.Btn_New_Tab)
	testing.expect_value(t, idx, -1)

	// Below Tab Bar -> None
	target, idx = ui.tab_bar_hit_test(&state, 3, tab_rects[:3], tab_x + 20.0, 50.0)
	testing.expect_value(t, target, ui.Tab_Hit_Target.None)
	testing.expect_value(t, idx, -1)

	// 4. Pointer dispatch actions
	consumed, action, t_idx := ui.tab_bar_dispatch_pointer(&state, 3, tab_rects[:3], tab_x + 20.0, 16.0, true)
	testing.expect(t, consumed, "pointer down on tab must be consumed")
	testing.expect_value(t, action, ui.Tab_Action.Switch_Tab)
	testing.expect_value(t, t_idx, 0)

	consumed, action, t_idx = ui.tab_bar_dispatch_pointer(&state, 3, tab_rects[:3], tab_x + tab_w - 10.0, 16.0, true)
	testing.expect(t, consumed, "pointer down on close button must be consumed")
	testing.expect_value(t, action, ui.Tab_Action.Close_Tab)
	testing.expect_value(t, t_idx, 0)

	consumed, action, t_idx = ui.tab_bar_dispatch_pointer(&state, 3, tab_rects[:3], last_tab.x + last_tab.w + 10.0, 16.0, true)
	testing.expect(t, consumed, "pointer down on new tab must be consumed")
	testing.expect_value(t, action, ui.Tab_Action.New_Tab)
	testing.expect_value(t, t_idx, -1)

	// Middle-click on tab item -> Close_Tab
	consumed, action, t_idx = ui.tab_bar_dispatch_pointer(&state, 3, tab_rects[:3], tab_x + 20.0, 16.0, true, 2, 1)
	testing.expect(t, consumed, "middle-click on tab must be consumed")
	testing.expect_value(t, action, ui.Tab_Action.Close_Tab)
	testing.expect_value(t, t_idx, 0)

	// Double-click on empty tab bar area -> New_Tab
	consumed, action, t_idx = ui.tab_bar_dispatch_pointer(&state, 3, tab_rects[:3], 850.0, 16.0, true, 1, 2)
	testing.expect(t, consumed, "double-click on empty tab bar must be consumed")
	testing.expect_value(t, action, ui.Tab_Action.New_Tab)
	testing.expect_value(t, t_idx, -1)
}

@test
test_search_bar_input_and_scan :: proc(t: ^testing.T) {
	state: ui.Search_Bar_State
	ui.search_bar_init(&state)
	state.visible = true
	ui.search_bar_layout(&state, 1024.0)

	// 1. Typing 'f', 'o', 'o'
	ev_f := input.Input_Event{event_type = .Key, kind = .Printable, rune = 'f'}
	ev_o := input.Input_Event{event_type = .Key, kind = .Printable, rune = 'o'}
	consumed, action := ui.search_bar_dispatch_key(&state, ev_f)
	testing.expect(t, consumed, "typing 'f' must be consumed")
	testing.expect_value(t, action, ui.Search_Action.Query_Changed)

	_, _ = ui.search_bar_dispatch_key(&state, ev_o)
	_, _ = ui.search_bar_dispatch_key(&state, ev_o)

	testing.expect_value(t, state.query_len, 3)
	testing.expect_value(t, string(state.query[:state.query_len]), "foo")

	// 2. Backspace
	ev_bs := input.Input_Event{event_type = .Key, kind = .Backspace}
	consumed, action = ui.search_bar_dispatch_key(&state, ev_bs)
	testing.expect(t, consumed, "backspace must be consumed")
	testing.expect_value(t, action, ui.Search_Action.Query_Changed)
	testing.expect_value(t, state.query_len, 2)
	testing.expect_value(t, string(state.query[:state.query_len]), "fo")

	// 3. Scan on Terminal
	term := new(termgrid.Terminal)
	termgrid.terminal_init(term, 10, 40)
	defer {
		termgrid.terminal_destroy(term)
		free(term)
	}
	termgrid.terminal_put_string(term, "foo bar baz foo")

	matches: [inter.MAX_SEARCH_MATCHES]inter.Search_Match
	match_count := ui.search_bar_execute_scan(&state, term, matches[:])
	testing.expect(t, match_count >= 2, "must find at least 2 occurrences of 'fo'")
	testing.expect_value(t, state.match_count, match_count)
	testing.expect(t, !state.is_invalid_regex, "normal query must not report invalid regex")

	// 4. Non-matching query
	state.query_len = 3
	copy(state.query[:3], "zzz")
	match_count = ui.search_bar_execute_scan(&state, term, matches[:])
	testing.expect_value(t, match_count, 0)
	testing.expect_value(t, state.match_count, 0)

	// 5. Corrupt regex handling without panic
	state.use_regex = true
	bad_rx := "[a-z("
	state.query_len = len(bad_rx)
	copy(state.query[:len(bad_rx)], bad_rx)

	match_count = ui.search_bar_execute_scan(&state, term, matches[:])
	testing.expect_value(t, match_count, 0)
	testing.expect(t, state.is_invalid_regex, "corrupt regex must set is_invalid_regex = true")
}

@test
test_security_pid_guard_and_title_sanitize :: proc(t: ^testing.T) {
	// 1. Title sanitization: strip control characters (< 32, 127)
	buf: [128]u8
	src_escape := "\x1b[31;1mRoot Shell\x1b[0m\r\n"
	n := app.session_sanitize_title(buf[:], src_escape)
	testing.expect_value(t, string(buf[:n]), "[31;1mRoot Shell[0m")

	// 2. Strip Unicode BiDi override runes (0x202E RLO, 0x2066 LRI)
	src_bidi := "Safe\u202EOverride\u2066Title"
	n = app.session_sanitize_title(buf[:], src_bidi)
	testing.expect_value(t, string(buf[:n]), "SafeOverrideTitle")

	// 3. Strict clamping to 64 bytes
	long_str := "0123456789012345678901234567890123456789012345678901234567890123456789"
	n = app.session_sanitize_title(buf[:], long_str)
	testing.expect_value(t, n, 64)

	// 4. PID guard validation: PID <= 1 must NEVER be sent signals
	// We verify that Tab_Session with pid = 1 or pid = 0 does not panic or call kill
	sm: app.Session_Manager
	app.session_manager_init(&sm, 4)
	defer app.session_manager_destroy(&sm)

	resize(&sm.tabs, 1)
	sm.tabs[0].status = .Running
	sm.tabs[0].backend.pty.pid = 1 // Init / launchd PID
	sm.active_idx = 0

	// session_close_tab on pid = 1: safely closes immediately and skips kill(<=1)
	ok := app.session_close_tab(&sm, 0)
	testing.expect(t, ok, "session_close_tab must succeed")
	testing.expect_value(t, len(sm.tabs), 0)
	testing.expect_value(t, sm.active_idx, -1)
}

@test
test_session_lifecycle_and_reap :: proc(t: ^testing.T) {
	sm: app.Session_Manager
	app.session_manager_init(&sm, 2)
	defer app.session_manager_destroy(&sm)

	// 1. Tab Limit Guard: spawning up to max_tabs (2)
	idx1, ok1 := app.session_spawn(&sm, "/bin/echo", {"lifecycle_test_1"}, 24, 80, nil, termgrid.Theme{})
	testing.expect(t, ok1, "tab 1 spawn must succeed")
	testing.expect_value(t, idx1, 0)

	idx2, ok2 := app.session_spawn(&sm, "/bin/echo", {"lifecycle_test_2"}, 24, 80, nil, termgrid.Theme{})
	testing.expect(t, ok2, "tab 2 spawn must succeed")
	testing.expect_value(t, idx2, 1)

	// Attempting tab 3 must be rejected by Max Tab Guard
	idx3, ok3 := app.session_spawn(&sm, "/bin/echo", {"lifecycle_test_3"}, 24, 80, nil, termgrid.Theme{})
	testing.expect(t, !ok3, "tab 3 spawn must be rejected by Max Tab Guard")
	testing.expect_value(t, idx3, -1)

	// 2. Poll and auto-close non-blocking when child processes exit
	// /bin/echo exits immediately, session_poll_all will detect exit and auto-close the tabs
	reaped := false
	for _ in 0..<100 {
		_ = app.session_poll_all(&sm)
		if len(sm.tabs) == 0 {
			reaped = true
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, reaped, "child processes must be auto-closed on exit")
	testing.expect_value(t, len(sm.tabs), 0)
	testing.expect_value(t, sm.active_idx, -1)
}

@test
test_ui_render_staging_bounds :: proc(t: ^testing.T) {
	r := new(render.Renderer)
	defer free(r)
	r.cell_width = 8.0
	r.cell_height = 16.0
	max_inst: u32 = 1024
	r.instances.max_instances = max_inst
	r.instances.instance_data = make([]instance.Instance_Data, int(max_inst))
	defer delete(r.instances.instance_data)

	theme := ui.theme_catppuccin_mocha()
	tab_state: ui.Tab_Bar_State
	ui.tab_bar_init(&tab_state)
	tab_rects: [4]ui.Rect_f32
	tab_count := ui.tab_bar_layout(&tab_state, 800.0, 4, tab_rects[:])

	tabs: [4]ui.UI_Tab_Info = {
		{title = "Tab 1", is_active = true, is_exited = false, has_bell = false},
		{title = "Tab 2", is_active = false, is_exited = false, has_bell = true},
		{title = "Tab 3", is_active = false, is_exited = true, has_bell = false},
		{title = "Tab 4", is_active = false, is_exited = false, has_bell = false},
	}

	search_state: ui.Search_Bar_State
	ui.search_bar_init(&search_state)
	search_state.visible = true
	ui.search_bar_layout(&search_state, 800.0)

	staged := ui.ui_render_stage(
		r,
		&theme,
		.Modern_Flat,
		&tab_state,
		tabs[:],
		0,
		tab_rects[:],
		&search_state,
		800.0,
		600.0,
	)

	testing.expect(t, staged > 0, "must stage UI quads")
	testing.expect(t, staged <= ui.UI_MAX_INSTANCES, "staging must not exceed UI_MAX_INSTANCES quota")
	testing.expect(t, r.ui_staged, "r.ui_staged must be true after staging")
	testing.expect(t, r.ui_bg_count > 0, "r.ui_bg_count must be > 0 after staging")
}

@test
test_ui_render_logical_to_physical_scale :: proc(t: ^testing.T) {
	for scale in ([]f32{1, 2}) {
		r := new(render.Renderer)
		defer free(r)
		r.cell_width = 8 * scale
		r.cell_height = 16 * scale
		state: ui.Tab_Bar_State
		rects: [1]ui.Rect_f32
		_ = ui.tab_bar_layout(&state, 800, 1, rects[:])
		tabs := [1]ui.UI_Tab_Info{{is_active = true}}
		theme := ui.theme_catppuccin_mocha()
		_ = ui.ui_render_stage(r, &theme, .Modern_Flat, &state, tabs[:], 0, rects[:], nil, 800, 600, scale)
		testing.expect_value(t, r.ui_bg_data[0].cw, state.rect.w * scale)
		testing.expect_value(t, r.ui_bg_data[0].ch, ui.TAB_BAR_HEIGHT * scale)
		testing.expect_value(t, r.ui_bg_data[2].x, rects[0].x * scale)
		target, _ := ui.tab_bar_hit_test(&state, 1, rects[:], rects[0].x + rects[0].w - ui.CLOSE_BTN_WIDTH / 2, ui.TAB_BAR_HEIGHT / 2)
		testing.expect_value(t, target, ui.Tab_Hit_Target.Btn_Close)
		target, _ = ui.tab_bar_hit_test(&state, 1, rects[:], rects[0].x + rects[0].w + ui.NEW_TAB_BTN_WIDTH / 2, ui.TAB_BAR_HEIGHT / 2)
		testing.expect_value(t, target, ui.Tab_Hit_Target.Btn_New_Tab)
	}
}

@test
test_tab_overflow_and_tiny_window_bounds :: proc(t: ^testing.T) {
	for width in ([]f32{0, 16, 80, 300, 800}) {
		state: ui.Tab_Bar_State
		rects: [16]ui.Rect_f32
		for count in ([]int{0, 1, 16}) {
			_ = ui.tab_bar_layout(&state, width, count, rects[:])
			testing.expect(t, state.new_tab_rect.x >= 0 && state.new_tab_rect.x + state.new_tab_rect.w <= width)
			for i in 0..<count {
				r := rects[i]
				testing.expect(t, r.x >= 0 && r.w >= 0 && r.x + r.w <= width)
				if r.w > 0 && r.w < ui.TAB_CLOSE_MIN_WIDTH {
					target, idx := ui.tab_bar_hit_test(&state, count, rects[:count], r.x + r.w / 2, r.h / 2)
					testing.expect_value(t, target, ui.Tab_Hit_Target.Tab_Item)
					testing.expect_value(t, idx, i)
				}
			}
			if state.new_tab_rect.w > 0 {
				target, _ := ui.tab_bar_hit_test(&state, count, rects[:count], state.new_tab_rect.x, ui.TAB_BAR_HEIGHT / 2)
				testing.expect_value(t, target, ui.Tab_Hit_Target.Btn_New_Tab)
			}
		}
	}
}

@test
test_confirm_dialog_layout :: proc(t: ^testing.T) {
	state: ui.Confirm_Dialog_State
	ui.confirm_dialog_init(&state)
	testing.expect_value(t, state.visible, false)
	testing.expect_value(t, state.target_tab_idx, -1)
	testing.expect_value(t, state.hover_target, ui.Confirm_Dialog_Target.None)

	ui.confirm_dialog_layout(&state, 800.0, 600.0)
	testing.expect_value(t, state.rect.w, ui.CONFIRM_DIALOG_WIDTH)
	testing.expect_value(t, state.rect.h, ui.CONFIRM_DIALOG_HEIGHT)
	testing.expect_value(t, state.rect.x, (800.0 - ui.CONFIRM_DIALOG_WIDTH) * 0.5)
	testing.expect_value(t, state.rect.y, (600.0 - ui.CONFIRM_DIALOG_HEIGHT) * 0.5)

	testing.expect_value(t, state.cancel_rect.w, ui.CONFIRM_BTN_CANCEL_W)
	testing.expect_value(t, state.cancel_rect.h, ui.CONFIRM_BTN_HEIGHT)
	testing.expect_value(t, state.confirm_rect.w, ui.CONFIRM_BTN_CONFIRM_W)
	testing.expect_value(t, state.confirm_rect.h, ui.CONFIRM_BTN_HEIGHT)

	// Tiny window clamp to 0
	ui.confirm_dialog_layout(&state, 100.0, 50.0)
	testing.expect_value(t, state.rect.x, 0.0)
	testing.expect_value(t, state.rect.y, 0.0)
}

@test
test_confirm_dialog_dispatch_pointer :: proc(t: ^testing.T) {
	state: ui.Confirm_Dialog_State
	ui.confirm_dialog_init(&state)
	ui.confirm_dialog_layout(&state, 800.0, 600.0)

	// Hidden dialog swallows nothing
	consumed, act := ui.confirm_dialog_dispatch_pointer(&state, 100, 100, true)
	testing.expect_value(t, consumed, false)
	testing.expect_value(t, act, ui.Confirm_Dialog_Action.None)

	// Show dialog
	ui.confirm_dialog_show(&state, 2)
	testing.expect_value(t, state.visible, true)
	testing.expect_value(t, state.target_tab_idx, 2)

	// Hover confirm button
	consumed, act = ui.confirm_dialog_dispatch_pointer(&state, state.confirm_rect.x + 5, state.confirm_rect.y + 5, false)
	testing.expect_value(t, consumed, true)
	testing.expect_value(t, act, ui.Confirm_Dialog_Action.None)
	testing.expect_value(t, state.hover_target, ui.Confirm_Dialog_Target.Btn_Confirm)

	// Hover cancel button
	consumed, act = ui.confirm_dialog_dispatch_pointer(&state, state.cancel_rect.x + 5, state.cancel_rect.y + 5, false)
	testing.expect_value(t, consumed, true)
	testing.expect_value(t, act, ui.Confirm_Dialog_Action.None)
	testing.expect_value(t, state.hover_target, ui.Confirm_Dialog_Target.Btn_Cancel)

	// Click confirm button
	consumed, act = ui.confirm_dialog_dispatch_pointer(&state, state.confirm_rect.x + 5, state.confirm_rect.y + 5, true)
	testing.expect_value(t, consumed, true)
	testing.expect_value(t, act, ui.Confirm_Dialog_Action.Confirm)

	// Click cancel button
	consumed, act = ui.confirm_dialog_dispatch_pointer(&state, state.cancel_rect.x + 5, state.cancel_rect.y + 5, true)
	testing.expect_value(t, consumed, true)
	testing.expect_value(t, act, ui.Confirm_Dialog_Action.Cancel)

	// Click backdrop (outside card)
	consumed, act = ui.confirm_dialog_dispatch_pointer(&state, 10, 10, true)
	testing.expect_value(t, consumed, true)
	testing.expect_value(t, act, ui.Confirm_Dialog_Action.Cancel)

	// Hide dialog
	ui.confirm_dialog_hide(&state)
	testing.expect_value(t, state.visible, false)
	consumed, act = ui.confirm_dialog_dispatch_pointer(&state, 10, 10, true)
	testing.expect_value(t, consumed, false)
}

@test
test_confirm_dialog_dispatch_key :: proc(t: ^testing.T) {
	state: ui.Confirm_Dialog_State
	ui.confirm_dialog_init(&state)

	// Hidden dialog
	consumed, act := ui.confirm_dialog_dispatch_key(&state, input.Input_Event{event_type = .Key, kind = .Enter})
	testing.expect_value(t, consumed, false)
	testing.expect_value(t, act, ui.Confirm_Dialog_Action.None)

	// Visible dialog
	ui.confirm_dialog_show(&state, 1)

	// Enter / Return -> Confirm
	consumed, act = ui.confirm_dialog_dispatch_key(&state, input.Input_Event{event_type = .Key, kind = .Enter})
	testing.expect_value(t, consumed, true)
	testing.expect_value(t, act, ui.Confirm_Dialog_Action.Confirm)

	// 'y' / 'Y' -> Confirm
	consumed, act = ui.confirm_dialog_dispatch_key(&state, input.Input_Event{event_type = .Key, kind = .Printable, rune = 'y'})
	testing.expect_value(t, consumed, true)
	testing.expect_value(t, act, ui.Confirm_Dialog_Action.Confirm)

	consumed, act = ui.confirm_dialog_dispatch_key(&state, input.Input_Event{event_type = .Key, kind = .Printable, rune = 'Y'})
	testing.expect_value(t, consumed, true)
	testing.expect_value(t, act, ui.Confirm_Dialog_Action.Confirm)

	// Escape -> Cancel
	consumed, act = ui.confirm_dialog_dispatch_key(&state, input.Input_Event{event_type = .Key, kind = .Escape})
	testing.expect_value(t, consumed, true)
	testing.expect_value(t, act, ui.Confirm_Dialog_Action.Cancel)

	// 'n' / 'N' -> Cancel
	consumed, act = ui.confirm_dialog_dispatch_key(&state, input.Input_Event{event_type = .Key, kind = .Printable, rune = 'n'})
	testing.expect_value(t, consumed, true)
	testing.expect_value(t, act, ui.Confirm_Dialog_Action.Cancel)

	consumed, act = ui.confirm_dialog_dispatch_key(&state, input.Input_Event{event_type = .Key, kind = .Printable, rune = 'N'})
	testing.expect_value(t, consumed, true)
	testing.expect_value(t, act, ui.Confirm_Dialog_Action.Cancel)

	// Other key -> swallowed (consumed = true, act = None)
	consumed, act = ui.confirm_dialog_dispatch_key(&state, input.Input_Event{event_type = .Key, kind = .Printable, rune = 'a'})
	testing.expect_value(t, consumed, true)
	testing.expect_value(t, act, ui.Confirm_Dialog_Action.None)
}

@test
test_session_terminating_reap_on_poll :: proc(t: ^testing.T) {
	sm: app.Session_Manager
	app.session_manager_init(&sm, 4)
	defer app.session_manager_destroy(&sm)

	idx, ok := app.session_spawn(&sm, "/usr/bin/true", {}, 24, 80, nil, termgrid.Theme{})
	testing.expect(t, ok, "spawn must succeed")
	testing.expect_value(t, idx, 0)
	testing.expect_value(t, len(sm.tabs), 1)

	// Close tab initiates termination (status -> Terminating)
	close_ok := app.session_close_tab(&sm, 0)
	testing.expect(t, close_ok, "session_close_tab must succeed")

	// Wait for child process to exit and be reaped by session_poll_all
	reaped := false
	for _ in 0..<100 {
		_ = app.session_poll_all(&sm)
		if len(sm.tabs) == 0 {
			reaped = true
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, reaped, "terminating tab must be reaped and removed by session_poll_all")
	testing.expect_value(t, len(sm.tabs), 0)
	testing.expect_value(t, sm.active_idx, -1)
}
