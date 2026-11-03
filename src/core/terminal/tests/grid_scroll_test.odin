package terminal_tests

import "core:testing"
import cell "../cell"
import damage "../damage"
import grid "../grid"

// Rows 0..5 hold 'A'..'F' in every column; row 2 is wrapped, row 3 is a prompt.
@(private = "file")
_lettered_grid :: proc(g: ^grid.Grid, d: ^damage.Damage_Tracker) {
	grid.grid_init(g, 6, 4)
	damage.damage_init(d, 6, 4)
	for r in 0 ..< 6 {
		for c in 0 ..< 4 {
			_ = grid.grid_set_cell(g, nil, r, c, cell.cell_make(rune('A' + r), 1, 0, {}, {.Has_Direct_Color}), {fg = {9, 9, 9}, has_fg = true})
		}
	}
	grid.grid_get_row(g, 2).wrap = true
	grid.grid_get_row(g, 3).is_prompt = true
	_ = damage.damage_consume(d)
}

@(private = "file")
_row_letters :: proc(g: ^grid.Grid) -> (out: [6]rune) {
	for r in 0 ..< 6 do out[r] = grid.grid_get_cell(g, r, 3).char
	return
}

@test
test_region_scroll_up_rotates_rows :: proc(t: ^testing.T) {
	g: grid.Grid
	d: damage.Damage_Tracker
	_lettered_grid(&g, &d)
	defer grid.grid_destroy(&g)
	defer damage.damage_destroy(&d)

	testing.expect_value(t, grid.grid_scroll_up(&g, &d, 1, 4, 2), 2)
	testing.expect_value(t, _row_letters(&g), [6]rune{'A', 'D', 'E', ' ', ' ', 'F'})
	testing.expect(t, grid.grid_get_row(&g, 1).is_prompt, "prompt flag moves with its row")
	testing.expect(t, !grid.grid_get_row(&g, 3).wrap && !grid.grid_get_row(&g, 4).wrap, "vacated rows are reset")
	testing.expect_value(t, grid.grid_get_direct_color(&g, 1, 0).fg, [3]u8{9, 9, 9})
	testing.expect_value(t, grid.grid_get_direct_color(&g, 3, 0), cell.Direct_Color{})
	testing.expect_value(t, g.history_count, 0)

	j := damage.damage_consume(&d)
	testing.expect(t, !j.full_damage, "a region scroll damages only the region")
	testing.expect_value(t, j.min_row, 1)
	testing.expect_value(t, j.max_row, 4)
	testing.expect_value(t, j.full_rows, 4)
}

@test
test_region_scroll_down_rotates_rows :: proc(t: ^testing.T) {
	g: grid.Grid
	d: damage.Damage_Tracker
	_lettered_grid(&g, &d)
	defer grid.grid_destroy(&g)
	defer damage.damage_destroy(&d)

	testing.expect_value(t, grid.grid_scroll_down(&g, &d, 1, 4, 1), 1)
	testing.expect_value(t, _row_letters(&g), [6]rune{'A', ' ', 'B', 'C', 'D', 'F'})
	testing.expect(t, grid.grid_get_row(&g, 3).wrap, "wrap flag moves with its row")
	testing.expect(t, grid.grid_get_row(&g, 4).is_prompt, "prompt flag moves with its row")
	testing.expect(t, !grid.grid_get_row(&g, 1).is_prompt && !grid.grid_get_row(&g, 1).wrap, "vacated row is reset")
}

@test
test_region_scroll_whole_region_clears_it :: proc(t: ^testing.T) {
	g: grid.Grid
	d: damage.Damage_Tracker
	_lettered_grid(&g, &d)
	defer grid.grid_destroy(&g)
	defer damage.damage_destroy(&d)

	testing.expect_value(t, grid.grid_scroll_up(&g, &d, 1, 4, 9), 4)
	testing.expect_value(t, _row_letters(&g), [6]rune{'A', ' ', ' ', ' ', ' ', 'F'})
}

@test
test_full_scroll_resets_exposed_row :: proc(t: ^testing.T) {
	g: grid.Grid
	d: damage.Damage_Tracker
	_lettered_grid(&g, &d)
	defer grid.grid_destroy(&g)
	defer damage.damage_destroy(&d)

	testing.expect_value(t, grid.grid_scroll_up(&g, &d, 0, 5, 1), 1)
	testing.expect_value(t, _row_letters(&g), [6]rune{'B', 'C', 'D', 'E', 'F', ' '})
	testing.expect_value(t, grid.grid_get_direct_color(&g, 5, 2), cell.Direct_Color{})
	testing.expect_value(t, g.history_count, 1)
	testing.expect_value(t, grid.grid_get_cell(&g, -1, 0).char, 'A')
	testing.expect(t, damage.damage_consume(&d).full_damage, "a full scroll is whole-screen damage")
}
