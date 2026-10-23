package term

// Behavioral tests for the scrollback scrollbar geometry and drag mapping.

import "core:testing"
import cursor "../../core/cursor"

@test
test_scrollbar_geometry_proportional_thumb :: proc(t: ^testing.T) {
	rect := [4]f32{0, 0, 800, 400}
	geometry := scrollbar_geometry(rect, rows_visible = 40, history = 40, scroll_offset = 0, scale = 1.0)
	testing.expect(t, geometry.valid)
	// 40 visible of 80 total means half the track.
	testing.expect(t, abs(geometry.thumb_h - geometry.track_h * 0.5) < 0.5)
	// At the live bottom the thumb sits at the bottom of the track.
	testing.expect(t, abs((geometry.thumb_y + geometry.thumb_h) - (geometry.track_y + geometry.track_h)) < 0.5)
}

@test
test_scrollbar_geometry_no_history_hides :: proc(t: ^testing.T) {
	geometry := scrollbar_geometry([4]f32{0, 0, 800, 400}, rows_visible = 40, history = 0, scroll_offset = 0)
	testing.expect(t, !geometry.valid)
}

@test
test_scrollbar_pointer_maps_to_offset :: proc(t: ^testing.T) {
	geometry := scrollbar_geometry([4]f32{0, 0, 800, 400}, rows_visible = 40, history = 200, scroll_offset = 0, scale = 1.0)
	testing.expect(t, geometry.valid)

	// Dragging the thumb to the very top means "oldest scrollback row".
	top_offset := scrollbar_offset_from_pointer(geometry, geometry.track_y + geometry.thumb_h * 0.5, geometry.thumb_h * 0.5, 200)
	testing.expect_value(t, top_offset, 200)

	// Dragging it to the bottom means "live output".
	bottom_offset := scrollbar_offset_from_pointer(
		geometry,
		geometry.track_y + geometry.track_h,
		geometry.thumb_h * 0.5,
		200,
	)
	testing.expect_value(t, bottom_offset, 0)

	// Mid-track lands roughly mid-history.
	middle_offset := scrollbar_offset_from_pointer(
		geometry,
		geometry.track_y + geometry.track_h * 0.5,
		geometry.thumb_h * 0.5,
		200,
	)
	testing.expect(t, middle_offset > 90 && middle_offset < 110)
}

@test
test_scrollbar_pointer_clamps_outside_track :: proc(t: ^testing.T) {
	geometry := scrollbar_geometry([4]f32{0, 0, 800, 400}, rows_visible = 40, history = 100, scroll_offset = 0)
	testing.expect_value(t, scrollbar_offset_from_pointer(geometry, -1000, 0, 100), 100)
	testing.expect_value(t, scrollbar_offset_from_pointer(geometry, 10000, 0, 100), 0)
}

@test
test_scrollbar_scales_for_retina :: proc(t: ^testing.T) {
	logical := scrollbar_geometry([4]f32{0, 0, 800, 400}, rows_visible = 40, history = 40, scroll_offset = 0, scale = 1.0)
	retina := scrollbar_geometry([4]f32{0, 0, 1600, 800}, rows_visible = 40, history = 40, scroll_offset = 0, scale = 2.0)
	testing.expect(t, abs(retina.thumb_h - logical.thumb_h * 2.0) < 0.5, "thumb must scale with the pixel density")
}

@test
test_hyperlink_scheme_allowlist :: proc(t: ^testing.T) {
	allowed := [?]string{"https://example.com", "http://example.com", "mailto:a@b.c"}
	for uri in allowed {
		testing.expect(t, _hyperlink_scheme_allowed(uri), "web/mail schemes must be allowed")
	}
	blocked := [?]string{
		"file:///etc/passwd",
		"javascript:alert(1)",
		"data:text/html,<script>",
		"ftp://example.com",
		"",
	}
	for uri in blocked {
		testing.expect(t, !_hyperlink_scheme_allowed(uri), "unsafe schemes must be rejected")
	}
}

@test
test_hyperlink_hover_cursor :: proc(t: ^testing.T) {
	// No link under the pointer -> cursor stays unhandled.
	_, no_link := _hyperlink_cursor_for("")
	testing.expect(t, !no_link, "empty URI must not claim the hover cursor")

	// Openable scheme -> hand pointer (Cmd+Click opens the browser).
	open_cur, open_ok := _hyperlink_cursor_for("https://example.com")
	testing.expect(t, open_ok && open_cur == cursor.Mouse_Cursor.Pointer, "openable link must show the hand pointer")

	// Link present but blocked scheme -> not-allowed.
	blocked_cur, blocked_ok := _hyperlink_cursor_for("file:///etc/passwd")
	testing.expect(t, blocked_ok && blocked_cur == cursor.Mouse_Cursor.Not_Allowed, "blocked-scheme link must show not-allowed")
}

@test
test_hyperlink_hover_struct_defaults_inactive :: proc(t: ^testing.T) {
	hover: Hyperlink_Hover
	testing.expect(t, !hover.active, "zero-initialized hover must be inactive")
	testing.expect(t, !hover.blocked, "default hover must not be blocked")

	// Verify that comparison (used by app_update_hyperlink_hover to detect changes) works
	h1 := Hyperlink_Hover{active = true, pane_id = 1, row = 2, col_start = 3, col_end = 10, blocked = false}
	h2 := Hyperlink_Hover{active = true, pane_id = 1, row = 2, col_start = 3, col_end = 10, blocked = false}
	h3 := Hyperlink_Hover{active = true, pane_id = 1, row = 2, col_start = 3, col_end = 10, blocked = true}

	testing.expect(t, h1 == h2, "identical hover states must be equal")
	testing.expect(t, h1 != h3, "differing blocked state must not be equal")
}
