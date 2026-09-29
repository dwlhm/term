package ui

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
}

// ui_shortcut_label returns the display label for an action. All glyphs used
// here are pinned in the render atlas (see src/render/atlas_prewarm.odin).
ui_shortcut_label :: proc(a: Shortcut_Action) -> string {
	switch a {
	case .New_Tab:        return "\u2318T"
	case .Close_Tab:      return "\u2318D"
	case .Close_Others:   return "\u2325\u2318D"
	case .Close_To_Right: return "\u2325\u21E7\u2318D"
	case .Rename_Tab:     return "\u2318R"
	case .Next_Tab:       return "\u2303\u21E5"
	case .Prev_Tab:       return "\u2303\u21E7\u21E5"
	case .Search:         return "\u2318F"
	case .Zoom_In:        return "\u2318+"
	case .Zoom_Out:       return "\u2318-"
	case .Reload_Config:  return "\u21E7\u2318R"
	case .Overflow:       return "\u21E7\u2318\\"
	case .Window_Zoom:    return "\u2303\u2318Z"
	case .Confirm:        return "\u21B5"
	case .Cancel:         return "esc"
	case .Search_Prev:    return "\u21E7\u21B5"
	case .Search_Next:    return "\u21B5"
	case .Search_Close:   return "esc"
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
