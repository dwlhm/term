package interaction_test

import "core:testing"
import inter "../"
import input "../../platform/input"
import tg "../../terminal"

@(test)
test_fsm_mode_transitions_and_reset :: proc(t: ^testing.T) {
	s: inter.Interaction_State
	inter.interaction_init(&s)

	testing.expect(t, s.mode == .Passthrough, "initial mode must be Passthrough")
	testing.expect(t, s.viewport_flow == .Live, "initial viewport flow must be Live")
	testing.expect(t, !s.selection_active, "initial selection must be inactive")

	// Enter Visual
	origin := tg.Terminal_Point{row = 2, col = 5}
	inter.interaction_enter_visual(&s, .Char, origin)
	testing.expect(t, s.mode == .Visual, "mode must be Visual")
	testing.expect(t, s.visual_kind == .Char, "visual kind must be Char")
	testing.expect(t, s.viewport_flow == .Paused, "viewport flow must be Paused in Visual")
	testing.expect(t, !s.selection_active, "selection must be inactive by default in Visual")
	testing.expect(t, s.selection_anchor == origin, "selection anchor must match origin")
	testing.expect(t, s.visual_cursor == origin, "visual cursor must match origin")

	inter.interaction_enter_visual(&s, .Char, origin, true)
	testing.expect(t, s.selection_active, "selection must be active when requested")

	// Enter Search
	inter.interaction_enter_search(&s)
	testing.expect(t, s.mode == .Search, "mode must be Search")
	testing.expect(t, s.viewport_flow == .Paused, "viewport flow must be Paused in Search")
	testing.expect(t, s.search_active, "search active must be true")

	// Exit to Passthrough
	snap := inter.interaction_exit_to_passthrough(&s)
	testing.expect(t, snap, "snap_to_live must be true when exiting paused state")
	testing.expect(t, s.mode == .Passthrough, "mode must return to Passthrough")
	testing.expect(t, s.viewport_flow == .Live, "viewport flow must return to Live")
	testing.expect(t, !s.selection_active, "selection must be inactive after exit")
	testing.expect(t, !s.search_active, "search must be inactive after exit")
}

@(test)
test_fsm_scrollback_push_compensation :: proc(t: ^testing.T) {
	s: inter.Interaction_State
	inter.interaction_init(&s)

	// In Live mode, push should have no effect
	inter.interaction_on_scrollback_push(&s, 10)
	testing.expect(t, s.paused_offset == 0, "scrollback push must not affect Live mode")
	testing.expect(t, s.paused_lines_accumulated == 0, "no lines accumulated in Live mode")

	// Pause viewport
	inter.interaction_pause_viewport(&s, 5)
	inter.interaction_enter_visual(&s, .Char, tg.Terminal_Point{row = 10, col = 3})
	s.visual_cursor = tg.Terminal_Point{row = 15, col = 8}

	s.search_active = true
	s.search_matches[0] = inter.Search_Match{row = 12, col_start = 1, col_end = 4}
	s.search_match_count = 1

	// Push 20 lines into scrollback while paused
	inter.interaction_on_scrollback_push(&s, 20)

	testing.expect(t, s.paused_offset == 25, "paused offset must increase by lines added")
	testing.expect(t, s.paused_lines_accumulated == 20, "accumulated lines must track total added")
	testing.expect(t, s.selection_anchor.row == 10, "append must preserve document anchor")
	testing.expect(t, s.visual_cursor.row == 15, "append must preserve document cursor")
	testing.expect(t, s.search_matches[0].row == 12, "append must preserve document match")

	// Resume viewport
	inter.interaction_resume_viewport(&s)
	testing.expect(t, s.viewport_flow == .Live, "viewport flow must be Live after resume")
	testing.expect(t, s.paused_offset == 0, "paused offset must reset on resume")
	testing.expect(t, s.paused_lines_accumulated == 0, "accumulated lines must reset on resume")
}

@(test)
test_query_word_bounds_alphanumeric_whitespace_symbols :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 2, 30)
	defer tg.terminal_destroy(&term)

	// Fill row 0: "hello_123   ===path"
	text := "hello_123   ===path"
	for r in text {
		tg.terminal_put_char(&term, r)
	}

	// 1. Alphanumeric / word bounds on "hello_123" (cols 0..8)
	start, end := inter.interaction_select_word_bounds(&term, tg.Terminal_Point{row = 0, col = 3})
	testing.expect(t, start.col == 0, "word start col must be 0")
	testing.expect(t, end.col == 8, "word end col must be 8")

	// 2. Whitespace bounds on "   " (cols 9..11)
	start, end = inter.interaction_select_word_bounds(&term, tg.Terminal_Point{row = 0, col = 10})
	testing.expect(t, start.col == 9, "whitespace start col must be 9")
	testing.expect(t, end.col == 11, "whitespace end col must be 11")

	// 3. Symbol bounds on "===" (cols 12..14)
	start, end = inter.interaction_select_word_bounds(&term, tg.Terminal_Point{row = 0, col = 13})
	testing.expect(t, start.col == 12, "symbol start col must be 12")
	testing.expect(t, end.col == 14, "symbol end col must be 14")

	// 4. Line bounds
	start, end = inter.interaction_select_line_bounds(&term, tg.Terminal_Point{row = 0, col = 5})
	testing.expect(t, start.col == 0, "line start col must be 0")
	testing.expect(t, end.col == 29, "line end col must be 29")
}

@(test)
test_query_search_scan_and_extract :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 2, 30)
	defer tg.terminal_destroy(&term)

	// Row 0: "alpha beta ALPHA"
	text := "alpha beta ALPHA"
	for r in text {
		tg.terminal_put_char(&term, r)
	}

	matches: [inter.MAX_SEARCH_MATCHES]inter.Search_Match
	count := inter.interaction_search_scan(&term, "alpha", matches[:])
	testing.expect(t, count == 2, "case-insensitive search scan must find 2 matches")
	testing.expect(t, matches[0].row == 0 && matches[0].col_start == 0 && matches[0].col_end == 4, "first match must be 0..4")
	testing.expect(t, matches[1].row == 0 && matches[1].col_start == 11 && matches[1].col_end == 15, "second match must be 11..15")

	// Selection extraction: Char mode
	s: inter.Interaction_State
	inter.interaction_init(&s)
	inter.interaction_enter_visual(&s, .Char, tg.Terminal_Point{row = 0, col = 6}, true)
	s.visual_cursor = tg.Terminal_Point{row = 0, col = 9}
	extracted := inter.interaction_extract_selection_text(&term, &s)
	defer delete(extracted)
	testing.expect(t, extracted == "beta", "extracted selection text must match 'beta'")

	// Selection extraction: Line mode
	s.visual_kind = .Line
	extracted_line := inter.interaction_extract_selection_text(&term, &s)
	defer delete(extracted_line)
	testing.expect(t, extracted_line == "alpha beta ALPHA", "extracted line must match entire row trimmed")

	// Selection extraction: Block mode
	s.visual_kind = .Block
	s.selection_anchor = tg.Terminal_Point{row = 0, col = 0}
	s.visual_cursor = tg.Terminal_Point{row = 0, col = 4}
	extracted_block := inter.interaction_extract_selection_text(&term, &s)
	defer delete(extracted_block)
	testing.expect(t, extracted_block == "alpha", "extracted block must match 'alpha'")
}

@(test)
test_zero_conflict_key_dispatcher :: proc(t: ^testing.T) {
	s: inter.Interaction_State
	inter.interaction_init(&s)

	// 1. In Passthrough: normal keys, Esc, Ctrl must NOT be consumed
	ev_esc := input.Input_Event{kind = .Escape}
	consumed, act := inter.interaction_dispatch_key(&s, ev_esc, false)
	testing.expect(t, !consumed, "Esc must NOT be consumed in Passthrough mode")
	testing.expect(t, act == .None, "Esc action must be None in Passthrough mode")

	ev_ctrl := input.Input_Event{kind = .Printable, rune = 'c', ctrl = true}
	consumed, act = inter.interaction_dispatch_key(&s, ev_ctrl, false)
	testing.expect(t, !consumed, "Ctrl+C must NOT be consumed in Passthrough mode")
	testing.expect(t, act == .None, "Ctrl+C action must be None in Passthrough mode")

	ev_char := input.Input_Event{kind = .Printable, rune = 'a'}
	consumed, act = inter.interaction_dispatch_key(&s, ev_char, false)
	testing.expect(t, !consumed, "Normal char must NOT be consumed in Passthrough mode")

	// 2. In Passthrough: Cmd+F enters Search mode
	ev_cmd_f := input.Input_Event{kind = .Printable, rune = 'f', gui = true}
	consumed, act = inter.interaction_dispatch_key(&s, ev_cmd_f, false)
	testing.expect(t, consumed, "Cmd+F must be consumed in Passthrough mode")
	testing.expect(t, s.mode == .Search, "Cmd+F must enter Search mode")

	// In Search mode: Esc exits to Passthrough and resumes live
	consumed, act = inter.interaction_dispatch_key(&s, ev_esc, false)
	testing.expect(t, consumed, "Esc must be consumed in Search mode")
	testing.expect(t, act == .Resume_Live, "Esc in Search mode must trigger Resume_Live")
	testing.expect(t, s.mode == .Passthrough, "Esc must return to Passthrough")

	// 3. In Passthrough: Cmd+Ctrl+Y enters Visual mode
	ev_cmd_v := input.Input_Event{kind = .Printable, rune = 'y', gui = true, ctrl = true}
	consumed, act = inter.interaction_dispatch_key(&s, ev_cmd_v, false)
	testing.expect(t, consumed, "Cmd+Ctrl+Y must be consumed in Passthrough mode")
	testing.expect(t, s.mode == .Visual, "Cmd+Ctrl+Y must enter Visual mode")

	// In Visual mode: Esc exits to Passthrough
	consumed, act = inter.interaction_dispatch_key(&s, ev_esc, false)
	testing.expect(t, consumed, "Esc must be consumed in Visual mode")
	testing.expect(t, act == .Resume_Live, "Esc in Visual mode must trigger Resume_Live")
	testing.expect(t, s.mode == .Passthrough, "Esc must return to Passthrough")

	// Enter visual again and test modal keys
	inter.interaction_enter_visual(&s, .Char, tg.Terminal_Point{row = 5, col = 5})

	// 'V' switches to Line mode
	ev_shift_v := input.Input_Event{kind = .Printable, rune = 'V'}
	consumed, _ = inter.interaction_dispatch_key(&s, ev_shift_v, false)
	testing.expect(t, consumed, "V must be consumed in Visual mode")
	testing.expect(t, s.visual_kind == .Line, "V must switch to Line visual mode")

	// Ctrl+V switches to Block mode
	ev_ctrl_v := input.Input_Event{kind = .Printable, rune = 'v', ctrl = true}
	consumed, _ = inter.interaction_dispatch_key(&s, ev_ctrl_v, false)
	testing.expect(t, consumed, "Ctrl+V must be consumed in Visual mode")
	testing.expect(t, s.visual_kind == .Block, "Ctrl+V must switch to Block visual mode")

	// Navigation: 'h', 'j', 'k', 'l'
	cur_col := s.visual_cursor.col
	ev_l := input.Input_Event{kind = .Printable, rune = 'l'}
	consumed, _ = inter.interaction_dispatch_key(&s, ev_l, false)
	testing.expect(t, consumed, "'l' must be consumed")
	testing.expect(t, s.visual_cursor.col == cur_col + 1, "'l' must move cursor right")

	// Yank / Copy: 'y' exits Visual and triggers Copy action
	ev_y := input.Input_Event{kind = .Printable, rune = 'y'}
	consumed, act = inter.interaction_dispatch_key(&s, ev_y, false)
	testing.expect(t, consumed, "'y' must be consumed in Visual mode")
	testing.expect(t, act == .Copy, "'y' must trigger Copy action")
	testing.expect(t, s.mode == .Passthrough, "'y' must exit to Passthrough mode")
}

@(test)
test_key_releases_do_not_trigger_interaction_actions :: proc(t: ^testing.T) {
	s: inter.Interaction_State
	inter.interaction_init(&s)

	paste_release := input.Input_Event{event_type = .Key, kind = .Printable, rune = 'v', gui = true, is_release = true}
	consumed, action := inter.interaction_dispatch_key(&s, paste_release, false)
	testing.expect(t, !consumed && action == .None && s.mode == .Passthrough, "GUI paste release must reach passthrough without repeating paste")

	inter.interaction_enter_visual(&s, .Char, tg.Terminal_Point{row = 2, col = 3})
	visual_before := s
	nav_release := input.Input_Event{event_type = .Key, kind = .Arrow_Right, is_release = true}
	consumed, action = inter.interaction_dispatch_key(&s, nav_release, false)
	testing.expect(t, consumed && action == .None, "visual release must be consumed without action")
	testing.expect(t, s.mode == visual_before.mode && s.visual_cursor == visual_before.visual_cursor && s.visual_kind == visual_before.visual_kind, "visual release must not move or change mode")

	inter.interaction_enter_search(&s)
	search_before := s
	text_release := input.Input_Event{event_type = .Key, kind = .Printable, rune = 'x', is_release = true}
	consumed, action = inter.interaction_dispatch_key(&s, text_release, false)
	testing.expect(t, consumed && action == .None, "search release must be consumed without action")
	testing.expect(t, s.mode == search_before.mode && s.search_len == search_before.search_len && s.search_active == search_before.search_active, "search release must not edit query")
}

@(test)
test_pointer_dispatcher_and_alt_screen :: proc(t: ^testing.T) {
	s: inter.Interaction_State
	inter.interaction_init(&s)

	cell_w := 10
	cell_h := 20

	// 1. In Alt Screen without Shift: mouse is NOT consumed (TUI owns mouse)
	ev_alt_mouse := input.Input_Pointer_Event{
		kind = .Button_Down,
		button = 1,
		clicks = 1,
		x = 50,
		y = 40,
		shift = false,
	}
	consumed, _ := inter.interaction_dispatch_pointer(&s, ev_alt_mouse, true, 24, 80, cell_w, cell_h)
	testing.expect(t, !consumed, "alt_screen mouse without shift must not be consumed")

	// 2. In Alt Screen WITH Shift: mouse is consumed (forced local selection)
	ev_alt_shift := input.Input_Pointer_Event{
		kind = .Button_Down,
		button = 1,
		clicks = 2,
		x = 50,
		y = 40,
		shift = true,
	}
	consumed, _ = inter.interaction_dispatch_pointer(&s, ev_alt_shift, true, 24, 80, cell_w, cell_h)
	testing.expect(t, consumed, "alt_screen mouse with shift must be consumed")
	testing.expect(t, s.mode == .Visual, "double-click with shift must enter Visual mode")
	testing.expect(t, s.visual_kind == .Char, "double-click must select Char mode")

	// Reset to Passthrough
	_ = inter.interaction_exit_to_passthrough(&s)

	// 3. Normal screen: Single click sets anchor, does not enter visual until dragged
	ev_click := input.Input_Pointer_Event{
		kind = .Button_Down,
		button = 1,
		clicks = 1,
		x = 30,
		y = 40,
	}
	consumed, _ = inter.interaction_dispatch_pointer(&s, ev_click, false, 24, 80, cell_w, cell_h)
	testing.expect(t, !consumed, "single click button down must not immediately consume in Passthrough")
	testing.expect(t, s.selection_anchor.row == 2 && s.selection_anchor.col == 3, "anchor must be set to clicked cell (row 2, col 3)")

	// Dragging with primary_down enters Visual(Char)
	ev_drag := input.Input_Pointer_Event{
		kind = .Motion,
		primary_down = true,
		x = 70,
		y = 40,
	}
	consumed, _ = inter.interaction_dispatch_pointer(&s, ev_drag, false, 24, 80, cell_w, cell_h)
	testing.expect(t, consumed, "mouse drag must be consumed")
	testing.expect(t, s.mode == .Visual, "mouse drag must transition to Visual mode")
	testing.expect(t, s.visual_cursor.col == 7, "drag motion must update visual cursor")

	// Reset
	_ = inter.interaction_exit_to_passthrough(&s)

	// 4. Triple-click selects entire line (Visual Line)
	ev_triple := input.Input_Pointer_Event{
		kind = .Button_Down,
		button = 1,
		clicks = 3,
		x = 50,
		y = 60,
	}
	consumed, _ = inter.interaction_dispatch_pointer(&s, ev_triple, false, 24, 80, cell_w, cell_h)
	testing.expect(t, consumed, "triple click must be consumed")
	testing.expect(t, s.mode == .Visual, "triple click must enter Visual mode")
	testing.expect(t, s.visual_kind == .Line, "triple click must select Visual Line")
	testing.expect(t, s.selection_anchor.row == 3, "triple click row must be 3")
}

@(test)
test_visual_mode_unmapped_keys_exit_to_passthrough :: proc(t: ^testing.T) {
	s: inter.Interaction_State

	test_keys := []rune{'a', 'x', 'i', ' '}
	for r in test_keys {
		inter.interaction_init(&s)
		inter.interaction_enter_visual(&s, .Char, tg.Terminal_Point{row = 3, col = 5}, true)
		testing.expect(t, s.mode == .Visual, "must be in Visual mode")
		testing.expect(t, s.selection_active, "selection must be active in Visual mode")

		ev := input.Input_Event{kind = .Printable, rune = r}
		consumed, act := inter.interaction_dispatch_key(&s, ev, false)
		testing.expect(t, consumed, "unmapped key must be consumed in Visual mode")
		testing.expect(t, act == .Resume_Live, "unmapped key must trigger Resume_Live")
		testing.expect(t, s.mode == .Passthrough, "mode must transition to Passthrough")
		testing.expect(t, !s.selection_active, "selection must be deactivated")
	}
}

@(test)
test_history_eviction_rebases_and_invalidates_document_positions :: proc(t: ^testing.T) {
	s: inter.Interaction_State
	inter.interaction_init(&s)
	inter.interaction_enter_visual(&s, .Char, tg.Terminal_Point{row = 4}, true)
	s.visual_cursor.row = 7
	s.search_active = true
	s.search_matches[0].row = 1
	s.search_matches[1].row = 5
	s.search_matches[2].row = 8
	s.search_match_count = 3
	s.search_match_idx = 2
	inter.interaction_on_scrollback_push(&s, 2, 2)
	testing.expect_value(t, s.selection_anchor.row, 2)
	testing.expect_value(t, s.visual_cursor.row, 5)
	testing.expect_value(t, s.search_match_count, 2)
	testing.expect_value(t, s.search_match_idx, 1)
	testing.expect_value(t, s.search_matches[1].row, 6)
	inter.interaction_on_scrollback_push(&s, 3, 3)
	testing.expect(t, !s.selection_active, "evicted endpoint invalidates selection")
	inter.interaction_on_scrollback_push(&s, 12, 12)
	testing.expect_value(t, s.search_match_count, 0)
	testing.expect_value(t, s.search_match_idx, 0)
}

@(test)
test_visual_mode_exit_keys :: proc(t: ^testing.T) {
	s: inter.Interaction_State

	// Test Ctrl+C exits Visual mode without copy
	inter.interaction_init(&s)
	inter.interaction_enter_visual(&s, .Char, tg.Terminal_Point{row = 2, col = 3})
	ev_ctrl_c := input.Input_Event{kind = .Printable, rune = 'c', ctrl = true}
	consumed, act := inter.interaction_dispatch_key(&s, ev_ctrl_c, false)
	testing.expect(t, consumed, "Ctrl+C must be consumed in Visual mode")
	testing.expect(t, act == .Resume_Live, "Ctrl+C must trigger Resume_Live")
	testing.expect(t, s.mode == .Passthrough, "Ctrl+C must transition to Passthrough")

	// Test 'i' exits Visual mode without copy
	inter.interaction_init(&s)
	inter.interaction_enter_visual(&s, .Char, tg.Terminal_Point{row = 2, col = 3})
	ev_i := input.Input_Event{kind = .Printable, rune = 'i'}
	consumed, act = inter.interaction_dispatch_key(&s, ev_i, false)
	testing.expect(t, consumed, "'i' must be consumed in Visual mode")
	testing.expect(t, act == .Resume_Live, "'i' must trigger Resume_Live")
	testing.expect(t, s.mode == .Passthrough, "'i' must transition to Passthrough")

	// Test 'q' exits Visual mode without copy
	inter.interaction_init(&s)
	inter.interaction_enter_visual(&s, .Char, tg.Terminal_Point{row = 2, col = 3})
	ev_q := input.Input_Event{kind = .Printable, rune = 'q'}
	consumed, act = inter.interaction_dispatch_key(&s, ev_q, false)
	testing.expect(t, consumed, "'q' must be consumed in Visual mode")
	testing.expect(t, act == .Resume_Live, "'q' must trigger Resume_Live")
	testing.expect(t, s.mode == .Passthrough, "'q' must transition to Passthrough")

	// Test Cmd+Ctrl+Y toggles out of Visual mode
	inter.interaction_init(&s)
	inter.interaction_enter_visual(&s, .Char, tg.Terminal_Point{row = 2, col = 3})
	ev_toggle := input.Input_Event{kind = .Printable, rune = 'y', gui = true, ctrl = true}
	consumed, act = inter.interaction_dispatch_key(&s, ev_toggle, false)
	testing.expect(t, consumed, "Cmd+Ctrl+Y must be consumed in Visual mode")
	testing.expect(t, act == .Resume_Live, "Cmd+Ctrl+Y must toggle to Resume_Live")
	testing.expect(t, s.mode == .Passthrough, "Cmd+Ctrl+Y must transition to Passthrough")
}

@(test)
test_visual_mode_yank_and_yy_line :: proc(t: ^testing.T) {
	s: inter.Interaction_State
	inter.interaction_init(&s)
	inter.interaction_enter_visual(&s, .Char, tg.Terminal_Point{row = 5, col = 10})

	// First 'y' on single-cell cursor sets pending_yank
	ev_y := input.Input_Event{kind = .Printable, rune = 'y'}
	consumed, act := inter.interaction_dispatch_key(&s, ev_y, false)
	testing.expect(t, consumed, "first 'y' on point must be consumed")
	testing.expect(t, act == .None, "first 'y' must wait for second 'y'")
	testing.expect(t, s.pending_yank, "pending_yank must be true")
	testing.expect(t, s.mode == .Visual, "must remain in Visual mode")

	// Second 'y' triggers line copy (yy)
	consumed, act = inter.interaction_dispatch_key(&s, ev_y, false)
	testing.expect(t, consumed, "second 'y' must be consumed")
	testing.expect(t, act == .Copy, "second 'y' must trigger Copy action")
	testing.expect(t, s.visual_kind == .Line, "visual_kind must be Line for yy")
	testing.expect(t, s.mode == .Passthrough, "yy must exit to Passthrough mode")
	testing.expect(t, !s.pending_yank, "pending_yank must be reset")
}

@(test)
test_select_all_shortcuts_and_query :: proc(t: ^testing.T) {
	s: inter.Interaction_State
	inter.interaction_init(&s)

	// Cmd+A in Passthrough mode
	ev_cmd_a := input.Input_Event{kind = .Printable, rune = 'a', gui = true}
	consumed, act := inter.interaction_dispatch_key(&s, ev_cmd_a, false)
	testing.expect(t, consumed, "Cmd+A must be consumed in Passthrough mode")
	testing.expect(t, act == .Select_All, "Cmd+A must trigger Select_All action")

	// Cmd+A in Visual mode
	inter.interaction_enter_visual(&s, .Char, tg.Terminal_Point{row = 2, col = 3})
	consumed, act = inter.interaction_dispatch_key(&s, ev_cmd_a, false)
	testing.expect(t, consumed, "Cmd+A must be consumed in Visual mode")
	testing.expect(t, act == .Select_All, "Cmd+A must trigger Select_All action in Visual mode")

	// Verify interaction_select_all bounds
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	inter.interaction_select_all(&term, &s)
	testing.expect(t, s.selection_active, "selection must be active after select_all")
	testing.expect(t, s.selection_anchor.row == 0 && s.selection_anchor.col == 0, "anchor must be top-left (0,0)")
	testing.expect(t, s.visual_cursor.row == 23 && s.visual_cursor.col == 79, "cursor must be bottom-right (23,79)")
}

@(test)
test_modeless_mouse_selection_and_typing_dismiss :: proc(t: ^testing.T) {
	s: inter.Interaction_State
	inter.interaction_init(&s)

	// In Passthrough mode, typing a normal key when selection is active clears selection
	s.selection_active = true
	ev_type := input.Input_Event{kind = .Printable, rune = 'x'}
	consumed, act := inter.interaction_dispatch_key(&s, ev_type, false)
	testing.expect(t, !consumed, "typing normal key in Passthrough must not be consumed (flows to PTY)")
	testing.expect(t, act == .None, "no action on typing")
	testing.expect(t, !s.selection_active, "typing in Passthrough must dismiss active selection")

	// Esc in Passthrough when selection is active clears selection
	s.selection_active = true
	ev_esc := input.Input_Event{kind = .Escape}
	consumed, _ = inter.interaction_dispatch_key(&s, ev_esc, false)
	testing.expect(t, consumed, "Esc in Passthrough must be consumed when selection is active")
	testing.expect(t, !s.selection_active, "Esc must dismiss active selection")
}

@(test)
test_decoupled_visual_navigation_and_mouse_continuation :: proc(t: ^testing.T) {
	s: inter.Interaction_State
	inter.interaction_init(&s)
	s.visual_cursor = tg.Terminal_Point{row = 5, col = 10}

	// a. Entering visual mode via Cmd+Ctrl+Y starts with selection_active == false
	ev_toggle := input.Input_Event{kind = .Printable, rune = 'y', gui = true, ctrl = true}
	consumed, act := inter.interaction_dispatch_key(&s, ev_toggle, false)
	testing.expect(t, consumed, "Cmd+Ctrl+Y consumed")
	testing.expect_value(t, s.mode, inter.Interaction_Mode.Visual)
	testing.expect(t, !s.selection_active, "selection must start inactive in Visual mode")
	testing.expect_value(t, s.visual_cursor, tg.Terminal_Point{row = 5, col = 10})

	// b. Free navigation with h/j/k/l and arrow keys without selection
	ev_h := input.Input_Event{kind = .Printable, rune = 'h'}
	ev_j := input.Input_Event{kind = .Printable, rune = 'j'}
	ev_k := input.Input_Event{kind = .Printable, rune = 'k'}
	ev_l := input.Input_Event{kind = .Printable, rune = 'l'}
	ev_arrow_right := input.Input_Event{kind = .Arrow_Right}

	_, _ = inter.interaction_dispatch_key(&s, ev_l, false)
	testing.expect_value(t, s.visual_cursor.col, 11)
	testing.expect(t, !s.selection_active, "free navigation must not activate selection")

	_, _ = inter.interaction_dispatch_key(&s, ev_arrow_right, false)
	testing.expect_value(t, s.visual_cursor.col, 12)
	testing.expect(t, !s.selection_active, "arrow right must not activate selection")

	_, _ = inter.interaction_dispatch_key(&s, ev_j, false)
	testing.expect_value(t, s.visual_cursor.row, 6)
	testing.expect(t, !s.selection_active, "j must not activate selection")

	_, _ = inter.interaction_dispatch_key(&s, ev_k, false)
	testing.expect_value(t, s.visual_cursor.row, 5)

	_, _ = inter.interaction_dispatch_key(&s, ev_h, false)
	testing.expect_value(t, s.visual_cursor.col, 11)

	// c. Starting selection with 'v' and expanding with 'l' or arrow keys
	ev_v := input.Input_Event{kind = .Printable, rune = 'v'}
	consumed, act = inter.interaction_dispatch_key(&s, ev_v, false)
	testing.expect(t, consumed, "'v' consumed")
	testing.expect(t, s.selection_active, "'v' must activate selection")
	testing.expect_value(t, s.selection_anchor, tg.Terminal_Point{row = 5, col = 11})
	testing.expect_value(t, s.visual_kind, inter.Visual_Kind.Char)

	_, _ = inter.interaction_dispatch_key(&s, ev_l, false)
	testing.expect_value(t, s.visual_cursor.col, 12)
	testing.expect(t, s.selection_active, "selection remains active while expanding")

	// f. Esc canceling selection first, then exiting visual mode on second Esc
	ev_esc := input.Input_Event{kind = .Escape}
	consumed, act = inter.interaction_dispatch_key(&s, ev_esc, false)
	testing.expect(t, consumed, "first Esc consumed")
	testing.expect(t, act == .None, "first Esc produces no exit action")
	testing.expect(t, !s.selection_active, "first Esc must deactivate selection")
	testing.expect_value(t, s.mode, inter.Interaction_Mode.Visual)

	consumed, act = inter.interaction_dispatch_key(&s, ev_esc, false)
	testing.expect(t, consumed, "second Esc consumed")
	testing.expect_value(t, act, inter.Interaction_Action.Resume_Live)
	testing.expect_value(t, s.mode, inter.Interaction_Mode.Passthrough)

	// d. Mouse drag in passthrough activating visual mode with selection_active == true directly
	cell_w := 10
	cell_h := 20
	ev_click := input.Input_Pointer_Event{
		kind = .Button_Down,
		button = 1,
		clicks = 1,
		x = 30, // col 3
		y = 40, // row 2
	}
	_, _ = inter.interaction_dispatch_pointer(&s, ev_click, false, 24, 80, cell_w, cell_h)
	testing.expect_value(t, s.mode, inter.Interaction_Mode.Passthrough)
	testing.expect_value(t, s.selection_anchor, tg.Terminal_Point{row = 2, col = 3})

	ev_drag := input.Input_Pointer_Event{
		kind = .Motion,
		primary_down = true,
		x = 80, // col 8
		y = 40, // row 2
	}
	consumed, _ = inter.interaction_dispatch_pointer(&s, ev_drag, false, 24, 80, cell_w, cell_h)
	testing.expect(t, consumed, "drag motion consumed")
	testing.expect_value(t, s.mode, inter.Interaction_Mode.Visual)
	testing.expect(t, s.selection_active, "drag must activate selection directly")
	testing.expect_value(t, s.visual_cursor, tg.Terminal_Point{row = 2, col = 8})

	// e. Releasing mouse button keeping visual mode and selection active, then continuing to expand/contract with keyboard
	ev_up := input.Input_Pointer_Event{
		kind = .Button_Up,
		button = 1,
		x = 80,
		y = 40,
	}
	consumed, act = inter.interaction_dispatch_pointer(&s, ev_up, false, 24, 80, cell_w, cell_h)
	testing.expect(t, consumed, "button up consumed")
	testing.expect_value(t, act, inter.Interaction_Action.None)
	testing.expect_value(t, s.mode, inter.Interaction_Mode.Visual)
	testing.expect(t, s.selection_active, "selection must remain active after mouse release")

	// Keyboard continuation: expand further with arrow key
	consumed, _ = inter.interaction_dispatch_key(&s, ev_arrow_right, false)
	testing.expect(t, consumed, "arrow right consumed after mouse release")
	testing.expect_value(t, s.visual_cursor.col, 9)
	testing.expect(t, s.selection_active, "selection continues expanding seamlessly with keyboard")

	// Keyboard continuation: expand with 'l'
	consumed, _ = inter.interaction_dispatch_key(&s, ev_l, false)
	testing.expect_value(t, s.visual_cursor.col, 10)
	testing.expect(t, s.selection_active, "selection continues expanding seamlessly with 'l'")

	// Keyboard continuation: contract with 'h'
	consumed, _ = inter.interaction_dispatch_key(&s, ev_h, false)
	testing.expect_value(t, s.visual_cursor.col, 9)
	testing.expect(t, s.selection_active, "selection contracts with 'h'")

	// Copy selection with 'y'
	ev_y := input.Input_Event{kind = .Printable, rune = 'y'}
	consumed, act = inter.interaction_dispatch_key(&s, ev_y, false)
	testing.expect(t, consumed, "'y' consumed")
	testing.expect_value(t, act, inter.Interaction_Action.Copy)
	testing.expect_value(t, s.mode, inter.Interaction_Mode.Passthrough)
}
