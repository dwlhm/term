package app_test

import "core:testing"
import "vendor:sdl3"
import app "../"
import ui "../../ui"
import input "../../platform/input"

@(test)
test_layout_pointer_scale_and_padding :: proc(t: ^testing.T) {
	for scale in ([]i32{1, 2}) {
		f := new(app.Frontend)
		defer free(f)
		f.window.handle = cast(^sdl3.Window)uintptr(1)
		f.window.width = 800
		f.window.height = 600
		f.window.pixel_w = f.window.width * scale
		f.window.pixel_h = f.window.height * scale
		f.renderer.cell_width = 8 * f32(scale)
		f.renderer.cell_height = 16 * f32(scale)
		app.frontend_update_padding(f)
		testing.expect_value(t, f.renderer.pad_y, (ui.TAB_BAR_HEIGHT + app.FRONTEND_CONTENT_PADDING) * f32(scale))
		rows, cols := app.grid_dimensions_for_pixels(f.window.pixel_w, f.window.pixel_h, f.renderer.cell_width, f.renderer.cell_height, f.renderer.pad_x, f.renderer.pad_y)
		for row in ([]int{0, 1, rows-1}) {
			x := (f.renderer.pad_x + f.renderer.cell_width / 2) / f32(scale)
			y := (f.renderer.pad_y + (f32(row) + 0.5) * f.renderer.cell_height) / f32(scale)
			point := app.frontend_pointer_cell(f, rows, cols, x, y)
			testing.expect_value(t, point.row, row)
			testing.expect_value(t, point.col, 0)
		}
		// Recomputing padding on resize must preserve initial geometry.
		app.frontend_update_padding(f)
		new_rows, new_cols := app.grid_dimensions_for_pixels(f.window.pixel_w, f.window.pixel_h, f.renderer.cell_width, f.renderer.cell_height, f.renderer.pad_x, f.renderer.pad_y)
		testing.expect_value(t, new_rows, rows)
		testing.expect_value(t, new_cols, cols)
	}
	testing.expect_value(t, app.frontend_content_scale(nil), f32(1))
	app.frontend_update_padding(nil)
	f_headless: app.Frontend
	app.frontend_update_padding(&f_headless)
	testing.expect_value(t, f_headless.renderer.pad_x, f32(0))
	testing.expect_value(t, f_headless.renderer.pad_y, f32(0))
}

@(test)
test_layout_dispatch_refreshes_logical_chrome :: proc(t: ^testing.T) {
	a := new(app.App)
	defer free(a)
	_bare_app(a)
	defer _bare_destroy(a)
	a.window.width = 800
	a.window.pixel_w = 1600
	a.window.height = 600
	a.window.pixel_h = 1200
	app.session_manager_init(&a.session_mgr, 2)
	defer app.session_manager_destroy(&a.session_mgr)
	// Parked sessions avoid process or GPU dependencies.
	for _ in 0..<2 {
		append(&a.session_mgr.tabs, app.Tab_Session{})
	}
	a.session_mgr.active_idx = 0
	ui.tab_bar_init(&a.tab_bar)
	rects: [2]ui.Rect_f32
	state: ui.Tab_Bar_State
	_ = ui.tab_bar_layout(&state, f32(a.window.width), 2, rects[:])
	point := rects[1]
	ev := [1]input.Input_Event{{event_type = .Pointer, pointer = {kind = .Button_Down, button = sdl3.BUTTON_RIGHT, x = point.x + point.w / 2, y = point.h / 2}}}
	_, _ = app.app_dispatch_input_events(a, ev[:])
	testing.expect_value(t, a.session_mgr.active_idx, 0)
	testing.expect_value(t, a.tab_bar.rect.w, f32(a.window.width))
	ev[0].pointer.button = sdl3.BUTTON_LEFT
	_, _ = app.app_dispatch_input_events(a, ev[:])
	testing.expect_value(t, a.session_mgr.active_idx, 1)
	// A subsequent resize must change hit rectangles before another draw.
	a.window.width /= 2
	_, _ = app.app_dispatch_input_events(a, ev[:])
	testing.expect_value(t, a.tab_bar.rect.w, f32(a.window.width))
}
