package interaction

import "core:unicode/utf8"
import input "../platform/input"
import termgrid "../terminal"

// interaction_dispatch_key routes keyboard input through the modal FSM.
// Passthrough mode passes standard typing and control keys straight through to the PTY
// while intercepting dedicated GUI shortcuts (Cmd+F, Cmd+Shift+Space, Cmd+C, Cmd+V).
// Visual and Search modes consume all relevant keystrokes for modal interaction.
interaction_dispatch_key :: proc(s: ^Interaction_State, ev: input.Input_Event, is_alt_screen: bool) -> (consumed: bool, action: Interaction_Action) {
	if s == nil do return false, .None
	if ev.is_release do return s.mode != .Passthrough, .None

	switch s.mode {
	case .Passthrough:
		// GUI shortcuts have top priority
		if ev.gui {
			if ev.shift && ev.rune == ' ' {
				interaction_enter_visual(s, .Char, s.visual_cursor)
				return true, .None
			}
			if ev.rune == 'f' || ev.rune == 'F' {
				interaction_enter_search(s)
				return true, .None
			}
			if ev.rune == 'c' || ev.rune == 'C' {
				if s.selection_active {
					return true, .Copy
				}
			}
			if ev.rune == 'v' || ev.rune == 'V' {
				return true, .Paste
			}
		}
		// Normal typing, Esc, Ctrl keys flow straight to PTY
		return false, .None

	case .Visual:
		// Esc or 'q' exits Visual back to Live Passthrough
		if ev.kind == .Escape || (!ev.ctrl && !ev.gui && (ev.rune == 'q' || ev.rune == 'Q')) {
			_ = interaction_exit_to_passthrough(s)
			return true, .Resume_Live
		}

		// Yank / Copy: 'y', Enter, or Cmd+C
		if (!ev.ctrl && !ev.gui && ev.rune == 'y') || ev.kind == .Enter || (ev.gui && (ev.rune == 'c' || ev.rune == 'C')) {
			_ = interaction_exit_to_passthrough(s)
			return true, .Copy
		}

		// Visual sub-kind switches
		if ev.ctrl && (ev.rune == 'v' || ev.rune == 'V') {
			s.visual_kind = .Block
			return true, .None
		}
		if !ev.ctrl && !ev.gui {
			if ev.rune == 'v' && !ev.shift {
				s.visual_kind = .Char
				return true, .None
			}
			if ev.rune == 'V' || (ev.shift && ev.rune == 'v') {
				s.visual_kind = .Line
				return true, .None
			}
			if ev.rune == '/' {
				interaction_enter_search(s)
				return true, .None
			}
		}

		// Cursor navigation in Visual mode
		if ev.kind == .Arrow_Left || (!ev.ctrl && !ev.gui && ev.rune == 'h') {
			s.visual_cursor.col = max(0, s.visual_cursor.col - 1)
			return true, .None
		}
		if ev.kind == .Arrow_Right || (!ev.ctrl && !ev.gui && ev.rune == 'l') {
			s.visual_cursor.col += 1
			return true, .None
		}
		if ev.kind == .Arrow_Up || (!ev.ctrl && !ev.gui && ev.rune == 'k') {
			s.visual_cursor.row = max(0, s.visual_cursor.row - 1)
			return true, .None
		}
		if ev.kind == .Arrow_Down || (!ev.ctrl && !ev.gui && ev.rune == 'j') {
			s.visual_cursor.row += 1
			return true, .None
		}
		if ev.kind == .Home || (!ev.ctrl && !ev.gui && (ev.rune == '0' || ev.rune == '^')) {
			s.visual_cursor.col = 0
			return true, .None
		}
		if ev.kind == .End || (!ev.ctrl && !ev.gui && ev.rune == '$') {
			s.visual_cursor.col = 999999
			return true, .None
		}
		if !ev.ctrl && !ev.gui && (ev.rune == 'w' || ev.rune == 'e') {
			s.visual_cursor.col += 1
			return true, .None
		}
		if !ev.ctrl && !ev.gui && ev.rune == 'b' {
			s.visual_cursor.col = max(0, s.visual_cursor.col - 1)
			return true, .None
		}

		_ = interaction_exit_to_passthrough(s)
		return true, .Resume_Live

	case .Search:
		if ev.kind == .Escape {
			_ = interaction_exit_to_passthrough(s)
			return true, .Resume_Live
		}

		// Next match: Enter (no shift) or 'n'
		if (ev.kind == .Enter && !ev.shift) || (!ev.ctrl && !ev.gui && ev.rune == 'n') {
			if s.search_match_count > 0 {
				s.search_match_idx = (s.search_match_idx + 1) % s.search_match_count
			}
			return true, .Scroll_To_Match
		}

		// Prev match: Shift+Enter or 'N'
		if (ev.kind == .Enter && ev.shift) || (!ev.ctrl && !ev.gui && (ev.rune == 'N' || (ev.shift && ev.rune == 'n'))) {
			if s.search_match_count > 0 {
				s.search_match_idx = (s.search_match_idx - 1 + s.search_match_count) % s.search_match_count
			}
			return true, .Scroll_To_Match
		}

		// Backspace
		if ev.kind == .Backspace {
			if s.search_len > 0 {
				s.search_len -= 1
				s.search_query[s.search_len] = 0
			}
			return true, .None
		}

		// Printable character append
		if ev.kind == .Printable && !ev.ctrl && !ev.gui {
			buf, n := utf8.encode_rune(ev.rune)
			if s.search_len + n < len(s.search_query) {
				copy(s.search_query[s.search_len:], buf[:n])
				s.search_len += n
				s.search_query[s.search_len] = 0
			}
			return true, .None
		}

		return true, .None
	}

	return false, .None
}

// interaction_dispatch_pointer routes mouse / pointer events into the interaction layer.
// Respects alt_screen pass-through unless Shift is held.
interaction_dispatch_pointer :: proc(s: ^Interaction_State, ev: input.Input_Pointer_Event, is_alt_screen: bool, rows, cols: int, cell_w, cell_h: int) -> (consumed: bool, action: Interaction_Action) {
	if s == nil do return false, .None

	// TUI apps maintain full control in alt_screen unless Shift is held
	if is_alt_screen && !ev.shift {
		return false, .None
	}

	col := cell_w > 0 ? int(ev.x) / cell_w : 0
	row := cell_h > 0 ? int(ev.y) / cell_h : 0
	col = clamp(col, 0, max(0, cols - 1))
	row = clamp(row, 0, max(0, rows - 1))
	pt := termgrid.Terminal_Point{row = row, col = col}

	switch ev.kind {
	case .Button_Down:
		if ev.button == 1 {
			if ev.gui {
				return true, .Open_Link
			}
			clicks := ev.clicks == 0 ? 1 : ev.clicks
			if clicks >= 3 {
				interaction_enter_visual(s, .Line, pt)
				return true, .None
			} else if clicks == 2 {
				interaction_enter_visual(s, .Char, pt)
				return true, .None
			} else {
				if s.mode == .Visual {
					s.selection_anchor = pt
					s.visual_cursor = pt
					return true, .None
				}
				s.selection_anchor = pt
				s.visual_cursor = pt
				return false, .None
			}
		}

	case .Motion:
		if ev.primary_down {
			if s.mode == .Passthrough {
				interaction_enter_visual(s, .Char, s.selection_anchor)
				s.visual_cursor = pt
				return true, .None
			}
			if s.mode == .Visual {
				s.visual_cursor = pt
				return true, .None
			}
		}

	case .Button_Up:
		if ev.button == 1 {
			if s.mode == .Visual && s.selection_active {
				s.visual_cursor = pt
				return true, .None
			}
		}

	case .Wheel:
		return false, .None
	}

	return false, .None
}

// interaction_dispatch_mouse delegates an Input_Event carrying pointer data to interaction_dispatch_pointer.
interaction_dispatch_mouse :: proc(s: ^Interaction_State, ev: input.Input_Event, is_alt_screen: bool, rows, cols: int, cell_w, cell_h: int) -> (consumed: bool, action: Interaction_Action) {
	if ev.event_type != .Pointer {
		return false, .None
	}
	return interaction_dispatch_pointer(s, ev.pointer, is_alt_screen, rows, cols, cell_w, cell_h)
}
