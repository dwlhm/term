package terminal_parser

import cell "../cell"
import damage "../damage"
import egc "../egc"
import grid "../grid"

_parser_erase_cell :: proc(p: ^Parser) -> (c: cell.Semantic_Cell, dc: cell.Direct_Color) {
	flags: cell.Cell_Flags = {}
	if .Has_Direct_Color in p.cursor.active_flags && p.cursor.direct_color.has_bg {
		flags += {.Has_Direct_Color}
		dc = p.cursor.direct_color
	}
	c = cell.cell_make(' ', p.cursor.active_fg, p.cursor.active_bg, {}, flags)
	return c, dc
}

_parser_apply_pending_wrap :: proc(p: ^Parser, g: ^grid.Grid, d: ^damage.Damage_Tracker) {
	if !p.cursor.pending_wrap do return
	p.cursor.col = 0
	if p.cursor.row == p.scroll_bottom {
		erase_c, erase_dc := _parser_erase_cell(p)
		grid.grid_scroll_up(g, d, p.scroll_top, p.scroll_bottom, 1, erase_c, erase_dc)
	} else if p.cursor.row < g.row_count - 1 {
		p.cursor.row += 1
	}
	p.cursor.pending_wrap = false
}

// _parser_sanitize_wide_boundary cleans up orphan Wide_Lead or Wide_Continuation cells
// that would otherwise be severed when overwriting or clearing a span.
_parser_sanitize_wide_boundary :: proc(g: ^grid.Grid, d: ^damage.Damage_Tracker, row, col: int) {
	if g == nil || row < 0 || row >= g.row_count || col < 0 || col >= g.col_count do return
	c := grid.grid_get_cell(g, row, col)
	if .Wide_Continuation in c.flags && col > 0 {
		grid.grid_set_cell(g, d, row, col - 1, cell.CELL_DEFAULT)
	}
	if .Wide_Lead in c.flags && col + 1 < g.col_count {
		grid.grid_set_cell(g, d, row, col + 1, cell.CELL_DEFAULT)
	}
}

// _parser_cluster_from_cell rebuilds the grapheme cluster runes referenced by a
// cell: either the EGC pool entry (Has_Egc) or the literal codepoint.
_parser_cluster_from_cell :: proc(p: ^Parser, c: cell.Semantic_Cell) -> (runes: [egc.MAX_EGC_RUNES]rune, count: int) {
	if .Has_Egc in c.flags && p.egc_pool != nil {
		if existing := egc.egc_pool_get(p.egc_pool, int(c.char - egc.EGC_INDEX_BASE)); existing != nil {
			for r in existing {
				if count >= egc.MAX_EGC_RUNES do break
				runes[count] = r
				count += 1
			}
			return
		}
	}
	runes[0] = c.char
	count = 1
	return
}

// _parser_extend_anchor appends `ch` to the grapheme cluster anchored at
// (row, target_col), allocating a new EGC entry and (when VS16/keycap widens a
// narrow base) placing the continuation cell. Cursor advances only on widening.
_parser_extend_anchor :: proc(p: ^Parser, g: ^grid.Grid, d: ^damage.Damage_Tracker, target_col: int, base: cell.Semantic_Cell, cluster: []rune, ch: rune) {
	if p.egc_pool == nil || len(cluster) >= egc.MAX_EGC_RUNES do return

	buf: [egc.MAX_EGC_RUNES]rune
	for r, i in cluster do buf[i] = r
	buf[len(cluster)] = ch
	new_runes := buf[:len(cluster) + 1]

	new_idx, ok := egc.egc_pool_alloc(p.egc_pool, new_runes)
	if !ok do return // Pool exhausted: keep base, drop the mark.

	new_cell := base
	new_cell.char = egc.EGC_INDEX_BASE + rune(new_idx)
	new_cell.flags += {.Has_Egc}

	base_dc := grid.grid_get_direct_color(g, p.cursor.row, target_col)
	if cell.grapheme_cluster_width(new_runes) == 2 && .Wide_Lead not_in base.flags {
		new_cell.flags += {.Wide_Lead}
		grid.grid_set_cell(g, d, p.cursor.row, target_col, new_cell, base_dc)
		if target_col + 1 < g.col_count {
			cont := cell.cell_make(' ', base.fg, base.bg, base.style, {.Wide_Continuation})
			grid.grid_set_cell(g, d, p.cursor.row, target_col + 1, cont, base_dc)
		}
		if p.cursor.col == target_col + 1 {
			if p.cursor.col + 1 < g.col_count {
				p.cursor.col += 1
			} else {
				p.cursor.pending_wrap = true
			}
		}
	} else {
		grid.grid_set_cell(g, d, p.cursor.row, target_col, new_cell, base_dc)
	}
}

// _parser_put_combining attaches a zero-width rune (combining mark, VS16, ZWJ,
// emoji modifier, keycap, or regional indicator) to the grapheme cluster in the
// cell to the left of the cursor, mirroring legacy terminal_put_combining.
_parser_put_combining :: proc(p: ^Parser, g: ^grid.Grid, d: ^damage.Damage_Tracker, ch: rune) {
	if g == nil || p.egc_pool == nil do return

	target_col := p.cursor.col if p.cursor.pending_wrap else p.cursor.col - 1
	if target_col < 0 do return

	prev := grid.grid_get_cell(g, p.cursor.row, target_col)
	if .Wide_Continuation in prev.flags && target_col >= 1 {
		target_col -= 1
	}

	base := grid.grid_get_cell(g, p.cursor.row, target_col)
	if base.char == 0 || base.char == ' ' do return

	cluster, count := _parser_cluster_from_cell(p, base)
	if !cell.grapheme_should_extend(cluster[:count], ch) do return
	_parser_extend_anchor(p, g, d, target_col, base, cluster[:count], ch)
}

_parser_put_char :: proc(p: ^Parser, g: ^grid.Grid, d: ^damage.Damage_Tracker, ch: rune) {
	if g == nil do return

	w := cell.wcwidth(ch)
	if w == 0 {
		_parser_put_combining(p, g, d, ch)
		return
	}

	// UAX #29 stateful anchor: a non-ASCII base rune may extend the cluster in
	// the previous cell (ZWJ emoji, regional-indicator pairs, keycaps).
	if ch >= 0x80 {
		target_col := p.cursor.col if p.cursor.pending_wrap else p.cursor.col - 1
		if target_col >= 0 {
			prev := grid.grid_get_cell(g, p.cursor.row, target_col)
			if .Wide_Continuation in prev.flags && target_col >= 1 {
				target_col -= 1
			}
		}

		if target_col >= 0 {
			anchor := grid.grid_get_cell(g, p.cursor.row, target_col)
			if anchor.char != 0 && anchor.char != ' ' {
				cluster, count := _parser_cluster_from_cell(p, anchor)
				if cell.grapheme_should_extend(cluster[:count], ch) {
					_parser_extend_anchor(p, g, d, target_col, anchor, cluster[:count], ch)
					return
				}
			}
		}
	}

	if p.cursor.pending_wrap || (w == 2 && p.cursor.col >= g.col_count - 1) {
		p.cursor.col = 0
		if p.cursor.row == p.scroll_bottom {
			erase_c, erase_dc := _parser_erase_cell(p)
			grid.grid_scroll_up(g, d, p.scroll_top, p.scroll_bottom, 1, erase_c, erase_dc)
		} else if p.cursor.row < g.row_count - 1 {
			p.cursor.row += 1
		}
		p.cursor.pending_wrap = false
	}

	// Wide character boundary sanitization prior to overwrite
	_parser_sanitize_wide_boundary(g, d, p.cursor.row, p.cursor.col)

	if w == 2 {
		if p.cursor.col + 1 < g.col_count {
			_parser_sanitize_wide_boundary(g, d, p.cursor.row, p.cursor.col + 1)
		}

		lead_flags := p.cursor.active_flags + {.Wide_Lead}
		c_lead := cell.cell_make(ch, p.cursor.active_fg, p.cursor.active_bg, p.cursor.active_style, lead_flags)
		grid.grid_set_cell(g, d, p.cursor.row, p.cursor.col, c_lead, p.cursor.direct_color)

		if p.cursor.col + 1 < g.col_count {
			cont_flags := p.cursor.active_flags + {.Wide_Continuation}
			c_cont := cell.cell_make(' ', p.cursor.active_fg, p.cursor.active_bg, p.cursor.active_style, cont_flags)
			grid.grid_set_cell(g, d, p.cursor.row, p.cursor.col + 1, c_cont, p.cursor.direct_color)
		}

		if p.cursor.col + 2 < g.col_count {
			p.cursor.col += 2
		} else {
			p.cursor.pending_wrap = true
		}
	} else {
		c := cell.cell_make(ch, p.cursor.active_fg, p.cursor.active_bg, p.cursor.active_style, p.cursor.active_flags)
		grid.grid_set_cell(g, d, p.cursor.row, p.cursor.col, c, p.cursor.direct_color)

		if p.cursor.col + 1 < g.col_count {
			p.cursor.col += 1
		} else {
			p.cursor.pending_wrap = true
		}
	}
}
