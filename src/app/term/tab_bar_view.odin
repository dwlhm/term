package term

// Top Bar & Tab Strip Rendering (surface tint + 1px inset border + tactile hover)
// Part of Tier 3 Application Shell (src/app/term/*).

import chrome_dl "../../core/chrome/draw_list"
import tabs_feat "../../features/tabs"
import sess_feat "../../features/session"

@(private = "file")
_tab_bar_draw_close :: proc(
	dl: ^chrome_dl.Ui_Draw_List,
	layout: ^Layout_State,
	close_r: [4]f32,
	alpha: f32,
	is_active, is_close_hovered: bool,
) {
	s := layout.metrics.scale
	if is_close_hovered {
		hover_bg := [4]f32{1.0, 1.0, 1.0, 0.13 * alpha}
		chrome_dl.ui_draw_rounded_rect(dl, close_r, hover_bg, close_r[3] * 0.5)
	}
	close_col := COLOR_TAB_TEXT_ACTIVE if is_close_hovered else (
		[4]f32{0.78, 0.83, 0.92, 0.80} if is_active else [4]f32{0.68, 0.73, 0.82, 0.68}
	)
	close_h := 12.0 * s
	close_w := chrome_text_width(layout.metrics, "✕", close_h)
	cx := close_r[0] + (close_r[2] - close_w) * 0.5
	cy := close_r[1] + (close_r[3] - close_h) * 0.5
	chrome_dl.ui_draw_text(dl, {cx, cy, close_w + 4.0 * s, close_h}, "✕", chrome_with_alpha(close_col, alpha))
}

@(private = "file")
_tab_bar_draw_tab_title :: proc(
	dl: ^chrome_dl.Ui_Draw_List,
	layout: ^Layout_State,
	g: Tab_Bar_Geometry,
	entry: ^tabs_feat.Tab_Entry,
	text_x, right_limit: f32,
	is_active, is_hovered: bool,
) {
	s := layout.metrics.scale
	text_max_w := right_limit - text_x
	if text_max_w <= 8.0 * s do return
	title := string(entry.title_buf[:entry.title_len]) if entry.title_len > 0 else "Shell"
	txt_col := COLOR_TAB_TEXT_ACTIVE if is_active else (COLOR_TAB_TEXT_HOVER if is_hovered else COLOR_TAB_TEXT_INACT)
	th := FONT_CHROME_BODY * s
	ty := g.tab_y + (g.tab_h - th) * 0.5
	if is_active {
		chrome_dl.ui_draw_text_bold(dl, {text_x, ty, text_max_w, th}, title, chrome_with_alpha(txt_col, g.alpha))
	} else {
		chrome_dl.ui_draw_text(dl, {text_x, ty, text_max_w, th}, title, chrome_with_alpha(txt_col, g.alpha))
	}
}

@(private = "file")
_tab_bar_draw_tab :: proc(
	dl: ^chrome_dl.Ui_Draw_List,
	layout: ^Layout_State,
	g: Tab_Bar_Geometry,
	entry: ^tabs_feat.Tab_Entry,
	idx: int,
	is_active: bool,
) {
	s := layout.metrics.scale
	tab_item_x := g.tabs_x + f32(idx) * (g.tab_w + g.tab_gap) - layout.tab_scroll_offset
	draw_x := max(g.tabs_x, tab_item_x)
	draw_r := min(g.tabs_end_x, tab_item_x + g.tab_w)
	draw_w := draw_r - draw_x
	if draw_w <= 2.0 * s do return

	is_hovered := (layout.tab_bar_hover.kind == .Tab || layout.tab_bar_hover.kind == .Tab_Close) && layout.tab_bar_hover.tab_idx == idx
	is_close_hovered := layout.tab_bar_hover.kind == .Tab_Close && layout.tab_bar_hover.tab_idx == idx
	pill_rect := [4]f32{draw_x, g.tab_y, draw_w, g.tab_h}
	radius := g.tab_h * 0.5

	bg := COLOR_TAB_ACTIVE_BG if is_active else (COLOR_TAB_HOVER_BG if is_hovered else COLOR_TAB_INACTIVE_BG)
	border := COLOR_TAB_ACTIVE_BORDER if is_active else (COLOR_CHROME_BORDER if is_hovered else COLOR_TAB_INACTIVE_BORDER)
	chrome_dl.ui_draw_rounded_rect(dl, pill_rect, chrome_with_alpha(bg, g.alpha), radius)
	chrome_dl.ui_draw_border(dl, pill_rect, chrome_with_alpha(border, g.alpha), radius, {}, 1.0 * s)

	left_pad := 12.0 * s
	close_r, has_close := tab_bar_close_rect(g, s, tab_item_x, draw_x, draw_r)
	show_close := has_close && (is_active || is_hovered)
	right_limit := (close_r[0] - 4.0 * s) if show_close else (draw_r - 10.0 * s)
	_tab_bar_draw_tab_title(dl, layout, g, entry, draw_x + left_pad, right_limit, is_active, is_hovered)

	if show_close {
		_tab_bar_draw_close(dl, layout, close_r, g.alpha, is_active, is_close_hovered)
	}
}

@(private = "file")
_tab_bar_draw_plus_button :: proc(dl: ^chrome_dl.Ui_Draw_List, g: Tab_Bar_Geometry, scale: f32, hovered: bool) {
	if g.new_tab_x <= g.tabs_x do return
	rect := [4]f32{g.new_tab_x, g.tab_y, g.btn_w, g.tab_h}
	radius := g.tab_h * 0.5
	bg := COLOR_TAB_HOVER_BG if hovered else COLOR_TAB_INACTIVE_BG
	border := COLOR_TAB_ACTIVE_BORDER if hovered else COLOR_CHROME_BORDER
	chrome_dl.ui_draw_rounded_rect(dl, rect, chrome_with_alpha(bg, g.alpha), radius)
	chrome_dl.ui_draw_border(dl, rect, chrome_with_alpha(border, g.alpha), radius, {}, 1.0 * scale)

	icon_col := COLOR_TAB_TEXT_ACTIVE if hovered else [4]f32{0.76, 0.80, 0.88, 0.85}
	arm := 9.0 * scale
	stroke := 1.5 * scale
	cx := g.new_tab_x + (g.btn_w - arm) * 0.5
	cy := g.tab_y + (g.tab_h - stroke) * 0.5
	chrome_dl.ui_draw_rounded_rect(dl, {cx, cy, arm, stroke}, chrome_with_alpha(icon_col, g.alpha), stroke * 0.5)
	cx2 := g.new_tab_x + (g.btn_w - stroke) * 0.5
	cy2 := g.tab_y + (g.tab_h - arm) * 0.5
	chrome_dl.ui_draw_rounded_rect(dl, {cx2, cy2, stroke, arm}, chrome_with_alpha(icon_col, g.alpha), stroke * 0.5)
}

@(private = "file")
_tab_bar_draw_overview_button :: proc(dl: ^chrome_dl.Ui_Draw_List, g: Tab_Bar_Geometry, scale: f32, is_open, hovered: bool) {
	if g.overview_x <= g.tabs_x do return
	rect := [4]f32{g.overview_x, g.tab_y, g.btn_w, g.tab_h}
	radius := g.tab_h * 0.5
	bg := COLOR_TAB_ACTIVE_BG if is_open else (COLOR_TAB_HOVER_BG if hovered else COLOR_TAB_INACTIVE_BG)
	border := COLOR_TAB_ACTIVE_BORDER if (is_open || hovered) else COLOR_CHROME_BORDER
	chrome_dl.ui_draw_rounded_rect(dl, rect, chrome_with_alpha(bg, g.alpha), radius)
	chrome_dl.ui_draw_border(dl, rect, chrome_with_alpha(border, g.alpha), radius, {}, 1.0 * scale)

	sq_s := 3.5 * scale
	sq_gap := 2.0 * scale
	tl_x := g.overview_x + (g.btn_w - (sq_s * 2.0 + sq_gap)) * 0.5
	tl_y := g.tab_y + (g.tab_h - (sq_s * 2.0 + sq_gap)) * 0.5
	icon_col := COLOR_TAB_TEXT_ACTIVE if (is_open || hovered) else [4]f32{0.76, 0.80, 0.88, 0.85}
	col := chrome_with_alpha(icon_col, g.alpha)
	r := 0.8 * scale

	chrome_dl.ui_draw_rounded_rect(dl, {tl_x, tl_y, sq_s, sq_s}, col, r)
	chrome_dl.ui_draw_rounded_rect(dl, {tl_x + sq_s + sq_gap, tl_y, sq_s, sq_s}, col, r)
	chrome_dl.ui_draw_rounded_rect(dl, {tl_x, tl_y + sq_s + sq_gap, sq_s, sq_s}, col, r)
	chrome_dl.ui_draw_rounded_rect(dl, {tl_x + sq_s + sq_gap, tl_y + sq_s + sq_gap, sq_s, sq_s}, col, r)
}

@(private = "file")
_tab_bar_draw_close_tooltip :: proc(
	dl: ^chrome_dl.Ui_Draw_List,
	layout: ^Layout_State,
	g: Tab_Bar_Geometry,
	tab_count: int,
) {
	if layout.tab_bar_hover.kind != .Tab_Close do return
	idx := layout.tab_bar_hover.tab_idx
	if idx < 0 || idx >= tab_count do return

	s := layout.metrics.scale
	tab_item_x := g.tabs_x + f32(idx) * (g.tab_w + g.tab_gap) - layout.tab_scroll_offset
	draw_x := max(g.tabs_x, tab_item_x)
	draw_r := min(g.tabs_end_x, tab_item_x + g.tab_w)
	close_r, has_close := tab_bar_close_rect(g, s, tab_item_x, draw_x, draw_r)
	if !has_close do return

	label, shortcut := "Close Tab", "⌘W"
	th, pad_x, gap := 13.0 * s, 8.0 * s, 6.0 * s
	lw := chrome_text_width(layout.metrics, label, th)
	sw := chrome_text_width(layout.metrics, shortcut, th)

	tip_w, tip_h, tip_r := pad_x * 2.0 + lw + gap + sw, 22.0 * s, 6.0 * s
	cx := close_r[0] + close_r[2] * 0.5
	margin := max(8.0 * s, layout.metrics.window_margin)
	tip_x := clamp(cx - tip_w * 0.5, margin, max(margin, layout.screen_w - margin - tip_w))
	tip_y := g.tab_y + g.tab_h + 4.0 * s
	tip_rect := [4]f32{tip_x, tip_y, tip_w, tip_h}
	ty := tip_y + (tip_h - th) * 0.5

	chrome_dl.ui_draw_rounded_rect(dl, tip_rect, chrome_with_alpha(COLOR_CHROME_SURFACE, g.alpha), tip_r)
	chrome_dl.ui_draw_border(dl, tip_rect, chrome_with_alpha(COLOR_TAB_ACTIVE_BORDER, g.alpha), tip_r, {}, 1.0 * s)
	chrome_dl.ui_draw_text(dl, {tip_x + pad_x, ty, lw + 2.0 * s, th}, label, chrome_with_alpha(COLOR_CHROME_TEXT, g.alpha))
	chrome_dl.ui_draw_text(dl, {tip_x + pad_x + lw + gap, ty, sw + 2.0 * s, th}, shortcut, chrome_with_alpha(COLOR_CHROME_TEXT_MUTED, g.alpha))
}

// tab_bar_view_emit renders the unified top bar: fullscreen backdrop, tabs,
// background session pill, [+] new tab, [⊞] tab overview buttons, and hover tooltip.
tab_bar_view_emit :: proc(
	dl: ^chrome_dl.Ui_Draw_List,
	layout: ^Layout_State,
	tabs: ^tabs_feat.Tabs_Manager,
	cmd_center: ^Command_Center_State,
	sessions: ^sess_feat.Session_Registry,
) {
	if dl == nil || layout == nil || tabs == nil || layout.tab_bar_anim_t <= 0.001 do return
	pill_w := session_pill_width(layout, sessions)
	g := tab_bar_geometry(layout, pill_w)
	s := layout.metrics.scale

	if layout.is_fullscreen {
		banner_rect := [4]f32{0, g.offset_y, layout.screen_w, g.bar_h + 2.0 * s}
		banner_bg := [4]f32{0.08, 0.09, 0.11, 0.92 * g.alpha}
		chrome_dl.ui_draw_rounded_rect(dl, banner_rect, banner_bg, 0)
	}

	layout_tab_bar_clamp_scroll(layout, len(tabs.entries), pill_w)

	for i in 0..<len(tabs.entries) {
		_tab_bar_draw_tab(dl, layout, g, &tabs.entries[i], i, i == tabs.model.active_idx)
	}

	is_ov_open := cmd_center != nil && cmd_center.visible && cmd_center.mode == .Tabs
	is_sessions_open := cmd_center != nil && cmd_center.visible && cmd_center.mode == .Sessions
	_tab_bar_draw_plus_button(dl, g, s, layout.tab_bar_hover.kind == .New_Tab)
	_tab_bar_draw_overview_button(dl, g, s, is_ov_open, layout.tab_bar_hover.kind == .Overview)
	session_pill_emit(dl, layout, g, sessions, is_sessions_open)
	_tab_bar_draw_close_tooltip(dl, layout, g, len(tabs.entries))
}
