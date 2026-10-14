package core_terminal

import "base:runtime"
import cell "cell"
import damage "damage"
import egc "egc"
import extension "extension"
import grid "grid"
import parser "parser"

Terminal :: struct {
	grid:       grid.Grid,
	damage:     damage.Damage_Tracker,
	egc_pool:   egc.Egc_Pool,
	extensions: extension.Terminal_Extension_Registry,
	parser:     parser.Parser,
	rows:       int,
	cols:       int,
	allocator:  runtime.Allocator,
}

terminal_init :: proc(t: ^Terminal, rows, cols: int, allocator: runtime.Allocator = context.allocator) {
	if t == nil do return
	t.rows = max(1, rows)
	t.cols = max(1, cols)
	t.allocator = allocator

	grid.grid_init(&t.grid, t.rows, t.cols, allocator)
	damage.damage_init(&t.damage, t.rows, t.cols, allocator)
	egc.egc_pool_init(&t.egc_pool)
	extension.registry_init(&t.extensions)
	parser.parser_init(&t.parser, t.rows, t.cols)
}

terminal_destroy :: proc(t: ^Terminal) {
	if t == nil do return
	grid.grid_destroy(&t.grid)
	damage.damage_destroy(&t.damage)
	extension.registry_destroy(&t.extensions)
	t.rows = 0
	t.cols = 0
}

terminal_feed_bytes :: proc(t: ^Terminal, data: []u8) {
	if t == nil || len(data) == 0 do return
	parser.parser_parse_bytes(&t.parser, &t.grid, &t.damage, &t.extensions, data, rawptr(t))
}

terminal_feed_string :: proc(t: ^Terminal, s: string) {
	terminal_feed_bytes(t, transmute([]u8)s)
}

terminal_resize :: proc(t: ^Terminal, new_rows, new_cols: int) {
	if t == nil || (new_rows == t.rows && new_cols == t.cols) do return
	t.rows = max(1, new_rows)
	t.cols = max(1, new_cols)
	grid.grid_resize(&t.grid, &t.damage, t.rows, t.cols)
	parser.parser_reset(&t.parser, t.rows, t.cols)
}

terminal_get_cell :: proc(t: ^Terminal, row, col: int) -> cell.Semantic_Cell {
	if t == nil do return cell.CELL_DEFAULT
	return grid.grid_get_cell(&t.grid, row, col)
}

terminal_consume_damage :: proc(t: ^Terminal) -> damage.Damage_Journal {
	if t == nil do return damage.Damage_Journal{has_damage = false}
	return damage.damage_consume(&t.damage)
}

terminal_register_osc :: proc(t: ^Terminal, osc_id: int, handler: extension.Osc_Handler_Proc, user_data: rawptr = nil) -> bool {
	if t == nil do return false
	return extension.registry_register_osc(&t.extensions, osc_id, handler, user_data)
}

terminal_register_extension :: proc(t: ^Terminal, ext: extension.Terminal_Extension) -> bool {
	if t == nil do return false
	return extension.registry_register_extension(&t.extensions, ext, rawptr(t))
}
