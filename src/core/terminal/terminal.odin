package core_terminal

import "base:runtime"
import cursor "../cursor"
import cell "cell"
import damage "damage"
import egc "egc"
import extension "extension"
import grid "grid"
import parser "parser"

Cursor_Shape :: parser.Cursor_Shape
Cell_Flag    :: cell.Cell_Flag
Style_Flag   :: cell.Style_Flag

Terminal :: struct {
	// `alt_grid` holds the inactive buffer (primary while the alternate screen is
	// active); `grid` is always the buffer the parser writes into.
	alt_grid:   grid.Grid,
	grid:       grid.Grid,
	alt_damage: damage.Damage_Tracker,
	damage:     damage.Damage_Tracker,
	egc_pool:   egc.Egc_Pool,
	hyperlinks: extension.Hyperlink_Table,
	extensions: extension.Terminal_Extension_Registry,
	parser:     parser.Parser,
	rows:       int,
	cols:       int,
	// Window title from OSC 0/2, kept as VT state so a paint can restore it.
	title_buf:  [256]u8,
	title_len:  int,
	allocator:  runtime.Allocator,
}

terminal_init :: proc(t: ^Terminal, rows, cols: int, allocator: runtime.Allocator = context.allocator) {
	if t == nil do return
	t.rows = max(1, rows)
	t.cols = max(1, cols)
	t.allocator = allocator

	grid.grid_init(&t.grid, t.rows, t.cols, allocator)
	// The alternate screen never contributes scrollback.
	grid.grid_init(&t.alt_grid, t.rows, t.cols, allocator, 0)
	damage.damage_init(&t.damage, t.rows, t.cols, allocator)
	damage.damage_init(&t.alt_damage, t.rows, t.cols, allocator)
	egc.egc_pool_init(&t.egc_pool)
	extension.registry_init(&t.extensions)
	extension.hyperlinks_init(&t.hyperlinks, _terminal_set_active_link)
	parser.parser_init(&t.parser, t.rows, t.cols)
	t.parser.egc_pool = &t.egc_pool
	t.parser.on_osc = _terminal_on_osc
	t.parser.on_csi = _terminal_on_csi
	t.parser.on_apc = _terminal_on_apc
	t.parser.on_dcs = _terminal_on_dcs
	t.parser.on_clear = _terminal_on_clear
	t.parser.on_scroll = _terminal_on_scroll
	t.parser.on_alt_screen = _terminal_on_alt_screen
	_ = extension.registry_register_osc(&t.extensions, 8, extension.osc_8_handler, rawptr(&t.hyperlinks))
	t.parser.user_data = rawptr(t)
}

_terminal_set_active_link :: proc(term: rawptr, link_id: u16) {
	if term == nil do return
	t := (^Terminal)(term)
	t.parser.active_link = link_id
}

// terminal_link_uri resolves an OSC 8 link id to its URI ("" when unknown).
terminal_link_uri :: proc(t: ^Terminal, link_id: u16) -> string {
	if t == nil do return ""
	return extension.hyperlinks_uri(&t.hyperlinks, link_id)
}

terminal_cell_hyperlink :: proc(t: ^Terminal, row, col: int) -> (link_id: u16, uri: string) {
	id := terminal_cell_link_id(t, row, col)
	if id == 0 do return 0, ""
	return id, terminal_link_uri(t, id)
}

// terminal_cell_link_id returns the OSC 8 link id stored beside a cell (0 when
// none), without resolving the URI string.
terminal_cell_link_id :: proc(t: ^Terminal, row, col: int) -> u16 {
	if t == nil do return 0
	cell_value := terminal_get_cell(t, row, col)
	if .Has_Hyperlink not_in cell_value.flags do return 0
	dc := terminal_get_direct_color(t, row, col)
	return dc.link_id
}

// terminal_hyperlink_span returns the contiguous run of cells on `row` that
// share the OSC 8 link under `col` (inclusive). It expands across spaces so
// hover highlighting and underlines stay continuous.
terminal_hyperlink_span :: proc(t: ^Terminal, row, col: int) -> (col_start, col_end: int, ok: bool) {
	if t == nil do return 0, 0, false
	link_id := terminal_cell_link_id(t, row, col)
	if link_id == 0 do return 0, 0, false

	col_start = col
	for col_start > 0 && terminal_cell_link_id(t, row, col_start - 1) == link_id {
		col_start -= 1
	}
	col_end = col
	for col_end < t.cols - 1 && terminal_cell_link_id(t, row, col_end + 1) == link_id {
		col_end += 1
	}
	return col_start, col_end, true
}

_terminal_on_osc :: proc(user_data: rawptr, osc_id: int, payload: string) -> bool {
	if user_data == nil do return false
	t := (^Terminal)(user_data)
	if osc_id == 0 || osc_id == 2 {
		t.title_len = min(len(payload), len(t.title_buf))
		copy(t.title_buf[:t.title_len], payload[:t.title_len])
	}
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

_terminal_on_dcs :: proc(user_data: rawptr, payload: []u8) -> bool {
	if user_data == nil do return false
	t := (^Terminal)(user_data)
	return extension.registry_dispatch_dcs(&t.extensions, payload, user_data)
}

_terminal_on_clear :: proc(user_data: rawptr, mode: int) {
	if user_data == nil do return
	t := (^Terminal)(user_data)
	extension.registry_dispatch_clear(&t.extensions, mode, user_data)
}

// _terminal_on_alt_screen swaps the visible buffer. Both grids share the same
// geometry, so the swap is O(1) and the parser's grid pointer stays valid.
_terminal_on_alt_screen :: proc(user_data: rawptr, enter: bool, mode: int) {
	if user_data == nil do return
	t := (^Terminal)(user_data)

	// When leaving alternate screen: clear its grid and alternate screen placements (mode 47 preserves)
	if !enter && mode != 47 {
		grid.grid_clear_all(&t.grid, &t.damage)
		extension.registry_dispatch_clear(&t.extensions, 3, rawptr(t))
	}

	t.grid, t.alt_grid = t.alt_grid, t.grid

	if enter && mode != 47 {
		grid.grid_clear_all(&t.grid, &t.damage)
	}

	t.parser.scroll_top = 0
	t.parser.scroll_bottom = max(0, t.rows - 1)
	damage.damage_mark_all(&t.damage, 1)
}

_terminal_on_scroll :: proc(user_data: rawptr, n: int, top, bottom: int) {
	if user_data == nil do return
	t := (^Terminal)(user_data)
	extension.registry_dispatch_scroll(&t.extensions, n, top, bottom, user_data)
}

terminal_destroy :: proc(t: ^Terminal) {
	if t == nil do return
	grid.grid_destroy(&t.grid)
	grid.grid_destroy(&t.alt_grid)
	damage.damage_destroy(&t.damage)
	damage.damage_destroy(&t.alt_damage)
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
	// Keep the hidden buffer in sync without letting its damage leak into the
	// visible one (its rows are marked on the next screen switch anyway). A
	// hidden main screen reflows with its cursor, the one ?1049h saved: leaving
	// the full-screen program puts it back on the same line.
	in_alt := t.parser.in_alt_screen
	hidden_disp := 0
	if in_alt {
		grid.grid_resize(&t.alt_grid, &t.alt_damage, t.rows, t.cols, &t.parser.cursor.saved_row, &t.parser.cursor.saved_col, nil, &hidden_disp)
	} else {
		grid.grid_resize(&t.alt_grid, &t.alt_damage, t.rows, t.cols, nil, nil, nil, &hidden_disp)
	}
	t.parser.cursor.row = clamp(t.parser.cursor.row, 0, t.rows - 1)
	t.parser.cursor.col = clamp(t.parser.cursor.col, 0, t.cols - 1)
	t.parser.scroll_top = clamp(t.parser.scroll_top, 0, t.rows - 1)
	t.parser.scroll_bottom = max(0, t.rows - 1)

	// Keep saved cursor in sync with reflow displacement so DECRC (\x1b8 / CSI u) restores accurately
	if !in_alt do t.parser.cursor.saved_row += t.parser.cursor.row - old_cur_r
	t.parser.cursor.saved_row = clamp(t.parser.cursor.saved_row, 0, t.rows - 1)
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

terminal_title :: proc(t: ^Terminal) -> string {
	if t == nil do return ""
	return string(t.title_buf[:t.title_len])
}

// terminal_parser_at_ground reports that no escape sequence, control string or
// UTF-8 sequence is half-received, so a paint can be spliced into the stream.
terminal_parser_at_ground :: proc(t: ^Terminal) -> bool {
	if t == nil do return true
	return t.parser.state == .Ground && t.parser.utf8_state == 0
}

terminal_in_alt_screen :: proc(t: ^Terminal) -> bool {
	if t == nil do return false
	return t.parser.in_alt_screen
}

// terminal_kitty_keyboard_flags returns the active Kitty keyboard enhancement
// flags, which the input encoder must honour for this session.
terminal_kitty_keyboard_flags :: proc(t: ^Terminal) -> u8 {
	if t == nil do return 0
	return parser.parser_kitty_keyboard_flags(&t.parser)
}

terminal_sync_output :: proc(t: ^Terminal) -> bool {
	if t == nil do return false
	return t.parser.sync_output
}

terminal_cursor_key_mode :: proc(t: ^Terminal) -> bool {
	if t == nil do return false
	return t.parser.cursor_key_mode
}

terminal_origin_mode :: proc(t: ^Terminal) -> bool {
	if t == nil do return false
	return t.parser.origin_mode
}

terminal_autowrap :: proc(t: ^Terminal) -> bool {
	if t == nil do return true
	return t.parser.autowrap
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

	// A full-screen TUI paints every cell, so a sparse lattice majority vote
	// reliably recovers its background. A transient centered widget (e.g. pi's
	// green command-success card) only covers a minority of samples and can
	// never leak into the pane background.
	keys: [16]u32
	counts: [16]int
	total := 0
	color_count := 0

	row_pos := [4]int{0, max(1, t.rows / 3), max(1, 2 * t.rows / 3), t.rows - 1}
	col_pos := [4]int{0, max(1, t.cols / 3), max(1, 2 * t.cols / 3), t.cols - 1}

	for rr in row_pos {
		for cc in col_pos {
			row := terminal_get_row(t, rr - scroll_offset)
			if row == nil || cc >= len(row.cells) do continue
			total += 1

			cell_val := row.cells[cc]
			key: u32
			ok := false
			if .Has_Direct_Color in cell_val.flags && cc < len(row.direct_colors) && row.direct_colors[cc].has_bg {
				key = 0x01000000 | (u32(row.direct_colors[cc].bg[0]) << 16) | (u32(row.direct_colors[cc].bg[1]) << 8) | u32(row.direct_colors[cc].bg[2])
				ok = true
			} else if cell_val.bg != 0 {
				key = 0x02000000 | u32(cell_val.bg)
				ok = true
			}
			if !ok do continue

			idx := -1
			for i in 0..<color_count {
				if keys[i] == key {
					idx = i
					break
				}
			}
			if idx < 0 && color_count < len(keys) {
				idx = color_count
				keys[idx] = key
				color_count += 1
			}
			if idx >= 0 {
				counts[idx] += 1
			}
		}
	}

	// Require a clear majority (>= 60%) before adopting a colour as the pane background.
	for i in 0..<color_count {
		if total > 0 && counts[i] * 5 >= total * 3 {
			key := keys[i]
			if (key & 0xFF000000) == 0x01000000 {
				dc.bg = [3]u8{u8((key >> 16) & 0xFF), u8((key >> 8) & 0xFF), u8(key & 0xFF)}
				dc.has_bg = true
				return dc, 0, true
			}
			return {}, u8(key & 0xFF), true
		}
	}

	return {}, 0, false
}

terminal_register_osc :: proc(t: ^Terminal, osc_id: int, handler: extension.Osc_Handler_Proc, user_data: rawptr = nil) -> bool {
	if t == nil do return false
	return extension.registry_register_osc(&t.extensions, osc_id, handler, user_data)
}

terminal_register_extension :: proc(t: ^Terminal, ext: extension.Terminal_Extension) -> bool {
	if t == nil do return false
	ok := extension.registry_register_extension(&t.extensions, ext, rawptr(t))
	if ok {
		for i in 0..<t.extensions.ext_count {
			e := &t.extensions.extensions[i]
			if e.name == "kitty_graphics" && e.user_data != nil {
				kstate := (^extension.Kitty_Extension)(e.user_data)
				if kstate.screen_provider == nil {
					kstate.screen_provider = proc(term_ptr: rawptr) -> extension.Kitty_Screen {
						if term_ptr == nil do return .Primary
						term := (^Terminal)(term_ptr)
						return .Alternate if terminal_in_alt_screen(term) else .Primary
					}
				}
				if kstate.cursor_provider == nil {
					kstate.cursor_provider = proc(term_ptr: rawptr) -> (int, int) {
						if term_ptr == nil do return 0, 0
						term := (^Terminal)(term_ptr)
						return term.parser.cursor.row, term.parser.cursor.col
					}
				}
				if kstate.grid_size_provider == nil {
					kstate.grid_size_provider = proc(term_ptr: rawptr) -> (int, int) {
						if term_ptr == nil do return 0, 0
						term := (^Terminal)(term_ptr)
						return term.cols, term.rows
					}
				}
				if kstate.cell_size_provider == nil {
					kstate.cell_size_provider = proc(term_ptr: rawptr) -> (int, int) {
						if term_ptr == nil do return 19, 43
						term := (^Terminal)(term_ptr)
						return term.parser.cell_w if term.parser.cell_w > 0 else 19, term.parser.cell_h if term.parser.cell_h > 0 else 43
					}
				}
				if kstate.cursor_advancer == nil {
					kstate.cursor_advancer = proc(term_ptr: rawptr, cols, rows: int) {
						if term_ptr == nil do return
						term := (^Terminal)(term_ptr)
						terminal_advance_cursor_for_image(term, cols, rows)
					}
				}
				if kstate.damage_notifier == nil {
					kstate.damage_notifier = proc(term_ptr: rawptr, start_row, row_count: int) {
						if term_ptr == nil do return
						term := (^Terminal)(term_ptr)
						for r := start_row; r < start_row + row_count && r < term.rows; r += 1 {
							if r >= 0 do damage.damage_mark_row(&term.damage, r, 1)
						}
					}
				}
				if kstate.responder == nil {
					kstate.responder = proc(term_ptr: rawptr, response: []u8) -> bool {
						return terminal_emit_response(term_ptr, response)
					}
				}
				break
			}
		}
	}
	return ok
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
