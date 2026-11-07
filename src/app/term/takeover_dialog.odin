package term

// Taking a session back from the automation that holds it (term auto): a
// confirmation, then MSG_V_TAKEOVER on the pane's link. The automation stops
// at once; what the person typed while it held the session is dropped.
// ↵ takes over · esc cancels.

import "vendor:sdl3"
import chrome_dl "../../core/chrome/draw_list"
import mux_feat "../../features/multiplexer"
import sess_feat "../../features/session"
import client_feat "../../features/session_client"

Takeover_Button :: enum u8 { Cancel, Take_Over }

TAKEOVER_BUTTON_LABELS := [Takeover_Button]string{.Cancel = "Cancel", .Take_Over = "Take over"}

Takeover_Dialog_State :: struct {
	anim:         Modal_Anim,
	session_id:   u32,
	owner_buf:    [64]u8,
	owner_len:    int,
	button_rects: [Takeover_Button][4]f32, // written by the renderer
}

// app_takeover_open asks to take the focused pane's session back; it does
// nothing when no automation holds it.
app_takeover_open :: proc(app: ^Term_App) {
	p := mux_feat.multiplexer_get_focused_pane(&app.mux)
	if p == nil || p.session == nil do return
	owner, _ := sess_feat.session_controller(p.session)
	if len(owner) == 0 do return
	d := &app.takeover
	d^ = {session_id = client_feat.client_session_id(&app.client, p.session)}
	d.owner_len = copy(d.owner_buf[:], owner)
	modal_anim_open(&d.anim)
}

takeover_dialog_handle_key :: proc(app: ^Term_App, key: sdl3.Keycode) -> bool {
	if !app.takeover.anim.visible do return false
	switch key {
	case sdl3.K_ESCAPE:                   modal_anim_close(&app.takeover.anim)
	case sdl3.K_RETURN, sdl3.K_KP_ENTER: _take_over(app)
	}
	return true // modal: typing never reaches a pane
}

takeover_dialog_handle_click :: proc(app: ^Term_App, mx, my: f32) -> bool {
	d := &app.takeover
	if !d.anim.visible do return false
	if tab_bar_point_in(d.button_rects[.Take_Over], mx, my) do _take_over(app)
	else if tab_bar_point_in(d.button_rects[.Cancel], mx, my) do modal_anim_close(&d.anim)
	return true
}

@(private = "file")
_take_over :: proc(app: ^Term_App) {
	if sess := app_shown_session(app, app.takeover.session_id); sess != nil do client_feat.client_takeover(&app.client, sess)
	modal_anim_close(&app.takeover.anim)
}

takeover_dialog_emit_draw_list :: proc(d: ^Takeover_Dialog_State, dl: ^chrome_dl.Ui_Draw_List, layout: ^Layout_State) {
	if d == nil || dl == nil || layout == nil || !modal_anim_shown(d.anim) do return
	s := max(1.0, layout.metrics.scale)
	e := chrome_modal_ease(d.anim.t)
	mw := min(520.0 * s, layout.screen_w - 32.0 * s)
	mh := 132.0 * s
	mx, my := (layout.screen_w - mw) * 0.5, max(72.0 * s, layout.screen_h * 0.2) + (1.0 - e) * 8.0 * s
	chrome_draw_modal_frame(dl, layout, {mx, my, mw, mh}, e)
	x, w := mx + 20.0 * s, mw - 40.0 * s
	chrome_dl.ui_draw_text_bold(dl, {x, my + 16.0 * s, w, FONT_CHROME_TITLE * s}, "Take this session back?", chrome_with_alpha(COLOR_CHROME_TEXT, e))
	owner := string(d.owner_buf[:d.owner_len])
	chrome_dl.ui_draw_text(dl, {x, my + 42.0 * s, w, FONT_CHROME_BODY * s}, owner, chrome_with_alpha(COLOR_CHROME_ACCENT, e))
	chrome_dl.ui_draw_text(dl, {x, my + 62.0 * s, w, FONT_CHROME_META * s}, "drives it. Taking it back stops that automation.", chrome_with_alpha(COLOR_CHROME_TEXT_MUTED, e))
	y := my + mh - 52.0 * s
	chrome_dl.ui_draw_rect(dl, {mx + 6.0 * s, y, mw - 12.0 * s, 1.0 * s}, chrome_with_alpha(COLOR_CHROME_BORDER, e))
	chrome_draw_key_hints(dl, layout.metrics, e, mx + 14.0 * s, y + 16.0 * s, {{"esc", "Cancel"}, {"↵", "Take over"}})
	bx := mx + mw - 6.0 * s
	for bi := len(Takeover_Button) - 1; bi >= 0; bi -= 1 {
		b := Takeover_Button(bi)
		bw := chrome_button_w(layout.metrics, TAKEOVER_BUTTON_LABELS[b])
		bx -= bw
		r := [4]f32{bx, y + 10.0 * s, bw, 32.0 * s}
		if d.anim.visible do d.button_rects[b] = r
		chrome_draw_button(dl, layout.metrics, e, r, TAKEOVER_BUTTON_LABELS[b], .Danger if b == .Take_Over else .Normal)
		bx -= 8.0 * s
	}
}
