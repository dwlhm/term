package ui

import "core:text/regex"
import "core:unicode"
import "core:unicode/utf8"

import inter "../interaction"
import termgrid "../terminal"
import input "../platform/input"

// Search_Hit_Target identifies interactive elements within the floating search bar.
Search_Hit_Target :: enum u8 {
	None = 0,
	Input_Field,
	Btn_Prev,
	Btn_Next,
	Btn_Case,
	Btn_Regex,
	Btn_Word,
	Btn_Close,
}

// Search_Action represents an actionable search operation.
Search_Action :: enum u8 {
	None = 0,
	Query_Changed,
	Next_Match,
	Prev_Match,
	Close,
}

// Search_Bar_State manages the interactive floating search card.
Search_Bar_State :: struct {
	visible:          bool,
	rect:             Rect_f32,
	query:            [256]u8,
	query_len:        int,
	match_count:      int,
	match_idx:        int,
	case_sensitive:   bool,
	use_regex:        bool,
	whole_word:       bool,
	is_invalid_regex: bool,
	hover_target:     Search_Hit_Target,
	active_target:    Search_Hit_Target,
}

// search_bar_init resets search bar fields to neutral hidden state.
search_bar_init :: proc(state: ^Search_Bar_State) {
	if state == nil do return
	state.visible = false
	state.rect = Rect_f32{}
	state.query_len = 0
	state.match_count = 0
	state.match_idx = 0
	state.case_sensitive = false
	state.use_regex = false
	state.whole_word = false
	state.is_invalid_regex = false
	state.hover_target = .None
	state.active_target = .None
}

SEARCH_BAR_MARGIN_RIGHT: f32 : 16.0
SEARCH_BAR_MARGIN_TOP:   f32 : 8.0
BTN_CTRL_WIDTH:          f32 : 28.0

// search_bar_layout calculates the positioned floating card rectangle.
search_bar_layout :: proc(state: ^Search_Bar_State, window_w: f32) {
	if state == nil do return
	x := window_w - SEARCH_BAR_W - SEARCH_BAR_MARGIN_RIGHT
	if x < 0 do x = 0
	y := TAB_BAR_HEIGHT + SEARCH_BAR_MARGIN_TOP
	state.rect = Rect_f32{
		x = x,
		y = y,
		w = SEARCH_BAR_W,
		h = SEARCH_BAR_H,
	}
}

// search_bar_dispatch_key consumes keyboard events for typing queries and navigating matches.
search_bar_dispatch_key :: proc(state: ^Search_Bar_State, ev: input.Input_Event) -> (consumed: bool, action: Search_Action) {
	if state == nil || !state.visible do return false, .None
	if ev.event_type != .Key do return false, .None
	if ev.is_release do return true, .None

	#partial switch ev.kind {
	case .Escape:
		state.visible = false
		return true, .Close

	case .Enter:
		if ev.shift {
			return true, .Prev_Match
		}
		return true, .Next_Match

	case .Backspace:
		if state.query_len > 0 {
			last_size := 1
			for offset := state.query_len - 1; offset >= 0; offset -= 1 {
				if (state.query[offset] & 0xC0) != 0x80 {
					last_size = state.query_len - offset
					break
				}
			}
			state.query_len = max(0, state.query_len - last_size)
			return true, .Query_Changed
		}
		return true, .None

	case .Printable:
		buf, bytes := utf8.encode_rune(ev.rune)
		if state.query_len + bytes <= len(state.query) {
			copy(state.query[state.query_len:], buf[:bytes])
			state.query_len += bytes
			return true, .Query_Changed
		}
		return true, .None
	}

	return true, .None
}

_search_bar_hit_target :: proc(state: ^Search_Bar_State, px, py: f32) -> Search_Hit_Target {
	if !point_in_rect(px, py, state.rect) do return .None

	r := state.rect
	close_r := Rect_f32{x = r.x + r.w - 28.0, y = r.y, w = 28.0, h = r.h}
	if point_in_rect(px, py, close_r) do return .Btn_Close

	next_r := Rect_f32{x = r.x + r.w - 52.0, y = r.y, w = 24.0, h = r.h}
	if point_in_rect(px, py, next_r) do return .Btn_Next

	prev_r := Rect_f32{x = r.x + r.w - 76.0, y = r.y, w = 24.0, h = r.h}
	if point_in_rect(px, py, prev_r) do return .Btn_Prev

	return .Input_Field
}

// search_bar_dispatch_pointer processes clicks on buttons and text field within search bar.
search_bar_dispatch_pointer :: proc(state: ^Search_Bar_State, px, py: f32, is_down: bool) -> (consumed: bool, action: Search_Action) {
	if state == nil || !state.visible do return false, .None
	if !point_in_rect(px, py, state.rect) do return false, .None

	target := _search_bar_hit_target(state, px, py)
	state.hover_target = target

	if is_down {
		state.active_target = target
		switch target {
		case .Btn_Close:
			state.visible = false
			return true, .Close
		case .Btn_Prev:
			return true, .Prev_Match
		case .Btn_Next:
			return true, .Next_Match
		case .Btn_Case:
			state.case_sensitive = !state.case_sensitive
			return true, .Query_Changed
		case .Btn_Regex:
			state.use_regex = !state.use_regex
			return true, .Query_Changed
		case .Btn_Word:
			state.whole_word = !state.whole_word
			return true, .Query_Changed
		case .Input_Field, .None:
			return true, .None
		}
	}

	return true, .None
}

SEARCH_MAX_SCAN_STEPS :: 100_000

// search_bar_execute_scan runs the query against the terminal grid without panics, respecting regex and bounds.
search_bar_execute_scan :: proc(state: ^Search_Bar_State, term: ^termgrid.Terminal, out_matches: []inter.Search_Match) -> int {
	if state == nil || term == nil || len(out_matches) == 0 {
		return 0
	}
	if state.query_len == 0 {
		state.match_count = 0
		state.match_idx = 0
		state.is_invalid_regex = false
		return 0
	}

	query_str := string(state.query[:state.query_len])

	if state.use_regex {
		rx, err := regex.create(query_str, flags = {})
		if err != nil {
			state.is_invalid_regex = true
			state.match_count = 0
			state.match_idx = 0
			return 0
		}
		defer regex.destroy(rx)
		state.is_invalid_regex = false

		total_rows := termgrid.scrollback_len(&term.scrollback) + term.grid.row_count
		cols := min(term.grid.col_count, 1024)
		count := 0
		steps := 0

		row_buf: [1024]u8

		for r in 0 ..< total_rows {
			if steps >= SEARCH_MAX_SCAN_STEPS || count >= len(out_matches) {
				break
			}
			row_len := 0
			for c in 0 ..< cols {
				cell := termgrid.terminal_view_get_document_cell(term, termgrid.Terminal_Point{row = r, col = c})
				if u8(cell.flags) & u8(termgrid.Cell_Flags.Wide_Continuation) != 0 {
					continue
				}
				ch: rune = ' '
				if cell.content != 0 {
					if termgrid.content_is_grapheme(cell.content) {
						ch = termgrid.grapheme_resolve_base(cell.content, &term.grapheme_store)
					} else {
						ch = rune(cell.content)
					}
				}
				if ch > 0 && ch < 128 && row_len < len(row_buf) {
					row_buf[row_len] = u8(ch)
					row_len += 1
				}
			}

			if row_len == 0 do continue
			steps += row_len

			res, match_ok := regex.match(rx, string(row_buf[:row_len]))
			if match_ok && count < len(out_matches) {
				out_matches[count] = inter.Search_Match{
					row       = r,
					col_start = 0,
					col_end   = max(0, row_len - 1),
				}
				count += 1
			}
		}

		state.match_count = count
		if state.match_count > 0 {
			state.match_idx = clamp(state.match_idx, 0, state.match_count - 1)
		} else {
			state.match_idx = 0
		}
		return count
	}

	state.is_invalid_regex = false
	count := inter.interaction_search_scan(term, query_str, out_matches)
	state.match_count = count
	if state.match_count > 0 {
		state.match_idx = clamp(state.match_idx, 0, state.match_count - 1)
	} else {
		state.match_idx = 0
	}
	return count
}
