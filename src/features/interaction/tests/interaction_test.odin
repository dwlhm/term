package feature_interaction_tests

import "core:testing"
import "base:runtime"
import feature ".."
import tabs "../../tabs"
import multiplexer "../../multiplexer"
import session "../../session"
import chrome_splits "../../../core/chrome/splits"
import terminal "../../../core/terminal"
import terminal_grid "../../../core/terminal/grid"
import cell "../../../core/terminal/cell"

@test
test_interaction_lifecycle :: proc(t: ^testing.T) {
	tm: tabs.Tabs_Manager
	mux: multiplexer.Multiplexer
	inter: feature.Interaction_State

	bar_rect: [4]f32 = {0.0, 0.0, 800.0, 36.0}
	tabs.tabs_manager_init(&tm, bar_rect)
	multiplexer.multiplexer_init(&mux)
	feature.interaction_init(&inter)

	defer {
		tabs.tabs_manager_destroy(&tm)
		multiplexer.multiplexer_destroy(&mux)
	}

	cfg := session.Session_Config{
		shell = "/bin/sh",
		rows  = 24,
		cols  = 80,
	}

	// 1. Create a terminal pane and tab
	pane_id, err := multiplexer.multiplexer_create_terminal_pane(&mux, cfg)
	testing.expect(t, err == .None, "Create terminal pane failed")
	tabs.tabs_manager_create_tab(&tm, "Shell", pane_id)

	content_rect: [4]f32 = {0.0, 36.0, 800.0, 564.0}
	tabs.tabs_manager_update_layout(&tm, content_rect)
	multiplexer.multiplexer_sync_split_rects(&mux, tm.entries[0].split_tree)

	// 2. Mouse click inside pane
	click_pos: [2]f32 = {100.0, 100.0}
	action := feature.interaction_on_mouse_down(&inter, &tm, &mux, click_pos, 1, {})
	testing.expect_value(t, action.kind, feature.Action_Kind.Pane_Focused)
	testing.expect_value(t, action.pane_id, pane_id)
	testing.expect_value(t, inter.mode, feature.Interaction_Mode.Selecting_Text)

	// 3. Mouse drag text selection
	drag_pos: [2]f32 = {150.0, 120.0}
	feature.interaction_on_mouse_move(&inter, &mux, drag_pos, {})
	testing.expect(t, inter.selection.active, "Selection should be active")

	feature.interaction_on_mouse_up(&inter, &mux, 1)
	testing.expect_value(t, inter.mode, feature.Interaction_Mode.Idle)

	// 4. Keyboard shortcut: Cmd+T -> Tab_New_Requested
	key_act := feature.interaction_on_key_press(&inter, &tm, &mux, 't', {.Cmd})
	testing.expect_value(t, key_act.kind, feature.Action_Kind.Tab_New_Requested)

	// 5. 3D canvas interaction test
	pane_3d := multiplexer.multiplexer_create_3d_pane(&mux)
	p3 := multiplexer.multiplexer_get_pane(&mux, pane_3d)

	// Split tree into two panes
	chrome_splits.split_node_split(tm.entries[0].split_tree, .Horizontal, 0.5, pane_3d)
	tabs.tabs_manager_update_layout(&tm, content_rect)
	multiplexer.multiplexer_sync_split_rects(&mux, tm.entries[0].split_tree)

	multiplexer.multiplexer_focus_pane(&mux, pane_3d)

	// Click in 3D pane
	pos_3d: [2]f32 = {450.0, 200.0}
	action_3d := feature.interaction_on_mouse_down(&inter, &tm, &mux, pos_3d, 1, {})
	testing.expect_value(t, action_3d.kind, feature.Action_Kind.Pane_Focused)
	testing.expect_value(t, inter.mode, feature.Interaction_Mode.Interacting_3D)

	// Drag rotates 3D camera
	feature.interaction_on_mouse_move(&inter, &mux, [2]f32{460.0, 210.0}, {})
	testing.expect(t, p3.interactor.is_dragging, "3D interactor should be dragging")

	// Mouse wheel zooms
	feature.interaction_on_mouse_wheel(&inter, &mux, 1.0)
	testing.expect(t, p3.interactor.distance < 4.2, "3D interactor distance should decrease on zoom in")

	feature.interaction_on_mouse_up(&inter, &mux, 1)
	testing.expect_value(t, inter.mode, feature.Interaction_Mode.Idle)
}

@test
test_selection_and_clipboard_bridge :: proc(t: ^testing.T) {
	// 1. Selection normalize & containment
	sel := feature.Mouse_Selection{
		active     = true,
		mode       = .Stream,
		pane_id    = 1,
		start_cell = {row = 2, col = 5},
		end_cell   = {row = 1, col = 2}, // Reversed coords to test sorting
	}

	norm, ok := feature.selection_normalize(sel)
	testing.expect(t, ok, "selection_normalize failed")
	testing.expect_value(t, norm.start_row, 1)
	testing.expect_value(t, norm.start_col, 2)
	testing.expect_value(t, norm.end_row, 2)
	testing.expect_value(t, norm.end_col, 5)

	testing.expect(t, feature.selection_contains_cell(sel, 1, 2), "Cell (1, 2) should be in selection")
	testing.expect(t, feature.selection_contains_cell(sel, 1, 10), "Cell (1, 10) should be in selection")
	testing.expect(t, feature.selection_contains_cell(sel, 2, 4), "Cell (2, 4) should be in selection")
	testing.expect(t, !feature.selection_contains_cell(sel, 0, 0), "Cell (0, 0) should not be in selection")
	testing.expect(t, !feature.selection_contains_cell(sel, 2, 6), "Cell (2, 6) should not be in selection")

	// 2. Clipboard Bridge & Paste
	mock_clip_content: string = "hello world"
	cb: feature.Clipboard_Bridge
	feature.clipboard_init(&cb,
		proc(text: string, user_data: rawptr) -> bool {
			s := (^string)(user_data)
			s^ = text
			return true
		},
		proc(allocator: runtime.Allocator, user_data: rawptr) -> (string, bool) {
			s := (^string)(user_data)
			return s^, true
		},
		proc(user_data: rawptr) -> bool {
			s := (^string)(user_data)
			return len(s^) > 0
		},
		&mock_clip_content,
	)

	text, get_ok := feature.clipboard_get_text(&cb)
	testing.expect(t, get_ok, "clipboard_get_text failed")
	testing.expect_value(t, text, "hello world")

	set_ok := feature.clipboard_set_text(&cb, "updated text")
	testing.expect(t, set_ok, "clipboard_set_text failed")
	testing.expect_value(t, mock_clip_content, "updated text")
}

@test
test_word_find_bounds :: proc(t: ^testing.T) {
	cells: [30]cell.Semantic_Cell
	sample := "foo bar_baz (qux)   end"
	for ch, i in sample {
		cells[i] = cell.Semantic_Cell{char = ch}
	}
	row := terminal_grid.Row{
		cells = cells[:len(sample)],
	}

	// 1. Click on 'o' in "foo"
	s0, e0 := feature.word_find_bounds(&row, 1)
	testing.expect_value(t, s0, 0)
	testing.expect_value(t, e0, 2)

	// 2. Click on 'b' in "bar_baz"
	s1, e1 := feature.word_find_bounds(&row, 5)
	testing.expect_value(t, s1, 4)
	testing.expect_value(t, e1, 10)

	// 3. Click on '('
	s2, e2 := feature.word_find_bounds(&row, 12)
	testing.expect_value(t, s2, 12)
	testing.expect_value(t, e2, 12)

	// 4. Click in whitespace between "qux)" and "end"
	s3, e3 := feature.word_find_bounds(&row, 18)
	testing.expect_value(t, s3, 17)
	testing.expect_value(t, e3, 19)
}

@test
test_double_triple_click_and_select_all :: proc(t: ^testing.T) {
	tm: tabs.Tabs_Manager
	mux: multiplexer.Multiplexer
	inter: feature.Interaction_State

	bar_rect: [4]f32 = {0.0, 0.0, 800.0, 36.0}
	tabs.tabs_manager_init(&tm, bar_rect)
	multiplexer.multiplexer_init(&mux)
	feature.interaction_init(&inter)

	defer {
		tabs.tabs_manager_destroy(&tm)
		multiplexer.multiplexer_destroy(&mux)
	}

	cfg := session.Session_Config{
		shell = "/bin/sh",
		rows  = 24,
		cols  = 80,
	}

	pane_id, err := multiplexer.multiplexer_create_terminal_pane(&mux, cfg)
	testing.expect(t, err == .None, "Create terminal pane failed")
	tabs.tabs_manager_create_tab(&tm, "Shell", pane_id)

	content_rect: [4]f32 = {0.0, 36.0, 800.0, 564.0}
	tabs.tabs_manager_update_layout(&tm, content_rect)
	multiplexer.multiplexer_sync_split_rects(&mux, tm.entries[0].split_tree)

	// Write known text to session grid
	p := multiplexer.multiplexer_get_pane(&mux, pane_id)
	terminal.terminal_feed_string(&p.session.term, "hello_world 12345\r\n")

	// Double-click test: clicks = 2 -> .Word mode
	click_pos: [2]f32 = {20.0, 45.0} // Inside pane, col ~2, row 0
	cell_check := terminal.terminal_get_cell(&p.session.term, 0, 2)
	testing.expect_value(t, cell_check.char, 'l') // 'h', 'e', 'l', 'l', 'o'

	cr, cc := feature.pixel_to_cell(click_pos, p.rect, inter.cell_width, inter.cell_height, 0.0, 0.0)
	testing.expect_value(t, cr, 0)
	testing.expect_value(t, cc, 2)

	phy_0 := terminal_grid.grid_physical_row(&p.session.term.grid, cr)
	wb_s, wb_e := feature.word_find_bounds(&p.session.term.grid.rows[phy_0], cc)
	testing.expect_value(t, wb_s, 0)
	testing.expect_value(t, wb_e, 10)

	act2 := feature.interaction_on_mouse_down(&inter, &tm, &mux, click_pos, 1, {}, clicks = 2)
	testing.expect_value(t, act2.kind, feature.Action_Kind.Pane_Focused)
	testing.expect(t, inter.selection.active, "Selection must be active on double click")
	testing.expect_value(t, inter.selection.mode, feature.Selection_Mode.Word)
	testing.expect_value(t, inter.selection.start_cell.col, 0)
	testing.expect_value(t, inter.selection.end_cell.col, 10) // "hello_world" is cols 0..10

	// Triple-click test: clicks = 3 -> .Line mode
	act3 := feature.interaction_on_mouse_down(&inter, &tm, &mux, click_pos, 1, {}, clicks = 3)
	testing.expect_value(t, act3.kind, feature.Action_Kind.Pane_Focused)
	testing.expect(t, inter.selection.active, "Selection must be active on triple click")
	testing.expect_value(t, inter.selection.mode, feature.Selection_Mode.Line)
	testing.expect_value(t, inter.selection.start_cell.col, 0)
	testing.expect_value(t, inter.selection.end_cell.col, 79) // entire line cols 0..79

	// Cmd+A test -> Text_Selected_All
	act_a := feature.interaction_on_key_press(&inter, &tm, &mux, 'a', {.Cmd})
	testing.expect_value(t, act_a.kind, feature.Action_Kind.Text_Selected_All)
	testing.expect(t, inter.selection.active, "Selection must be active on Cmd+A")
	testing.expect_value(t, inter.selection.start_cell.row, 0)
	testing.expect_value(t, inter.selection.end_cell.row, 23)
}

@test
test_clipboard_osc_52_guard :: proc(t: ^testing.T) {
	guard := feature.Clipboard_Guard{
		allow_remote_write = true,
		max_payload_bytes  = 100,
	}

	// Normal payload under limit
	testing.expect(t, feature.clipboard_guard_check(&guard, "hello world"), "Payload under limit must pass guard")

	// Oversized payload
	oversized := "0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789 extra"
	testing.expect(t, !feature.clipboard_guard_check(&guard, oversized), "Oversized payload must be blocked by guard")

	// Disabled remote write
	guard.allow_remote_write = false
	testing.expect(t, !feature.clipboard_guard_check(&guard, "short text"), "Disabled remote write must block payload")
}

@test
test_selection_canceled_on_user_input :: proc(t: ^testing.T) {
	tm: tabs.Tabs_Manager
	mux: multiplexer.Multiplexer
	inter: feature.Interaction_State

	bar_rect: [4]f32 = {0.0, 0.0, 800.0, 36.0}
	tabs.tabs_manager_init(&tm, bar_rect)
	multiplexer.multiplexer_init(&mux)
	feature.interaction_init(&inter)

	defer {
		tabs.tabs_manager_destroy(&tm)
		multiplexer.multiplexer_destroy(&mux)
	}

	cfg := session.Session_Config{
		shell = "/bin/sh",
		rows  = 24,
		cols  = 80,
	}

	pane_id, err := multiplexer.multiplexer_create_terminal_pane(&mux, cfg)
	testing.expect(t, err == .None, "Create terminal pane failed")
	tabs.tabs_manager_create_tab(&tm, "Shell", pane_id)

	content_rect: [4]f32 = {0.0, 36.0, 800.0, 564.0}
	tabs.tabs_manager_update_layout(&tm, content_rect)
	multiplexer.multiplexer_sync_split_rects(&mux, tm.entries[0].split_tree)

	// User selects text via Cmd+A
	_ = feature.interaction_on_key_press(&inter, &tm, &mux, 'a', {.Cmd})
	testing.expect(t, inter.selection.active, "Selection must be active before user input")

	// User types a command character 'l'
	_ = feature.interaction_on_key_press(&inter, &tm, &mux, 'l', {})
	testing.expect(t, !inter.selection.active, "Selection must be canceled/cleared on user input command")
}




