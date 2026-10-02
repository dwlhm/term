package ui_test

import "core:testing"
import "core:fmt"
import "core:strings"
import "core:time"
import posix "core:sys/posix"

import ui "../"
import tabs "../../platform/tabs"
import termgrid "../../terminal"
import inter "../../interaction"
import input "../../platform/input"
import render "../../render"
import instance "../../render/instance"
import i18n "../../i18n"
import app "../../app"

@test
test_tab_bar_layout_and_hit_test :: proc(t: ^testing.T) {
	state: ui.Tab_Bar_State
	ui.tab_bar_init(&state)

	tab_rects: [16]ui.Rect_f32

	// 1. Single tab on wide window (1000px): content-driven width
	n := ui.tab_bar_layout(&state, 1000.0, 1, tab_rects[:])
	testing.expect_value(t, n, 1)
	testing.expect(t, tab_rects[0].w > 0)
	testing.expect_value(t, tab_rects[0].h, ui.TAB_BAR_HEIGHT)

	// 2. Many tabs exceed the available width:
	n = ui.tab_bar_layout(&state, 800.0, 10, tab_rects[:])
	testing.expect_value(t, n, 10)
	testing.expect(t, tab_rects[0].w > 0)
	testing.expect(t, state.scroll_max > 0, "overflow must expose a positive scroll range")
	testing.expect(t, state.new_tab_rect.x + state.new_tab_rect.w <= state.rect.w)

	// 3. Hit-testing: tab item, new tab button, and outside
	n = ui.tab_bar_layout(&state, 1000.0, 3, tab_rects[:])
	tab_x := tab_rects[0].x
	tab_w := tab_rects[0].w

	// Center of Tab 0 -> Tab_Item
	target, idx := ui.tab_bar_hit_test(&state, 3, tab_rects[:3], tab_x + 20.0, 16.0)
	testing.expect_value(t, target, ui.Tab_Hit_Target.Tab_Item)
	testing.expect_value(t, idx, 0)

	// Right edge of Tab 0 -> Tab_Item (close button removed from tab strip)
	target, idx = ui.tab_bar_hit_test(&state, 3, tab_rects[:3], tab_x + tab_w - 5.0, 16.0)
	testing.expect_value(t, target, ui.Tab_Hit_Target.Tab_Item)
	testing.expect_value(t, idx, 0)

	// Right next to the last tab -> Btn_New_Tab
	target, idx = ui.tab_bar_hit_test(&state, 3, tab_rects[:3], state.new_tab_rect.x + 5.0, 16.0)
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

	// Right-click on tab -> Context_Menu
	consumed, action, t_idx = ui.tab_bar_dispatch_pointer(&state, 3, tab_rects[:3], tab_x + tab_w - 5.0, 16.0, true, 3, 1)
	testing.expect(t, consumed, "right-click on tab must be consumed")
	testing.expect_value(t, action, ui.Tab_Action.Context_Menu)
	testing.expect_value(t, t_idx, 0)

	consumed, action, t_idx = ui.tab_bar_dispatch_pointer(&state, 3, tab_rects[:3], state.new_tab_rect.x + 5.0, 16.0, true)
	testing.expect(t, consumed, "pointer down on new tab must be consumed")
	testing.expect_value(t, action, ui.Tab_Action.New_Tab)
	testing.expect_value(t, t_idx, -1)

	// Middle-click on tab item -> Close_Tab
	consumed, action, t_idx = ui.tab_bar_dispatch_pointer(&state, 3, tab_rects[:3], tab_x + 20.0, 16.0, true, 2, 1)
	testing.expect(t, consumed, "middle-click on tab must be consumed")
	testing.expect_value(t, action, ui.Tab_Action.Close_Tab)
	testing.expect_value(t, t_idx, 0)

	// Double-click on the trailing drag region -> Window_Zoom (native titlebar action)
	consumed, action, t_idx = ui.tab_bar_dispatch_pointer(&state, 3, tab_rects[:3], 850.0, 16.0, true, 1, 2)
	testing.expect(t, consumed, "double-click on empty tab bar must be consumed")
	testing.expect_value(t, action, ui.Tab_Action.Window_Zoom)
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
		i18n.i18n_get(),
		&tab_state,
		tabs[:],
		tab_rects[:],
		&search_state,
		800.0,
		600.0,
	)

	testing.expect(t, staged > 0, "must stage UI quads")
	testing.expect(t, staged <= ui.UI_MAX_INSTANCES, "staging must not exceed UI_MAX_INSTANCES quota")
	testing.expect(t, r.ui_staged, "r.ui_staged must be true after staging")
	testing.expect(t, r.ui_layer_bg_count[render.UI_Layer.Tab_Chrome] > 0, "tab chrome layer must hold quads after staging")
}

@test
test_ui_render_confirm_dialog_stages :: proc(t: ^testing.T) {
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
	rects: [1]ui.Rect_f32
	_ = ui.tab_bar_layout(&tab_state, 800, 1, rects[:])
	tabs := [1]ui.UI_Tab_Info{{is_active = true}}

	confirm: ui.Confirm_Dialog_State
	ui.confirm_dialog_init(&confirm)
	ui.confirm_dialog_layout(&confirm, 800, 600)

	hidden_count := ui.ui_render_stage(r, &theme, i18n.i18n_get(), &tab_state, tabs[:], rects[:], nil, 800, 600)

	ui.confirm_dialog_show(&confirm, 0, 1)
	shown_count := ui.ui_render_stage(r, &theme, i18n.i18n_get(), &tab_state, tabs[:], rects[:], nil, 800, 600, 1, "", nil, nil, nil, &confirm)

	testing.expect(t, shown_count > hidden_count, "visible dialog must stage additional card and button quads")
	testing.expect(t, r.ui_layer_bg_count[render.UI_Layer.Overlay] > 0, "dialog card background must be staged on the overlay layer")
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
		_ = ui.ui_render_stage(r, &theme, i18n.i18n_get(), &state, tabs[:], rects[:], nil, 800, 600, scale)
		testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Tab_Chrome][0].cw, state.rect.w * scale)
		testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Tab_Chrome][0].ch, ui.TAB_BAR_HEIGHT * scale)
		// Tab_Chrome quad 2 is the active tab underline at rects[0].x.
		testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Tab_Chrome][2].x, rects[0].x * scale)
		target, _ := ui.tab_bar_hit_test(&state, 1, rects[:], rects[0].x + rects[0].w / 2, ui.TAB_BAR_HEIGHT / 2)
		testing.expect_value(t, target, ui.Tab_Hit_Target.Tab_Item)
		target, _ = ui.tab_bar_hit_test(&state, 1, rects[:], state.new_tab_rect.x + state.new_tab_rect.w / 2, ui.TAB_BAR_HEIGHT / 2)
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

			// The new-tab control must always stay inside the window, overflow or not.
			testing.expect(t, state.new_tab_rect.x >= 0 && state.new_tab_rect.w >= 0)
			testing.expect(t, state.new_tab_rect.x + state.new_tab_rect.w <= width + 0.001)

			overflow := state.scroll_max > 0
			for i in 0..<count {
				r := rects[i]
				if overflow {
					// In content-driven layout, visible tabs have positive width within bounds,
					// while overflowing tabs not currently visible have w == 0.
					if r.w > 0 {
						testing.expect(t, r.x >= 0 && r.x + r.w <= width + 0.001)
					}
				} else {
					testing.expect(t, r.x >= 0 && r.w >= 0 && r.x + r.w <= width + 0.001)
				}
			}

			// A point inside the visible viewport maps to the logical tab index under it.
			if count > 0 && state.viewport_rect.w > 1 && state.visible_tab_count > 0 {
				probe_x := state.viewport_rect.x + 1.0
				target, idx := ui.tab_bar_hit_test(&state, count, rects[:count], probe_x, ui.TAB_BAR_HEIGHT / 2)
				testing.expect_value(t, target, ui.Tab_Hit_Target.Tab_Item)
				testing.expect_value(t, idx, state.display_start)
			}

			if state.new_tab_rect.w > 0 {
				target, _ := ui.tab_bar_hit_test(&state, count, rects[:count], state.new_tab_rect.x, ui.TAB_BAR_HEIGHT / 2)
				testing.expect_value(t, target, ui.Tab_Hit_Target.Btn_New_Tab)
			}
		}
	}
}

@test
test_tab_bar_scroll_clamps :: proc(t: ^testing.T) {
	state: ui.Tab_Bar_State
	ui.tab_bar_init(&state)
	rects: [16]ui.Rect_f32
	_ = ui.tab_bar_layout(&state, 800.0, 16, rects[:])
	testing.expect(t, state.scroll_max > 0, "layout must produce a scrollable strip")

	// Scrolling toward the start at the origin must not move the offset.
	changed := ui.tab_bar_scroll(&state, 10)
	testing.expect(t, !changed, "scrolling left at origin must not change offset")
	testing.expect_value(t, state.scroll_offset, 0.0)

	// Forward wheel moves the strip by whole steps.
	changed = ui.tab_bar_scroll(&state, -1)
	testing.expect(t, changed, "scrolling forward must change offset")
	testing.expect(t, state.scroll_offset > 0.0)

	// Must clamp at the far end.
	_ = ui.tab_bar_scroll(&state, -1000)
	testing.expect_value(t, state.scroll_offset, state.scroll_max)

	// Must clamp back at the origin.
	_ = ui.tab_bar_scroll(&state, 1000)
	testing.expect_value(t, state.scroll_offset, 0.0)
}

@test
test_tab_bar_scroll_to_tab_keeps_target_visible :: proc(t: ^testing.T) {
	state: ui.Tab_Bar_State
	ui.tab_bar_init(&state)
	rects: [16]ui.Rect_f32
	_ = ui.tab_bar_layout(&state, 800.0, 16, rects[:])

	// Scrolling to the last tab must bring it fully inside the viewport.
	changed := ui.tab_bar_scroll_to_tab(&state, 15)
	testing.expect(t, changed, "scrolling to an off-screen tab must change offset")
	_ = ui.tab_bar_layout(&state, 800.0, 16, rects[:])
	last := rects[15]
	testing.expect(t, last.x >= state.viewport_rect.x - 0.001, "tab left edge must be inside the viewport")
	testing.expect(t, last.x + last.w <= state.viewport_rect.x + state.viewport_rect.w + 0.001, "tab right edge must be inside the viewport")

	// Scrolling back to the first tab must restore visibility.
	changed = ui.tab_bar_scroll_to_tab(&state, 0)
	testing.expect(t, changed, "scrolling back to the first tab must change offset")
	_ = ui.tab_bar_layout(&state, 800.0, 16, rects[:])
	first := rects[0]
	testing.expect(t, first.x >= state.viewport_rect.x - 0.001, "first tab left edge must be inside the viewport")
	testing.expect(t, first.x + first.w <= state.viewport_rect.x + state.viewport_rect.w + 0.001, "first tab right edge must be inside the viewport")
}

@test
test_tab_bar_hit_test_after_scroll :: proc(t: ^testing.T) {
	state: ui.Tab_Bar_State
	ui.tab_bar_init(&state)
	rects: [16]ui.Rect_f32
	_ = ui.tab_bar_layout(&state, 800.0, 16, rects[:])
	_ = ui.tab_bar_scroll(&state, -6) // six wheel steps forward
	_ = ui.tab_bar_layout(&state, 800.0, 16, rects[:])
	testing.expect(t, state.scroll_offset > 0.0, "offset must have advanced")

	// A fixed point inside the viewport must map to the logical tab whose shifted rect contains it.
	probe_x := state.viewport_rect.x + 10.0
	target, idx := ui.tab_bar_hit_test(&state, 16, rects[:], probe_x, ui.TAB_BAR_HEIGHT / 2)
	testing.expect_value(t, target, ui.Tab_Hit_Target.Tab_Item)
	testing.expect_value(t, idx, state.display_start)
	testing.expect(t, idx > 0, "scrolling must shift the logical index under a fixed point")
}

@test
test_tab_bar_anim_update_settles :: proc(t: ^testing.T) {
	state: ui.Tab_Bar_State
	ui.tab_bar_init(&state)
	theme := ui.theme_catppuccin_mocha()

	// An idle animation must not request a repaint.
	testing.expect(t, !ui.tab_bar_anim_update(&state, 1, 16.0, theme.motion.hover_ms, theme.motion.active_ms), "inactive animation must report no repaint")

	state.hover_tab_idx = 2
	state.hover_close_idx = 3
	state.hover_new_tab = true
	ui.tab_bar_anim_activate(&state)

	testing.expect(t, ui.tab_bar_anim_update(&state, 1, 16.0, theme.motion.hover_ms, theme.motion.active_ms), "animation must report repaint while transitioning")

	settled := false
	for _ in 0..<600 {
		if !ui.tab_bar_anim_update(&state, 1, 16.0, theme.motion.hover_ms, theme.motion.active_ms) {
			settled = true
			break
		}
	}
	testing.expect(t, settled, "animation must settle to rest")
	testing.expect(t, !state.anim.anim_active, "anim_active must clear at rest")
	testing.expect_value(t, state.anim.hover_t[2], 1.0)
	testing.expect_value(t, state.anim.hover_t[0], 0.0)
	testing.expect_value(t, state.anim.active_t[1], 1.0)
	testing.expect_value(t, state.anim.active_t[0], 0.0)
	testing.expect_value(t, state.anim.close_t[3], 1.0)
	testing.expect_value(t, state.anim.new_tab_t, 1.0)
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

@test
test_tab_bar_geometry_tokens :: proc(t: ^testing.T) {
	testing.expect_value(t, ui.TAB_BAR_HEIGHT, f32(28))
	testing.expect_value(t, ui.TAB_MIN_W, f32(110))
	testing.expect_value(t, ui.TAB_MAX_W, f32(200))
	testing.expect_value(t, ui.NEW_TAB_BTN_WIDTH, f32(28))
	testing.expect_value(t, ui.CLOSE_BTN_WIDTH, f32(22))
	testing.expect_value(t, ui.TAB_TITLE_PAD_LEFT, f32(10))

	state: ui.Tab_Bar_State
	rects: [8]ui.Rect_f32
	n := ui.tab_bar_layout(&state, 800.0, 3, rects[:])
	testing.expect_value(t, n, 3)
	for i in 0 ..< n {
		testing.expect_value(t, rects[i].h, ui.TAB_BAR_HEIGHT)
	}
}

@test
test_tab_bar_reserves_drag_area :: proc(t: ^testing.T) {
	for width in ([]f32{400.0, 800.0, 1200.0}) {
		for count in ([]int{1, 4, 16}) {
			state: ui.Tab_Bar_State
			rects: [16]ui.Rect_f32
			_ = ui.tab_bar_layout(&state, width, count, rects[:])
			testing.expect(
				t,
				state.drag_rect.w >= ui.TAB_BAR_MIN_DRAG_W - 0.001,
				"tab bar must reserve a trailing free drag area",
			)
		}
	}
}

@test
test_tab_overflow_dropdown_key_navigation :: proc(t: ^testing.T) {
	bar: ui.Tab_Bar_State
	rects: [16]ui.Rect_f32
	_ = ui.tab_bar_layout(&bar, 800.0, 16, rects[:])
	testing.expect(t, bar.overflow_rect.w > 0, "16 tabs on an 800px window must overflow")

	tabs: [16]ui.UI_Tab_Info
	for i in 0 ..< 16 {
		tabs[i].id = u32(i + 1)
		tabs[i].is_active = (i == 2)
	}

	m: ui.Tab_Overflow_State
	m.visible = true
	ui.tab_overflow_refresh(&m, tabs[:], &bar, 800, 600)
	testing.expect_value(t, m.selected_tab_id, u32(3))

	ev: input.Input_Event
	ev.event_type = .Key

	ev.kind = .Arrow_Down
	testing.expect_value(t, ui.tab_overflow_dispatch_key(&m, tabs[:], ev), ui.Tab_Overflow_Action.None)
	testing.expect_value(t, m.selected_tab_id, u32(4))

	ev.kind = .Arrow_Up
	testing.expect_value(t, ui.tab_overflow_dispatch_key(&m, tabs[:], ev), ui.Tab_Overflow_Action.None)
	testing.expect_value(t, m.selected_tab_id, u32(3))

	ev.kind = .Home
	testing.expect_value(t, ui.tab_overflow_dispatch_key(&m, tabs[:], ev), ui.Tab_Overflow_Action.None)
	testing.expect_value(t, m.selected_tab_id, u32(1))

	ev.kind = .End
	testing.expect_value(t, ui.tab_overflow_dispatch_key(&m, tabs[:], ev), ui.Tab_Overflow_Action.None)
	testing.expect_value(t, m.selected_tab_id, u32(16))

	ev.kind = .Enter
	testing.expect_value(t, ui.tab_overflow_dispatch_key(&m, tabs[:], ev), ui.Tab_Overflow_Action.Activate)

	ev.kind = .Escape
	testing.expect_value(t, ui.tab_overflow_dispatch_key(&m, tabs[:], ev), ui.Tab_Overflow_Action.Dismiss)
}

@test
test_tab_overflow_dropdown_pointer_and_autoclose :: proc(t: ^testing.T) {
	bar: ui.Tab_Bar_State
	rects: [16]ui.Rect_f32
	_ = ui.tab_bar_layout(&bar, 800.0, 16, rects[:])

	tabs: [16]ui.UI_Tab_Info
	for i in 0 ..< 16 {
		tabs[i].id = u32(i + 1)
		tabs[i].is_active = (i == 2)
	}

	m: ui.Tab_Overflow_State
	m.visible = true
	ui.tab_overflow_refresh(&m, tabs[:], &bar, 800, 600)

	r1 := ui.tab_overflow_row_rect(&m, 1)
	act := ui.tab_overflow_dispatch_pointer(&m, tabs[:], r1.x + r1.w * 0.5, r1.y + r1.h * 0.5, true, 0)
	testing.expect_value(t, act, ui.Tab_Overflow_Action.Activate)
	testing.expect_value(t, m.selected_tab_id, u32(2))

	act = ui.tab_overflow_dispatch_pointer(&m, tabs[:], m.rect.x - 50, m.rect.y - 50, true, 0)
	testing.expect_value(t, act, ui.Tab_Overflow_Action.Dismiss)

	bar2: ui.Tab_Bar_State
	rects2: [2]ui.Rect_f32
	_ = ui.tab_bar_layout(&bar2, 800.0, 2, rects2[:])
	m2: ui.Tab_Overflow_State
	m2.visible = true
	ui.tab_overflow_refresh(&m2, tabs[:2], &bar2, 800, 600)
	testing.expect(t, !m2.visible, "dropdown must auto-close when no overflow remains")
}

@test
test_shortcut_registry_labels :: proc(t: ^testing.T) {
	testing.expect_value(t, ui.ui_shortcut_label(.New_Tab), "\u2318T")
	testing.expect_value(t, ui.ui_shortcut_label(.Close_Tab), "\u2318D")
	testing.expect_value(t, ui.ui_shortcut_label(.Close_Others), "\u2325\u2318D")
	testing.expect_value(t, ui.ui_shortcut_label(.Close_To_Right), "\u2325\u21E7\u2318D")
	testing.expect_value(t, ui.ui_shortcut_label(.Detach_Tab), "\u2325\u2318B")
	testing.expect_value(t, ui.ui_shortcut_label(.Overflow), "\u21E7\u2318\\")
	testing.expect_value(t, ui.ui_shortcut_label(.Window_Zoom), "\u2303\u2318Z")
	testing.expect_value(t, ui.ui_shortcut_label(.Cancel), "esc")
	testing.expect_value(t, ui.ui_shortcut_tab_label(0, 3), "\u23181")
	testing.expect_value(t, ui.ui_shortcut_tab_label(7, 16), "\u23188")
	testing.expect_value(t, ui.ui_shortcut_tab_label(15, 16), "\u23189")
	testing.expect_value(t, ui.ui_shortcut_tab_label(9, 16), "")
}

@test
test_ui_render_overflow_hints_stage :: proc(t: ^testing.T) {
	r := new(render.Renderer)
	defer free(r)
	r.cell_width = 8.0
	r.cell_height = 16.0
	max_inst: u32 = 2048
	r.instances.max_instances = max_inst
	r.instances.instance_data = make([]instance.Instance_Data, int(max_inst))
	defer delete(r.instances.instance_data)
	for &s in r.atlas.slots do s.valid = true

	theme := ui.theme_catppuccin_mocha()
	state: ui.Tab_Bar_State
	ui.tab_bar_init(&state)
	rects: [16]ui.Rect_f32
	_ = ui.tab_bar_layout(&state, 800.0, 16, rects[:])
	tabs: [16]ui.UI_Tab_Info
	for i in 0 ..< 16 {
		tabs[i] = {id = u32(i + 1), title = "Tab", is_active = (i == 0)}
	}

	hidden := ui.ui_render_stage(r, &theme, i18n.i18n_get(), &state, tabs[:], rects[:], nil, 800, 600)

	overflow: ui.Tab_Overflow_State
	overflow.visible = true
	overflow.selected_tab_id = 1
	ui.tab_overflow_refresh(&overflow, tabs[:], &state, 800, 600)
	shown := ui.ui_render_stage(r, &theme, i18n.i18n_get(), &state, tabs[:], rects[:], nil, 800, 600, 1, "", nil, nil, nil, nil, &overflow)
	testing.expect(t, shown > hidden, "visible overflow dropdown must stage extra rows and shortcut badges")
}

@test
test_ui_draw_water_ring_and_alpha :: proc(t: ^testing.T) {
	r := new(render.Renderer)
	defer free(r)
	render.renderer_ui_reset(r)

	col := ui.Color{0.2, 0.4, 0.8, 0.5}
	ui.ui_draw_water_ring(r, 100, 100, 30, 2, col)
	testing.expect(t, r.ui_layer_bg_count[render.UI_Layer.Overlay] > 0, "water ring must stage background quads")
	// Verify that emit_bg preserved the alpha channel!
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Overlay][0].a, f32(0.5))
}

@test
test_ui_draw_hover_ripple :: proc(t: ^testing.T) {
	r := new(render.Renderer)
	defer free(r)
	render.renderer_ui_reset(r)

	col := ui.Color{0.35, 0.75, 1.0, 0.8}
	ui.ui_draw_hover_ripple(r, 150, 150, 0.5, col)
	testing.expect(t, r.ui_layer_bg_count[render.UI_Layer.Overlay] >= 32, "hover ripple must stage multiple concentric rings")
}

@test
test_ui_draw_splash_ripple :: proc(t: ^testing.T) {
	r := new(render.Renderer)
	defer free(r)
	render.renderer_ui_reset(r)

	col := ui.Color{0.35, 0.75, 1.0, 0.8}
	ui.ui_draw_splash_ripple(r, 200, 200, 0.3, 0.8, col)
	testing.expect(t, r.ui_layer_bg_count[render.UI_Layer.Overlay] >= 32, "splash ripple must stage expanding waves")
}

@test
test_ui_stage_water_3d_hover :: proc(t: ^testing.T) {
	r := new(render.Renderer)
	defer free(r)
	render.renderer_ui_reset(r)

	col := ui.Color{0.35, 0.75, 1.0, 0.85}
	ui.ui_stage_water_3d_hover(r, 800, 600, 150, 150, 0.5, col)
	testing.expect_value(t, r.ui_layer_bg_count[render.UI_Layer.Overlay], u32(1))
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Overlay][0].cw, f32(800))
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Overlay][0].ch, f32(600))
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Overlay][0].u0, f32(150)) // cx
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Overlay][0].v0, f32(150)) // cy
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Overlay][0].u1, f32(0.5)) // hover_time
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Overlay][0].v1, f32(-1.0)) // reserved hover effect marker
}

@test
test_ui_stage_water_3d_splash :: proc(t: ^testing.T) {
	r := new(render.Renderer)
	defer free(r)
	render.renderer_ui_reset(r)

	col := ui.Color{0.35, 0.75, 1.0, 0.85}
	ui.ui_stage_water_3d_splash(r, 1024, 768, 200, 300, 0.4, 1.6, col)
	testing.expect_value(t, r.ui_layer_bg_count[render.UI_Layer.Overlay], u32(1))
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Overlay][0].cw, f32(1024))
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Overlay][0].ch, f32(768))
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Overlay][0].u0, f32(200)) // cx
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Overlay][0].v0, f32(300)) // cy
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Overlay][0].u1, f32(0.4 / 1.6)) // normalized progress
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Overlay][0].v1, f32(-2.0)) // reserved splash effect marker
}


@test
test_ui_stage_water_3d_splash_duration_boundaries :: proc(t: ^testing.T) {
	r := new(render.Renderer)
	defer free(r)
	col := ui.Color{0.35, 0.75, 1.0, 0.85}
	duration: f32 = 2.4
	progress: f32 = 0.25
	ui.ui_stage_water_3d_splash(r, 800, 600, 100, 150, duration * progress, duration, col)
	testing.expect_value(t, r.ui_layer_bg_count[render.UI_Layer.Overlay], u32(1))
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Overlay][0].u1, progress)

	render.renderer_ui_reset(r)
	ui.ui_stage_water_3d_splash(r, 800, 600, 100, 150, 0, duration, col)
	testing.expect_value(t, r.ui_layer_bg_count[render.UI_Layer.Overlay], u32(1))
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Overlay][0].u1, f32(0))

	render.renderer_ui_reset(r)
	ui.ui_stage_water_3d_splash(r, 800, 600, 100, 150, duration, duration, col)
	ui.ui_stage_water_3d_splash(r, 800, 600, 100, 150, duration * 2, duration, col)
	ui.ui_stage_water_3d_splash(r, 800, 600, 100, 150, 0, 0, col)
	ui.ui_stage_water_3d_splash(r, 800, 600, 100, 150, 0, -duration, col)
	ui.ui_stage_water_3d_splash(r, 800, 600, 100, 150, -duration, duration, col)
	testing.expect_value(t, r.ui_layer_bg_count[render.UI_Layer.Overlay], u32(0))
}

@test
test_water_surface_filters_bounds_and_resets :: proc(t: ^testing.T) {
	r := new(render.Renderer)
	defer free(r)
	col := ui.Color{0.5, 0.6, 0.65, 0.7}
	waves: [instance.WATER_MAX_WAVES + 1]instance.Water_Wave
	for &w in waves {
		w = instance.Water_Wave{origin_age_strength = {100, 150, 0.3, 0.4}, lifetime_params = {2, 0, 0, 0}}
	}
	ui.ui_stage_water_surface(r, 800, 600, 2, waves[:], col)
	testing.expect_value(t, r.ui_layer_bg_count[render.UI_Layer.Overlay], u32(1))
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Overlay][0].v1, f32(-3))
	testing.expect_value(t, r.instances.uniform_data.water_meta[0], f32(instance.WATER_MAX_WAVES))
	testing.expect_value(t, r.instances.uniform_data.water_meta[1], f32(2))
	testing.expect_value(t, r.instances.uniform_data.waves[0].origin_age_strength[0], f32(100))

	render.renderer_ui_reset(r)
	bad := transmute(f32)u32(0x7fc00000)
	waves[0].origin_age_strength[0] = bad
	waves[1].origin_age_strength[2] = waves[1].lifetime_params[0]
	ui.ui_stage_water_surface(r, 800, 600, 2, waves[:3], col)
	testing.expect_value(t, r.instances.uniform_data.water_meta[0], f32(1))
	testing.expect_value(t, r.instances.uniform_data.waves[1].lifetime_params[0], f32(0))

	render.renderer_ui_reset(r)
	ui.ui_stage_water_surface(r, 800, 600, 2, nil, col)
	testing.expect_value(t, r.ui_layer_bg_count[render.UI_Layer.Overlay], u32(0))
	testing.expect_value(t, r.instances.uniform_data.water_meta[0], f32(0))
	ui.ui_stage_water_surface(r, 800, 600, bad, waves[2:], col)
	testing.expect_value(t, r.ui_layer_bg_count[render.UI_Layer.Overlay], u32(0))
	// A saturated layer must refuse new quads instead of spilling anywhere.
	overlay_cap: u32 = u32(render.UI_LAYER_BG_CAPACITY[render.UI_Layer.Overlay])
	r.ui_layer_bg_count[render.UI_Layer.Overlay] = overlay_cap
	ui.ui_stage_water_surface(r, 800, 600, 2, waves[2:], col)
	testing.expect_value(t, r.ui_layer_bg_count[render.UI_Layer.Overlay], overlay_cap)
	testing.expect_value(t, r.instances.uniform_data.water_meta[0], f32(0))
}

@test
test_pane_chrome_dividers_and_active_border :: proc(t: ^testing.T) {
	r := new(render.Renderer)
	defer free(r)
	theme := ui.theme_catppuccin_mocha()

	dividers := []ui.Pane_Divider{
		{x = 400, y = 28, w = 1, h = 572, is_hovered = false},
		{x = 401, y = 300, w = 399, h = 1, is_hovered = true},
	}
	active_rect := ui.Rect_f32{x = 0, y = 28, w = 400, h = 572}

	all_edges := ui.PANE_EDGE_LEFT | ui.PANE_EDGE_RIGHT | ui.PANE_EDGE_TOP | ui.PANE_EDGE_BOTTOM
	ui.ui_stage_pane_chrome(r, &theme, dividers, active_rect, all_edges, true, 1.0)
	testing.expect(t, r.ui_staged, "ui must be staged")
	// 2 dividers + 4 border quads = 6 quads on the pane-chrome layer
	testing.expect_value(t, r.ui_layer_bg_count[render.UI_Layer.Pane_Chrome], u32(6))

	// Divider 0: border_divider at full alpha
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Pane_Chrome][0].x, f32(400))
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Pane_Chrome][0].y, f32(28))
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Pane_Chrome][0].cw, f32(1))
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Pane_Chrome][0].ch, f32(572))
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Pane_Chrome][0].r, theme.border_divider.r)
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Pane_Chrome][0].a, theme.border_divider.a)

	// Divider 1: surface_hover
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Pane_Chrome][1].x, f32(401))
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Pane_Chrome][1].y, f32(300))
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Pane_Chrome][1].cw, f32(399))
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Pane_Chrome][1].ch, f32(1))
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Pane_Chrome][1].r, theme.surface_hover.r)

	// Border quads (top, bottom, left, right): accent_primary
	for i in 2..<6 {
		testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Pane_Chrome][i].r, theme.accent_primary.r)
		testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Pane_Chrome][i].g, theme.accent_primary.g)
		testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Pane_Chrome][i].b, theme.accent_primary.b)
	}
}

@test
test_pane_chrome_hollow_cursor :: proc(t: ^testing.T) {
	r := new(render.Renderer)
	defer free(r)

	ui.ui_stage_hollow_cursor(r, 100, 200, 8, 16, {0.8, 0.8, 0.8, 0.8}, 1.0)
	testing.expect(t, r.ui_staged, "ui must be staged")
	testing.expect_value(t, r.ui_layer_bg_count[render.UI_Layer.Pane_Chrome], u32(4))

	// Top: (100, 200, 8, 1)
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Pane_Chrome][0].x, f32(100))
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Pane_Chrome][0].y, f32(200))
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Pane_Chrome][0].cw, f32(8))
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Pane_Chrome][0].ch, f32(1))

	// Bottom: (100, 215, 8, 1)
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Pane_Chrome][1].x, f32(100))
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Pane_Chrome][1].y, f32(215))
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Pane_Chrome][1].cw, f32(8))
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Pane_Chrome][1].ch, f32(1))

	// Left: (100, 200, 1, 16)
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Pane_Chrome][2].x, f32(100))
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Pane_Chrome][2].y, f32(200))
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Pane_Chrome][2].cw, f32(1))
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Pane_Chrome][2].ch, f32(16))

	// Right: (107, 200, 1, 16)
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Pane_Chrome][3].x, f32(107))
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Pane_Chrome][3].y, f32(200))
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Pane_Chrome][3].cw, f32(1))
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Pane_Chrome][3].ch, f32(16))
}

@test
test_session_switcher_render_clips_scrolled_rows :: proc(t: ^testing.T) {
	r := new(render.Renderer)
	for &slot in r.atlas.slots do slot.valid = true
	defer free(r)
	theme := ui.theme_catppuccin_mocha()
	bar: ui.Tab_Bar_State
	ui.tab_bar_init(&bar)
	state: ui.Session_Switcher_State
	tabs.session_switcher_init(&state)
	state.visible = true
	state.item_count = 20
	for i in 0 ..< state.item_count {
		state.items[i].title = "A very long session title that should not overlap the status"
		state.items[i].cwd = "/workspace/very/long/path/that/is/clipped"
		state.items[i].tab_idx = i
	}
	tabs.session_switcher_filter(&state)
	state.selected_match_idx = 15
	tabs.session_switcher_layout(&state, 420, 300)
	testing.expect(t, state.scroll_offset > 0)
	_ = ui.ui_render_stage(r, &theme, i18n.i18n_get(), &bar, nil, nil, nil, 420, 300, 1, "", nil, nil, nil, nil, nil, &state)
	testing.expect(t, r.ui_layer_glyph_count[render.UI_Layer.Modal] > 0)
	for glyph in r.ui_glyph_data[render.UI_Layer.Modal][:r.ui_layer_glyph_count[render.UI_Layer.Modal]] {
		testing.expect(t, glyph.x >= state.rect.x && glyph.x + glyph.cw <= state.rect.x + state.rect.w)
		testing.expect(t, glyph.y >= state.rect.y && glyph.y + glyph.ch <= state.rect.y + state.rect.h)
	}
	tabs.session_switcher_layout(&state, 100, 80)
	_ = ui.ui_render_stage(r, &theme, i18n.i18n_get(), &bar, nil, nil, nil, 100, 80, 1, "", nil, nil, nil, nil, nil, &state)
	testing.expect_value(t, r.ui_layer_glyph_count[render.UI_Layer.Modal], u32(0))
}

@test
test_ui_layer_plan_puts_modal_above_pane_chrome :: proc(t: ^testing.T) {
	r := new(render.Renderer)
	defer free(r)
	for &slot in r.atlas.slots do slot.valid = true
	theme := ui.theme_catppuccin_mocha()

	// Split-pane chrome is staged in device pixels by the app, after the
	// tab chrome pass has already staged the visible session switcher.
	dividers := []ui.Pane_Divider{{x = 400, y = 28, w = 1, h = 572}}
	active_rect := ui.Rect_f32{x = 0, y = 28, w = 400, h = 572}

	bar: ui.Tab_Bar_State
	ui.tab_bar_init(&bar)
	switcher: ui.Session_Switcher_State
	tabs.session_switcher_init(&switcher)
	switcher.visible = true
	switcher.item_count = 3
	for i in 0 ..< switcher.item_count {
		switcher.items[i].title = "Session"
		switcher.items[i].cwd = "/tmp"
		switcher.items[i].tab_idx = i
	}
	tabs.session_switcher_filter(&switcher)
	tabs.session_switcher_layout(&switcher, 800, 600)

	render.renderer_ui_reset(r)
	_ = ui.ui_render_stage(r, &theme, i18n.i18n_get(), &bar, nil, nil, nil, 800, 600, 1, "", nil, nil, nil, nil, nil, &switcher)
	ui.ui_stage_pane_chrome(r, &theme, dividers, active_rect, ui.PANE_EDGE_RIGHT, true, 1.0)

	testing.expect(t, r.ui_layer_bg_count[render.UI_Layer.Modal] > 0, "the visible switcher must populate the modal layer")
	testing.expect(t, r.ui_layer_bg_count[render.UI_Layer.Pane_Chrome] > 0, "split-pane chrome must populate the pane-chrome layer")

	runs: [render.UI_LAYER_COUNT]render.UI_Layer_Run
	total := render.renderer_ui_layer_plan(r, 0, &runs)
	testing.expect(t, total > 0, "the layer plan must cover staged instances")
	testing.expect_value(t, runs[render.UI_Layer.Modal].bg_count, r.ui_layer_bg_count[render.UI_Layer.Modal])
	testing.expect(t,
		runs[render.UI_Layer.Modal].bg_offset >= runs[render.UI_Layer.Pane_Chrome].bg_offset + u64(runs[render.UI_Layer.Pane_Chrome].bg_count) * instance.INSTANCE_STRIDE,
		"every modal instance must be uploaded after every pane-chrome instance",
	)
}

@test
test_ui_active_pane_outline_respects_edge_mask :: proc(t: ^testing.T) {
	r := new(render.Renderer)
	defer free(r)
	theme := ui.theme_catppuccin_mocha()
	active_rect := ui.Rect_f32{x = 0, y = 28, w = 400, h = 572}

	// A single edge bit must emit exactly one accent quad.
	ui.ui_stage_pane_chrome(r, &theme, nil, active_rect, ui.PANE_EDGE_RIGHT, true, 1.0)
	testing.expect_value(t, r.ui_layer_bg_count[render.UI_Layer.Pane_Chrome], u32(1))
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Pane_Chrome][0].x, f32(399))
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Pane_Chrome][0].cw, f32(1))
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Pane_Chrome][0].ch, f32(572))
	testing.expect_value(t, r.ui_bg_data[render.UI_Layer.Pane_Chrome][0].r, theme.accent_primary.r)

	// An empty mask emits nothing at all.
	render.renderer_ui_reset(r)
	ui.ui_stage_pane_chrome(r, &theme, nil, active_rect, 0, true, 1.0)
	testing.expect_value(t, r.ui_layer_bg_count[render.UI_Layer.Pane_Chrome], u32(0))

	// The outline never exceeds four quads, one per requested edge.
	render.renderer_ui_reset(r)
	all_edges := ui.PANE_EDGE_LEFT | ui.PANE_EDGE_RIGHT | ui.PANE_EDGE_TOP | ui.PANE_EDGE_BOTTOM
	ui.ui_stage_pane_chrome(r, &theme, nil, active_rect, all_edges, true, 1.0)
	testing.expect(t, r.ui_layer_bg_count[render.UI_Layer.Pane_Chrome] <= 4, "the outline is capped at four edges")

	// show_active_border suppresses the outline even when edges are requested.
	render.renderer_ui_reset(r)
	ui.ui_stage_pane_chrome(r, &theme, nil, active_rect, all_edges, false, 1.0)
	testing.expect_value(t, r.ui_layer_bg_count[render.UI_Layer.Pane_Chrome], u32(0))
}

// _rune_len counts runes in s; byte length differs once UI copy carries symbols.
_rune_len :: proc(s: string) -> int {
	n := 0
	for _ in s do n += 1
	return n
}

// _session_switcher_test_state builds a laid-out switcher with count rows; the trailing
// `persisted` rows are saved layouts rather than sessions.
_session_switcher_test_state :: proc(state: ^tabs.Session_Switcher_State, count, persisted_rows: int) {
	tabs.session_switcher_init(state)
	state.visible = true
	state.item_count = count
	for i in 0 ..< count {
		state.items[i].title = fmt.bprintf(state.items[i].title_buf[:], "S%d", i)
		state.items[i].cwd = "/tmp"
		state.items[i].tab_idx = i
		state.items[i].pane_count = 1
		state.items[i].is_persisted = i >= count - persisted_rows
	}
	tabs.session_switcher_filter(state)
	state.selected_match_idx = 0
	tabs.session_switcher_layout(state, 800, 600)
}

@test
test_session_switcher_renders_close_affordance_per_row :: proc(t: ^testing.T) {
	r := new(render.Renderer)
	for &slot in r.atlas.slots do slot.valid = true
	// Tag the pinned close glyph's slot so staged affordances are identifiable.
	r.atlas.slots[render.PINNED_SLOT_UI].u0 = 0.75
	defer free(r)
	theme := ui.theme_catppuccin_mocha()
	bar: ui.Tab_Bar_State
	ui.tab_bar_init(&bar)

	state: ui.Session_Switcher_State
	_session_switcher_test_state(&state, 5, 1)
	rows := min(state.visible_rows, state.match_count)
	testing.expect(t, rows == state.match_count, "every row must fit the visible window")

	_ = ui.ui_render_stage(r, &theme, i18n.i18n_get(), &bar, nil, nil, nil, 800, 600, 1, "", nil, nil, nil, nil, nil, &state)
	footer_y := state.rect.y + state.rect.h - tabs.SESSION_SWITCHER_FOOTER_HEIGHT
	close_glyphs, hovered := 0, 0
	for glyph in r.ui_glyph_data[render.UI_Layer.Modal][:r.ui_layer_glyph_count[render.UI_Layer.Modal]] {
		if glyph.u0 != 0.75 || glyph.y >= footer_y do continue
		close_glyphs += 1
		if glyph.r == theme.status_danger.r do hovered += 1
	}
	testing.expect(t, close_glyphs == 4, "every non-layout row stages one close affordance")
	testing.expect_value(t, hovered, 0)

	// Hovering a row tints exactly that row's affordance.
	state.hover_close_row = 1
	_ = ui.ui_render_stage(r, &theme, i18n.i18n_get(), &bar, nil, nil, nil, 800, 600, 1, "", nil, nil, nil, nil, nil, &state)
	close_glyphs, hovered = 0, 0
	for glyph in r.ui_glyph_data[render.UI_Layer.Modal][:r.ui_layer_glyph_count[render.UI_Layer.Modal]] {
		if glyph.u0 != 0.75 || glyph.y >= footer_y do continue
		close_glyphs += 1
		if glyph.r == theme.status_danger.r do hovered += 1
	}
	testing.expect_value(t, close_glyphs, 4)
	testing.expect_value(t, hovered, 1)

	// The affordance sits inside its row's close rect.
	for row in 0 ..< rows {
		close_rect := tabs.session_switcher_close_rect(&state, row)
		row_rect := tabs.session_switcher_row_rect(&state, row)
		testing.expect(t, close_rect.x >= row_rect.x && close_rect.x + close_rect.w <= row_rect.x + row_rect.w)
	}
}

@test
test_session_switcher_status_shows_pane_count :: proc(t: ^testing.T) {
	r := new(render.Renderer)
	for &slot in r.atlas.slots do slot.valid = true
	defer free(r)
	theme := ui.theme_catppuccin_mocha()
	bar: ui.Tab_Bar_State
	ui.tab_bar_init(&bar)

	state: ui.Session_Switcher_State
	_session_switcher_test_state(&state, 4, 0)
	// Row 0 stays single-pane in both passes so the selected-row footer is unchanged.
	for i in 1 ..< state.item_count {
		state.items[i].pane_count = 3
	}
	_ = ui.ui_render_stage(r, &theme, i18n.i18n_get(), &bar, nil, nil, nil, 800, 600, 1, "", nil, nil, nil, nil, nil, &state)
	split_glyphs := int(r.ui_layer_glyph_count[render.UI_Layer.Modal])

	for i in 1 ..< state.item_count {
		state.items[i].pane_count = 1
	}
	_ = ui.ui_render_stage(r, &theme, i18n.i18n_get(), &bar, nil, nil, nil, 800, 600, 1, "", nil, nil, nil, nil, nil, &state)
	single_glyphs := int(r.ui_layer_glyph_count[render.UI_Layer.Modal])

	// Each multi-pane row appends " · 3 panes" to its status column.
	testing.expect_value(t, split_glyphs - single_glyphs, 3 * _rune_len(" · 3 panes"))
}
