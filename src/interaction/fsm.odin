package interaction

import termgrid "../terminal"

// interaction_init initializes an Interaction_State to default Passthrough Live state.
interaction_init :: proc(s: ^Interaction_State) {
	if s == nil do return
	s^ = Interaction_State{
		mode          = .Passthrough,
		visual_kind   = .Char,
		viewport_flow = .Live,
	}
}

// interaction_enter_visual transitions the state into Visual mode with the specified kind and origin point.
interaction_enter_visual :: proc(s: ^Interaction_State, kind: Visual_Kind, origin: termgrid.Terminal_Point) {
	if s == nil do return
	s.mode = .Visual
	s.visual_kind = kind
	s.viewport_flow = .Paused
	s.selection_anchor = origin
	s.visual_cursor = origin
	s.selection_active = true
}

// interaction_enter_search transitions the state into Search mode.
interaction_enter_search :: proc(s: ^Interaction_State) {
	if s == nil do return
	s.mode = .Search
	s.viewport_flow = .Paused
	s.search_active = true
}

// interaction_exit_to_passthrough transitions from Visual or Search back to Passthrough mode,
// resetting active selection and search flags. Returns snap_to_live indicating whether the viewport
// was paused and should snap back to the live prompt.
interaction_exit_to_passthrough :: proc(s: ^Interaction_State) -> (snap_to_live: bool) {
	if s == nil do return false
	was_paused := s.viewport_flow == .Paused || s.mode != .Passthrough
	s.mode = .Passthrough
	s.selection_active = false
	s.search_active = false
	interaction_resume_viewport(s)
	return was_paused
}

// interaction_pause_viewport sets viewport flow to Paused with the given initial offset.
interaction_pause_viewport :: proc(s: ^Interaction_State, offset: int) {
	if s == nil do return
	s.viewport_flow = .Paused
	s.paused_offset = offset
	s.paused_lines_accumulated = 0
}

// interaction_resume_viewport restores viewport flow to Live and resets paused counters.
interaction_resume_viewport :: proc(s: ^Interaction_State) {
	if s == nil do return
	s.viewport_flow = .Live
	s.paused_offset = 0
	s.paused_lines_accumulated = 0
}

// interaction_on_scrollback_push anchors a paused viewport while retaining
// document coordinates on append and rebasing them only on history eviction.
interaction_on_scrollback_push :: proc(s: ^Interaction_State, lines_added: int, lines_evicted: int = 0) {
	if s == nil || lines_added <= 0 do return
	if s.viewport_flow != .Paused do return

	s.paused_offset += lines_added
	s.paused_lines_accumulated += lines_added
	evicted := max(0, lines_evicted)
	if evicted == 0 do return
	if s.selection_active {
		s.selection_anchor.row -= evicted
		s.visual_cursor.row -= evicted
		if s.selection_anchor.row < 0 || s.visual_cursor.row < 0 {
			s.selection_active = false
		}
	}
	if s.search_active && s.search_match_count > 0 {
		count := 0
		selected := -1
		for i in 0 ..< s.search_match_count {
			match := s.search_matches[i]
			match.row -= evicted
			if match.row < 0 do continue
			if i == s.search_match_idx { selected = count }
			s.search_matches[count] = match
			count += 1
		}
		s.search_match_count = count
		s.search_match_idx = 0
		if count > 0 { s.search_match_idx = max(0, selected) }
	}
}
