package term

// Command Center scoring + row builders (one builder per mode).

import "core:fmt"
import "core:strings"
import sess_feat "../../features/session"

// command_center_score ranks title/description against an already lowercased query.
command_center_score :: proc(query_lower, title, description: string) -> int {
	q := query_lower
	if len(q) == 0 do return 1
	t := strings.to_lower(title, context.temp_allocator)
	if strings.has_prefix(t, q) do return 1000
	for i in 1..<len(t) {
		boundary := t[i - 1] == ' ' || t[i - 1] == '/' || t[i - 1] == '-' || t[i - 1] == '('
		if boundary && strings.has_prefix(t[i:], q) do return 700
	}
	if strings.contains(t, q) do return 400
	if strings.contains(strings.to_lower(description, context.temp_allocator), q) do return 150
	qi := 0
	for ti in 0..<len(t) do if qi < len(q) && t[ti] == q[qi] do qi += 1
	return 50 if qi == len(q) else 0
}

@(private = "file")
_push :: proc(cc: ^Command_Center_State, row: Command_Center_Row) -> bool {
	if cc.row_count >= COMMAND_CENTER_MAX_ROWS do return false
	cc.rows[cc.row_count] = row
	cc.row_count += 1
	return true
}

// _sort_rows is a stable insertion sort over rows[from:row_count].
@(private = "file")
_sort_rows :: proc(cc: ^Command_Center_State, src: Command_Center_Sources, less: proc(src: Command_Center_Sources, a, b: Command_Center_Row) -> bool) {
	for i in 1..<cc.row_count {
		key := cc.rows[i]
		j := i - 1
		for j >= 0 && less(src, key, cc.rows[j]) {
			cc.rows[j + 1] = cc.rows[j]
			j -= 1
		}
		cc.rows[j + 1] = key
	}
}

@(private = "file")
_by_score :: proc(_: Command_Center_Sources, a, b: Command_Center_Row) -> bool { return a.score > b.score }

@(private = "file")
_state_rank :: proc(e: ^sess_feat.Detached_Session_Entry) -> int {
	if e == nil do return 3
	switch e.state {
	case .Busy:   return 0
	case .Idle:   return 1
	case .Exited: return 2
	}
	return 3
}

// _by_session orders attention first, then Busy, Idle, Exited, then id.
@(private = "file")
_by_session :: proc(src: Command_Center_Sources, a, b: Command_Center_Row) -> bool {
	ea := sess_feat.session_registry_find(src.sessions, a.session_id)
	eb := sess_feat.session_registry_find(src.sessions, b.session_id)
	att_a, att_b := ea != nil && ea.attention, eb != nil && eb.attention
	if att_a != att_b do return att_a
	if _state_rank(ea) != _state_rank(eb) do return _state_rank(ea) < _state_rank(eb)
	return a.session_id < b.session_id
}

@(private = "file")
_build_command_groups :: proc(cc: ^Command_Center_State) {
	for cat in Action_Category {
		header_done := false
		for m in ACTION_CATALOG {
			if m.id == .Command_Center_Toggle || m.category != cat do continue
			if !header_done do header_done = _push(cc, {kind = .Header, category = cat})
			_ = _push(cc, {kind = .Action, category = cat, action = m.id, score = 1})
		}
	}
}

@(private = "file")
_build_command_matches :: proc(cc: ^Command_Center_State, src: Command_Center_Sources, q: string) {
	for m in ACTION_CATALOG {
		if m.id == .Command_Center_Toggle do continue
		if sc := command_center_score(q, m.title, m.description); sc > 0 {
			_ = _push(cc, {kind = .Action, category = m.category, action = m.id, score = sc})
		}
	}
	_sort_rows(cc, src, _by_score)
}

@(private = "file")
_build_tabs :: proc(cc: ^Command_Center_State, src: Command_Center_Sources, q: string) {
	if src.tabs == nil do return
	for &entry, i in src.tabs.entries {
		title := string(entry.title_buf[:entry.title_len]) if entry.title_len > 0 else "Shell"
		sc := command_center_score(q, title, "")
		if sc == 0 && fmt.tprintf("%d", i + 1) == q do sc = 1
		if sc > 0 do _ = _push(cc, {kind = .Tab, tab_index = i, score = sc})
	}
}

// command_center_session_label is the display/filter label of a background session.
command_center_session_label :: proc(sess: ^sess_feat.Terminal_Session) -> string {
	label := sess_feat.session_get_title(sess)
	return label if len(label) > 0 else "shell"
}

@(private = "file")
_build_sessions :: proc(cc: ^Command_Center_State, src: Command_Center_Sources, q: string) {
	if src.sessions == nil do return
	for e in src.sessions.entries {
		if sc := command_center_score(q, command_center_session_label(e.session), ""); sc > 0 {
			_ = _push(cc, {kind = .Session, session_id = e.id, score = sc})
		}
	}
	_sort_rows(cc, src, _by_session)
}

// command_center_build_rows fills rows for cc.mode and the current query.
command_center_build_rows :: proc(cc: ^Command_Center_State, src: Command_Center_Sources) {
	if cc == nil do return
	cc.row_count = 0
	q := strings.to_lower(text_input_as_string(&cc.input), context.temp_allocator)
	switch cc.mode {
	case .Commands:
		if len(q) == 0 do _build_command_groups(cc)
		else do _build_command_matches(cc, src, q)
	case .Tabs:
		_build_tabs(cc, src, q)
	case .Sessions:
		_build_sessions(cc, src, q)
	}
}
