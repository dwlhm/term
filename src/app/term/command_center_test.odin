package term

import "core:testing"
import "vendor:sdl3"

import chrome_dl "../../core/chrome/draw_list"
import sess_feat "../../features/session"

@test
test_score_order :: proc(t: ^testing.T) {
	testing.expect_value(t, command_center_score("new", "new tab", ""), 1000)
	testing.expect_value(t, command_center_score("pane", "Split Pane Right", ""), 700)
	testing.expect_value(t, command_center_score("term", "Find in Terminal", ""), 700)
	testing.expect_value(t, command_center_score("lose", "Close Tab", ""), 400)
	testing.expect_value(t, command_center_score("desc", "Copy Text", "some description"), 150)
	testing.expect_value(t, command_center_score("spd", "Split Pane Down", ""), 50)
	testing.expect_value(t, command_center_score("zzz", "Copy Text", ""), 0)
}

@test
test_commands_grouped_with_headers :: proc(t: ^testing.T) {
	cc: Command_Center_State
	command_center_init(&cc)
	command_center_open(&cc, .Commands, {})

	testing.expect_value(t, cc.rows[0].kind, Command_Center_Row_Kind.Header)
	testing.expect_value(t, cc.rows[0].category, Action_Category.Sessions)

	for i in 1..<cc.row_count {
		if cc.rows[i].kind == .Header {
			testing.expect(t, cc.rows[i-1].kind != .Header, "no consecutive headers")
		}
	}
	for i in 0..<cc.row_count {
		if cc.rows[i].kind == .Action {
			testing.expect(t, cc.rows[i].action != .Command_Center_Toggle, "toggle absent")
		}
	}
	testing.expect(t, cc.rows[cc.selected_idx].kind != .Header, "selected not header")
}

@test
test_commands_query_sorted :: proc(t: ^testing.T) {
	cc: Command_Center_State
	command_center_init(&cc)
	command_center_open(&cc, .Commands, {})
	command_center_handle_text(&cc, "pane", {})

	for i in 0..<cc.row_count {
		testing.expect(t, cc.rows[i].kind != .Header, "no headers")
	}
	for i in 1..<cc.row_count {
		testing.expect(t, cc.rows[i-1].score >= cc.rows[i].score, "non-increasing")
	}
}

@test
test_navigation_skips_headers_and_wraps :: proc(t: ^testing.T) {
	cc: Command_Center_State
	command_center_init(&cc)
	command_center_open(&cc, .Commands, {})

	for _ in 0..<(cc.row_count + 5) {
		testing.expect(t, cc.rows[cc.selected_idx].kind != .Header, "not header")
		command_center_handle_key(&cc, sdl3.K_DOWN, sdl3.KMOD_NONE, {})
	}

	// move to first selectable
	for i in 0..<cc.row_count {
		if cc.rows[i].kind != .Header {
			cc.selected_idx = i
			break
		}
	}
	command_center_handle_key(&cc, sdl3.K_UP, sdl3.KMOD_NONE, {})

	last_sel := 0
	for i := cc.row_count - 1; i >= 0; i -= 1 {
		if cc.rows[i].kind != .Header {
			last_sel = i
			break
		}
	}
	testing.expect_value(t, cc.selected_idx, last_sel)
}

@test
test_tab_key_cycles_modes :: proc(t: ^testing.T) {
	cc: Command_Center_State
	command_center_init(&cc)
	command_center_open(&cc, .Commands, {})

	testing.expect_value(t, cc.mode, Command_Center_Mode.Commands)
	command_center_handle_key(&cc, sdl3.K_TAB, sdl3.KMOD_NONE, {})
	testing.expect_value(t, cc.mode, Command_Center_Mode.Tabs)
	testing.expect_value(t, text_input_as_string(&cc.input), "")
	command_center_handle_key(&cc, sdl3.K_TAB, sdl3.KMOD_NONE, {})
	testing.expect_value(t, cc.mode, Command_Center_Mode.Sessions)
	command_center_handle_key(&cc, sdl3.K_TAB, sdl3.KMOD_NONE, {})
	testing.expect_value(t, cc.mode, Command_Center_Mode.Commands)
	command_center_handle_key(&cc, sdl3.K_TAB, sdl3.KMOD_SHIFT, {})
	testing.expect_value(t, cc.mode, Command_Center_Mode.Sessions)
}

@test
test_sessions_rows_and_outcomes :: proc(t: ^testing.T) {
	reg: sess_feat.Session_Registry
	sess_feat.session_registry_init(&reg)
	defer sess_feat.session_registry_destroy(&reg)

	sess_feat.session_registry_apply_row(&reg, {id = 5, state = .Idle, title = "five"}, false)
	sess_feat.session_registry_apply_row(&reg, {id = 9, state = .Idle, title = "nine"}, false)

	if e := sess_feat.session_registry_find(&reg, 9); e != nil {
		e.attention = true
	}

	src := Command_Center_Sources{sessions = &reg}

	cc: Command_Center_State
	command_center_init(&cc)
	command_center_open(&cc, .Sessions, src)

	testing.expect_value(t, cc.row_count, 2)
	testing.expect_value(t, cc.rows[0].session_id, u32(9))
	testing.expect_value(t, cc.rows[1].session_id, u32(5))

	res := command_center_handle_key(&cc, sdl3.K_RETURN, sdl3.KMOD_NONE, src)
	testing.expect_value(t, res.outcome, Command_Center_Outcome.Attach_Session)
	testing.expect_value(t, res.session_id, u32(9))
	testing.expect(t, !cc.visible, "closed")

	command_center_open(&cc, .Sessions, src)
	for i in 0..<cc.row_count {
		if cc.rows[i].session_id == 5 {
			cc.selected_idx = i
			break
		}
	}
	res2 := command_center_handle_key(&cc, sdl3.K_BACKSPACE, sdl3.KMOD_GUI, src)
	testing.expect_value(t, res2.outcome, Command_Center_Outcome.Kill_Session)
	testing.expect_value(t, res2.session_id, u32(5))
	testing.expect(t, cc.visible, "still visible")

	if e := sess_feat.session_registry_find(&reg, 9); e != nil {
		e.state = .Exited
	}
	command_center_open(&cc, .Sessions, src)
	for i in 0..<cc.row_count {
		if cc.rows[i].session_id == 9 {
			cc.selected_idx = i
			break
		}
	}
	res3 := command_center_handle_key(&cc, sdl3.K_RETURN, sdl3.KMOD_NONE, src)
	testing.expect_value(t, res3.outcome, Command_Center_Outcome.None)
}

@test
test_command_center_animation :: proc(t: ^testing.T) {
	cc: Command_Center_State
	command_center_init(&cc)
	src := Command_Center_Sources{}
	command_center_open(&cc, .Commands, src)
	testing.expect_value(t, cc.anim_t, f32(0))

	anim := command_center_update(&cc, 0.06)
	testing.expect(t, anim, "animating")
	testing.expect(t, cc.anim_t > 0 && cc.anim_t < 1, "range")

	anim2 := command_center_update(&cc, 1.0)
	testing.expect_value(t, cc.anim_t, f32(1))
	testing.expect(t, !anim2, "not animating")

	command_center_close(&cc)
	testing.expect(t, !cc.visible, "visible false")
	testing.expect(t, cc.closing, "closing true")

	anim3 := command_center_update(&cc, 1.0)
	testing.expect(t, !cc.closing, "closing false")
	testing.expect_value(t, cc.anim_t, f32(0))
	testing.expect(t, !anim3, "not animating")
}

@test
test_command_center_emit_uses_tokens_and_hit_rects :: proc(t: ^testing.T) {
	layout: Layout_State
	layout_init(&layout, 2.0, 8, 8, 1.0)
	layout.screen_w = 2560
	layout.screen_h = 1600

	cc: Command_Center_State
	command_center_init(&cc)
	src := Command_Center_Sources{}
	command_center_open(&cc, .Commands, src)
	_ = command_center_update(&cc, 1.0)

	dl: chrome_dl.Ui_Draw_List
	chrome_dl.ui_draw_list_init(&dl)
	defer chrome_dl.ui_draw_list_destroy(&dl)

	command_center_emit_draw_list(&cc, src, &dl, &layout)

	testing.expect(t, cc.row_rect_count > 0, "row rects")
	for i in 0..<cc.row_rect_count {
		r := cc.row_rects[i]
		testing.expect(t, r[0] >= cc.modal_rect[0] && r[1] >= cc.modal_rect[1] &&
			r[0]+r[2] <= cc.modal_rect[0]+cc.modal_rect[2] &&
			r[1]+r[3] <= cc.modal_rect[1]+cc.modal_rect[3], "row inside modal")
	}
	for m in Command_Center_Mode {
		cr := cc.chip_rects[m]
		testing.expect(t, cr[2] > 0, "chip width")
		testing.expect(t, cr[0] >= cc.modal_rect[0] && cr[1] >= cc.modal_rect[1] &&
			cr[0]+cr[2] <= cc.modal_rect[0]+cc.modal_rect[2] &&
			cr[1]+cr[3] <= cc.modal_rect[1]+cc.modal_rect[3], "chip inside modal")
	}
	old := [4]f32{0.20, 0.36, 0.65, 0.85}
	for cmd in dl.commands {
		testing.expect(t, cmd.color != old, "no old color")
		testing.expect(t, cmd.border_color != old, "no old border color")
	}
}

@test
test_command_center_caret_uses_text_measure :: proc(t: ^testing.T) {
	layout: Layout_State
	layout_init(&layout, 2.0, 8, 8, 1.0)
	layout.screen_w = 2560
	layout.screen_h = 1600

	cc: Command_Center_State
	command_center_init(&cc)
	src := Command_Center_Sources{}
	command_center_open(&cc, .Commands, src)
	text_input_insert(&cc.input, "abc")
	_ = command_center_update(&cc, 1.0)

	dl: chrome_dl.Ui_Draw_List
	chrome_dl.ui_draw_list_init(&dl)
	defer chrome_dl.ui_draw_list_destroy(&dl)

	command_center_emit_draw_list(&cc, src, &dl, &layout)

	s := layout.metrics.scale
	expected_x := cc.modal_rect[0] + 18.0 * s + chrome_text_width(layout.metrics, "abc", 15.0 * s)
	target_w := 2.0 * s
	found := false
	for cmd in dl.commands {
		if cmd.kind == .Rect && cmd.rect[2] == target_w && cmd.color == chrome_with_alpha(COLOR_CHROME_ACCENT, 1.0) {
			testing.expect_value(t, cmd.rect[0], expected_x)
			found = true
			break
		}
	}
	testing.expect(t, found, "caret found")
}
