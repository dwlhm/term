package term

// Mouse Interaction & Keyboard Selection Engine
// Part of Tier 3 Application Shell (src/app/term/*).
// Uses features/interaction/selection for coordinate storage & auto-select algorithms.

import "vendor:sdl3"
import chrome_splits "../../core/chrome/splits"
import feat_inter "../../features/interaction"
import sess_feat "../../features/session"
import terminal_grid "../../core/terminal/grid"

Cell_Pos                 :: feat_inter.Cell_Pos
Selection_Mode           :: feat_inter.Selection_Mode
Selection_State          :: feat_inter.Selection_State
Mouse_Selection          :: feat_inter.Selection_State
Normalized_Selection     :: feat_inter.Normalized_Selection

selection_normalize      :: feat_inter.selection_normalize
selection_contains_cell  :: feat_inter.selection_contains_cell
selection_row_bounds     :: feat_inter.selection_row_bounds
mouse_pixel_to_cell      :: feat_inter.pixel_to_cell
mouse_is_in_rect         :: feat_inter.is_in_rect

Clipboard_Bridge         :: feat_inter.Clipboard_Bridge
clipboard_init           :: feat_inter.clipboard_init
clipboard_set_text         :: feat_inter.clipboard_set_text
clipboard_set_text_guarded :: feat_inter.clipboard_set_text_guarded
clipboard_get_text         :: feat_inter.clipboard_get_text
clipboard_copy_selection :: feat_inter.clipboard_copy_selection
clipboard_paste          :: feat_inter.clipboard_paste

Mouse_State :: struct {
	pos:                 [2]f32,
	is_down:             bool,
	button:              u8,
	selection:           feat_inter.Selection_State,
	cell_w:              f32,
	cell_h:              f32,
	pad_x:               f32,
	pad_y:               f32,
	pending_start:       feat_inter.Cell_Pos,
	pending_pane:        u32,
	drag_started:        bool,
	is_dragging_divider: bool,
	drag_split_node:     ^chrome_splits.Split_Node,
	hovered_split_node:  ^chrome_splits.Split_Node,
	hovered_is_horiz:    bool,
}

mouse_init :: proc(m: ^Mouse_State, cell_w, cell_h: f32, pad_x: f32 = 12.0, pad_y: f32 = 8.0) {
	if m == nil do return
	m.pos = {0.0, 0.0}
	m.is_down = false
	m.button = 0
	m.cell_w = max(1.0, cell_w)
	m.cell_h = max(1.0, cell_h)
	m.pad_x = pad_x
	m.pad_y = pad_y
	m.drag_started = false
	m.is_dragging_divider = false
	m.drag_split_node = nil
	m.hovered_split_node = nil
	m.hovered_is_horiz = false
	feat_inter.selection_init(&m.selection)
}

mouse_on_button_down :: proc(
	m: ^Mouse_State,
	pos: [2]f32,
	button: u8,
	pane_id: u32,
	pane_rect: [4]f32,
	sess: ^sess_feat.Terminal_Session = nil,
	scroll_offset: int = 0,
	clicks: int = 1,
	is_shift: bool = false,
	is_alt: bool = false,
) {
	if m == nil do return
	m.pos = pos
	m.is_down = true
	m.button = button
	m.drag_started = false

	if button == sdl3.BUTTON_LEFT {
		screen_r, cell_c := feat_inter.pixel_to_cell(pos, pane_rect, m.cell_w, m.cell_h, m.pad_x, m.pad_y)
		cell_r := screen_r - scroll_offset

		// 1. Shift + Click: Extend existing selection
		if is_shift && m.selection.active && m.selection.pane_id == pane_id {
			m.selection.end_cell = {cell_r, cell_c}
			return
		}

		// 2. Triple Click: Select entire line via line_find_bounds
		if clicks >= 3 {
			cols := sess.term.cols if sess != nil else 80
			start_c, end_c := feat_inter.line_find_bounds(cols)
			m.selection.active = true
			m.selection.mode = .Line
			m.selection.pane_id = pane_id
			m.selection.start_cell = {row = cell_r, col = start_c}
			m.selection.end_cell = {row = cell_r, col = end_c}
			m.pending_start = m.selection.start_cell
			m.drag_started = true
			return
		}

		// 3. Double Click: Auto-select word under cursor via word_find_bounds
		if clicks == 2 {
			start_c, end_c := cell_c, cell_c
			if sess != nil {
				phy_r := terminal_grid.grid_physical_row(&sess.term.grid, cell_r)
				if phy_r < len(sess.term.grid.rows) {
					start_c, end_c = feat_inter.word_find_bounds(&sess.term.grid.rows[phy_r], cell_c)
				}
			}
			m.selection.active = true
			m.selection.mode = .Word
			m.selection.pane_id = pane_id
			m.selection.start_cell = {row = cell_r, col = start_c}
			m.selection.end_cell = {row = cell_r, col = end_c}
			m.pending_start = m.selection.start_cell
			m.drag_started = true
			return
		}

		// 4. Single Click: prepare drag selection (or Block mode if Alt/Option is held)
		m.selection.active = false
		m.selection.mode = .Block if is_alt else .Stream
		m.pending_start = {cell_r, cell_c}
		m.pending_pane  = pane_id
	}
}

mouse_on_motion :: proc(
	m: ^Mouse_State,
	pos: [2]f32,
	pane_rect: [4]f32,
	sess: ^sess_feat.Terminal_Session = nil,
	scroll_offset: int = 0,
) {
	if m == nil do return
	m.pos = pos

	if m.is_down && m.button == sdl3.BUTTON_LEFT {
		screen_r, cell_c := feat_inter.pixel_to_cell(pos, pane_rect, m.cell_w, m.cell_h, m.pad_x, m.pad_y)
		cell_r := screen_r - scroll_offset

		if !m.drag_started {
			if cell_r != m.pending_start.row || cell_c != m.pending_start.col {
				m.drag_started = true
				m.selection.active = true
				m.selection.pane_id = m.pending_pane
				m.selection.start_cell = m.pending_start
				m.selection.end_cell = {cell_r, cell_c}
			}
		} else {
			#partial switch m.selection.mode {
			case .Line:
				cols := sess.term.cols if sess != nil else 80
				_, end_c := feat_inter.line_find_bounds(cols)
				if cell_r >= m.pending_start.row {
					m.selection.start_cell = {row = m.pending_start.row, col = 0}
					m.selection.end_cell = {row = cell_r, col = end_c}
				} else {
					m.selection.start_cell = {row = cell_r, col = 0}
					m.selection.end_cell = {row = m.pending_start.row, col = end_c}
				}

			case .Word:
				if sess != nil {
					phy_r := terminal_grid.grid_physical_row(&sess.term.grid, cell_r)
					if phy_r < len(sess.term.grid.rows) {
						wb_start, wb_end := feat_inter.word_find_bounds(&sess.term.grid.rows[phy_r], cell_c)
						if cell_r > m.pending_start.row || (cell_r == m.pending_start.row && cell_c >= m.pending_start.col) {
							m.selection.start_cell = m.pending_start
							m.selection.end_cell = {row = cell_r, col = wb_end}
						} else {
							m.selection.start_cell = {row = cell_r, col = wb_start}
							m.selection.end_cell = m.pending_start
						}
						return
					}
				}
				m.selection.end_cell = {cell_r, cell_c}

			case: // .Stream, .Block
				m.selection.end_cell = {cell_r, cell_c}
			}
		}
	}
}

mouse_on_button_up :: proc(m: ^Mouse_State, button: u8) {
	if m == nil do return
	m.is_down = false
	m.drag_started = false

	if m.selection.mode == .Stream && m.selection.start_cell == m.selection.end_cell {
		m.selection.active = false
	}
}

mouse_clear_selection :: proc(m: ^Mouse_State) {
	if m == nil do return
	m.drag_started = false
	feat_inter.selection_clear(&m.selection)
}

mouse_select_all :: proc(m: ^Mouse_State, pane_id: u32, sess: ^sess_feat.Terminal_Session) {
	if m == nil || sess == nil do return
	g := &sess.term.grid
	m.selection.active = true
	m.selection.mode = .Stream
	m.selection.pane_id = pane_id
	m.selection.start_cell = {row = -g.history_count, col = 0}
	m.selection.end_cell = {row = sess.term.rows - 1, col = max(0, sess.term.cols - 1)}
	m.drag_started = false
}

mouse_keyboard_select :: proc(
	m: ^Mouse_State,
	pane_id: u32,
	sess: ^sess_feat.Terminal_Session,
	action: Action_Id,
) {
	if m == nil || sess == nil do return
	g := &sess.term.grid
	min_row := -g.history_count
	max_row := sess.term.rows - 1
	cols    := max(1, sess.term.cols)

	if !m.selection.active || m.selection.pane_id != pane_id {
		cur_r := sess.term.parser.cursor.row - sess.scroll_offset
		cur_c := clamp(sess.term.parser.cursor.col, 0, cols - 1)
		m.selection.active = true
		m.selection.mode = .Stream
		m.selection.pane_id = pane_id
		m.selection.start_cell = {row = cur_r, col = cur_c}
		m.selection.end_cell = m.selection.start_cell
	}

	#partial switch action {
	case .Select_Left:
		if m.selection.end_cell.col > 0 {
			m.selection.end_cell.col -= 1
		} else if m.selection.end_cell.row > min_row {
			m.selection.end_cell.row -= 1
			m.selection.end_cell.col = cols - 1
		}

	case .Select_Right:
		if m.selection.end_cell.col < cols - 1 {
			m.selection.end_cell.col += 1
		} else if m.selection.end_cell.row < max_row {
			m.selection.end_cell.row += 1
			m.selection.end_cell.col = 0
		}

	case .Select_Up:
		if m.selection.end_cell.row > min_row {
			m.selection.end_cell.row -= 1
		}

	case .Select_Down:
		if m.selection.end_cell.row < max_row {
			m.selection.end_cell.row += 1
		}

	case .Select_Line_Start:
		m.selection.end_cell.col = 0

	case .Select_Line_End:
		m.selection.end_cell.col = cols - 1

	case .Select_Word_Left:
		phy_r := terminal_grid.grid_physical_row(g, m.selection.end_cell.row)
		if phy_r < len(g.rows) {
			row := &g.rows[phy_r]
			c := m.selection.end_cell.col
			for c > 0 && feat_inter.char_class(row.cells[c - 1].char) == .Whitespace {
				c -= 1
			}
			if c > 0 {
				tc := feat_inter.char_class(row.cells[c - 1].char)
				for c > 0 && feat_inter.char_class(row.cells[c - 1].char) == tc {
					c -= 1
				}
			}
			m.selection.end_cell.col = c
		} else if m.selection.end_cell.col > 0 {
			m.selection.end_cell.col = max(0, m.selection.end_cell.col - 4)
		}

	case .Select_Word_Right:
		phy_r := terminal_grid.grid_physical_row(g, m.selection.end_cell.row)
		if phy_r < len(g.rows) {
			row := &g.rows[phy_r]
			c := m.selection.end_cell.col
			if c < len(row.cells) {
				tc := feat_inter.char_class(row.cells[c].char)
				for c < len(row.cells) && feat_inter.char_class(row.cells[c].char) == tc {
					c += 1
				}
			}
			for c < len(row.cells) && feat_inter.char_class(row.cells[c].char) == .Whitespace {
				c += 1
			}
			m.selection.end_cell.col = min(cols - 1, c)
		} else {
			m.selection.end_cell.col = min(cols - 1, m.selection.end_cell.col + 4)
		}
	}

	// Auto-scroll viewport if keyboard selection extends beyond screen top/bottom
	screen_r := m.selection.end_cell.row + sess.scroll_offset
	if screen_r < 0 {
		sess.scroll_offset = clamp(-m.selection.end_cell.row, 0, g.history_count)
	} else if screen_r >= sess.term.rows {
		sess.scroll_offset = clamp(sess.term.rows - 1 - m.selection.end_cell.row, 0, g.history_count)
	}
}
