package term

import "core:fmt"
import chrome_dl "../../core/chrome/draw_list"
import sess_feat "../../features/session"

@(private = "file")
Qd_Ctx :: struct {
	d:  ^Quit_Dialog_State,
	dl: ^chrome_dl.Ui_Draw_List,
	m:  Visual_Metrics,
	s, e: f32,
	r:  [4]f32, // modal rect
}

quit_dialog_emit_draw_list :: proc(d: ^Quit_Dialog_State, cands: []Quit_Candidate, dl: ^chrome_dl.Ui_Draw_List, layout: ^Layout_State) {
	if d == nil || dl == nil || layout == nil || (!d.visible && !d.closing) do return
	s := max(1.0, layout.metrics.scale)
	e := chrome_modal_ease(d.anim_t)
	rows := min(len(cands), QUIT_VISIBLE_ROWS)
	first := clamp(d.selected - rows + 1, 0, max(0, len(cands) - rows))
	mw := min(580.0 * s, layout.screen_w - 32.0 * s)
	mh := 72.0 * s + f32(rows) * 52.0 * s + 8.0 * s + 56.0 * s
	mx, my := (layout.screen_w - mw) * 0.5, max(72.0 * s, layout.screen_h * 0.2) + (1.0 - e) * 8.0 * s
	chrome_draw_modal_frame(dl, layout, {mx, my, mw, mh}, e)
	ctx := Qd_Ctx{d = d, dl = dl, m = layout.metrics, s = s, e = e, r = {mx, my, mw, mh}}
	if d.visible do d.modal_rect = ctx.r
	_qd_header(ctx, len(cands))
	d.row_count = 0
	for k in 0..<rows do _qd_row(ctx, k, first + k, &cands[first + k], {mx + 6.0 * s, my + 72.0 * s + f32(k) * 52.0 * s, mw - 12.0 * s, 48.0 * s})
	_qd_footer(ctx, my + mh - 56.0 * s)
}

@(private = "file")
_qd_header :: proc(ctx: Qd_Ctx, n: int) {
	s, x := ctx.s, ctx.r[0] + 20.0 * ctx.s
	w := ctx.r[2] - 40.0 * s
	chrome_dl.ui_draw_text_bold(ctx.dl, {x, ctx.r[1] + 16.0 * s, w, FONT_CHROME_TITLE * s}, "Quit Term?", chrome_with_alpha(COLOR_CHROME_TEXT, ctx.e))
	sub := "1 program is still running." if n == 1 else fmt.tprintf("%d programs are still running.", n)
	sub = fmt.tprintf("%s Kept ones continue in Background Sessions.", sub)
	chrome_dl.ui_draw_text(ctx.dl, {x, ctx.r[1] + 40.0 * s, w, FONT_CHROME_BODY * s}, sub, chrome_with_alpha(COLOR_CHROME_TEXT_MUTED, ctx.e))
}

@(private = "file")
_qd_row :: proc(ctx: Qd_Ctx, k, i: int, c: ^Quit_Candidate, r: [4]f32) {
	s, d := ctx.s, ctx.d
	if d.visible {
		d.row_rects[k], d.row_idx[k] = r, i
		d.row_count = k + 1
	}
	if i == d.selected do chrome_dl.ui_draw_rounded_rect(ctx.dl, r, chrome_with_alpha(COLOR_CHROME_ACCENT_SOFT, ctx.e), 8.0 * s)
	else if i == d.hover do chrome_dl.ui_draw_rounded_rect(ctx.dl, r, chrome_with_alpha(COLOR_CHROME_HOVER, ctx.e), 8.0 * s)
	choice := "Keep running" if c.keep else "Kill"
	col := COLOR_CHROME_SUCCESS if c.keep else COLOR_CHROME_DANGER
	ch_h := FONT_CHROME_META * s
	cw := chrome_text_width(ctx.m, choice, ch_h) + 20.0 * s
	cr := [4]f32{r[0] + r[2] - 12.0 * s - cw, r[1] + 11.0 * s, cw, 26.0 * s}
	chrome_dl.ui_draw_rounded_rect(ctx.dl, cr, chrome_with_alpha(COLOR_CHROME_KEYCAP_BG, ctx.e), 13.0 * s)
	chrome_dl.ui_draw_border(ctx.dl, cr, chrome_with_alpha(COLOR_CHROME_KEYCAP_BORDER, ctx.e), 13.0 * s)
	chrome_dl.ui_draw_text(ctx.dl, {cr[0] + 10.0 * s, cr[1] + (cr[3] - ch_h) * 0.5, cw - 20.0 * s, ch_h}, choice, chrome_with_alpha(col, ctx.e))
	tw := cr[0] - r[0] - 40.0 * s
	chrome_dl.ui_draw_rounded_rect(ctx.dl, {r[0] + 14.0 * s, r[1] + 11.5 * s, 7.0 * s, 7.0 * s}, chrome_with_alpha(COLOR_CHROME_ACCENT, ctx.e), 3.5 * s)
	title := sess_feat.registry_text(&c.title)
	chrome_dl.ui_draw_text(ctx.dl, {r[0] + 30.0 * s, r[1] + 6.5 * s, tw, FONT_CHROME_BODY * s}, title if len(title) > 0 else "program", chrome_with_alpha(COLOR_CHROME_TEXT, ctx.e))
	chrome_dl.ui_draw_text(ctx.dl, {r[0] + 30.0 * s, r[1] + 25.5 * s, tw, FONT_CHROME_META * s}, sess_feat.registry_text(&c.detail), chrome_with_alpha(COLOR_CHROME_TEXT_MUTED, ctx.e))
}

@(private = "file")
_qd_footer :: proc(ctx: Qd_Ctx, y: f32) {
	s := ctx.s
	P := 6.0 * s
	chrome_dl.ui_draw_rect(ctx.dl, {ctx.r[0] + P, y, ctx.r[2] - 2.0 * P, 1.0 * s}, chrome_with_alpha(COLOR_CHROME_BORDER, ctx.e))
	HINTS := [][2]string{{"space", "Toggle"}, {"esc", "Cancel"}}
	chrome_draw_key_hints(ctx.dl, ctx.m, ctx.e, ctx.r[0] + 14.0 * s, y + 18.0 * s, HINTS)
	bx := ctx.r[0] + ctx.r[2] - P
	th := FONT_CHROME_BODY * s
	for bi := len(Quit_Button) - 1; bi >= 0; bi -= 1 {
		b := Quit_Button(bi)
		label := QUIT_BUTTON_LABELS[b]
		bw := chrome_text_width(ctx.m, label, th) + 24.0 * s
		bx -= bw
		br := [4]f32{bx, y + 12.0 * s, bw, 32.0 * s}
		if ctx.d.visible do ctx.d.button_rects[b] = br
		primary := b == .Quit
		chrome_dl.ui_draw_rounded_rect(ctx.dl, br, chrome_with_alpha(COLOR_CHROME_ACCENT_SOFT if primary else COLOR_CHROME_RAISED, ctx.e), 8.0 * s)
		chrome_dl.ui_draw_border(ctx.dl, br, chrome_with_alpha(COLOR_CHROME_BORDER, ctx.e), 8.0 * s)
		tc := COLOR_CHROME_ACCENT if primary else (COLOR_CHROME_DANGER if b == .Kill_All else COLOR_CHROME_TEXT)
		trect := [4]f32{bx + 12.0 * s, br[1] + (br[3] - th) * 0.5, bw - 24.0 * s, th}
		if primary do chrome_dl.ui_draw_text_bold(ctx.dl, trect, label, chrome_with_alpha(tc, ctx.e))
		else do chrome_dl.ui_draw_text(ctx.dl, trect, label, chrome_with_alpha(tc, ctx.e))
		bx -= 8.0 * s
	}
}
