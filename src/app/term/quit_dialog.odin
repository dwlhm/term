package term

// Quit dialog state + input: one row per running program with a Keep running /
// Kill choice, and buttons Kill all · Keep all running · Quit.
// ↑↓ select · space toggles · ↵ quits · esc cancels.

import "vendor:sdl3"

Quit_Button :: enum u8 { Kill_All, Keep_All, Quit }

QUIT_BUTTON_LABELS := [Quit_Button]string{.Kill_All = "Kill all", .Keep_All = "Keep all running", .Quit = "Quit"}
QUIT_VISIBLE_ROWS :: 7

Quit_Dialog_State :: struct {
	visible:      bool,
	closing:      bool,
	anim_t:       f32,
	selected:     int,
	hover:        int, // -1: none
	// Written by the renderer, read by the hit tests.
	modal_rect:   [4]f32,
	row_rects:    [QUIT_VISIBLE_ROWS][4]f32,
	row_idx:      [QUIT_VISIBLE_ROWS]int, // candidate shown in each visible row
	row_count:    int,
	button_rects: [Quit_Button][4]f32,
}

quit_dialog_open :: proc(d: ^Quit_Dialog_State) {
	d^ = {visible = true, hover = -1}
}

quit_dialog_close :: proc(d: ^Quit_Dialog_State) {
	if !d.visible do return
	d.visible, d.closing = false, true
}

quit_dialog_update :: proc(d: ^Quit_Dialog_State, dt: f32) -> (animating: bool) {
	if d.visible do d.anim_t = min(1.0, d.anim_t + dt / 0.12)
	else if d.closing {
		d.anim_t = max(0.0, d.anim_t - dt / 0.09)
		d.closing = d.anim_t > 0
	}
	return (d.anim_t > 0 && d.anim_t < 1) || d.closing
}

// quit_dialog_handle_key: true when the dialog consumed the key (it is modal).
quit_dialog_handle_key :: proc(app: ^Term_App, key: sdl3.Keycode) -> bool {
	d := &app.quit.dialog
	if !d.visible do return false
	cands := app_quit_candidates(app)
	switch key {
	case sdl3.K_ESCAPE:
		app_quit_cancel(app)
	case sdl3.K_DOWN, sdl3.K_UP:
		if len(cands) > 0 do d.selected = (d.selected + (1 if key == sdl3.K_DOWN else len(cands) - 1)) % len(cands)
	case sdl3.K_SPACE:
		if d.selected < len(cands) do cands[d.selected].keep = !cands[d.selected].keep
	case sdl3.K_RETURN, sdl3.K_KP_ENTER:
		app_quit_finish(app)
	}
	return true
}

quit_dialog_handle_click :: proc(app: ^Term_App, mx, my: f32) -> bool {
	d := &app.quit.dialog
	if !d.visible do return false
	cands := app_quit_candidates(app)
	for k in 0..<d.row_count {
		i := d.row_idx[k]
		if i >= len(cands) || !tab_bar_point_in(d.row_rects[k], mx, my) do continue
		d.selected = i
		cands[i].keep = !cands[i].keep
		return true
	}
	for b in Quit_Button {
		if !tab_bar_point_in(d.button_rects[b], mx, my) do continue
		_press(app, b)
		return true
	}
	return true // modal: clicks outside do nothing
}

quit_dialog_handle_motion :: proc(app: ^Term_App, mx, my: f32) -> (changed: bool) {
	d := &app.quit.dialog
	if !d.visible do return false
	hover := -1
	for k in 0..<d.row_count do if tab_bar_point_in(d.row_rects[k], mx, my) do hover = d.row_idx[k]
	changed = hover != d.hover
	d.hover = hover
	return
}

@(private = "file")
_press :: proc(app: ^Term_App, b: Quit_Button) {
	switch b {
	case .Kill_All, .Keep_All:
		for &c in app_quit_candidates(app) do c.keep = b == .Keep_All
		app_quit_finish(app)
	case .Quit:
		app_quit_finish(app)
	}
}
