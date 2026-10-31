package term

// Command Center → app actions bridge.

import chrome_render "../../core/render/chrome"
import sess_feat "../../features/session"

app_command_center_sources :: proc(app: ^Term_App) -> Command_Center_Sources {
	return {tabs = &app.tabs_mgr, sessions = &app.session_reg}
}

app_apply_command_center_result :: proc(app: ^Term_App, res: Command_Center_Result) {
	if app == nil do return
	switch res.outcome {
	case .None:           return
	case .Run_Action:     app_execute_action(app, res.action)
	case .Select_Tab:     app_select_tab(app, res.tab_index)
	case .Attach_Session: _ = app_attach_background_session(app, res.session_id)
	case .Kill_Session:
		_ = sess_feat.session_registry_remove(&app.session_reg, res.session_id)
		command_center_refresh(&app.cmd_center, app_command_center_sources(app))
	}
	chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
}
