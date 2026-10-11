package render_tests

import "core:testing"
import render "../"
import instance "../instance"
import termgrid "../../terminal"
import interaction "../../interaction"

OVERLAY_TEST_ROWS :: 24
OVERLAY_TEST_COLS :: 80
OVERLAY_TEST_MAX  :: 64
OVERLAY_TEST_CW   :: 8
OVERLAY_TEST_CH   :: 16

_overlay_test_renderer :: proc(rows, cols: int, max_inst: u32) -> render.Renderer {
	r: render.Renderer
	r.rows = i32(rows)
	r.cols = i32(cols)
	r.cell_width = OVERLAY_TEST_CW
	r.cell_height = OVERLAY_TEST_CH
	r.instances.max_instances = max_inst
	r.instances.instance_data = make([]instance.Instance_Data, int(max_inst))
	return r
}

@(test)
test_block_selection_containment :: proc(t: ^testing.T) {
	term: termgrid.Terminal
	termgrid.terminal_init(&term, 10, 20)
	defer termgrid.terminal_destroy(&term)

	// Rectangular selection from (2, 3) to (5, 8)
	view := termgrid.Terminal_View{
		selection = termgrid.Terminal_Selection{
			active = true,
			block  = true,
			anchor = termgrid.Terminal_Point{row = 2, col = 3},
			focus  = termgrid.Terminal_Point{row = 5, col = 8},
		},
	}

	// 1. Corners inside selection
	testing.expect(t, termgrid.terminal_view_selection_contains(&term, &view, {row = 2, col = 3}), "top-left corner must be inside")
	testing.expect(t, termgrid.terminal_view_selection_contains(&term, &view, {row = 5, col = 8}), "bottom-right corner must be inside")
	testing.expect(t, termgrid.terminal_view_selection_contains(&term, &view, {row = 2, col = 8}), "top-right corner must be inside")
	testing.expect(t, termgrid.terminal_view_selection_contains(&term, &view, {row = 5, col = 3}), "bottom-left corner must be inside")

	// 2. Interior points inside selection
	testing.expect(t, termgrid.terminal_view_selection_contains(&term, &view, {row = 3, col = 5}), "interior point (3, 5) must be inside")
	testing.expect(t, termgrid.terminal_view_selection_contains(&term, &view, {row = 4, col = 4}), "interior point (4, 4) must be inside")

	// 3. Points outside row range
	testing.expect(t, !termgrid.terminal_view_selection_contains(&term, &view, {row = 1, col = 5}), "row above must be outside")
	testing.expect(t, !termgrid.terminal_view_selection_contains(&term, &view, {row = 6, col = 5}), "row below must be outside")

	// 4. Points within row range but outside column range
	// In stream selection, row 3 col 1 would be selected. In block selection, it must be OUTSIDE.
	testing.expect(t, !termgrid.terminal_view_selection_contains(&term, &view, {row = 3, col = 1}), "col to left on interior row must be outside")
	testing.expect(t, !termgrid.terminal_view_selection_contains(&term, &view, {row = 3, col = 9}), "col to right on interior row must be outside")
	testing.expect(t, !termgrid.terminal_view_selection_contains(&term, &view, {row = 4, col = 0}), "col 0 on interior row must be outside")
	testing.expect(t, !termgrid.terminal_view_selection_contains(&term, &view, {row = 4, col = 15}), "col 15 on interior row must be outside")

	// 5. Inverted anchor/focus (bottom-right to top-left)
	view_inv := termgrid.Terminal_View{
		selection = termgrid.Terminal_Selection{
			active = true,
			block  = true,
			anchor = termgrid.Terminal_Point{row = 5, col = 8},
			focus  = termgrid.Terminal_Point{row = 2, col = 3},
		},
	}
	testing.expect(t, termgrid.terminal_view_selection_contains(&term, &view_inv, {row = 3, col = 5}), "inverted block: interior must be inside")
	testing.expect(t, !termgrid.terminal_view_selection_contains(&term, &view_inv, {row = 3, col = 1}), "inverted block: col to left must be outside")

	// 6. Inverted anchor/focus horizontally (top-right to bottom-left)
	view_diag := termgrid.Terminal_View{
		selection = termgrid.Terminal_Selection{
			active = true,
			block  = true,
			anchor = termgrid.Terminal_Point{row = 2, col = 8},
			focus  = termgrid.Terminal_Point{row = 5, col = 3},
		},
	}
	testing.expect(t, termgrid.terminal_view_selection_contains(&term, &view_diag, {row = 3, col = 5}), "diagonal block: interior must be inside")
	testing.expect(t, !termgrid.terminal_view_selection_contains(&term, &view_diag, {row = 3, col = 1}), "diagonal block: col to left must be outside")

	// 7. Comparison with block = false (stream selection)
	view_stream := termgrid.Terminal_View{
		selection = termgrid.Terminal_Selection{
			active = true,
			block  = false,
			anchor = termgrid.Terminal_Point{row = 2, col = 3},
			focus  = termgrid.Terminal_Point{row = 5, col = 8},
		},
	}
	testing.expect(t, termgrid.terminal_view_selection_contains(&term, &view_stream, {row = 3, col = 1}), "stream selection must contain (3, 1)")

	// 8. Inactive selection must contain nothing
	view_inactive := termgrid.Terminal_View{
		selection = termgrid.Terminal_Selection{
			active = false,
			block  = true,
			anchor = termgrid.Terminal_Point{row = 2, col = 3},
			focus  = termgrid.Terminal_Point{row = 5, col = 8},
		},
	}
	testing.expect(t, !termgrid.terminal_view_selection_contains(&term, &view_inactive, {row = 3, col = 5}), "inactive selection must contain nothing")
}

@(test)
test_interaction_overlay_draw_inactive_and_nil_safety :: proc(t: ^testing.T) {
	r := _overlay_test_renderer(OVERLAY_TEST_ROWS, OVERLAY_TEST_COLS, OVERLAY_TEST_MAX)
	defer delete(r.instances.instance_data)

	term: termgrid.Terminal
	termgrid.terminal_init(&term, OVERLAY_TEST_ROWS, OVERLAY_TEST_COLS)
	defer termgrid.terminal_destroy(&term)

	view: termgrid.Terminal_View
	s: interaction.Interaction_State

	// Nil renderer
	testing.expect(t, !render.interaction_overlay_draw(nil, &s, &view, &term), "nil renderer must return false")

	// Nil state
	testing.expect(t, !render.interaction_overlay_draw(&r, nil, &view, &term), "nil state must return false")

	// Inactive search
	s.search_active = false
	s.search_match_count = 5
	testing.expect(t, !render.interaction_overlay_draw(&r, &s, &view, &term), "inactive search must return false")

	// Active search with 0 matches
	s.search_active = true
	s.search_match_count = 0
	testing.expect(t, !render.interaction_overlay_draw(&r, &s, &view, &term), "zero matches must return false")

	// Zero max instances
	empty_r: render.Renderer
	testing.expect(t, !render.interaction_overlay_draw(&empty_r, &s, &view, &term), "empty renderer must return false")
}

@(test)
test_interaction_overlay_draw_stages_visible_matches :: proc(t: ^testing.T) {
	r := _overlay_test_renderer(OVERLAY_TEST_ROWS, OVERLAY_TEST_COLS, OVERLAY_TEST_MAX)
	defer delete(r.instances.instance_data)

	// Put a sentinel background quad at index 0 (dense region) to verify it stays untouched.
	instance.instance_renderer_fill_bg(&r.instances, 0, 0, 0, OVERLAY_TEST_CW, OVERLAY_TEST_CH, 0.1, 0.2, 0.3)
	sentinel := r.instances.instance_data[0]

	term: termgrid.Terminal
	termgrid.terminal_init(&term, OVERLAY_TEST_ROWS, OVERLAY_TEST_COLS)
	defer termgrid.terminal_destroy(&term)

	view: termgrid.Terminal_View

	s: interaction.Interaction_State
	s.search_active = true
	s.search_match_count = 2
	s.search_match_idx = 1 // second match is the active match

	// Match 0: secondary highlight at row 1, cols 2..3 (2 cells)
	s.search_matches[0] = interaction.Search_Match{
		row       = 1,
		col_start = 2,
		col_end   = 3,
	}

	// Match 1: active/primary highlight at row 3, cols 10..12 (3 cells)
	s.search_matches[1] = interaction.Search_Match{
		row       = 3,
		col_start = 10,
		col_end   = 12,
	}

	drew := render.interaction_overlay_draw(&r, &s, &view, &term)
	testing.expect(t, drew, "visible search matches must return true")
	testing.expect(t, r.interaction_staged, "r.interaction_staged must be set to true")
	testing.expect_value(t, r.interaction_quad_count, 5)

	// Staged quads: 5 cells total.
	// start_slot should be inst.max_instances - 1 - 5 = 64 - 6 = 58.
	expected_start := u32(OVERLAY_TEST_MAX - 1 - 5)
	testing.expect_value(t, r.interaction_slot_start, expected_start)

	// Check Match 0 quads (secondary highlight: R=0.8, G=0.6, B=0.2)
	q0 := r.instances.instance_data[expected_start]
	testing.expect_value(t, q0.x, f32(2 * OVERLAY_TEST_CW))
	testing.expect_value(t, q0.y, f32(1 * OVERLAY_TEST_CH))
	testing.expect_value(t, q0.cw, f32(OVERLAY_TEST_CW))
	testing.expect_value(t, q0.ch, f32(OVERLAY_TEST_CH))
	testing.expect_value(t, q0.r, render.INTERACTION_MATCH_SECONDARY_R)
	testing.expect_value(t, q0.g, render.INTERACTION_MATCH_SECONDARY_G)
	testing.expect_value(t, q0.b, render.INTERACTION_MATCH_SECONDARY_B)

	q1 := r.instances.instance_data[expected_start + 1]
	testing.expect_value(t, q1.x, f32(3 * OVERLAY_TEST_CW))
	testing.expect_value(t, q1.y, f32(1 * OVERLAY_TEST_CH))
	testing.expect_value(t, q1.r, render.INTERACTION_MATCH_SECONDARY_R)

	// Check Match 1 quads (active primary highlight: R=1.0, G=0.8, B=0.2)
	q2 := r.instances.instance_data[expected_start + 2]
	testing.expect_value(t, q2.x, f32(10 * OVERLAY_TEST_CW))
	testing.expect_value(t, q2.y, f32(3 * OVERLAY_TEST_CH))
	testing.expect_value(t, q2.r, render.INTERACTION_MATCH_PRIMARY_R)
	testing.expect_value(t, q2.g, render.INTERACTION_MATCH_PRIMARY_G)
	testing.expect_value(t, q2.b, render.INTERACTION_MATCH_PRIMARY_B)

	q3 := r.instances.instance_data[expected_start + 3]
	testing.expect_value(t, q3.x, f32(11 * OVERLAY_TEST_CW))
	testing.expect_value(t, q3.y, f32(3 * OVERLAY_TEST_CH))
	testing.expect_value(t, q3.r, render.INTERACTION_MATCH_PRIMARY_R)

	q4 := r.instances.instance_data[expected_start + 4]
	testing.expect_value(t, q4.x, f32(12 * OVERLAY_TEST_CW))
	testing.expect_value(t, q4.y, f32(3 * OVERLAY_TEST_CH))
	testing.expect_value(t, q4.r, render.INTERACTION_MATCH_PRIMARY_R)

	// Slot 63 (cursor reserved slot) must be untouched (zeroed)
	cursor_slot := r.instances.instance_data[OVERLAY_TEST_MAX - 1]
	testing.expect(t, cursor_slot == instance.Instance_Data{}, "cursor slot must be untouched")

	// Sentinel at slot 0 must be untouched
	testing.expect(t, r.instances.instance_data[0] == sentinel, "dense region slot 0 must be untouched")

	// Guarantees: terminal state and damage tracking must NOT be mutated
	cur := termgrid.terminal_get_cursor(&term)
	testing.expect_value(t, cur.row, 0)
	testing.expect_value(t, cur.col, 0)
}

@(test)
test_interaction_overlay_draw_viewport_filtering :: proc(t: ^testing.T) {
	r := _overlay_test_renderer(OVERLAY_TEST_ROWS, OVERLAY_TEST_COLS, OVERLAY_TEST_MAX)
	defer delete(r.instances.instance_data)

	term: termgrid.Terminal
	termgrid.terminal_init(&term, OVERLAY_TEST_ROWS, OVERLAY_TEST_COLS)
	defer termgrid.terminal_destroy(&term)

	view: termgrid.Terminal_View
	view.scrollback_offset = 0

	s: interaction.Interaction_State
	s.search_active = true
	s.search_match_count = 1
	// Match is placed out of visible viewport (row 100 > 24)
	s.search_matches[0] = interaction.Search_Match{
		row       = 100,
		col_start = 5,
		col_end   = 8,
	}

	drew := render.interaction_overlay_draw(&r, &s, &view, &term)
	testing.expect(t, !drew, "match outside visible viewport must not stage quads")
	testing.expect(t, !r.interaction_staged, "r.interaction_staged must be false when no matches visible")
	testing.expect_value(t, r.interaction_quad_count, 0)
}
