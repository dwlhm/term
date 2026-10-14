package feature_interaction

// feature_interaction: Ingestion of keyboard and mouse events, spatial routing,
// text selection, and 3D orbit controls.
// Part of Tier 2 Feature Composition Layer.

import "base:runtime"
import chrome_hit "../../core/chrome/hit_test"
import chrome_splits "../../core/chrome/splits"
import chrome_tabs "../../core/chrome/tabs"
import three_d "../../core/render/three_d"
import tabs "../tabs"
import multiplexer "../multiplexer"
import session "../session"

Modifier_Flags :: bit_set[Modifier_Key]
Modifier_Key :: enum {
	Shift,
	Ctrl,
	Alt,
	Cmd,
}

Interaction_Mode :: enum {
	Idle,
	Dragging_Divider,
	Selecting_Text,
	Interacting_3D,
}

Cell_Pos :: struct {
	row: int,
	col: int,
}

Text_Selection :: struct {
	active:     bool,
	pane_id:    u32,
	start_cell: Cell_Pos,
	end_cell:   Cell_Pos,
}

Action_Kind :: enum {
	None,
	Tab_Selected,
	Tab_Closed,
	Tab_New_Requested,
	Pane_Focused,
	Pane_Split_Requested,
	Pane_Toggle_3D_Requested,
	Text_Copied,
}

Interaction_Action :: struct {
	kind:    Action_Kind,
	index:   int,
	pane_id: u32,
}

Interaction_State :: struct {
	mode:             Interaction_Mode,
	selection:        Text_Selection,
	dragged_node:     ^chrome_splits.Split_Node,
	cell_width:       f32,
	cell_height:      f32,
	last_mouse_pos:   [2]f32,
	clipboard_buf:    [4096]u8,
	clipboard_len:    int,
}

interaction_init :: proc(s: ^Interaction_State, cell_w: f32 = 8.5, cell_h: f32 = 17.0) {
	if s == nil do return
	s.mode = .Idle
	s.selection.active = false
	s.dragged_node = nil
	s.cell_width = max(1.0, cell_w)
	s.cell_height = max(1.0, cell_h)
	s.last_mouse_pos = {0.0, 0.0}
	s.clipboard_len = 0
}

interaction_on_mouse_down :: proc(
	s: ^Interaction_State,
	tm: ^tabs.Tabs_Manager,
	mux: ^multiplexer.Multiplexer,
	pos: [2]f32,
	button: int,
	mods: Modifier_Flags,
) -> Interaction_Action {
	if s == nil || tm == nil || mux == nil do return {kind = .None}

	s.last_mouse_pos = pos

	// Query hit test
	_, active_tab := tabs.tabs_manager_get_active(tm)
	split_root: ^chrome_splits.Split_Node = active_tab.split_tree if active_tab != nil else nil

	hit := chrome_hit.chrome_hit_test(&tm.model, split_root, pos)

	switch hit.kind {
	case .Tab_Header:
		tabs.tabs_manager_select_tab(tm, hit.index)
		return Interaction_Action{kind = .Tab_Selected, index = hit.index}

	case .Tab_Close:
		tabs.tabs_manager_close_tab(tm, hit.index)
		return Interaction_Action{kind = .Tab_Closed, index = hit.index}

	case .Split_Divider:
		// Start dragging divider
		s.mode = .Dragging_Divider
		s.dragged_node = split_root
		return {kind = .None}

	case .Pane:
		multiplexer.multiplexer_focus_pane(mux, hit.pane_id)
		pane := multiplexer.multiplexer_get_pane(mux, hit.pane_id)
		if pane != nil {
			if pane.kind == .Three_D {
				s.mode = .Interacting_3D
				three_d.interactor_on_mouse_down(&pane.interactor, pos.x, pos.y, button)
			} else if pane.kind == .Terminal {
				s.mode = .Selecting_Text
				s.selection.active = true
				s.selection.pane_id = hit.pane_id
				c_x := int((pos.x - pane.rect[0]) / s.cell_width)
				c_y := int((pos.y - pane.rect[1]) / s.cell_height)
				s.selection.start_cell = {row = max(0, c_y), col = max(0, c_x)}
				s.selection.end_cell = s.selection.start_cell
			}
		}
		return Interaction_Action{kind = .Pane_Focused, pane_id = hit.pane_id}

	case .None, .Modal:
		return {kind = .None}
	}

	return {kind = .None}
}

interaction_on_mouse_move :: proc(
	s: ^Interaction_State,
	mux: ^multiplexer.Multiplexer,
	pos: [2]f32,
	mods: Modifier_Flags,
) {
	if s == nil || mux == nil do return
	s.last_mouse_pos = pos

	switch s.mode {
	case .Dragging_Divider:
		if s.dragged_node != nil && s.dragged_node.kind != .Leaf {
			if s.dragged_node.kind == .Horizontal {
				rel_x := pos.x - s.dragged_node.rect[0]
				new_ratio := rel_x / max(1.0, s.dragged_node.rect[2])
				s.dragged_node.ratio = clamp(new_ratio, 0.1, 0.9)
			} else if s.dragged_node.kind == .Vertical {
				rel_y := pos.y - s.dragged_node.rect[1]
				new_ratio := rel_y / max(1.0, s.dragged_node.rect[3])
				s.dragged_node.ratio = clamp(new_ratio, 0.1, 0.9)
			}
		}

	case .Selecting_Text:
		pane := multiplexer.multiplexer_get_pane(mux, s.selection.pane_id)
		if pane != nil {
			c_x := int((pos.x - pane.rect[0]) / s.cell_width)
			c_y := int((pos.y - pane.rect[1]) / s.cell_height)
			s.selection.end_cell = {row = max(0, c_y), col = max(0, c_x)}
		}

	case .Interacting_3D:
		pane := multiplexer.multiplexer_get_focused_pane(mux)
		if pane != nil && pane.kind == .Three_D {
			is_shift := .Shift in mods
			three_d.interactor_on_mouse_move(&pane.interactor, pos.x, pos.y, is_shift)
		}

	case .Idle:
		break
	}
}

interaction_on_mouse_up :: proc(
	s: ^Interaction_State,
	mux: ^multiplexer.Multiplexer,
	button: int,
) {
	if s == nil || mux == nil do return

	switch s.mode {
	case .Dragging_Divider:
		s.mode = .Idle
		s.dragged_node = nil

	case .Selecting_Text:
		s.mode = .Idle

	case .Interacting_3D:
		pane := multiplexer.multiplexer_get_focused_pane(mux)
		if pane != nil && pane.kind == .Three_D {
			three_d.interactor_on_mouse_up(&pane.interactor, button)
		}
		s.mode = .Idle

	case .Idle:
		break
	}
}

interaction_on_mouse_wheel :: proc(
	s: ^Interaction_State,
	mux: ^multiplexer.Multiplexer,
	dy: f32,
) {
	if s == nil || mux == nil do return
	pane := multiplexer.multiplexer_get_focused_pane(mux)
	if pane != nil && pane.kind == .Three_D {
		three_d.interactor_on_mouse_wheel(&pane.interactor, dy)
	}
}

interaction_on_key_press :: proc(
	s: ^Interaction_State,
	tm: ^tabs.Tabs_Manager,
	mux: ^multiplexer.Multiplexer,
	key_char: rune,
	mods: Modifier_Flags,
) -> Interaction_Action {
	if s == nil || tm == nil || mux == nil do return {kind = .None}

	// 1. Process Command / Control shortcuts
	if .Cmd in mods || .Ctrl in mods {
		switch key_char {
		case 't', 'T':
			return Interaction_Action{kind = .Tab_New_Requested}
		case 'w', 'W':
			act_idx, _ := tabs.tabs_manager_get_active(tm)
			if act_idx >= 0 {
				tabs.tabs_manager_close_tab(tm, act_idx)
				return Interaction_Action{kind = .Tab_Closed, index = act_idx}
			}
		case 'd':
			return Interaction_Action{kind = .Pane_Split_Requested}
		case '3':
			// 3D canvas toggle shortcut: Cmd+Shift+3 or Cmd+3
			return Interaction_Action{kind = .Pane_Toggle_3D_Requested}
		case 'c', 'C':
			// Copy selection
			if s.selection.active {
				pane := multiplexer.multiplexer_get_pane(mux, s.selection.pane_id)
				if pane != nil && pane.session != nil {
					// Copy selected text into clipboard_buf
					s.clipboard_len = 0
					min_r := min(s.selection.start_cell.row, s.selection.end_cell.row)
					max_r := max(s.selection.start_cell.row, s.selection.end_cell.row)
					min_c := min(s.selection.start_cell.col, s.selection.end_cell.col)
					max_c := max(s.selection.start_cell.col, s.selection.end_cell.col)

					for r in min_r..=max_r {
						for c in min_c..=max_c {
							ch := session.session_get_cell(pane.session, r, c).char
							if s.clipboard_len < len(s.clipboard_buf) - 4 {
								s.clipboard_buf[s.clipboard_len] = u8(ch) if (ch >= 32 && ch <= 126) else ' '
								s.clipboard_len += 1
							}
						}
						if r < max_r && s.clipboard_len < len(s.clipboard_buf) - 1 {
							s.clipboard_buf[s.clipboard_len] = '\n'
							s.clipboard_len += 1
						}
					}
					return Interaction_Action{kind = .Text_Copied}
				}
			}
		}
	}

	// 2. Normal key routed to active terminal session PTY
	pane := multiplexer.multiplexer_get_focused_pane(mux)
	if pane != nil && pane.kind == .Terminal && pane.session != nil {
		buf: [4]u8
		if key_char >= 0 && key_char <= 127 {
			buf[0] = u8(key_char)
			_, _ = session.session_write(pane.session, buf[:1])
		}
	}

	return {kind = .None}
}
