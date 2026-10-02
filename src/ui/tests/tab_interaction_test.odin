package ui_test

import "core:testing"

import ui "../"
import input "../../platform/input"

@test
test_tab_menu_refresh_matrix :: proc(t: ^testing.T) {
	m: ui.Tab_Menu_State
	ui.tab_menu_init(&m)

	// Single tab: only Close, New_Tab, and Rename are enabled.
	m.target_idx = 0
	ui.tab_menu_refresh(&m, 1, 4)
	testing.expect(t, !m.disabled[int(ui.Tab_Menu_Item.Close)])
	testing.expect(t, m.disabled[int(ui.Tab_Menu_Item.Close_Others)])
	testing.expect(t, m.disabled[int(ui.Tab_Menu_Item.Close_To_Right)])
	testing.expect(t, !m.disabled[int(ui.Tab_Menu_Item.New_Tab)])
	testing.expect(t, !m.disabled[int(ui.Tab_Menu_Item.Rename)])

	// Middle tab of three: close-others and close-to-right both apply.
	m.target_idx = 1
	ui.tab_menu_refresh(&m, 3, 4)
	testing.expect(t, !m.disabled[int(ui.Tab_Menu_Item.Close_Others)])
	testing.expect(t, !m.disabled[int(ui.Tab_Menu_Item.Close_To_Right)])

	// Last tab: nothing to the right.
	m.target_idx = 2
	ui.tab_menu_refresh(&m, 3, 4)
	testing.expect(t, m.disabled[int(ui.Tab_Menu_Item.Close_To_Right)])

	// Max tabs reached: New_Tab is disabled.
	ui.tab_menu_refresh(&m, 4, 4)
	testing.expect(t, m.disabled[int(ui.Tab_Menu_Item.New_Tab)])

	// Empty strip: Close and Rename are disabled, New_Tab stays available.
	m.target_idx = -1
	ui.tab_menu_refresh(&m, 0, 4)
	testing.expect(t, m.disabled[int(ui.Tab_Menu_Item.Close)])
	testing.expect(t, m.disabled[int(ui.Tab_Menu_Item.Rename)])
	testing.expect(t, !m.disabled[int(ui.Tab_Menu_Item.New_Tab)])
}

@test
test_tab_menu_key_navigation :: proc(t: ^testing.T) {
	m: ui.Tab_Menu_State
	ui.tab_menu_init(&m)
	ui.tab_menu_open(&m, 0, 7, 1, 4, 10, 10, 800, 600)
	testing.expect(t, m.visible)

	consumed: bool
	action: ui.Tab_Menu_Action
	item: ui.Tab_Menu_Item

	// Down from -1 selects the first enabled item (Close).
	consumed, action, _ = ui.tab_menu_dispatch_key(&m, input.Input_Event{event_type = .Key, kind = .Arrow_Down}, 1, 4)
	testing.expect(t, consumed)
	testing.expect_value(t, action, ui.Tab_Menu_Action.None)
	testing.expect_value(t, m.active_item, int(ui.Tab_Menu_Item.Close))

	// Down skips the disabled middle entries and lands on New_Tab.
	_, _, _ = ui.tab_menu_dispatch_key(&m, input.Input_Event{event_type = .Key, kind = .Arrow_Down}, 1, 4)
	testing.expect_value(t, m.active_item, int(ui.Tab_Menu_Item.New_Tab))
	_, _, _ = ui.tab_menu_dispatch_key(&m, input.Input_Event{event_type = .Key, kind = .Arrow_Down}, 1, 4)
	testing.expect_value(t, m.active_item, int(ui.Tab_Menu_Item.Rename))
	// New session entries remain reachable before wrapping.
	_, _, _ = ui.tab_menu_dispatch_key(&m, input.Input_Event{event_type = .Key, kind = .Arrow_Down}, 1, 4)
	testing.expect_value(t, m.active_item, int(ui.Tab_Menu_Item.Detach))
	_, _, _ = ui.tab_menu_dispatch_key(&m, input.Input_Event{event_type = .Key, kind = .Arrow_Down}, 1, 4)
	testing.expect_value(t, m.active_item, int(ui.Tab_Menu_Item.Sessions))
	// Forward wrap returns to Close, backward wrap returns to Sessions.
	_, _, _ = ui.tab_menu_dispatch_key(&m, input.Input_Event{event_type = .Key, kind = .Arrow_Down}, 1, 4)
	testing.expect_value(t, m.active_item, int(ui.Tab_Menu_Item.Close))
	_, _, _ = ui.tab_menu_dispatch_key(&m, input.Input_Event{event_type = .Key, kind = .Arrow_Up}, 1, 4)
	testing.expect_value(t, m.active_item, int(ui.Tab_Menu_Item.Sessions))

	// Enter activates the active enabled item.
	m.active_item = int(ui.Tab_Menu_Item.New_Tab)
	consumed, action, item = ui.tab_menu_dispatch_key(&m, input.Input_Event{event_type = .Key, kind = .Enter}, 1, 4)
	testing.expect(t, consumed)
	testing.expect_value(t, action, ui.Tab_Menu_Action.Activated)
	testing.expect_value(t, item, ui.Tab_Menu_Item.New_Tab)

	// Escape dismisses; other keys are swallowed.
	consumed, action, _ = ui.tab_menu_dispatch_key(&m, input.Input_Event{event_type = .Key, kind = .Escape}, 1, 4)
	testing.expect(t, consumed)
	testing.expect_value(t, action, ui.Tab_Menu_Action.Dismissed)
	consumed, action, _ = ui.tab_menu_dispatch_key(&m, input.Input_Event{event_type = .Key, kind = .Printable, rune = 'x'}, 1, 4)
	testing.expect(t, consumed)
	testing.expect_value(t, action, ui.Tab_Menu_Action.None)
}

@test
test_tab_menu_pointer_activation :: proc(t: ^testing.T) {
	m: ui.Tab_Menu_State
	ui.tab_menu_init(&m)
	// Target is the last of two tabs, so Close_To_Right is disabled.
	ui.tab_menu_open(&m, 1, 2, 2, 4, 20, 20, 800, 600)

	close_rect := m.item_rects[int(ui.Tab_Menu_Item.Close)]
	consumed: bool
	action: ui.Tab_Menu_Action
	item: ui.Tab_Menu_Item
	consumed, action, _ = ui.tab_menu_dispatch_pointer(&m, close_rect.x + 4, close_rect.y + 4, false, 2, 4)
	testing.expect(t, consumed)
	testing.expect_value(t, m.hover_item, int(ui.Tab_Menu_Item.Close))

	// A click on a disabled item is swallowed and stays open.
	disabled_rect := m.item_rects[int(ui.Tab_Menu_Item.Close_To_Right)]
	testing.expect(t, m.disabled[int(ui.Tab_Menu_Item.Close_To_Right)])
	consumed, action, _ = ui.tab_menu_dispatch_pointer(&m, disabled_rect.x + 4, disabled_rect.y + 4, true, 2, 4)
	testing.expect(t, consumed)
	testing.expect_value(t, action, ui.Tab_Menu_Action.None)
	testing.expect(t, m.visible)

	// A click on an enabled item activates it.
	consumed, action, item = ui.tab_menu_dispatch_pointer(&m, close_rect.x + 4, close_rect.y + 4, true, 2, 4)
	testing.expect_value(t, action, ui.Tab_Menu_Action.Activated)
	testing.expect_value(t, item, ui.Tab_Menu_Item.Close)

	// A click outside the panel dismisses it.
	consumed, action, _ = ui.tab_menu_dispatch_pointer(&m, 2, 2, true, 2, 4)
	testing.expect(t, consumed)
	testing.expect_value(t, action, ui.Tab_Menu_Action.Dismissed)
}

@test
test_tab_rename_key_editing :: proc(t: ^testing.T) {
	rs: ui.Tab_Rename_State
	ui.tab_rename_init(&rs)
	testing.expect(t, !rs.active)
	testing.expect(t, ui.tab_rename_begin(&rs, 1, 42, "Shell"))
	testing.expect_value(t, ui.tab_rename_text(&rs), "Shell")

	// Append a printable rune.
	consumed, action := ui.tab_rename_dispatch_key(&rs, input.Input_Event{event_type = .Key, kind = .Printable, rune = '!'})
	testing.expect(t, consumed)
	testing.expect_value(t, action, ui.Tab_Rename_Action.Changed)
	testing.expect_value(t, ui.tab_rename_text(&rs), "Shell!")

	// Backspace trims the last byte.
	consumed, action = ui.tab_rename_dispatch_key(&rs, input.Input_Event{event_type = .Key, kind = .Backspace})
	testing.expect(t, consumed)
	testing.expect_value(t, action, ui.Tab_Rename_Action.Changed)
	testing.expect_value(t, ui.tab_rename_text(&rs), "Shell")

	// Backspace removes a whole multibyte UTF-8 sequence.
	_ = ui.tab_rename_begin(&rs, 1, 42, "ab")
	_, _ = ui.tab_rename_dispatch_key(&rs, input.Input_Event{event_type = .Key, kind = .Printable, rune = 'é'})
	testing.expect_value(t, len(ui.tab_rename_text(&rs)), 4)
	_, _ = ui.tab_rename_dispatch_key(&rs, input.Input_Event{event_type = .Key, kind = .Backspace})
	testing.expect_value(t, ui.tab_rename_text(&rs), "ab")

	// Enter commits and Escape cancels.
	consumed, action = ui.tab_rename_dispatch_key(&rs, input.Input_Event{event_type = .Key, kind = .Enter})
	testing.expect(t, consumed)
	testing.expect_value(t, action, ui.Tab_Rename_Action.Commit)
	consumed, action = ui.tab_rename_dispatch_key(&rs, input.Input_Event{event_type = .Key, kind = .Escape})
	testing.expect(t, consumed)
	testing.expect_value(t, action, ui.Tab_Rename_Action.Cancel)
}

@test
test_tab_drag_gap_and_dispatch :: proc(t: ^testing.T) {
	bar: ui.Tab_Bar_State
	ui.tab_bar_init(&bar)
	rects: [4]ui.Rect_f32
	_ = ui.tab_bar_layout(&bar, 800.0, 4, rects[:])

	// Boundaries resolve against the tab centers; gap == count uses the last edge.
	testing.expect_value(t, ui.tab_bar_drop_gap(&bar, 4, rects[:], rects[0].x + 1.0), 0)
	testing.expect_value(t, ui.tab_bar_drop_gap(&bar, 4, rects[:], rects[3].x + rects[3].w), 4)
	testing.expect_value(t, ui.tab_bar_gap_x(&bar, 4, rects[:], 4), rects[3].x + rects[3].w)

	d: ui.Tab_Drag_State
	ui.tab_drag_reset(&d)
	testing.expect(t, ui.tab_drag_begin(&d, 2, 99, rects[2].x + 10.0, 16.0))

	// Below the threshold the gesture stays pressed but is still consumed.
	consumed, action, _ := ui.tab_drag_dispatch_pointer(&d, &bar, 4, rects[:], rects[2].x + 12.0, 16.0, .Motion, 1)
	testing.expect(t, consumed)
	testing.expect_value(t, action, ui.Tab_Drag_Action.Move)
	testing.expect_value(t, d.phase, ui.Tab_Drag_Phase.Pressed)

	// Crossing the threshold enters dragging and resolves the insertion gap.
	consumed, action, _ = ui.tab_drag_dispatch_pointer(&d, &bar, 4, rects[:], rects[0].x + 2.0, 16.0, .Motion, 1)
	testing.expect(t, consumed)
	testing.expect_value(t, d.phase, ui.Tab_Drag_Phase.Dragging)
	testing.expect_value(t, d.drop_gap, 0)

	// Release drops at the resolved gap and resets to idle.
	gap: int
	consumed, action, gap = ui.tab_drag_dispatch_pointer(&d, &bar, 4, rects[:], rects[0].x + 2.0, 16.0, .Button_Up, 1)
	testing.expect(t, consumed)
	testing.expect_value(t, action, ui.Tab_Drag_Action.Drop)
	testing.expect_value(t, gap, 0)
	testing.expect_value(t, d.phase, ui.Tab_Drag_Phase.Idle)
}
