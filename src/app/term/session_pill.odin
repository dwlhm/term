package term

import "core:fmt"

import chrome_dl "../../core/chrome/draw_list"
import sess_feat "../../features/session"

// session_pill_label formats the background-session pill label into buf.
session_pill_label :: proc(reg: ^sess_feat.Session_Registry, buf: []u8) -> string {
	count := sess_feat.session_registry_count(reg)
	attention := sess_feat.session_registry_attention_count(reg)
	if count == 0 do return ""
	if attention == 0 do return fmt.bprintf(buf, "%d background", count)
	return fmt.bprintf(buf, "%d background · %d new", count, attention)
}

// session_pill_width returns the pill width for the given registry (0 when empty).
session_pill_width :: proc(layout: ^Layout_State, reg: ^sess_feat.Session_Registry) -> f32 {
	if layout == nil || sess_feat.session_registry_count(reg) == 0 do return 0
	s := layout.metrics.scale
	buf: [64]u8
	return (9 + 6 + 6 + 10) * s + chrome_text_width(layout.metrics, session_pill_label(reg, buf[:]), 11.5 * s)
}

// _pill_colors picks bg/dot/text tokens: attention → warning, any busy → accent.
@(private = "file")
_pill_colors :: proc(reg: ^sess_feat.Session_Registry, active: bool) -> (bg, dot, text: [4]f32) {
	attention := sess_feat.session_registry_attention_count(reg)
	busy := false
	if reg != nil do for entry in reg.entries do busy ||= entry.state == .Busy
	bg = COLOR_TAB_ACTIVE_BG if active else (COLOR_CHROME_ACCENT_SOFT if attention > 0 else COLOR_TAB_INACTIVE_BG)
	dot = COLOR_CHROME_WARNING if attention > 0 else (COLOR_CHROME_ACCENT if busy else COLOR_CHROME_TEXT_FAINT)
	text = COLOR_CHROME_TEXT if attention > 0 else COLOR_CHROME_TEXT_MUTED
	return
}

session_pill_emit :: proc(dl: ^chrome_dl.Ui_Draw_List, layout: ^Layout_State, g: Tab_Bar_Geometry, reg: ^sess_feat.Session_Registry, active: bool) {
	if g.pill_rect[2] <= 0 || layout == nil do return
	label := session_pill_label(reg, make([]u8, 64, context.temp_allocator)) // temp: lives until the frame renders
	if len(label) == 0 do return
	s, r := layout.metrics.scale, g.pill_rect
	bg, dot, text := _pill_colors(reg, active)
	radius := g.tab_h * 0.5
	chrome_dl.ui_draw_rounded_rect(dl, r, chrome_with_alpha(bg, g.alpha), radius)
	chrome_dl.ui_draw_border(dl, r, chrome_with_alpha(COLOR_CHROME_BORDER, g.alpha), radius, {}, 1.0 * s)
	dot_size := 6.0 * s
	chrome_dl.ui_draw_rounded_rect(dl, {r[0] + 9.0 * s, r[1] + (r[3] - dot_size) * 0.5, dot_size, dot_size}, chrome_with_alpha(dot, g.alpha), 3.0 * s)
	text_h := 11.5 * s
	text_rect := [4]f32{r[0] + 21.0 * s, r[1] + (r[3] - text_h) * 0.5, chrome_text_width(layout.metrics, label, text_h), text_h}
	chrome_dl.ui_draw_text(dl, text_rect, label, chrome_with_alpha(text, g.alpha))
}
