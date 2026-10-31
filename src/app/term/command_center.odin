package term

// Command Center: Commands / Tabs / Sessions palette (state + input).
// Part of Tier 3 Application Shell (src/app/term/*).
// Invariant: fixed-size row storage; rows are rebuilt only on open, mode
// switch, query change or refresh (command_center_rank.odin).

import "vendor:sdl3"
import tabs_feat "../../features/tabs"
import sess_feat "../../features/session"

COMMAND_CENTER_MAX_ROWS     :: 160
COMMAND_CENTER_VISIBLE_CAP :: 9

Command_Center_Mode :: enum u8 { Commands, Tabs, Sessions }
Command_Center_Row_Kind :: enum u8 { Header, Action, Tab, Session }
Command_Center_Row :: struct {
	kind:       Command_Center_Row_Kind,
	category:   Action_Category,
	action:     Action_Id,
	tab_index:  int,
	session_id: u32,
	score:      int,
}

Command_Center_Outcome :: enum u8 { None, Run_Action, Select_Tab, Attach_Session, Kill_Session }

Command_Center_Result :: struct {
	outcome:    Command_Center_Outcome,
	action:     Action_Id,
	tab_index:  int,
	session_id: u32,
	handled:    bool,
}

Command_Center_Sources :: struct {
	tabs:     ^tabs_feat.Tabs_Manager,
	sessions: ^sess_feat.Session_Registry,
}

Command_Center_State :: struct {
	visible:       bool,
	mode:          Command_Center_Mode,
	input:         Text_Input,
	rows:          [COMMAND_CENTER_MAX_ROWS]Command_Center_Row,
	row_count:     int,
	selected_idx:  int,
	hover_idx:     int, // -1 when no row is hovered
	scroll_offset: int,
	accum_wheel:   f32,
	anim_t:        f32,
	closing:       bool,
	// Written by the renderer on every emit, read by click/motion hit tests.
	modal_rect:     [4]f32,
	search_rect:    [4]f32,
	chip_rects:     [Command_Center_Mode][4]f32,
	row_rects:      [COMMAND_CENTER_VISIBLE_CAP][4]f32,
	row_rect_idx:   [COMMAND_CENTER_VISIBLE_CAP]int,
	row_rect_count: int,
}

// _first_selectable returns the first non-header row (0 when none).
@(private = "file")
_first_selectable :: proc(cc: ^Command_Center_State) -> int {
	for i in 0..<cc.row_count do if cc.rows[i].kind != .Header do return i
	return 0
}

@(private = "file")
_adjust_scroll :: proc(cc: ^Command_Center_State) {
	if cc.selected_idx < cc.scroll_offset do cc.scroll_offset = cc.selected_idx
	if cc.selected_idx >= cc.scroll_offset + COMMAND_CENTER_VISIBLE_CAP {
		cc.scroll_offset = cc.selected_idx - (COMMAND_CENTER_VISIBLE_CAP - 1)
	}
	cc.scroll_offset = clamp(cc.scroll_offset, 0, max(0, cc.row_count - COMMAND_CENTER_VISIBLE_CAP))
}

// _select_row selects idx, or the first selectable row when idx is a header or out of range.
@(private = "file")
_select_row :: proc(cc: ^Command_Center_State, idx: int) {
	valid := idx >= 0 && idx < cc.row_count && cc.rows[idx].kind != .Header
	cc.selected_idx = idx if valid else _first_selectable(cc)
	cc.hover_idx = -1
	_adjust_scroll(cc)
}

// _rebuild rebuilds rows for the current mode/query and selects the initial row
// (the active tab in .Tabs, otherwise the first selectable row).
@(private = "file")
_rebuild :: proc(cc: ^Command_Center_State, src: Command_Center_Sources) {
	command_center_build_rows(cc, src)
	cc.scroll_offset, cc.accum_wheel = 0, 0
	target := -1
	if cc.mode == .Tabs && src.tabs != nil {
		for i in 0..<cc.row_count do if cc.rows[i].tab_index == src.tabs.model.active_idx do target = i
	}
	_select_row(cc, target)
}

@(private = "file")
_same_row :: proc(a, b: Command_Center_Row) -> bool {
	return a.kind == b.kind && a.action == b.action && a.tab_index == b.tab_index && a.session_id == b.session_id
}

@(private = "file")
_activate_row :: proc(cc: ^Command_Center_State, src: Command_Center_Sources, idx: int) -> Command_Center_Result {
	if idx < 0 || idx >= cc.row_count do return {handled = true}
	row := cc.rows[idx]
	res := Command_Center_Result{handled = true, action = row.action, tab_index = row.tab_index, session_id = row.session_id}
	switch row.kind {
	case .Header:  return res
	case .Action:  res.outcome = .Run_Action
	case .Tab:     res.outcome = .Select_Tab
	case .Session:
		entry := sess_feat.session_registry_find(src.sessions, row.session_id)
		if entry == nil || entry.state == .Exited do return res
		res.outcome = .Attach_Session
	}
	cc.visible = false
	return res
}

@(private = "file")
_switch_mode :: proc(cc: ^Command_Center_State, src: Command_Center_Sources, back: bool) {
	n := len(Command_Center_Mode)
	cc.mode = Command_Center_Mode((int(cc.mode) + (n - 1 if back else 1)) % n)
	text_input_clear(&cc.input)
	_rebuild(cc, src)
}

// _step moves the selection by dir (±1) to the next non-header row, wrapping.
@(private = "file")
_step :: proc(cc: ^Command_Center_State, dir: int) {
	if cc.row_count == 0 do return
	idx := cc.selected_idx
	for _ in 0..<cc.row_count {
		idx = (idx + dir + cc.row_count) % cc.row_count
		if cc.rows[idx].kind != .Header do break
	}
	_select_row(cc, idx)
}

@(private = "file")
_row_at :: proc(cc: ^Command_Center_State, mx, my: f32) -> int {
	for i in 0..<cc.row_rect_count {
		if tab_bar_point_in(cc.row_rects[i], mx, my) do return cc.row_rect_idx[i]
	}
	return -1
}

command_center_init :: proc(cc: ^Command_Center_State) {
	if cc == nil do return
	cc^ = {}
	cc.hover_idx = -1
	text_input_init(&cc.input)
}

command_center_open :: proc(cc: ^Command_Center_State, mode: Command_Center_Mode, src: Command_Center_Sources) {
	if cc == nil do return
	cc.visible = true
	cc.mode = mode
	text_input_clear(&cc.input)
	_rebuild(cc, src)
}

command_center_toggle :: proc(cc: ^Command_Center_State, mode: Command_Center_Mode, src: Command_Center_Sources) {
	if cc == nil do return
	if cc.visible && cc.mode == mode do command_center_close(cc)
	else do command_center_open(cc, mode, src)
}

command_center_close :: proc(cc: ^Command_Center_State) {
	if cc == nil do return
	cc.visible = false
}

// command_center_refresh rebuilds rows keeping the selected row when it survives.
command_center_refresh :: proc(cc: ^Command_Center_State, src: Command_Center_Sources) {
	if cc == nil do return
	had := cc.selected_idx < cc.row_count
	prev := cc.rows[cc.selected_idx] if had else Command_Center_Row{}
	command_center_build_rows(cc, src)
	target := -1
	for i in 0..<cc.row_count do if had && _same_row(cc.rows[i], prev) do target = i
	_select_row(cc, target)
}

command_center_handle_wheel :: proc(cc: ^Command_Center_State, dy: f32) {
	if cc == nil || !cc.visible || cc.row_count <= COMMAND_CENTER_VISIBLE_CAP do return
	cc.accum_wheel += dy
	step := int(cc.accum_wheel)
	if step == 0 do return
	cc.accum_wheel -= f32(step)
	cc.scroll_offset = clamp(cc.scroll_offset - step, 0, cc.row_count - COMMAND_CENTER_VISIBLE_CAP)
}

command_center_handle_key :: proc(cc: ^Command_Center_State, key: sdl3.Keycode, mod: sdl3.Keymod, src: Command_Center_Sources) -> Command_Center_Result {
	if cc == nil || !cc.visible do return {}
	switch key {
	case sdl3.K_ESCAPE:
		command_center_close(cc)
		return {handled = true}
	case sdl3.K_TAB:
		_switch_mode(cc, src, (mod & sdl3.KMOD_SHIFT) != sdl3.KMOD_NONE)
		return {handled = true}
	case sdl3.K_DOWN, sdl3.K_UP:
		_step(cc, 1 if key == sdl3.K_DOWN else -1)
		return {handled = true}
	case sdl3.K_RETURN, sdl3.K_KP_ENTER:
		return _activate_row(cc, src, cc.selected_idx)
	}
	if cc.mode == .Sessions && key == sdl3.K_BACKSPACE && (mod & sdl3.KMOD_GUI) != sdl3.KMOD_NONE {
		if cc.selected_idx < cc.row_count && cc.rows[cc.selected_idx].kind == .Session {
			return {outcome = .Kill_Session, session_id = cc.rows[cc.selected_idx].session_id, handled = true}
		}
		return {handled = true}
	}
	changed, handled := text_input_handle_key(&cc.input, key, mod)
	if changed do command_center_refresh(cc, src)
	return {handled = handled}
}

command_center_handle_text :: proc(cc: ^Command_Center_State, text: string, src: Command_Center_Sources) {
	if cc == nil || !cc.visible do return
	if text_input_insert(&cc.input, text) do command_center_refresh(cc, src)
}

command_center_handle_click :: proc(cc: ^Command_Center_State, mx, my: f32, src: Command_Center_Sources) -> Command_Center_Result {
	if cc == nil || !cc.visible do return {}
	for m in Command_Center_Mode {
		if !tab_bar_point_in(cc.chip_rects[m], mx, my) do continue
		cc.mode = m
		text_input_clear(&cc.input)
		_rebuild(cc, src)
		return {handled = true}
	}
	if idx := _row_at(cc, mx, my); idx >= 0 do return _activate_row(cc, src, idx)
	if !tab_bar_point_in(cc.modal_rect, mx, my) do command_center_close(cc)
	return {handled = true}
}

command_center_handle_motion :: proc(cc: ^Command_Center_State, mx, my: f32) -> (changed: bool) {
	if cc == nil || !cc.visible do return false
	idx := _row_at(cc, mx, my)
	if idx >= 0 && cc.rows[idx].kind == .Header do idx = -1
	changed = idx != cc.hover_idx
	cc.hover_idx = idx
	return
}
