package core_terminal

import "base:runtime"
import cursor "../cursor"
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
	t.parser.egc_pool = &t.egc_pool
	t.parser.on_osc = _terminal_on_osc
	t.parser.on_csi = _terminal_on_csi
	t.parser.on_apc = _terminal_on_apc
	t.parser.on_clear = _terminal_on_clear
	t.parser.on_scroll = _terminal_on_scroll
	t.parser.user_data = rawptr(t)
}

_terminal_on_osc :: proc(user_data: rawptr, osc_id: int, payload: string) -> bool {
	if user_data == nil do return false
	t := (^Terminal)(user_data)
	return extension.registry_dispatch_osc(&t.extensions, osc_id, payload, user_data)
}

_terminal_on_csi :: proc(user_data: rawptr, cmd: rune, params: []int) -> bool {
	if user_data == nil do return false
	t := (^Terminal)(user_data)
	return extension.registry_dispatch_csi(&t.extensions, cmd, params, user_data)
}

_terminal_on_apc :: proc(user_data: rawptr, payload: []u8) -> bool {
	if user_data == nil do return false
	t := (^Terminal)(user_data)
	return extension.registry_dispatch_apc(&t.extensions, payload, user_data)
}

_terminal_on_clear :: proc(user_data: rawptr, mode: int) {
	if user_data == nil do return
	t := (^Terminal)(user_data)
	extension.registry_dispatch_clear(&t.extensions, mode, user_data)
}

_terminal_on_scroll :: proc(user_data: rawptr, n: int, top, bottom: int) {
	if user_data == nil do return
	t := (^Terminal)(user_data)
	extension.registry_dispatch_scroll(&t.extensions, n, top, bottom, user_data)
}

terminal_destroy :: proc(t: ^Terminal) {
	if t == nil do return
	grid.grid_destroy(&t.grid)
	damage.damage_destroy(&t.damage)
	extension.registry_destroy(&t.extensions)
	parser.parser_destroy(&t.parser)
	egc.egc_pool_init(&t.egc_pool)
	t.rows = 0
	t.cols = 0
}

terminal_reset :: proc(t: ^Terminal) {
	if t == nil do return
	grid.grid_clear_all(&t.grid, &t.damage)
	grid.grid_clear_history(&t.grid)
	egc.egc_pool_init(&t.egc_pool)
	parser.parser_reset(&t.parser, t.rows, t.cols)
	extension.registry_dispatch_clear(&t.extensions, 3, rawptr(t))
}

terminal_advance_cursor_for_image :: proc(t: ^Terminal, cols, rows: int) {
	if t == nil do return
	p := &t.parser
	g := &t.grid
	d := &t.damage

	target_row := p.cursor.row + rows
	if target_row > p.scroll_bottom {
		overflow := target_row - p.scroll_bottom
		parser.parser_scroll_up(p, g, d, overflow)
		p.cursor.row = p.scroll_bottom
	} else {
		p.cursor.row = min(g.row_count - 1, target_row)
	}
	p.cursor.col = 0
	p.cursor.pending_wrap = false
}

terminal_feed_bytes :: proc(t: ^Terminal, data: []u8) {
	if t == nil || len(data) == 0 do return
	parser.parser_parse_bytes(&t.parser, &t.grid, &t.damage, data)
}

terminal_feed_string :: proc(t: ^Terminal, s: string) {
	terminal_feed_bytes(t, transmute([]u8)s)
}

terminal_resize :: proc(t: ^Terminal, new_rows, new_cols: int) {
	if t == nil || (new_rows == t.rows && new_cols == t.cols) do return
	old_cur_r := t.parser.cursor.row
	t.rows = max(1, new_rows)
	t.cols = max(1, new_cols)
	disp := 0
	grid.grid_resize(&t.grid, &t.damage, t.rows, t.cols, &t.parser.cursor.row, &t.parser.cursor.col, &t.parser.cursor.pending_wrap, &disp)
	t.parser.cursor.row = clamp(t.parser.cursor.row, 0, t.rows - 1)
	t.parser.cursor.col = clamp(t.parser.cursor.col, 0, t.cols - 1)
	t.parser.scroll_top = clamp(t.parser.scroll_top, 0, t.rows - 1)
	t.parser.scroll_bottom = max(0, t.rows - 1)

	// Keep saved cursor in sync with reflow displacement so DECRC (\x1b8 / CSI u) restores accurately
	delta_r := t.parser.cursor.row - old_cur_r
	t.parser.cursor.saved_row = clamp(t.parser.cursor.saved_row + delta_r, 0, t.rows - 1)
	t.parser.cursor.saved_col = clamp(t.parser.cursor.saved_col, 0, t.cols - 1)

	// Notify extensions of terminal resize and grid vertical displacement
	extension.registry_dispatch_resize(&t.extensions, t.rows, t.cols, disp, rawptr(t))
}

terminal_get_cell :: proc(t: ^Terminal, row, col: int) -> cell.Semantic_Cell {
	if t == nil do return cell.CELL_DEFAULT
	return grid.grid_get_cell(&t.grid, row, col)
}

terminal_get_direct_color :: proc(t: ^Terminal, row, col: int) -> cell.Direct_Color {
	if t == nil do return {}
	return grid.grid_get_direct_color(&t.grid, row, col)
}

terminal_get_row :: proc(t: ^Terminal, logical_row: int) -> ^grid.Row {
	if t == nil do return nil
	return grid.grid_get_row(&t.grid, logical_row)
}

terminal_physical_row :: proc(t: ^Terminal, logical_row: int) -> int {
	if t == nil do return 0
	return grid.grid_physical_row(&t.grid, logical_row)
}

terminal_consume_damage :: proc(t: ^Terminal) -> damage.Damage_Journal {
	if t == nil do return damage.Damage_Journal{has_damage = false}
	return damage.damage_consume(&t.damage)
}

terminal_get_egc_runes :: proc(t: ^Terminal, char_or_index: rune) -> []rune {
	if t == nil do return nil
	idx := int(char_or_index - egc.EGC_INDEX_BASE) if char_or_index >= egc.EGC_INDEX_BASE else int(char_or_index)
	if idx < 0 || idx >= egc.MAX_EGC_ENTRIES do return nil
	return egc.egc_pool_get(&t.egc_pool, idx)
}

terminal_cursor_pos :: proc(t: ^Terminal) -> (row, col: int) {
	if t == nil do return 0, 0
	return t.parser.cursor.row, t.parser.cursor.col
}

terminal_cursor_style :: proc(t: ^Terminal) -> (shape: parser.Cursor_Shape, blinking, visible: bool) {
	if t == nil do return .Block, false, false
	return t.parser.cursor.shape, t.parser.cursor.blinking, t.parser.cursor.visible
}

terminal_cursor_direct_color :: proc(t: ^Terminal) -> cell.Direct_Color {
	if t == nil do return {}
	return t.parser.cursor.direct_color
}

terminal_cursor_active_bg :: proc(t: ^Terminal) -> u8 {
	if t == nil do return 0
	return t.parser.cursor.active_bg
}

terminal_cursor_active_fg :: proc(t: ^Terminal) -> u8 {
	if t == nil do return 0
	return t.parser.cursor.active_fg
}

terminal_in_alt_screen :: proc(t: ^Terminal) -> bool {
	if t == nil do return false
	return t.parser.in_alt_screen
}

terminal_cursor_key_mode :: proc(t: ^Terminal) -> bool {
	if t == nil do return false
	return t.parser.cursor_key_mode
}

terminal_history_count :: proc(t: ^Terminal) -> int {
	if t == nil do return 0
	return t.grid.history_count
}

terminal_clear_history :: proc(t: ^Terminal) {
	if t == nil do return
	grid.grid_clear_history(&t.grid)
}

terminal_sample_bg :: proc(t: ^Terminal, scroll_offset: int = 0) -> (dc: cell.Direct_Color, palette_idx: u8, found: bool) {
	if t == nil || t.rows <= 0 || t.cols <= 0 do return {}, 0, false

	// Only sample background when in alternate screen buffer (e.g. Neovim, Vim, Nano, TUI apps).
	// When in standard shell buffer, preserve the uniform original terminal background
	// so CLI commands (video player, cat, scripts) never corrupt or hijack the pane card.
	if !t.parser.in_alt_screen do return {}, 0, false

	mid_r := t.rows / 2
	mid_c := t.cols / 2
	probe_points := [4][2]int{
		{mid_r, mid_c},  // Dead center of TUI canvas
		{0, 0},          // Top left
		{1, 0},          // Second row left (below header)
		{t.rows - 1, 0}, // Bottom row left (statusline or command line)
	}

	for pt in probe_points {
		r := pt[0]
		c := pt[1]
		if r < 0 || r >= t.rows || c < 0 || c >= t.cols do continue
		row := terminal_get_row(t, r - scroll_offset)
		if row == nil || c >= len(row.cells) do continue

		cell_val := row.cells[c]
		if .Has_Direct_Color in cell_val.flags && c < len(row.direct_colors) && row.direct_colors[c].has_bg {
			return row.direct_colors[c], 0, true
		}
		if cell_val.bg != 0 {
			return {}, cell_val.bg, true
		}
	}

	// Parser active background if cursor has bg
	if t.parser.cursor.direct_color.has_bg {
		return t.parser.cursor.direct_color, 0, true
	}
	if t.parser.cursor.active_bg != 0 {
		return {}, t.parser.cursor.active_bg, true
	}

	return {}, 0, false
}

terminal_register_osc :: proc(t: ^Terminal, osc_id: int, handler: extension.Osc_Handler_Proc, user_data: rawptr = nil) -> bool {
	if t == nil do return false
	return extension.registry_register_osc(&t.extensions, osc_id, handler, user_data)
}

terminal_register_extension :: proc(t: ^Terminal, ext: extension.Terminal_Extension) -> bool {
	if t == nil do return false
	return extension.registry_register_extension(&t.extensions, ext, rawptr(t))
}

terminal_emit_response :: proc(term_ptr: rawptr, data: []u8) -> bool {
	if term_ptr == nil do return false
	t := (^Terminal)(term_ptr)
	return parser.parser_emit_response(&t.parser, data)
}

terminal_emit_response_string :: proc(term_ptr: rawptr, s: string) -> bool {
	return terminal_emit_response(term_ptr, transmute([]u8)s)
}

terminal_drain_response :: proc(t: ^Terminal, out: []u8) -> int {
	if t == nil do return 0
	return parser.parser_drain_response(&t.parser, out)
}

terminal_set_cell_size :: proc(t: ^Terminal, cell_w, cell_h: int) {
	if t == nil do return
	t.parser.cell_w = cell_w
	t.parser.cell_h = cell_h
}

// terminal_cursor maps terminal state and active mouse tracking to a platform-neutral Mouse_Cursor.
terminal_cursor :: proc(
	t: ^Terminal,
	is_shift_held: bool = false,
	osc_pointer_shape: string = "",
) -> cursor.Mouse_Cursor {
	if len(osc_pointer_shape) > 0 {
		switch osc_pointer_shape {
		case "default":                                         return .Default
		case "pointer":                                         return .Pointer
		case "crosshair":                                       return .Crosshair
		case "col-resize", "ew-resize", "e-resize", "w-resize": return .Col_Resize
		case "row-resize", "ns-resize", "n-resize", "s-resize": return .Row_Resize
		case "move":                                            return .Move
		case "not-allowed":                                     return .Not_Allowed
		case "wait":                                            return .Wait
		case "text", "ibeam":                                   return .Text
		case:                                                   return .Default
		}
	}

	if t != nil && t.parser.mouse_mode != .None && !is_shift_held {
		return .Default
	}

	return .Text
}
