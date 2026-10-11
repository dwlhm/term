package modals

// Automated Unit Tests for Chrome Modals Declarative Geometry Engine.
// Verifies modal layout geometry, shadow bounds, input box offsets,
// visibility toggling, empty query placeholders, and zero memory leaks.

import "core:mem"
import "core:testing"
import "../draw_list"

@test
test_modal_visibility_toggle :: proc(t: ^testing.T) {
	dl: draw_list.Ui_Draw_List
	draw_list.ui_draw_list_init(&dl)
	defer draw_list.ui_draw_list_destroy(&dl)

	m := Chrome_Modal{
		title   = "Search",
		rect    = {100, 100, 400, 300},
		visible = false,
	}

	// When visible is false, 0 commands should be emitted
	modal_emit_draw_list(&m, &dl)
	testing.expect_value(t, len(dl.commands), 0)

	// When visible is true, commands should be emitted
	m.visible = true
	modal_emit_draw_list(&m, &dl)
	testing.expect(t, len(dl.commands) > 0)
}

@test
test_modal_geometry_and_shadow_bounds :: proc(t: ^testing.T) {
	dl: draw_list.Ui_Draw_List
	draw_list.ui_draw_list_init(&dl)
	defer draw_list.ui_draw_list_destroy(&dl)

	m := Chrome_Modal{
		title       = "Palette",
		query       = "build",
		match_count = 5,
		rect        = {100.0, 150.0, 400.0, 200.0},
		visible     = true,
	}

	modal_emit_draw_list(&m, &dl)
	testing.expect_value(t, len(dl.commands), 8)

	// 0: Drop shadow
	shadow_cmd := dl.commands[0]
	testing.expect_value(t, shadow_cmd.kind, draw_list.Ui_Cmd_Kind.Shadow)
	testing.expect_value(t, shadow_cmd.rect, [4]f32{92.0, 146.0, 416.0, 216.0})
	testing.expect_value(t, shadow_cmd.radius, f32(12.0))

	// 1: Background body
	body_cmd := dl.commands[1]
	testing.expect_value(t, body_cmd.kind, draw_list.Ui_Cmd_Kind.Rounded_Rect)
	testing.expect_value(t, body_cmd.rect, [4]f32{100.0, 150.0, 400.0, 200.0})
	testing.expect_value(t, body_cmd.radius, f32(8.0))

	// 2: Outline border
	border_cmd := dl.commands[2]
	testing.expect_value(t, border_cmd.kind, draw_list.Ui_Cmd_Kind.Border)
	testing.expect_value(t, border_cmd.rect, [4]f32{100.0, 150.0, 400.0, 200.0})
	testing.expect_value(t, border_cmd.radius, f32(8.0))

	// 3: Title text
	title_cmd := dl.commands[3]
	testing.expect_value(t, title_cmd.kind, draw_list.Ui_Cmd_Kind.Text_Run)
	testing.expect_value(t, title_cmd.rect, [4]f32{116.0, 162.0, 368.0, 18.0})
	testing.expect_value(t, title_cmd.text, "Palette")

	// 4: Input box background
	input_bg_cmd := dl.commands[4]
	testing.expect_value(t, input_bg_cmd.kind, draw_list.Ui_Cmd_Kind.Rounded_Rect)
	testing.expect_value(t, input_bg_cmd.rect, [4]f32{116.0, 186.0, 368.0, 28.0})
	testing.expect_value(t, input_bg_cmd.radius, f32(4.0))

	// 5: Input box border
	input_border_cmd := dl.commands[5]
	testing.expect_value(t, input_border_cmd.kind, draw_list.Ui_Cmd_Kind.Border)
	testing.expect_value(t, input_border_cmd.rect, [4]f32{116.0, 186.0, 368.0, 28.0})
	testing.expect_value(t, input_border_cmd.radius, f32(4.0))

	// 6: Input text
	input_text_cmd := dl.commands[6]
	testing.expect_value(t, input_text_cmd.kind, draw_list.Ui_Cmd_Kind.Text_Run)
	testing.expect_value(t, input_text_cmd.rect, [4]f32{124.0, 192.0, 352.0, 16.0})
	testing.expect_value(t, input_text_cmd.text, "build")

	// 7: Match count text
	match_cmd := dl.commands[7]
	testing.expect_value(t, match_cmd.kind, draw_list.Ui_Cmd_Kind.Text_Run)
	testing.expect_value(t, match_cmd.rect, [4]f32{116.0, 326.0, 368.0, 16.0})
	testing.expect_value(t, match_cmd.text, "5 matches")
}

@test
test_modal_placeholder_and_zero_matches :: proc(t: ^testing.T) {
	dl: draw_list.Ui_Draw_List
	draw_list.ui_draw_list_init(&dl)
	defer draw_list.ui_draw_list_destroy(&dl)

	m := Chrome_Modal{
		title       = "Search",
		query       = "",
		match_count = 0,
		rect        = {100.0, 100.0, 500.0, 300.0},
		visible     = true,
	}

	modal_emit_draw_list(&m, &dl)
	// Without match count text, exactly 7 commands are emitted
	testing.expect_value(t, len(dl.commands), 7)

	// Command 6 is input text with default placeholder
	input_text_cmd := dl.commands[6]
	testing.expect_value(t, input_text_cmd.text, "Type a command...")
}

@test
test_modal_nil_guards :: proc(t: ^testing.T) {
	dl: draw_list.Ui_Draw_List
	draw_list.ui_draw_list_init(&dl)
	defer draw_list.ui_draw_list_destroy(&dl)

	m := Chrome_Modal{visible = true}
	modal_emit_draw_list(nil, &dl)
	modal_emit_draw_list(&m, nil)
	modal_emit_draw_list(nil, nil)
	testing.expect_value(t, len(dl.commands), 0)
}

@test
test_modal_previews_and_zero_leaks :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)

	dl: draw_list.Ui_Draw_List
	draw_list.ui_draw_list_init(&dl, alloc)
	defer draw_list.ui_draw_list_destroy(&dl)

	preview_modal_normal(&dl, {0, 0, 1920, 1080})
	testing.expect(t, len(dl.commands) > 0)

	draw_list.ui_draw_list_clear(&dl)

	preview_modal_extreme(&dl, {0, 0, 1920, 1080})
	testing.expect(t, len(dl.commands) > 0)

	draw_list.ui_draw_list_destroy(&dl)
	testing.expect_value(t, track.current_memory_allocated, 0)
}
