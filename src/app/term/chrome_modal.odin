package term

// Shared modal chrome (Command Center, quit and takeover confirmations):
// open/close animation, backdrop, lifted surface, keycaps and buttons, all
// from COLOR_CHROME_* tokens.

import chrome_dl "../../core/chrome/draw_list"

// chrome_modal_ease maps a 0..1 open animation to the cubic ease-out every modal uses.
chrome_modal_ease :: proc(t: f32) -> f32 { return 1.0 - (1.0 - t) * (1.0 - t) * (1.0 - t) }

// Modal_Anim: a confirmation modal's open (120 ms) and close (90 ms) animation.
Modal_Anim :: struct {
	visible: bool,
	closing: bool,
	t:       f32,
}

modal_anim_open :: proc(a: ^Modal_Anim) { a^ = {visible = true} }

modal_anim_close :: proc(a: ^Modal_Anim) {
	if !a.visible do return
	a.visible, a.closing = false, true
}

// modal_anim_update advances it; true while it still animates.
modal_anim_update :: proc(a: ^Modal_Anim, dt: f32) -> (animating: bool) {
	if a.visible do a.t = min(1.0, a.t + dt / 0.12)
	else if a.closing {
		a.t = max(0.0, a.t - dt / 0.09)
		a.closing = a.t > 0
	}
	return (a.t > 0 && a.t < 1) || a.closing
}

modal_anim_shown :: proc(a: Modal_Anim) -> bool { return a.visible || a.closing }

chrome_draw_modal_frame :: proc(dl: ^chrome_dl.Ui_Draw_List, layout: ^Layout_State, rect: [4]f32, e: f32) {
	s := max(1.0, layout.metrics.scale)
	chrome_dl.ui_draw_rect(dl, {0, 0, layout.screen_w, layout.screen_h}, chrome_with_alpha(COLOR_CHROME_BACKDROP, e))
	// Same corner radius as the body, dropped 6 px: a soft lift below the modal, not a ring around it.
	chrome_dl.ui_draw_shadow(dl, {rect[0], rect[1] + 6.0 * s, rect[2], rect[3]}, chrome_with_alpha(COLOR_CHROME_SHADOW, e), 14.0 * s)
	chrome_dl.ui_draw_rounded_rect(dl, rect, chrome_with_alpha(COLOR_CHROME_SURFACE, e), 14.0 * s)
	chrome_dl.ui_draw_border(dl, rect, chrome_with_alpha(COLOR_CHROME_BORDER, e), 14.0 * s, 1.0 * s)
}

chrome_keycap_w :: proc(m: Visual_Metrics, label: string) -> f32 {
	return max(22.0 * m.scale, chrome_text_width(m, label, FONT_CHROME_META * m.scale) + 12.0 * m.scale)
}

chrome_draw_keycap :: proc(dl: ^chrome_dl.Ui_Draw_List, m: Visual_Metrics, e: f32, rect: [4]f32, label: string, lh: f32) {
	s, tw := m.scale, chrome_text_width(m, label, lh)
	chrome_dl.ui_draw_rounded_rect(dl, rect, chrome_with_alpha(COLOR_CHROME_KEYCAP_BG, e), 5.0 * s)
	chrome_dl.ui_draw_border(dl, rect, chrome_with_alpha(COLOR_CHROME_KEYCAP_BORDER, e), 5.0 * s)
	chrome_dl.ui_draw_text(dl, {rect[0] + (rect[2] - tw) * 0.5, rect[1] + (rect[3] - lh) * 0.5, tw, lh}, label, chrome_with_alpha(COLOR_CHROME_TEXT_MUTED, e))
}

// chrome_draw_key_hints draws "keycap label" pairs left to right from x; returns the end x.
chrome_draw_key_hints :: proc(dl: ^chrome_dl.Ui_Draw_List, m: Visual_Metrics, e, x, y: f32, hints: [][2]string) -> f32 {
	s, fx := m.scale, x
	th := FONT_CHROME_META * s
	for h in hints {
		kw, lw := chrome_keycap_w(m, h[0]), chrome_text_width(m, h[1], th)
		chrome_draw_keycap(dl, m, e, {fx, y, kw, 20.0 * s}, h[0], th)
		chrome_dl.ui_draw_text(dl, {fx + kw + 5.0 * s, y + (20.0 * s - th) * 0.5, lw, th}, h[1], chrome_with_alpha(COLOR_CHROME_TEXT_FAINT, e))
		fx += kw + 5.0 * s + lw + 14.0 * s
	}
	return fx
}

Chrome_Button_Kind :: enum u8 { Normal, Primary, Danger }

chrome_button_w :: proc(m: Visual_Metrics, label: string) -> f32 {
	return chrome_text_width(m, label, FONT_CHROME_BODY * m.scale) + 24.0 * m.scale
}

// chrome_draw_button: a modal footer button (primary: accent and bold;
// danger: a red label).
chrome_draw_button :: proc(dl: ^chrome_dl.Ui_Draw_List, m: Visual_Metrics, e: f32, rect: [4]f32, label: string, kind: Chrome_Button_Kind) {
	s, th := m.scale, FONT_CHROME_BODY * m.scale
	chrome_dl.ui_draw_rounded_rect(dl, rect, chrome_with_alpha(COLOR_CHROME_ACCENT_SOFT if kind == .Primary else COLOR_CHROME_RAISED, e), 8.0 * s)
	chrome_dl.ui_draw_border(dl, rect, chrome_with_alpha(COLOR_CHROME_BORDER, e), 8.0 * s)
	tc := COLOR_CHROME_ACCENT if kind == .Primary else (COLOR_CHROME_DANGER if kind == .Danger else COLOR_CHROME_TEXT)
	trect := [4]f32{rect[0] + 12.0 * s, rect[1] + (rect[3] - th) * 0.5, rect[2] - 24.0 * s, th}
	if kind == .Primary do chrome_dl.ui_draw_text_bold(dl, trect, label, chrome_with_alpha(tc, e))
	else do chrome_dl.ui_draw_text(dl, trect, label, chrome_with_alpha(tc, e))
}
