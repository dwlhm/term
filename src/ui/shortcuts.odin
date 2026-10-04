package ui

import "../platform/input"

// Shortcut_Action enumerates every user-triggerable chrome action that has a
// keyboard equivalent. Labels are the single source of truth for both key
// routing hints and the context menu.
Shortcut_Action :: enum u8 {
	New_Tab,
	Close_Tab,
	Close_Others,
	Close_To_Right,
	Rename_Tab,
	Next_Tab,
	Prev_Tab,
	Search,
	Zoom_In,
	Zoom_Out,
	Reload_Config,
	Overflow,
	Window_Zoom,
	Confirm,
	Cancel,
	Search_Prev,
	Search_Next,
	Search_Close,
	Detach_Tab,
	Attach_Session,
	Split_Vertical,
	Split_Horizontal,
	Pane_Resize_Left,
	Pane_Resize_Right,
	Pane_Resize_Up,
	Pane_Resize_Down,
	Pane_Equalize,
	Pane_Zoom,
	Pane_Prev,
	Pane_Next,
	Toggle_Devtools,
}

// ui_shortcut_label returns the display label for an action. All glyphs used
// here are pinned in the render atlas (see src/render/atlas_prewarm.odin).
ui_shortcut_label :: proc(a: Shortcut_Action) -> string {
	switch a {
	case .New_Tab:           return "\u2318T"
	case .Close_Tab:         return "\u2318D"
	case .Close_Others:      return "\u2325\u2318D"
	case .Close_To_Right:    return "\u2325\u21E7\u2318D"
	case .Rename_Tab:        return "\u2318R"
	case .Next_Tab:          return "\u2303\u21E5"
	case .Prev_Tab:          return "\u2303\u21E7\u21E5"
	case .Search:            return "\u2318F"
	case .Zoom_In:           return "\u2318+"
	case .Zoom_Out:          return "\u2318-"
	case .Reload_Config:     return "\u21E7\u2318R"
	case .Overflow:          return "\u21E7\u2318\\"
	case .Window_Zoom:       return "\u2303\u2318Z"
	case .Confirm:           return "\u21B5"
	case .Cancel:            return "esc"
	case .Search_Prev:       return "\u21E7\u21B5"
	case .Search_Next:       return "\u21B5"
	case .Search_Close:      return "esc"
	case .Detach_Tab:        return "\u2325\u2318B"
	case .Attach_Session:    return "\u2318O"
	case .Split_Vertical:    return "\u2318\\"
	case .Split_Horizontal:  return "\u2325\u2318\\"
	case .Pane_Resize_Left:  return "\u2325\u21E7\u2318\u2190"
	case .Pane_Resize_Right: return "\u2325\u21E7\u2318\u2192"
	case .Pane_Resize_Up:    return "\u2325\u21E7\u2318\u2191"
	case .Pane_Resize_Down:  return "\u2325\u21E7\u2318\u2193"
	case .Pane_Equalize:     return "\u2325\u2318="
	case .Pane_Zoom:         return "\u21E7\u2318\u21B5"
	case .Pane_Prev:         return "\u2318["
	case .Pane_Next:         return "\u2318]"
	case .Toggle_Devtools:   return "\u2325\u2318I"
	}
	return ""
}

_TAB_SHORTCUT_LABELS := [9]string{
	"\u23181", "\u23182", "\u23183", "\u23184", "\u23185",
	"\u23186", "\u23187", "\u23188", "\u23189",
}

// ui_shortcut_tab_label returns the direct-select label for tab index i of
// count, or "" when the tab has no direct shortcut (⌘1..⌘8, last tab ⌘9).
ui_shortcut_tab_label :: proc(i, count: int) -> string {
	if i < 0 || i >= count do return ""
	if i < 8 do return _TAB_SHORTCUT_LABELS[i]
	if i == count - 1 do return _TAB_SHORTCUT_LABELS[8]
	return ""
}

// _TAB_BAR_HINTS are the always-visible trailing tab-bar shortcut hints.
_TAB_BAR_HINTS := [3]Shortcut_Action{.New_Tab, .Close_Tab, .Overflow}

// ui_shortcut_matches owns exact physical shortcut routing and ignores releases.
ui_shortcut_matches :: proc(action: Shortcut_Action, ev: input.Input_Event) -> bool {
	if ev.event_type != .Key || ev.is_release do return false
	gui, alt, shift, ctrl := true, false, false, false
	key := false
	#partial switch action {
	case .Split_Vertical: key = ev.rune == '\\'
	case .Split_Horizontal: key = ev.rune == '\\'
		alt = true
	case .Overflow: key = ev.rune == '\\'
		shift = true
	case .Pane_Prev: key = ev.rune == '['
	case .Pane_Next: key = ev.rune == ']'
	case .Pane_Equalize: key = ev.rune == '='
		alt = true
	case .Pane_Zoom: key = ev.kind == .Enter
		shift = true
	case .Pane_Resize_Left: key = ev.kind == .Arrow_Left
		alt = true
		shift = true
	case .Pane_Resize_Right: key = ev.kind == .Arrow_Right
		alt = true
		shift = true
	case .Pane_Resize_Up: key = ev.kind == .Arrow_Up
		alt = true
		shift = true
	case .Pane_Resize_Down: key = ev.kind == .Arrow_Down
		alt = true
		shift = true
	case .Next_Tab: key = ev.kind == .Tab
		gui = false
		ctrl = true
	case .Prev_Tab: key = ev.kind == .Tab
		gui = false
		ctrl = true
		shift = true
	case .Toggle_Devtools: key = ev.rune == 'i'
		alt = true
	case: return false
	}
	return key && ev.gui == gui && ev.alt == alt && ev.shift == shift && ev.ctrl == ctrl
}
