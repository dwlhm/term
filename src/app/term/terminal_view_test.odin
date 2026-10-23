package term

// Behavioral tests for pane_grid_pad, the cell-grid centering geometry helper.

import "core:testing"

@test
test_pane_grid_pad_exact_fit :: proc(t: ^testing.T) {
	// 10 cols x 40px + 2*4px = 408 wide; 5 rows x 20px + 2*4px = 108 tall.
	rect := [4]f32{0, 0, 408, 108}
	px, py := pane_grid_pad(rect, 5, 10, 40, 20, 4, 4)
	testing.expect_value(t, px, f32(4))
	testing.expect_value(t, py, f32(4))
}

@test
test_pane_grid_pad_centers_leftover :: proc(t: ^testing.T) {
	// content_h = 100, 4 rows x 20px = 80 -> leftover 20 split into 10 top/bottom.
	rect := [4]f32{0, 0, 408, 108}
	px, py := pane_grid_pad(rect, 4, 10, 40, 20, 4, 4)
	testing.expect_value(t, px, f32(4))
	testing.expect_value(t, py, f32(14))
}

@test
test_pane_grid_pad_clamps_to_term_size :: proc(t: ^testing.T) {
	// Term is 3 rows while the pane fits 5; grid = 3 rows -> leftover centered.
	rect := [4]f32{0, 0, 408, 108}
	px, py := pane_grid_pad(rect, 3, 10, 40, 20, 4, 4)
	testing.expect_value(t, px, f32(4))
	testing.expect_value(t, py, f32(24))
}

@test
test_pane_grid_pad_zero_cell_returns_base :: proc(t: ^testing.T) {
	px, py := pane_grid_pad([4]f32{0, 0, 800, 400}, 24, 80, 0, 0, 4, 4)
	testing.expect_value(t, px, f32(4))
	testing.expect_value(t, py, f32(4))
}
