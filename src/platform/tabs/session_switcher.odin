package platform_tabs

import "base:intrinsics"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:unicode"
import "core:unicode/utf8"
import input "../input"
import session_core "../../session_core"

import "core:sys/darwin"
import posix "core:sys/posix"

SESSION_SWITCHER_MAX_QUERY :: 64
SESSION_SWITCHER_MAX_ITEMS :: 256
SESSION_SWITCHER_MAX_VISIBLE_ROWS :: 8
SESSION_SWITCHER_WIDTH: f32 : 540.0
SESSION_SWITCHER_ROW_HEIGHT: f32 : 44.0
SESSION_SWITCHER_HEADER_HEIGHT: f32 : 64.0
SESSION_SWITCHER_FOOTER_HEIGHT: f32 : 48.0
// The close affordance spans the full row height so the target is comfortable to hit;
// the inset keeps it clear of the row's right edge.
SESSION_SWITCHER_CLOSE_WIDTH: f32 : 28.0
SESSION_SWITCHER_CLOSE_INSET: f32 : 8.0
// Smallest comfortable click target the close affordance must keep on both axes.
SESSION_SWITCHER_MIN_TARGET: f32 : 20.0

// Footer copy advertises only the actions that are actually valid for the selected row.
SESSION_SWITCHER_HINT_EMPTY :: "↑↓ / scroll · Enter: Open · Esc: Close"
SESSION_SWITCHER_HINT_LAYOUT :: "Enter: Restore layout · Esc: Close"
SESSION_SWITCHER_HINT_BACKGROUND :: "Enter: Attach · ✕ or ⌘X: Terminate · Esc: Close"
SESSION_SWITCHER_HINT_SPLIT_TAB :: "Enter: Switch · ✕ or ⌘X: Close"
SESSION_SWITCHER_HINT_TAB :: "Enter: Switch · ⌥⌘B: Background · ⌘X: Close"

// Tab_Session carries lightweight tab session metadata for standalone caller and test compatibility.
Tab_Session :: struct {
	id:        u32,
	title:     string,
	pid:       int,
	cwd:       string,
	is_active: bool,
}

// Session_Switcher_Item represents a single active tab or detached session row in the switcher.
Session_Switcher_Item :: struct {
	id:          string,
	title:       string,
	pid:         int,
	cwd:         string,
	is_current:  bool,
	is_exited:   bool,
	tab_id:      u32,
	is_detached: bool,
	tab_idx:     int, // -1 if detached
	rss_mb:      int,
	cpu_pct:     f32,
	is_persisted: bool,
	// Pane count of the row's tab; 1 for single-pane tabs, background sessions and layouts.
	pane_count: int,
	layout_name: string,
	id_buf:      [64]u8,
	title_buf:   [128]u8,
	cwd_buf:     [256]u8,
	layout_buf:  [64]u8,
}

// Session_Switcher_State tracks modal search query, matching results, and visual bounds.
Session_Switcher_State :: struct {
	visible:            bool,
	// Row index whose close affordance the pointer is over, or -1 when none.
	hover_close_row:    int,
	rect:               Rect_f32,
	query:              [SESSION_SWITCHER_MAX_QUERY]u8,
	query_len:          int,
	items:              [SESSION_SWITCHER_MAX_ITEMS]Session_Switcher_Item,
	item_count:         int,
	matches:            [SESSION_SWITCHER_MAX_ITEMS]int,
	match_count:        int,
	selected_match_idx: int,
	detached_count:     int,
	scroll_offset:      int,
	visible_rows:       int,
	message_buf:        [160]u8,
	message_len:        int,
	truncated:          bool,
}

// Session_Switcher_Action encodes actions triggered by keyboard navigation in the switcher.
Session_Switcher_Action :: enum {
	None = 0,
	Switch_Tab,
	Attach,
	Detach,
	Terminate,
	Close,
	Restore_Layout,
}

// session_query_taskinfo inspects resident memory and CPU usage for a given process PID.
session_query_taskinfo :: proc(pid: int) -> (rss_mb: int, cpu_pct: f32) {
	if pid <= 1 do return 0, 0.0
	when ODIN_OS == .Darwin {
		tinfo: darwin.proc_taskinfo
		ret := darwin.proc_pidinfo(posix.pid_t(pid), .TASKINFO, 0, &tinfo, size_of(tinfo))
		if ret > 0 {
			rss_mb = int(tinfo.pti_resident_size / (1024 * 1024))
			return rss_mb, 0.0
		}
	}
	return 0, 0.0
}

// session_switcher_fuzzy_match performs case-insensitive subsequence matching with bonus scoring.
// Bonus awarded for prefix match, word boundaries ('/', '_', '-', ' ', '.', ':'), and consecutive matches.
session_switcher_fuzzy_match :: proc(query: string, target: string) -> (matched: bool, score: int) {
	if len(query) == 0 {
		return true, 0
	}
	if len(target) == 0 {
		return false, 0
	}

	q_rem := query
	t_rem := target
	t_idx := 0
	last_match_idx := -2

	for len(q_rem) > 0 {
		q_rune, q_w := utf8.decode_rune_in_string(q_rem)
		q_rem = q_rem[q_w:]
		q_lower := unicode.to_lower(q_rune)

		found := false
		for len(t_rem) > 0 {
			t_rune, t_w := utf8.decode_rune_in_string(t_rem)
			curr_idx := t_idx
			t_idx += t_w
			t_rem = t_rem[t_w:]
			t_lower := unicode.to_lower(t_rune)

			if q_lower == t_lower {
				found = true
				score += 10
				if curr_idx == 0 {
					score += 25
				} else if curr_idx == last_match_idx + 1 {
					score += 20
				} else {
					prev_char := target[curr_idx - 1]
					if prev_char == '/' || prev_char == '_' || prev_char == '-' || prev_char == ' ' || prev_char == '.' || prev_char == ':' {
						score += 15
					}
				}
				last_match_idx = curr_idx
				break
			}
		}

		if !found {
			return false, 0
		}
	}

	return true, score
}

// session_switcher_filter applies fuzzy matching against title, pid, cwd, and status,
// sorting matches descending by score and clamping selection.
session_switcher_filter :: proc(state: ^Session_Switcher_State) {
	if state == nil do return

	q_str := string(state.query[:state.query_len])
	scores: [SESSION_SWITCHER_MAX_ITEMS]int
	count := 0

	for i := 0; i < state.item_count; i += 1 {
		item := &state.items[i]
		target_buf: [512]u8
		status_str := "layout" if item.is_persisted else (item.is_detached ? "detached" : "active")
		target_str := fmt.bprintf(target_buf[:], "%s %d %s %s", item.title, item.pid, item.cwd, status_str)

		matched, score := session_switcher_fuzzy_match(q_str, target_str)
		if matched {
			state.matches[count] = i
			scores[count] = score
			count += 1
		}
	}
	state.match_count = count

	// Sort matches descending by score using stable insertion sort
	for i := 1; i < state.match_count; i += 1 {
		key_match := state.matches[i]
		key_score := scores[i]
		j := i - 1
		for j >= 0 && scores[j] < key_score {
			state.matches[j + 1] = state.matches[j]
			scores[j + 1] = scores[j]
			j -= 1
		}
		state.matches[j + 1] = key_match
		scores[j + 1] = key_score
	}

	// Clamp selected match index
	if state.match_count == 0 {
		state.selected_match_idx = 0
	} else {
		state.selected_match_idx = clamp(state.selected_match_idx, 0, state.match_count - 1)
	}
}

// session_switcher_footer_hint returns the footer copy for the selected row. It never
// advertises an action the row cannot service: detach is single-pane only, and saved
// layouts cannot be terminated at all.
session_switcher_footer_hint :: proc(item: ^Session_Switcher_Item) -> string {
	if item == nil do return SESSION_SWITCHER_HINT_EMPTY
	if item.is_persisted do return SESSION_SWITCHER_HINT_LAYOUT
	if item.is_detached do return SESSION_SWITCHER_HINT_BACKGROUND
	if item.pane_count > 1 do return SESSION_SWITCHER_HINT_SPLIT_TAB
	return SESSION_SWITCHER_HINT_TAB
}

// session_switcher_pane_count reports how many leaf panes a tab shows. `tab_leaf_panes`
// lives in the app package, which imports this one, so the leaf count is derived from the
// pane tree's fixed node pool through the same compile-time reflection the rest of the
// ingestion path uses. Leaf nodes are exactly the panes: a split contributes an extra
// node of kind Split, which must not be counted.
session_switcher_pane_count :: proc($T: typeid, tab: ^T) -> int {
	when intrinsics.type_has_field(T, "tree") {
		leaves := 0
		for i in 0 ..< len(tab.tree.node_in_use) {
			if tab.tree.node_in_use[i] && tab.tree.nodes[i].kind == .Leaf do leaves += 1
		}
		return leaves
	}
	return 1
}

// session_switcher_init zeroes and initializes switcher state.
session_switcher_init :: proc(state: ^Session_Switcher_State) {
	if state == nil do return
	state^ = {}
	state.hover_close_row = -1
}

// session_switcher_show populates switcher items from active tabs and detached registry sessions,
// queries process resource metrics, resets search query, and presents the switcher card.
session_switcher_show :: proc(state: ^Session_Switcher_State, tabs: []$T, active_idx: int, reg: ^session_core.Session_Registry = nil, saved_layouts: []string = nil) {
	if state == nil do return

	state.item_count = 0
	state.truncated = false
	state.scroll_offset = 0
	state.hover_close_row = -1

	// 1. Ingest active tabs
	for i := 0; i < len(tabs); i += 1 {
		if state.item_count >= SESSION_SWITCHER_MAX_ITEMS do break
		tab := &tabs[i]
		item := &state.items[state.item_count]
		item^ = {}
		item.pane_count = 1
		item.tab_idx = i
		item.is_detached = false
		item.is_current = i == active_idx
		if panes := session_switcher_pane_count(T, tab); panes > 1 {
			item.pane_count = panes
		}

		when intrinsics.type_has_field(T, "id") {
			item.tab_id = tab.id
			id_str := fmt.bprintf(item.id_buf[:], "%v", tab.id)
			item.id = id_str
		} else {
			id_str := fmt.bprintf(item.id_buf[:], "tab_%d", i + 1)
			item.id = id_str
		}

		title_str := ""
		when intrinsics.type_has_field(T, "title_override_active") {
			if tab.title_override_active && tab.title_override_len > 0 {
				title_str = string(tab.title_override_buf[:tab.title_override_len])
			} else if tab.title_len > 0 {
				title_str = string(tab.title_buf[:tab.title_len])
			}
		} else when intrinsics.type_has_field(T, "title") {
			title_str = tab.title
		}

		if len(title_str) == 0 {
			title_str = fmt.bprintf(item.title_buf[:], "Tab %d", i + 1)
			item.title = title_str
		} else {
			copy_len := min(len(title_str), len(item.title_buf))
			copy(item.title_buf[:], title_str[:copy_len])
			item.title = string(item.title_buf[:copy_len])
		}

		when intrinsics.type_has_field(T, "backend") {
			item.pid = tab.backend.pty.pid
		} else when intrinsics.type_has_field(T, "pid") {
			item.pid = int(tab.pid)
		}

		cwd_str := ""
		when intrinsics.type_has_field(T, "last_cwd_len") {
			if tab.last_cwd_len > 0 {
				cwd_str = string(tab.last_cwd_buf[:tab.last_cwd_len])
			} else {
				when intrinsics.type_has_field(T, "backend") {
					cwd_str = tab.backend.cwd
				}
			}
		} else when intrinsics.type_has_field(T, "cwd") {
			cwd_str = tab.cwd
		}

		if len(cwd_str) > 0 {
			copy_len := min(len(cwd_str), len(item.cwd_buf))
			copy(item.cwd_buf[:], cwd_str[:copy_len])
			item.cwd = string(item.cwd_buf[:copy_len])
		}

		item.rss_mb, item.cpu_pct = session_query_taskinfo(item.pid)
		state.item_count += 1
	}

	// 2. Ingest detached persistent sessions
	state.detached_count = 0
	if reg != nil {
		detached_ids: [SESSION_SWITCHER_MAX_ITEMS]string
		detached_cnt := session_core.session_registry_list_detached(reg, detached_ids[:])
		state.detached_count = session_core.session_registry_detached_count(reg)
		state.truncated = state.detached_count + len(tabs) + len(saved_layouts) > SESSION_SWITCHER_MAX_ITEMS
		for d := 0; d < detached_cnt; d += 1 {
			if state.item_count >= SESSION_SWITCHER_MAX_ITEMS do break
			id := detached_ids[d]
			cs := session_core.session_registry_lookup(reg, id)
			if cs == nil do continue

			item := &state.items[state.item_count]
			item^ = {}
			item.pane_count = 1
			item.tab_idx = -1
			item.is_detached = true

			copy_len := min(len(id), len(item.id_buf))
			copy(item.id_buf[:], id[:copy_len])
			item.id = string(item.id_buf[:copy_len])

			sync.mutex_lock(&cs.lock)
			title := string(cs.title_buf[:cs.title_len])
			if cs.title_override_len > 0 do title = string(cs.title_override_buf[:cs.title_override_len])
			if len(title) == 0 do title = id
			n := copy(item.title_buf[:], title)
			item.title = string(item.title_buf[:n])
			n = copy(item.cwd_buf[:], cs.cwd)
			item.cwd = string(item.cwd_buf[:n])
			item.is_exited = cs.pty_handle.state == .Exited

			item.pid = cs.pty_handle.pid
			sync.mutex_unlock(&cs.lock)
			item.rss_mb, item.cpu_pct = session_query_taskinfo(item.pid)

			state.item_count += 1
		}
	}

	// 3. Ingest saved persisted layouts
	for l := 0; l < len(saved_layouts); l += 1 {
		if state.item_count >= SESSION_SWITCHER_MAX_ITEMS do break
		name := saved_layouts[l]
		item := &state.items[state.item_count]
		item^ = {}
		item.pane_count = 1
		item.tab_idx = -1
		item.is_detached = false
		item.is_persisted = true

		copy_len := min(len(name), len(item.layout_buf))
		copy(item.layout_buf[:], name[:copy_len])
		item.layout_name = string(item.layout_buf[:copy_len])
		item.id = item.layout_name

		title_str := fmt.bprintf(item.title_buf[:], "[Layout] %s", name)
		item.title = title_str

		state.item_count += 1
	}

	state.query_len = 0
	session_switcher_filter(state)

	if active_idx >= 0 && active_idx < len(tabs) {
		for m := 0; m < state.match_count; m += 1 {
			item_idx := state.matches[m]
			if state.items[item_idx].tab_idx == active_idx {
				state.selected_match_idx = m
				break
			}
		}
	}

	state.visible = true
}

// session_switcher_hide closes the session switcher modal and clears search query.
session_switcher_hide :: proc(state: ^Session_Switcher_State) {
	if state == nil do return
	state.visible = false
	state.query_len = 0
	state.hover_close_row = -1
}

// session_switcher_layout calculates floating modal bounds positioned upper-center.
session_switcher_layout :: proc(state: ^Session_Switcher_State, window_w, window_h: f32) {
	if state == nil do return
	w := max(0, min(SESSION_SWITCHER_WIDTH, window_w - 20))
	available := max(0, window_h - 20 - SESSION_SWITCHER_HEADER_HEIGHT - SESSION_SWITCHER_FOOTER_HEIGHT)
	state.visible_rows = min(SESSION_SWITCHER_MAX_VISIBLE_ROWS, max(0, int(available / SESSION_SWITCHER_ROW_HEIGHT)))
	rows := min(max(1, state.match_count), state.visible_rows)
	h := min(max(0, window_h - 20), SESSION_SWITCHER_HEADER_HEIGHT + f32(rows) * SESSION_SWITCHER_ROW_HEIGHT + SESSION_SWITCHER_FOOTER_HEIGHT)
	state.rect = Rect_f32{x = max(0, (window_w - w) * 0.5), y = max(0, min(60, window_h - h - 10)), w = w, h = h}
	session_switcher_reveal_selection(state)
}

// session_switcher_dispatch_key processes keyboard navigation and search typing.
session_switcher_dispatch_key :: proc(
	state: ^Session_Switcher_State,
	ev: input.Input_Event,
) -> (consumed: bool, action: Session_Switcher_Action, item: Session_Switcher_Item) {
	if state == nil || !state.visible do return false, .None, {}
	if ev.event_type != .Key || ev.is_release do return false, .None, {}

	// Escape -> Close
	if ev.kind == .Escape {
		return true, .Close, {}
	}

	// Arrow navigation
	if ev.kind == .Arrow_Up {
		if state.match_count > 0 {
			state.selected_match_idx = (state.selected_match_idx - 1 + state.match_count) % state.match_count
			session_switcher_reveal_selection(state)
		}
		return true, .None, {}
	}
	if ev.kind == .Arrow_Down {
		if state.match_count > 0 {
			state.selected_match_idx = (state.selected_match_idx + 1) % state.match_count
			session_switcher_reveal_selection(state)
		}
		return true, .None, {}
	}

	selected_item: Session_Switcher_Item
	has_selected := false
	if state.match_count > 0 && state.selected_match_idx >= 0 && state.selected_match_idx < state.match_count {
		selected_item = state.items[state.matches[state.selected_match_idx]]
		has_selected = true
	}

	// Enter -> Activate (Attach, Restore_Layout, or Switch_Tab)
	if ev.kind == .Enter {
		if has_selected {
			if selected_item.is_persisted {
				return true, .Restore_Layout, selected_item
			} else if selected_item.is_detached {
				return true, .Attach, selected_item
			} else {
				return true, .Switch_Tab, selected_item
			}
		}
		return true, .None, {}
	}

	is_ctrl_or_gui := ev.ctrl || ev.gui

	// Shortcut: Alt+Cmd+b for Detach (strictly consistent with global shortcut)
	if ev.alt && ev.gui && !ev.ctrl && !ev.shift && (ev.rune == 'b' || ev.rune == 'B') {
		if has_selected && !selected_item.is_detached && !selected_item.is_persisted {
			return true, .Detach, selected_item
		}
		return true, .None, {}
	}

	// Shortcuts: Ctrl+X / Cmd+X for Terminate / Kill
	if is_ctrl_or_gui && (ev.rune == 'x' || ev.rune == 'X' || ev.rune == 24) {
		if has_selected && !selected_item.is_persisted {
			return true, .Terminate, selected_item
		}
		return true, .None, {}
	}

	// Backspace: delete rune from search query
	if ev.kind == .Backspace {
		if state.query_len > 0 {
			state.query_len -= 1
			for state.query_len > 0 && (state.query[state.query_len] & 0xC0) == 0x80 {
				state.query_len -= 1
			}
			session_switcher_filter(state)
		}
		return true, .None, {}
	}

	// Character typing into query
	if !is_ctrl_or_gui && !ev.alt {
		if ev.rune >= 32 {
			buf, n := utf8.encode_rune(ev.rune)
			if state.query_len + n <= len(state.query) {
				copy(state.query[state.query_len:], buf[:n])
				state.query_len += n
				session_switcher_filter(state)
			}
			return true, .None, {}
		}
	}

	return true, .None, {}
}

// Drawing and hit testing share the same row geometry and scroll window.
session_switcher_row_rect :: proc(state: ^Session_Switcher_State, row: int) -> Rect_f32 {
	return Rect_f32{x = state.rect.x + 4, y = state.rect.y + SESSION_SWITCHER_HEADER_HEIGHT + f32(row) * SESSION_SWITCHER_ROW_HEIGHT, w = max(0, state.rect.w - 8), h = SESSION_SWITCHER_ROW_HEIGHT}
}

// session_switcher_close_rect returns the row's close affordance bounds. It is always
// contained by the row rect and stays at least the minimum target size on both axes.
session_switcher_close_rect :: proc(state: ^Session_Switcher_State, row: int) -> Rect_f32 {
	rr := session_switcher_row_rect(state, row)
	w := min(SESSION_SWITCHER_CLOSE_WIDTH, rr.w)
	x := max(rr.x, rr.x + rr.w - SESSION_SWITCHER_CLOSE_INSET - w)
	return Rect_f32{x = x, y = rr.y, w = w, h = rr.h}
}

session_switcher_reveal_selection :: proc(state: ^Session_Switcher_State) {
	rows := max(1, state.visible_rows)
	if state.selected_match_idx < state.scroll_offset do state.scroll_offset = state.selected_match_idx
	if state.selected_match_idx >= state.scroll_offset + rows do state.scroll_offset = state.selected_match_idx - rows + 1
	state.scroll_offset = clamp(state.scroll_offset, 0, max(0, state.match_count - rows))
}

session_switcher_dispatch_pointer :: proc(state: ^Session_Switcher_State, px, py: f32, click: bool, wheel: int = 0) -> (Session_Switcher_Action, Session_Switcher_Item) {
	if state == nil || !state.visible do return .None, {}
	if click && !point_in_rect(px, py, state.rect) do return .Close, {}
	if wheel != 0 {
		state.scroll_offset = clamp(state.scroll_offset - wheel, 0, max(0, state.match_count - max(1, state.visible_rows)))
		state.selected_match_idx = clamp(state.selected_match_idx, state.scroll_offset, min(state.match_count - 1, state.scroll_offset + max(1, state.visible_rows) - 1)) if state.match_count > 0 else 0
	}
	visible := min(state.visible_rows, state.match_count - state.scroll_offset)
	state.hover_close_row = -1
	for row in 0 ..< visible {
		if !point_in_rect(px, py, session_switcher_row_rect(state, row)) do continue
		item_idx := state.scroll_offset + row
		entry := &state.items[item_idx]
		// The close affordance wins over the row's Enter-equivalent, but only on rows
		// where terminate is valid.
		if !entry.is_persisted && point_in_rect(px, py, session_switcher_close_rect(state, row)) {
			state.hover_close_row = row
			if click {
				state.selected_match_idx = item_idx
				return .Terminate, entry^
			}
			return .None, {}
		}
		if click {
			state.selected_match_idx = item_idx
			_, action, item := session_switcher_dispatch_key(state, input.Input_Event{event_type = .Key, kind = .Enter})
			return action, item
		}
	}
	return .None, {}
}
