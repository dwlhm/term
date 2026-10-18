package term

// Centralized Keyboard Keymap Registry & Action Dispatcher
// Part of Tier 3 Application Shell (src/app/term/*).
// Invariant: Zero side-effect coupling to WGPU or PTY internals.

import "vendor:sdl3"

Action_Id :: enum {
	None,
	Command_Center_Toggle,
	Tab_New,
	Tab_Close,
	Tab_Next,
	Tab_Prev,
	Tab_Overview_Toggle,
	Tab_Select_1,
	Tab_Select_2,
	Tab_Select_3,
	Tab_Select_4,
	Tab_Select_5,
	Tab_Select_6,
	Tab_Select_7,
	Tab_Select_8,
	Tab_Select_9,
	Pane_Split_Right,
	Pane_Split_Down,
	Pane_Close,
	Pane_Focus_Next,
	Pane_Focus_Prev,
	Pane_Toggle_Zoom,
	Scroll_Page_Up,
	Scroll_Page_Down,
	Scroll_Line_Up,
	Scroll_Line_Down,
	Scroll_To_Top,
	Scroll_To_Bottom,
	Scroll_Clear,
	Clipboard_Copy,
	Clipboard_Paste,
	Select_All,
	Select_Left,
	Select_Right,
	Select_Up,
	Select_Down,
	Select_Word_Left,
	Select_Word_Right,
	Select_Line_Start,
	Select_Line_End,
	Font_Zoom_In,
	Font_Zoom_Out,
	Font_Zoom_Reset,
	Toggle_Fullscreen,
	App_Quit,
	App_Reload_Config,
}

Action_Metadata :: struct {
	id:           Action_Id,
	title:        string,
	shortcut:     string,
	description:  string,
}

ACTION_CATALOG := []Action_Metadata{
	{.Command_Center_Toggle, "Command Center / Spotlight", "⌘K / ⇧⌘P", "Open command search palette"},
	{.Tab_New,               "New Tab",                    "⌘T",       "Open a new terminal tab"},
	{.Tab_Close,             "Close Tab",                  "⌘W",       "Close the active tab"},
	{.Tab_Next,              "Next Tab",                   "^Tab",     "Switch to the next tab"},
	{.Tab_Prev,              "Previous Tab",               "⇧^Tab",    "Switch to previous tab"},
	{.Tab_Overview_Toggle,   "Show All Tabs",              "⇧⌘A / ⇧⌘O","Open tab overview and quick switcher"},
	{.Pane_Split_Right,      "Split Pane Right",           "⌘D",       "Split terminal horizontally"},
	{.Pane_Split_Down,       "Split Pane Down",            "⇧⌘D",      "Split terminal vertically"},
	{.Pane_Close,            "Close Pane",                 "⇧⌘W",      "Close active split pane"},
	{.Pane_Focus_Next,       "Focus Next Pane",            "⌘]",       "Move focus to next pane"},
	{.Pane_Focus_Prev,       "Focus Previous Pane",        "⌘[",       "Move focus to previous pane"},
	{.Pane_Toggle_Zoom,      "Toggle Maximize Pane",       "⇧⌘Enter",  "Maximize or restore pane"},
	{.Scroll_Page_Up,        "Scroll Page Up",             "⇧PgUp",    "Scroll history page up"},
	{.Scroll_Page_Down,      "Scroll Page Down",           "⇧PgDn",    "Scroll history page down"},
	{.Scroll_Clear,          "Clear Scrollback",           "⌘K",       "Clear terminal screen and buffer"},
	{.Clipboard_Copy,        "Copy Text",                  "⌘C",       "Copy selected text"},
	{.Clipboard_Paste,       "Paste Text",                 "⌘V",       "Paste text into terminal"},
	{.Select_All,            "Select All Text",            "⌘A",       "Select all terminal text"},
	{.Select_Left,           "Select Character Left",      "⇧←",       "Expand selection left"},
	{.Select_Right,          "Select Character Right",     "⇧→",       "Expand selection right"},
	{.Select_Up,             "Select Line Up",             "⇧↑",       "Expand selection up"},
	{.Select_Down,           "Select Line Down",           "⇧↓",       "Expand selection down"},
	{.Select_Word_Left,      "Select Word Left",           "⇧⌥←",      "Expand selection word left"},
	{.Select_Word_Right,     "Select Word Right",          "⇧⌥→",      "Expand selection word right"},
	{.Select_Line_Start,     "Select to Line Start",       "⇧⌘←",      "Expand selection to line start"},
	{.Select_Line_End,       "Select to Line End",         "⇧⌘→",      "Expand selection to line end"},
	{.Font_Zoom_In,          "Zoom In Font",               "⌘+",       "Increase terminal text size"},
	{.Font_Zoom_Out,         "Zoom Out Font",              "⌘-",       "Decrease terminal text size"},
	{.Font_Zoom_Reset,       "Reset Font Zoom",            "⌘0",       "Reset terminal text size"},
	{.Toggle_Fullscreen,     "Toggle Fullscreen",          "^⌘F",      "Toggle fullscreen mode"},
	{.App_Quit,              "Quit Term",                  "⌘Q",       "Gracefully quit Term"},
}

action_get_metadata :: proc(id: Action_Id) -> (Action_Metadata, bool) {
	for m in ACTION_CATALOG {
		if m.id == id do return m, true
	}
	return Action_Metadata{id = .None, title = "", shortcut = "", description = ""}, false
}

keymap_evaluate :: proc(key: sdl3.Keycode, mod: sdl3.Keymod) -> (Action_Id, bool) {
	is_cmd   := (mod & sdl3.KMOD_GUI)   != sdl3.KMOD_NONE
	is_ctrl  := (mod & sdl3.KMOD_CTRL)  != sdl3.KMOD_NONE
	is_shift := (mod & sdl3.KMOD_SHIFT) != sdl3.KMOD_NONE
	is_alt   := (mod & sdl3.KMOD_ALT)   != sdl3.KMOD_NONE

	// macOS Command shortcuts
	if is_cmd {
		if is_shift {
			switch key {
			case sdl3.K_P:                  return .Command_Center_Toggle, true
			case sdl3.K_A, sdl3.K_O:        return .Tab_Overview_Toggle, true
			case sdl3.K_D:                  return .Pane_Split_Down, true
			case sdl3.K_W:                  return .Pane_Close, true
			case sdl3.K_RETURN, sdl3.K_KP_ENTER: return .Pane_Toggle_Zoom, true
			case sdl3.K_RIGHTBRACKET:       return .Tab_Next, true
			case sdl3.K_LEFTBRACKET:        return .Tab_Prev, true
			case sdl3.K_R:                  return .App_Reload_Config, true
			case sdl3.K_PLUS, sdl3.K_EQUALS: return .Font_Zoom_In, true
			case sdl3.K_LEFT:               return .Select_Line_Start, true
			case sdl3.K_RIGHT:              return .Select_Line_End, true
			}
		} else if is_ctrl {
			switch key {
			case sdl3.K_F:                  return .Toggle_Fullscreen, true
			}
		} else {
			switch key {
			case sdl3.K_K:                  return .Command_Center_Toggle, true
			case sdl3.K_T:                  return .Tab_New, true
			case sdl3.K_W:                  return .Tab_Close, true
			case sdl3.K_D:                  return .Pane_Split_Right, true
			case sdl3.K_C:                  return .Clipboard_Copy, true
			case sdl3.K_V:                  return .Clipboard_Paste, true
			case sdl3.K_A:                  return .Select_All, true
			case sdl3.K_PLUS, sdl3.K_EQUALS: return .Font_Zoom_In, true
			case sdl3.K_MINUS:              return .Font_Zoom_Out, true
			case sdl3.K_0:                  return .Font_Zoom_Reset, true
			case sdl3.K_RIGHTBRACKET:       return .Pane_Focus_Next, true
			case sdl3.K_LEFTBRACKET:        return .Pane_Focus_Prev, true
			case sdl3.K_1:                  return .Tab_Select_1, true
			case sdl3.K_2:                  return .Tab_Select_2, true
			case sdl3.K_3:                  return .Tab_Select_3, true
			case sdl3.K_4:                  return .Tab_Select_4, true
			case sdl3.K_5:                  return .Tab_Select_5, true
			case sdl3.K_6:                  return .Tab_Select_6, true
			case sdl3.K_7:                  return .Tab_Select_7, true
			case sdl3.K_8:                  return .Tab_Select_8, true
			case sdl3.K_9:                  return .Tab_Select_9, true
			case sdl3.K_Q:                  return .App_Quit, true
			}
		}
	}

	// macOS / Universal Option + Shift word navigation shortcuts
	if is_alt && is_shift && !is_cmd && !is_ctrl {
		switch key {
		case sdl3.K_LEFT:  return .Select_Word_Left, true
		case sdl3.K_RIGHT: return .Select_Word_Right, true
		}
	}

	// Plain Shift + Arrow selection shortcuts
	if is_shift && !is_cmd && !is_ctrl && !is_alt {
		switch key {
		case sdl3.K_LEFT:  return .Select_Left, true
		case sdl3.K_RIGHT: return .Select_Right, true
		case sdl3.K_UP:    return .Select_Up, true
		case sdl3.K_DOWN:  return .Select_Down, true
		}
	}

	// Linux / Windows fallback or alternative Ctrl+Shift shortcuts
	if is_ctrl && is_shift {
		switch key {
		case sdl3.K_P:                      return .Command_Center_Toggle, true
		case sdl3.K_A, sdl3.K_O:            return .Tab_Overview_Toggle, true
		case sdl3.K_T:                      return .Tab_New, true
		case sdl3.K_W:                      return .Tab_Close, true
		case sdl3.K_C:                      return .Clipboard_Copy, true
		case sdl3.K_V:                      return .Clipboard_Paste, true
		case sdl3.K_D:                      return .Pane_Split_Right, true
		case sdl3.K_E:                      return .Pane_Split_Down, true
		case sdl3.K_Z:                      return .Pane_Toggle_Zoom, true
		case sdl3.K_PLUS, sdl3.K_EQUALS:    return .Font_Zoom_In, true
		case sdl3.K_MINUS:                  return .Font_Zoom_Out, true
		}
	}

	// Tab cycling via Ctrl+Tab
	if is_ctrl && !is_cmd && !is_alt {
		if key == sdl3.K_TAB {
			return (.Tab_Prev if is_shift else .Tab_Next), true
		}
	}

	// Scrolling shortcuts
	if is_shift && !is_cmd && !is_ctrl {
		switch key {
		case sdl3.K_PAGEUP:                 return .Scroll_Page_Up, true
		case sdl3.K_PAGEDOWN:               return .Scroll_Page_Down, true
		case sdl3.K_HOME:                   return .Scroll_To_Top, true
		case sdl3.K_END:                    return .Scroll_To_Bottom, true
		}
	}

	return .None, false
}

is_selection_action :: proc(act: Action_Id) -> bool {
	#partial switch act {
	case .Select_Left, .Select_Right, .Select_Up, .Select_Down,
	     .Select_Word_Left, .Select_Word_Right, .Select_Line_Start, .Select_Line_End:
		return true
	case:
		return false
	}
}

