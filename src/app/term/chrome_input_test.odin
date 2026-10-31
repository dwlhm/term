package term

import "core:testing"
import "vendor:sdl3"

@test
test_command_center_input_navigation_and_deletion :: proc(t: ^testing.T) {
	cc: Command_Center_State
	command_center_init(&cc)
	command_center_open(&cc, .Commands, {})

	command_center_handle_text(&cc, "git status", {})
	testing.expect_value(t, text_input_as_string(&cc.input), "git status")

	// Option + Backspace deletes "status"
	res_opt := command_center_handle_key(&cc, sdl3.K_BACKSPACE, sdl3.KMOD_ALT, {})
	testing.expect(t, res_opt.handled)
	testing.expect_value(t, text_input_as_string(&cc.input), "git ")

	// Cmd + Backspace deletes "git " to beginning
	res_cmd := command_center_handle_key(&cc, sdl3.K_BACKSPACE, sdl3.KMOD_GUI, {})
	testing.expect(t, res_cmd.handled)
	testing.expect_value(t, text_input_as_string(&cc.input), "")

	// Selection and replace
	command_center_handle_text(&cc, "tab", {})
	testing.expect_value(t, text_input_as_string(&cc.input), "tab")

	res_sel := command_center_handle_key(&cc, sdl3.K_A, sdl3.KMOD_GUI, {})
	testing.expect(t, res_sel.handled)
	_, _, sel_active := text_input_selection_range(&cc.input)
	testing.expect(t, sel_active, "Cmd+A must activate selection in command center")

	command_center_handle_text(&cc, "help", {})
	testing.expect_value(t, text_input_as_string(&cc.input), "help")
}

@test
test_search_input_navigation_and_deletion :: proc(t: ^testing.T) {
	app := new(Term_App)
	defer free(app)
	app.search.active = true
	text_input_init(&app.search.input)

	app_search_append(app, "find me")
	testing.expect_value(t, app_search_query(app), "find me")

	// Option + Backspace deletes word "me"
	handled_opt := app_search_handle_key(app, sdl3.K_BACKSPACE, sdl3.KMOD_ALT)
	testing.expect(t, handled_opt)
	testing.expect_value(t, app_search_query(app), "find ")

	// Cmd + Backspace deletes to start
	handled_cmd := app_search_handle_key(app, sdl3.K_BACKSPACE, sdl3.KMOD_GUI)
	testing.expect(t, handled_cmd)
	testing.expect_value(t, app_search_query(app), "")

	// Selection via Cmd + A and backspace
	app_search_append(app, "needle")
	handled_a := app_search_handle_key(app, sdl3.K_A, sdl3.KMOD_GUI)
	testing.expect(t, handled_a)
	_, _, sel_active := text_input_selection_range(&app.search.input)
	testing.expect(t, sel_active)

	handled_del := app_search_handle_key(app, sdl3.K_BACKSPACE, sdl3.KMOD_NONE)
	testing.expect(t, handled_del)
	testing.expect_value(t, app_search_query(app), "")
}
