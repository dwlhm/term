package term

// Multi-Surface (OSC 7502) Floating Pane Geometry & Modal Chrome.
// Part of Tier 3 Application Shell (src/app/term/*).

import chrome_dl "../../core/chrome/draw_list"
import core_terminal "../../core/terminal"
import mux_feat "../../features/multiplexer"

// surface_popup_body_rect computes the floating Pane_Entry rectangle (including
// standard `pane_pad_x` and `pane_pad_y`) for a `.Popup` surface.
surface_popup_body_rect :: proc(
	content_area: [4]f32,
	root_rect: [4]f32,
	t: ^core_terminal.Terminal,
	s: ^core_terminal.Terminal_Surface,
	metrics: Visual_Metrics,
) -> [4]f32 {
	if t == nil || s == nil do return {}
	cw := max(1.0, metrics.cell_w)
	ch := max(1.0, metrics.cell_h)
	scale := max(1.0, metrics.scale)
	hdr_h := (32.0 * scale) if (s.chrome != .None && s.title_len > 0) else 0.0
	bw := f32(max(1, s.req_w)) * cw + 2.0 * metrics.pane_pad_x
	bh := f32(max(1, s.req_h)) * ch + 2.0 * metrics.pane_pad_y
	bx := content_area[0]
	by := content_area[1]
	switch s.anchor {
	case .Center:
		bx = content_area[0] + (content_area[2] - bw) * 0.5
		by = content_area[1] + (content_area[3] - (bh + hdr_h)) * 0.5 + hdr_h
	case .Absolute:
		bx = content_area[0] + f32(max(0, s.req_x - 1)) * cw
		by = content_area[1] + f32(max(0, s.req_y - 1)) * ch + hdr_h
	case .Cursor:
		bx = root_rect[0] + f32(t.parser.cursor.col + s.req_x) * cw
		by = root_rect[1] + metrics.pane_pad_y + f32(t.parser.cursor.row + 1 + s.req_y) * ch + hdr_h
		if by + bh > content_area[1] + content_area[3] {
			above := root_rect[1] + metrics.pane_pad_y + f32(t.parser.cursor.row) * ch - bh
			if above >= content_area[1] + hdr_h do by = above
		}
	}
	min_x := content_area[0] + 4.0 * scale
	min_y := content_area[1] + hdr_h + 4.0 * scale
	max_x := max(min_x, content_area[0] + content_area[2] - bw - 4.0 * scale)
	max_y := max(min_y, content_area[1] + content_area[3] - bh - 4.0 * scale)
	return {clamp(bx, min_x, max_x), clamp(by, min_y, max_y), bw, bh}
}

// surface_view_emit_chrome renders modal/card chrome behind a floating Pane_Entry
// on CHROME_LAYER_ID using Term's shared `chrome_draw_modal_frame` and tokens.
surface_view_emit_chrome :: proc(dl: ^chrome_dl.Ui_Draw_List, layout: ^Layout_State, pane: ^mux_feat.Pane_Entry) {
	if dl == nil || layout == nil || pane == nil || !pane.is_floating || pane.session == nil do return
	s := core_terminal.terminal_surface_find(&pane.session.term, pane.surface_id)
	if s == nil || !s.visible || s.chrome == .None do return
	scale := max(1.0, layout.metrics.scale)
	hdr_h := (32.0 * scale) if s.title_len > 0 else 0.0
	modal_rect := [4]f32{pane.rect[0], pane.rect[1] - hdr_h, pane.rect[2], pane.rect[3] + hdr_h}
	if s.chrome == .Modal {
		chrome_draw_modal_frame(dl, layout, modal_rect, 1.0)
		if pane.is_focused {
			chrome_dl.ui_draw_border(dl, modal_rect, {0.30, 0.55, 0.90, 0.70}, 14.0 * scale, 1.0 * scale)
		}
	} else {
		rad := 10.0 * scale
		chrome_dl.ui_draw_shadow(dl, {modal_rect[0], modal_rect[1] + 5.0 * scale, modal_rect[2], modal_rect[3]}, COLOR_CHROME_SHADOW, rad)
		chrome_dl.ui_draw_rounded_rect(dl, modal_rect, COLOR_CHROME_SURFACE, rad)
		b_col := [4]f32{0.30, 0.55, 0.90, 0.70} if pane.is_focused else COLOR_CHROME_BORDER
		chrome_dl.ui_draw_border(dl, modal_rect, b_col, rad, 1.0 * scale)
	}
	if hdr_h > 0 {
		title := core_terminal.terminal_surface_title(s)
		txt_h := FONT_CHROME_BODY * scale
		chrome_dl.ui_draw_text_bold(dl, {modal_rect[0] + 14.0 * scale, modal_rect[1] + (hdr_h - txt_h) * 0.5, modal_rect[2] - 28.0 * scale, txt_h}, title, COLOR_CHROME_TEXT)
		chrome_dl.ui_draw_rect(dl, {modal_rect[0] + 1.0 * scale, pane.rect[1], modal_rect[2] - 2.0 * scale, 1.0 * scale}, COLOR_CHROME_BORDER)
	}
}
