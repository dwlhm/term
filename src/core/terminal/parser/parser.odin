package terminal_parser

import "base:runtime"
import "core:strconv"
import "core:strings"
import cell "../cell"
import damage "../damage"
import egc "../egc"
import grid "../grid"
import extension "../extension"

Parser_State :: enum u8 {
	Ground,
	Escape,
	Csi_Entry,
	Csi_Param,
	Osc_String,
	Esc_In_Osc,
}

Cursor_Shape :: enum u8 {
	Block,
	Beam,
	Underline,
}

Cursor :: struct {
	row:            int,
	col:            int,
	saved_row:      int,
	saved_col:      int,
	active_fg:      u8,
	active_bg:      u8,
	active_style:   cell.Style_Flags,
	active_flags:   cell.Cell_Flags,
	visible:        bool,
	pending_wrap:   bool,
	shape:          Cursor_Shape,
	blinking:       bool,
}

MAX_CSI_PARAMS :: 16
MAX_OSC_BUFFER :: 512

Parser :: struct {
	state:            Parser_State,
	cursor:           Cursor,
	scroll_top:       int,
	scroll_bottom:    int,

	csi_params:       [MAX_CSI_PARAMS]int,
	csi_count:        int,
	csi_prefix:       u8, // e.g. '?'
	csi_intermediate: u8, // e.g. ' ' (0x20) for DECSCUSR

	in_alt_screen:    bool,
	cursor_key_mode:  bool, // DECCKM (?1)

	osc_buf:        [MAX_OSC_BUFFER]u8,
	osc_len:        int,

	utf8_state:     u8,
	utf8_len:       u8,
	utf8_buf:       [4]u8,

	egc_pool:       ^egc.Egc_Pool,
}

parser_init :: proc(p: ^Parser, rows, cols: int) {
	if p == nil do return
	p.state = .Ground
	p.scroll_top = 0
	p.scroll_bottom = max(0, rows - 1)
	p.cursor = Cursor{
		row          = 0,
		col          = 0,
		saved_row    = 0,
		saved_col    = 0,
		active_fg    = 7,
		active_bg    = 0,
		active_style = {},
		active_flags = {},
		visible      = true,
		pending_wrap = false,
		shape        = .Block,
		blinking     = true,
	}
	p.csi_count = 0
	p.csi_prefix = 0
	p.csi_intermediate = 0
	p.in_alt_screen = false
	p.cursor_key_mode = false
	p.osc_len = 0
	p.utf8_state = 0
	p.utf8_len = 0
	p.egc_pool = nil
}

parser_reset :: proc(p: ^Parser, rows, cols: int) {
	parser_init(p, rows, cols)
}

_parser_apply_pending_wrap :: proc(p: ^Parser, g: ^grid.Grid, d: ^damage.Damage_Tracker) {
	if !p.cursor.pending_wrap do return
	p.cursor.col = 0
	if p.cursor.row == p.scroll_bottom {
		grid.grid_scroll_up(g, d, p.scroll_top, p.scroll_bottom, 1)
	} else if p.cursor.row < g.row_count - 1 {
		p.cursor.row += 1
	}
	p.cursor.pending_wrap = false
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

	if cell.grapheme_cluster_width(new_runes) == 2 && .Wide_Lead not_in base.flags {
		new_cell.flags += {.Wide_Lead}
		grid.grid_set_cell(g, d, p.cursor.row, target_col, new_cell)
		if target_col + 1 < g.col_count {
			cont := cell.cell_make(' ', base.fg, base.bg, base.style, {.Wide_Continuation})
			grid.grid_set_cell(g, d, p.cursor.row, target_col + 1, cont)
		}
		if p.cursor.col == target_col + 1 && p.cursor.col + 1 < g.col_count {
			p.cursor.col += 1
		}
	} else {
		grid.grid_set_cell(g, d, p.cursor.row, target_col, new_cell)
	}
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
		_parser_apply_pending_wrap(p, g, d)

		target_col := p.cursor.col - 1
		if target_col >= 0 {
			prev := grid.grid_get_cell(g, p.cursor.row, target_col)
			if .Wide_Continuation in prev.flags && p.cursor.col >= 2 {
				target_col = p.cursor.col - 2
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
			grid.grid_scroll_up(g, d, p.scroll_top, p.scroll_bottom, 1)
		} else if p.cursor.row < g.row_count - 1 {
			p.cursor.row += 1
		}
		p.cursor.pending_wrap = false
	}

	if w == 2 {
		lead_flags := p.cursor.active_flags + {.Wide_Lead}
		c_lead := cell.cell_make(ch, p.cursor.active_fg, p.cursor.active_bg, p.cursor.active_style, lead_flags)
		grid.grid_set_cell(g, d, p.cursor.row, p.cursor.col, c_lead)

		if p.cursor.col + 1 < g.col_count {
			cont_flags := p.cursor.active_flags + {.Wide_Continuation}
			c_cont := cell.cell_make(' ', p.cursor.active_fg, p.cursor.active_bg, p.cursor.active_style, cont_flags)
			grid.grid_set_cell(g, d, p.cursor.row, p.cursor.col + 1, c_cont)
		}

		if p.cursor.col + 2 < g.col_count {
			p.cursor.col += 2
		} else {
			p.cursor.pending_wrap = true
		}
	} else {
		c := cell.cell_make(ch, p.cursor.active_fg, p.cursor.active_bg, p.cursor.active_style, p.cursor.active_flags)
		grid.grid_set_cell(g, d, p.cursor.row, p.cursor.col, c)

		if p.cursor.col + 1 < g.col_count {
			p.cursor.col += 1
		} else {
			p.cursor.pending_wrap = true
		}
	}
}

// _parser_put_combining attaches a zero-width rune (combining mark, VS16, ZWJ,
// emoji modifier, keycap, or regional indicator) to the grapheme cluster in the
// cell to the left of the cursor, mirroring legacy terminal_put_combining.
_parser_put_combining :: proc(p: ^Parser, g: ^grid.Grid, d: ^damage.Damage_Tracker, ch: rune) {
	if g == nil || p.egc_pool == nil || p.cursor.col == 0 do return

	target_col := p.cursor.col - 1
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

_parser_feed_utf8 :: proc(p: ^Parser, g: ^grid.Grid, d: ^damage.Damage_Tracker, b: u8) {
	if p.utf8_state == 0 {
		if b < 0xC0 {
			return
		} else if b < 0xE0 {
			p.utf8_state = 1
			p.utf8_buf[0] = b
			p.utf8_len = 1
		} else if b < 0xF0 {
			p.utf8_state = 2
			p.utf8_buf[0] = b
			p.utf8_len = 1
		} else if b < 0xF8 {
			p.utf8_state = 3
			p.utf8_buf[0] = b
			p.utf8_len = 1
		}
		return
	}

	if b < 0x80 || b >= 0xC0 {
		p.utf8_state = 0
		p.utf8_len = 0
		if b >= 0xC0 {
			_parser_feed_utf8(p, g, d, b)
		}
		return
	}

	p.utf8_buf[p.utf8_len] = b
	p.utf8_len += 1
	p.utf8_state -= 1

	if p.utf8_state == 0 {
		val: u32
		switch p.utf8_len {
		case 2:
			val = (u32(p.utf8_buf[0] & 0x1F) << 6) | u32(p.utf8_buf[1] & 0x3F)
		case 3:
			val = (u32(p.utf8_buf[0] & 0x0F) << 12) | (u32(p.utf8_buf[1] & 0x3F) << 6) | u32(p.utf8_buf[2] & 0x3F)
		case 4:
			val = (u32(p.utf8_buf[0] & 0x07) << 18) | (u32(p.utf8_buf[1] & 0x3F) << 12) | (u32(p.utf8_buf[2] & 0x3F) << 6) | u32(p.utf8_buf[3] & 0x3F)
		}
		p.utf8_len = 0
		if val > 0 && val <= 0x10FFFF {
			_parser_put_char(p, g, d, rune(val))
		}
	}
}

_parser_handle_csi :: proc(p: ^Parser, g: ^grid.Grid, d: ^damage.Damage_Tracker, ext_reg: ^extension.Terminal_Extension_Registry, cmd: u8, term_ptr: rawptr) {
	if g == nil do return

	param0 := p.csi_params[0] if p.csi_count > 0 && p.csi_params[0] > 0 else 1

	switch cmd {
	case 'A': // CUU - Cursor Up
		p.cursor.row = max(p.scroll_top, p.cursor.row - param0)
		p.cursor.pending_wrap = false

	case 'B': // CUD - Cursor Down
		p.cursor.row = min(p.scroll_bottom, p.cursor.row + param0)
		p.cursor.pending_wrap = false

	case 'C': // CUF - Cursor Forward
		p.cursor.col = min(g.col_count - 1, p.cursor.col + param0)
		p.cursor.pending_wrap = false

	case 'D': // CUB - Cursor Back
		p.cursor.col = max(0, p.cursor.col - param0)
		p.cursor.pending_wrap = false

	case 'H', 'f': // CUP - Cursor Position
		r := 1
		c := 1
		if p.csi_count >= 1 && p.csi_params[0] > 0 do r = p.csi_params[0]
		if p.csi_count >= 2 && p.csi_params[1] > 0 do c = p.csi_params[1]
		p.cursor.row = clamp(r - 1, 0, g.row_count - 1)
		p.cursor.col = clamp(c - 1, 0, g.col_count - 1)
		p.cursor.pending_wrap = false

	case 'J': // ED - Erase in Display
		mode := p.csi_params[0] if p.csi_count > 0 else 0
		switch mode {
		case 0: // Erase below
			grid.grid_clear_line(g, d, p.cursor.row, p.cursor.col, g.col_count)
			for r in (p.cursor.row + 1)..<g.row_count {
				grid.grid_clear_line(g, d, r, 0, g.col_count)
			}
		case 1: // Erase above
			for r in 0..<p.cursor.row {
				grid.grid_clear_line(g, d, r, 0, g.col_count)
			}
			grid.grid_clear_line(g, d, p.cursor.row, 0, p.cursor.col + 1)
		case 2, 3: // Erase all
			grid.grid_clear_all(g, d)
		}

	case 'K': // EL - Erase in Line
		mode := p.csi_params[0] if p.csi_count > 0 else 0
		switch mode {
		case 0: // Erase to right
			grid.grid_clear_line(g, d, p.cursor.row, p.cursor.col, g.col_count)
		case 1: // Erase to left
			grid.grid_clear_line(g, d, p.cursor.row, 0, p.cursor.col + 1)
		case 2: // Erase entire line
			grid.grid_clear_line(g, d, p.cursor.row, 0, g.col_count)
		}

	case 'L': // IL - Insert Lines
		grid.grid_scroll_down(g, d, p.cursor.row, p.scroll_bottom, param0)

	case 'M': // DL - Delete Lines
		grid.grid_scroll_up(g, d, p.cursor.row, p.scroll_bottom, param0)

	case 'P': // DCH - Delete Characters
		count := min(param0, g.col_count - p.cursor.col)
		for c in p.cursor.col..<(g.col_count - count) {
			src := grid.grid_get_cell(g, p.cursor.row, c + count)
			grid.grid_set_cell(g, d, p.cursor.row, c, src)
		}
		grid.grid_clear_line(g, d, p.cursor.row, g.col_count - count, g.col_count)

	case '@': // ICH - Insert Characters
		count := min(param0, g.col_count - p.cursor.col)
		for c := g.col_count - 1; c >= p.cursor.col + count; c -= 1 {
			src := grid.grid_get_cell(g, p.cursor.row, c - count)
			grid.grid_set_cell(g, d, p.cursor.row, c, src)
		}
		grid.grid_clear_line(g, d, p.cursor.row, p.cursor.col, p.cursor.col + count)

	case 'm': // SGR - Styling & Color Attributes
		if p.csi_count == 0 {
			p.cursor.active_fg = 7
			p.cursor.active_bg = 0
			p.cursor.active_style = {}
			p.cursor.active_flags = {}
			return
		}

		idx := 0
		for idx < p.csi_count {
			code := p.csi_params[idx]
			idx += 1
			switch code {
			case 0: // Reset
				p.cursor.active_fg = 7
				p.cursor.active_bg = 0
				p.cursor.active_style = {}
				p.cursor.active_flags = {}
			case 1: p.cursor.active_style += {.Bold}
			case 2: p.cursor.active_style += {.Dim}
			case 3: p.cursor.active_style += {.Italic}
			case 4: p.cursor.active_style += {.Underline}
			case 7: p.cursor.active_style += {.Invert}
			case 9: p.cursor.active_style += {.Strike}
			case 22: p.cursor.active_style -= {.Bold, .Dim}
			case 23: p.cursor.active_style -= {.Italic}
			case 24: p.cursor.active_style -= {.Underline}
			case 27: p.cursor.active_style -= {.Invert}
			case 29: p.cursor.active_style -= {.Strike}
			case 30..=37: // Standard FG (0..7)
				p.cursor.active_fg = u8(code - 30)
			case 39: // Default FG
				p.cursor.active_fg = 7
			case 40..=47: // Standard BG (0..7)
				p.cursor.active_bg = u8(code - 40)
			case 49: // Default BG
				p.cursor.active_bg = 0
			case 90..=97: // Bright FG (8..15)
				p.cursor.active_fg = u8(code - 90 + 8)
			case 100..=107: // Bright BG (8..15)
				p.cursor.active_bg = u8(code - 100 + 8)
			case 38: // Extended FG (256 color or TrueColor)
				if idx < p.csi_count && p.csi_params[idx] == 5 {
					// 38;5;<color>
					idx += 1
					if idx < p.csi_count {
						p.cursor.active_fg = u8(p.csi_params[idx] & 0xFF)
						idx += 1
					}
				} else if idx < p.csi_count && p.csi_params[idx] == 2 {
					// 38;2;<r>;<g>;<b> (TrueColor)
					idx += 1
					if idx + 2 < p.csi_count {
						p.cursor.active_flags += {.Has_Direct_Color}
						idx += 3
					}
				}
			case 48: // Extended BG
				if idx < p.csi_count && p.csi_params[idx] == 5 {
					idx += 1
					if idx < p.csi_count {
						p.cursor.active_bg = u8(p.csi_params[idx] & 0xFF)
						idx += 1
					}
				} else if idx < p.csi_count && p.csi_params[idx] == 2 {
					idx += 1
					if idx + 2 < p.csi_count {
						p.cursor.active_flags += {.Has_Direct_Color}
						idx += 3
					}
				}
			}
		}

	case 'r': // DECSTBM - Set Top and Bottom Margins
		t := 1
		b := g.row_count
		if p.csi_count >= 1 && p.csi_params[0] > 0 do t = p.csi_params[0]
		if p.csi_count >= 2 && p.csi_params[1] > 0 do b = p.csi_params[1]
		if t < b && b <= g.row_count {
			p.scroll_top = t - 1
			p.scroll_bottom = b - 1
			p.cursor.row = p.scroll_top
			p.cursor.col = 0
			p.cursor.pending_wrap = false
		}

	case 's': // SCOSC - Save Cursor Position
		p.cursor.saved_row = p.cursor.row
		p.cursor.saved_col = p.cursor.col

	case 'u': // SCOSC - Restore Cursor Position
		p.cursor.row = clamp(p.cursor.saved_row, 0, g.row_count - 1)
		p.cursor.col = clamp(p.cursor.saved_col, 0, g.col_count - 1)
		p.cursor.pending_wrap = false

	case 'h': // SM - Set Mode
		if p.csi_prefix == '?' {
			for idx in 0..<p.csi_count {
				mode := p.csi_params[idx]
				switch mode {
				case 1:
					p.cursor_key_mode = true
				case 25:
					p.cursor.visible = true
				case 47, 1047, 1049:
					p.in_alt_screen = true
					if mode == 1049 {
						p.cursor.saved_row = p.cursor.row
						p.cursor.saved_col = p.cursor.col
					}
				}
			}
		}

	case 'l': // RM - Reset Mode
		if p.csi_prefix == '?' {
			for idx in 0..<p.csi_count {
				mode := p.csi_params[idx]
				switch mode {
				case 1:
					p.cursor_key_mode = false
				case 25:
					p.cursor.visible = false
				case 47, 1047, 1049:
					p.in_alt_screen = false
					if mode == 1049 {
						p.cursor.row = clamp(p.cursor.saved_row, 0, g.row_count - 1)
						p.cursor.col = clamp(p.cursor.saved_col, 0, g.col_count - 1)
					}
				}
			}
		}

	case 'q': // DECSCUSR - Set Cursor Style
		if p.csi_intermediate == ' ' {
			mode := p.csi_params[0] if p.csi_count > 0 else 0
			switch mode {
			case 0, 1:
				p.cursor.shape = .Block
				p.cursor.blinking = true
			case 2:
				p.cursor.shape = .Block
				p.cursor.blinking = false
			case 3:
				p.cursor.shape = .Underline
				p.cursor.blinking = true
			case 4:
				p.cursor.shape = .Underline
				p.cursor.blinking = false
			case 5:
				p.cursor.shape = .Beam
				p.cursor.blinking = true
			case 6:
				p.cursor.shape = .Beam
				p.cursor.blinking = false
			}
		}

	case:
		// Dispatch unhandled custom CSI to extension registry
		if ext_reg != nil {
			extension.registry_dispatch_csi(ext_reg, rune(cmd), p.csi_params[:p.csi_count], term_ptr)
		}
	}
}

_parser_dispatch_osc :: proc(p: ^Parser, ext_reg: ^extension.Terminal_Extension_Registry, term_ptr: rawptr) {
	if p == nil || p.osc_len == 0 do return
	defer p.osc_len = 0

	s := string(p.osc_buf[:p.osc_len])
	semi_idx := strings.index_byte(s, ';')

	osc_id := 0
	payload := ""

	if semi_idx >= 0 {
		num_str := s[:semi_idx]
		parsed_id, ok := strconv.parse_int(num_str)
		if ok {
			osc_id = parsed_id
		}
		if semi_idx + 1 < len(s) {
			payload = s[semi_idx + 1 :]
		}
	} else {
		parsed_id, ok := strconv.parse_int(s)
		if ok {
			osc_id = parsed_id
		}
	}

	// Dispatch to modular extension registry!
	if ext_reg != nil {
		extension.registry_dispatch_osc(ext_reg, osc_id, payload, term_ptr)
	}
}

parser_parse_byte :: proc(p: ^Parser, g: ^grid.Grid, d: ^damage.Damage_Tracker, ext_reg: ^extension.Terminal_Extension_Registry, b: u8, term_ptr: rawptr) {
	if p == nil do return

	switch p.state {
	case .Ground:
		if b >= 0x80 {
			_parser_feed_utf8(p, g, d, b)
			return
		}

		if p.utf8_state != 0 {
			p.utf8_state = 0
			p.utf8_len = 0
		}

		switch b {
		case 0x1B: // ESC
			p.state = .Escape
		case '\r': // Carriage Return
			p.cursor.col = 0
			p.cursor.pending_wrap = false
		case '\n', 0x0B, 0x0C: // Line Feed, VT, FF
			if p.cursor.row == p.scroll_bottom {
				grid.grid_scroll_up(g, d, p.scroll_top, p.scroll_bottom, 1)
			} else if p.cursor.row < g.row_count - 1 {
				p.cursor.row += 1
			}
			p.cursor.pending_wrap = false
		case '\t': // Tab
			next_tab := (p.cursor.col / 8 + 1) * 8
			p.cursor.col = min(g.col_count - 1, next_tab)
			p.cursor.pending_wrap = false
		case 0x08: // Backspace
			p.cursor.col = max(0, p.cursor.col - 1)
			p.cursor.pending_wrap = false
		case 0x07: // BEL
			// Bell ignored in core
		case 0x20..=0x7E: // Printable ASCII Fast Path
			_parser_put_char(p, g, d, rune(b))
		}

	case .Escape:
		p.utf8_state = 0
		p.utf8_len = 0
		switch b {
		case '[':
			p.state = .Csi_Entry
			p.csi_count = 0
			p.csi_prefix = 0
			p.csi_intermediate = 0
			for i in 0..<MAX_CSI_PARAMS {
				p.csi_params[i] = 0
			}
		case ']':
			p.state = .Osc_String
			p.osc_len = 0
		case 'M': // Reverse Index (scroll down if at top margin)
			if p.cursor.row == p.scroll_top {
				grid.grid_scroll_down(g, d, p.scroll_top, p.scroll_bottom, 1)
			} else {
				p.cursor.row = max(0, p.cursor.row - 1)
			}
			p.state = .Ground
		case '7': // Save Cursor
			p.cursor.saved_row = p.cursor.row
			p.cursor.saved_col = p.cursor.col
			p.state = .Ground
		case '8': // Restore Cursor
			p.cursor.row = clamp(p.cursor.saved_row, 0, g.row_count - 1)
			p.cursor.col = clamp(p.cursor.saved_col, 0, g.col_count - 1)
			p.state = .Ground
		case:
			p.state = .Ground
		}

	case .Csi_Entry:
		if b == '?' || b == '>' || b == '<' || b == '=' {
			p.csi_prefix = b
			p.state = .Csi_Param
		} else if b >= '0' && b <= '9' {
			p.csi_params[0] = int(b - '0')
			p.csi_count = 1
			p.state = .Csi_Param
		} else if b == ';' {
			p.csi_count = 2
			p.state = .Csi_Param
		} else if b >= 0x20 && b <= 0x2F {
			p.csi_intermediate = b
			p.state = .Csi_Param
		} else if b >= 0x40 && b <= 0x7E {
			// Instant CSI command with 0 parameters
			_parser_handle_csi(p, g, d, ext_reg, b, term_ptr)
			p.state = .Ground
		} else {
			p.state = .Ground
		}

	case .Csi_Param:
		if b >= '0' && b <= '9' {
			idx := max(0, p.csi_count - 1)
			if p.csi_count == 0 {
				idx = 0
				p.csi_count = 1
			}
			p.csi_params[idx] = p.csi_params[idx] * 10 + int(b - '0')
		} else if b == ';' {
			if p.csi_count < MAX_CSI_PARAMS {
				p.csi_count += 1
				p.csi_params[p.csi_count - 1] = 0
			}
		} else if b >= 0x20 && b <= 0x2F {
			p.csi_intermediate = b
		} else if b >= 0x40 && b <= 0x7E {
			// End of CSI command
			_parser_handle_csi(p, g, d, ext_reg, b, term_ptr)
			p.state = .Ground
		} else {
			p.state = .Ground
		}

	case .Osc_String:
		if b == 0x07 { // BEL terminates OSC
			_parser_dispatch_osc(p, ext_reg, term_ptr)
			p.state = .Ground
		} else if b == 0x1B { // ESC inside OSC might be ST (ESC \)
			p.state = .Esc_In_Osc
		} else {
			if p.osc_len < MAX_OSC_BUFFER - 1 {
				p.osc_buf[p.osc_len] = b
				p.osc_len += 1
			}
		}

	case .Esc_In_Osc:
		if b == '\\' { // String Terminator (ST)
			_parser_dispatch_osc(p, ext_reg, term_ptr)
			p.state = .Ground
		} else {
			// Aborted OSC sequence
			p.osc_len = 0
			p.state = .Ground
		}
	}
}

parser_parse_bytes :: proc(p: ^Parser, g: ^grid.Grid, d: ^damage.Damage_Tracker, ext_reg: ^extension.Terminal_Extension_Registry, data: []u8, term_ptr: rawptr) {
	if p == nil || len(data) == 0 do return

	i := 0
	for i < len(data) {
		// Fast ASCII run scanner in Ground state (only when not in middle of UTF-8 sequence)
		if p.state == .Ground && p.utf8_state == 0 {
			start := i
			for i < len(data) && data[i] >= 0x20 && data[i] <= 0x7E && !p.cursor.pending_wrap {
				_parser_put_char(p, g, d, rune(data[i]))
				i += 1
			}
			if i > start && i < len(data) && (data[i] < 0x20 || data[i] > 0x7E) {
				// Process next byte
				parser_parse_byte(p, g, d, ext_reg, data[i], term_ptr)
				i += 1
				continue
			}
			if i >= len(data) do break
		}

		parser_parse_byte(p, g, d, ext_reg, data[i], term_ptr)
		i += 1
	}
}
