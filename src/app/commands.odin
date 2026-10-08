package main

import ui "../ui"

Command_Preset :: enum {
	NativeV1,
	Legacy,
}

Command_Result :: enum {
	Handled,
	Ignored,
	Failed,
}

// dispatch_command routes a shortcut action to its corresponding app handler.
dispatch_command :: proc(a: ^App, action: ui.Shortcut_Action) -> Command_Result {
	if a == nil do return .Failed

	tab := _app_active_tab(a)

	#partial switch action {
	case .Detach_Tab:
		if tab == nil do return .Ignored
		_app_detach_current_tab(a)
		return .Handled

	case .Close_Tab:
		if tab == nil do return .Ignored
		_app_request_close_tab(a, a.session_mgr.active_idx)
		return .Handled

	case .Close_Pane:
		if tab == nil do return .Ignored
		_app_close_pane(a, tab.tree.focused_pane_id)
		return .Handled

	case .New_Tab:
		_ = _app_spawn_default_tab(a)
		return .Handled

	case .Attach_Session:
		_app_open_session_switcher(a)
		return .Handled

	case .Toggle_Devtools:
		_app_toggle_devtools(a)
		return .Handled

	case .Split_Vertical:
		if tab == nil do return .Ignored
		_ = _app_split_pane(a, .Vertical)
		return .Handled

	case .Split_Horizontal:
		if tab == nil do return .Ignored
		_ = _app_split_pane(a, .Horizontal)
		return .Handled

	case .Pane_Focus_Left:
		if tab == nil do return .Ignored
		_ = pane_tree_navigate_spatially(&tab.tree, .Vertical, false)
		return .Handled

	case .Pane_Focus_Right:
		if tab == nil do return .Ignored
		_ = pane_tree_navigate_spatially(&tab.tree, .Vertical, true)
		return .Handled

	case .Pane_Focus_Up:
		if tab == nil do return .Ignored
		_ = pane_tree_navigate_spatially(&tab.tree, .Horizontal, false)
		return .Handled

	case .Pane_Focus_Down:
		if tab == nil do return .Ignored
		_ = pane_tree_navigate_spatially(&tab.tree, .Horizontal, true)
		return .Handled
	}

	return .Ignored
}
