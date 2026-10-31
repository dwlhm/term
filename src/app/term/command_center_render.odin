package term

import "core:fmt"
import "core:strings"
import chrome_dl "../../core/chrome/draw_list"
import sess_feat "../../features/session"

@(private = "file") CC_LABELS := [Command_Center_Mode]string{.Commands = "Commands", .Tabs = "Tabs", .Sessions = "Sessions"}
@(private = "file") CC_PLACEHOLDERS := [Command_Center_Mode]string{.Commands = "Search commands…", .Tabs = "Switch to tab…", .Sessions = "Filter background sessions…"}
@(private = "file") CC_EMPTY := [Command_Center_Mode]string{.Commands = "No matching commands", .Tabs = "No matching tabs", .Sessions = "No background sessions — ⌥⌘B detaches the focused pane"}

@(private = "file")
Cc_Ctx :: struct {
	cc: ^Command_Center_State, src: Command_Center_Sources, dl: ^chrome_dl.Ui_Draw_List,
	m: Visual_Metrics, s, e, modal_x, modal_y, modal_w, modal_h: f32,
}

@(private = "file")
_cc_keycap_w :: proc(m: Visual_Metrics, label: string) -> f32 {
	return max(20.0 * m.scale, chrome_text_width(m, label, 11.5 * m.scale) + 10.0 * m.scale)
}

@(private = "file")
_cc_draw_keycap :: proc(dl: ^chrome_dl.Ui_Draw_List, m: Visual_Metrics, e: f32, rect: [4]f32, label: string, lh: f32) {
	s, tw := m.scale, chrome_text_width(m, label, lh)
	chrome_dl.ui_draw_rounded_rect(dl, rect, chrome_with_alpha(COLOR_CHROME_KEYCAP_BG, e), 5.0 * s)
	chrome_dl.ui_draw_border(dl, rect, chrome_with_alpha(COLOR_CHROME_KEYCAP_BORDER, e), 5.0 * s)
	chrome_dl.ui_draw_text(dl, {rect[0] + (rect[2] - tw) * 0.5, rect[1] + (rect[3] - lh) * 0.5, tw, lh}, label, chrome_with_alpha(COLOR_CHROME_TEXT_MUTED, e))
}

@(private = "file")
_cc_split_keycaps :: proc(seg: string, allocator := context.temp_allocator) -> [dynamic]string {
	out := make([dynamic]string, allocator)
	s := seg
	outer: for len(s) > 0 {
		for m in ([]string{"⌘", "⌥", "⇧", "⌃", "^"}) {
			if strings.has_prefix(s, m) { append(&out, m); s = s[len(m):]; continue outer }
		}
		append(&out, s); break
	}
	return out
}

@(private = "file")
_cc_calc_list_h :: proc(cc: ^Command_Center_State, s, cap_h: f32) -> f32 {
	if cc.row_count == 0 do return 36.0 * s
	h: f32 = 0
	for r in 0..<COMMAND_CENTER_VISIBLE_CAP {
		idx := cc.scroll_offset + r
		if idx >= cc.row_count do break
		rh: f32 = 28.0 * s if cc.rows[idx].kind == .Header else (36.0 * s if cc.rows[idx].kind == .Tab else 44.0 * s)
		if h + rh > cap_h && h > 0 do break
		h += rh
	}
	return max(36.0 * s, h)
}

@(private = "file")
_cc_draw_chips :: proc(ctx: Cc_Ctx) {
	cy, cx := ctx.modal_y + 10.0 * ctx.s, ctx.modal_x + 12.0 * ctx.s
	n_sess := len(ctx.src.sessions.entries) if ctx.src.sessions != nil else 0
	for mode in Command_Center_Mode {
		lbl := fmt.tprintf("%s · %d", CC_LABELS[mode], n_sess) if mode == .Sessions && n_sess > 0 else CC_LABELS[mode]
		tw, cw := chrome_text_width(ctx.m, lbl, 12.0 * ctx.s), chrome_text_width(ctx.m, lbl, 12.0 * ctx.s) + 20.0 * ctx.s
		r := [4]f32{cx, cy, cw, 24.0 * ctx.s}
		if ctx.cc.visible do ctx.cc.chip_rects[mode] = r
		is_act := ctx.cc.mode == mode
		if is_act do chrome_dl.ui_draw_rounded_rect(ctx.dl, r, chrome_with_alpha(COLOR_CHROME_ACCENT_SOFT, ctx.e), 12.0 * ctx.s)
		tc := COLOR_CHROME_ACCENT if is_act else COLOR_CHROME_TEXT_MUTED
		chrome_dl.ui_draw_text(ctx.dl, {cx + 10.0 * ctx.s, cy + 6.0 * ctx.s, tw, 12.0 * ctx.s}, lbl, chrome_with_alpha(tc, ctx.e))
		cx += cw + 4.0 * ctx.s
	}
}

@(private = "file")
_cc_draw_search :: proc(ctx: Cc_Ctx, P: f32) {
	sy, sh, th := ctx.modal_y + 34.0 * ctx.s, 44.0 * ctx.s, 15.0 * ctx.s
	if ctx.cc.visible do ctx.cc.search_rect = {ctx.modal_x + P, sy, ctx.modal_w - 2.0 * P, sh}
	tx, ty := ctx.modal_x + 18.0 * ctx.s, sy + (sh - th) * 0.5
	q := text_input_as_string(&ctx.cc.input)
	if s_idx, e_idx, sel := text_input_selection_range(&ctx.cc.input); sel {
		sx, sw := tx + chrome_text_width(ctx.m, q[:s_idx], th), chrome_text_width(ctx.m, q[s_idx:e_idx], th)
		chrome_dl.ui_draw_rounded_rect(ctx.dl, {sx, ty, sw, th}, chrome_with_alpha(COLOR_CHROME_ACCENT_SOFT, ctx.e), 3.0 * ctx.s)
	} else {
		cx := tx + chrome_text_width(ctx.m, q[:clamp(ctx.cc.input.cursor, 0, len(q))], th)
		chrome_dl.ui_draw_rect(ctx.dl, {cx, ty - 2.0 * ctx.s, 2.0 * ctx.s, th + 4.0 * ctx.s}, chrome_with_alpha(COLOR_CHROME_ACCENT, ctx.e))
	}
	txt, col := q, COLOR_CHROME_TEXT
	if len(q) == 0 do txt, col = CC_PLACEHOLDERS[ctx.cc.mode], COLOR_CHROME_TEXT_FAINT
	chrome_dl.ui_draw_text(ctx.dl, {tx, ty, ctx.modal_w - 2.0 * P - 18.0 * ctx.s, th}, txt, chrome_with_alpha(col, ctx.e))
	chrome_dl.ui_draw_rect(ctx.dl, {ctx.modal_x + P, sy + sh, ctx.modal_w - 2.0 * P, 1.0 * ctx.s}, chrome_with_alpha(COLOR_CHROME_BORDER, ctx.e))
}

@(private = "file")
_cc_draw_action_row :: proc(ctx: Cc_Ctx, action: Action_Id, r: [4]f32) {
	meta, ok := action_get_metadata(action)
	if !ok do return
	s, seg := ctx.s, meta.shortcut
	if i := strings.index(seg, " / "); i >= 0 do seg = seg[:i]
	labels := _cc_split_keycaps(seg)
	total: f32 = 0
	for lb in labels do total += _cc_keycap_w(ctx.m, lb)
	if len(labels) > 1 do total += 3.0 * s * f32(len(labels) - 1)
	kx := r[0] + r[2] - 14.0 * s - total
	for lb in labels {
		kw := _cc_keycap_w(ctx.m, lb)
		_cc_draw_keycap(ctx.dl, ctx.m, ctx.e, {kx, r[1] + 5.0 * s, kw, 20.0 * s}, lb, 11.5 * s)
		kx += kw + 3.0 * s
	}
	max_w := r[2] - 28.0 * s - (total + 10.0 * s if total > 0 else 0)
	chrome_dl.ui_draw_text(ctx.dl, {r[0] + 14.0 * s, r[1] + 7.0 * s, max_w, 13.5 * s}, meta.title, chrome_with_alpha(COLOR_CHROME_TEXT, ctx.e))
	if len(meta.description) > 0 do chrome_dl.ui_draw_text(ctx.dl, {r[0] + 14.0 * s, r[1] + 25.0 * s, max_w, 11.0 * s}, meta.description, chrome_with_alpha(COLOR_CHROME_TEXT_MUTED, ctx.e))
}

@(private = "file")
_cc_draw_tab_row :: proc(ctx: Cc_Ctx, tab_idx: int, r: [4]f32) {
	s := ctx.s
	is_active := ctx.src.tabs != nil && tab_idx == ctx.src.tabs.model.active_idx
	badge := fmt.tprintf("%d", tab_idx + 1)
	bw := _cc_keycap_w(ctx.m, badge)
	_cc_draw_keycap(ctx.dl, ctx.m, ctx.e, {r[0] + 12.0 * s, r[1] + 8.0 * s, bw, 20.0 * s}, badge, 11.5 * s)
	title := "Shell"
	if ctx.src.tabs != nil && tab_idx >= 0 && tab_idx < len(ctx.src.tabs.entries) {
		if e := &ctx.src.tabs.entries[tab_idx]; e.title_len > 0 do title = string(e.title_buf[:e.title_len])
	}
	tx, cw := r[0] + 12.0 * s + bw + 10.0 * s, chrome_text_width(ctx.m, "current", 11.5 * s)
	max_w := r[0] + r[2] - 14.0 * s - tx - (cw + 10.0 * s if is_active else 0.0)
	chrome_dl.ui_draw_text(ctx.dl, {tx, r[1] + 11.25 * s, max_w, 13.5 * s}, title, chrome_with_alpha(COLOR_CHROME_TEXT, ctx.e))
	if is_active do chrome_dl.ui_draw_text(ctx.dl, {r[0] + r[2] - 14.0 * s - cw, r[1] + 12.25 * s, cw, 11.5 * s}, "current", chrome_with_alpha(COLOR_CHROME_SUCCESS, ctx.e))
}

@(private = "file")
_cc_draw_session_row :: proc(ctx: Cc_Ctx, sess_id: u32, r: [4]f32) {
	s := ctx.s
	entry := sess_feat.session_registry_find(ctx.src.sessions, sess_id)
	title, state_str, dot_col := "shell", "idle", COLOR_CHROME_TEXT_FAINT
	if entry != nil {
		if tt := sess_feat.session_get_title(entry.session); len(tt) > 0 do title = tt
		#partial switch entry.state {
		case .Busy:   state_str, dot_col = "running", COLOR_CHROME_ACCENT
		case .Idle:   state_str, dot_col = "idle", COLOR_CHROME_TEXT_FAINT
		case .Exited: state_str, dot_col = "exited", COLOR_CHROME_DANGER
		}
		if entry.attention do dot_col = COLOR_CHROME_WARNING
	}
	chrome_dl.ui_draw_rounded_rect(ctx.dl, {r[0] + 14.0 * s, r[1] + 10.25 * s, 7.0 * s, 7.0 * s}, chrome_with_alpha(dot_col, ctx.e), 3.5 * s)
	chrome_dl.ui_draw_text(ctx.dl, {r[0] + 30.0 * s, r[1] + 7.0 * s, r[2] - 120.0 * s, 13.5 * s}, title, chrome_with_alpha(COLOR_CHROME_TEXT, ctx.e))
	if entry != nil {
		snap := sess_feat.session_snapshot_make(entry.session, 0, sess_id, context.temp_allocator)
		parts := make([dynamic]string, context.temp_allocator)
		append(&parts, fmt.tprintf("#%d", sess_id))
		if snap.pid > 0 do append(&parts, fmt.tprintf("pid %d", snap.pid))
		if b := snap.cwd; len(b) > 0 {
			if li := strings.last_index_byte(b, '/'); li >= 0 && li + 1 < len(b) do b = b[li+1:]
			append(&parts, b)
		}
		if len(snap.status_msg) > 0 do append(&parts, snap.status_msg)
		chrome_dl.ui_draw_text(ctx.dl, {r[0] + 30.0 * s, r[1] + 25.0 * s, r[2] - 120.0 * s, 11.0 * s}, strings.join(parts[:], " · ", context.temp_allocator), chrome_with_alpha(COLOR_CHROME_TEXT_MUTED, ctx.e))
	}
	sw := chrome_text_width(ctx.m, state_str, 11.5 * s)
	chrome_dl.ui_draw_text(ctx.dl, {r[0] + r[2] - 14.0 * s - sw, r[1] + 7.0 * s, sw, 11.5 * s}, state_str, chrome_with_alpha(COLOR_CHROME_TEXT_MUTED, ctx.e))
}

@(private = "file")
_cc_draw_list_rows :: proc(ctx: Cc_Ctx, P, row_start_y, cap_h, list_h: f32) {
	s := ctx.s
	if ctx.cc.row_count == 0 {
		msg := CC_EMPTY[ctx.cc.mode]
		tw := chrome_text_width(ctx.m, msg, 13.0 * s)
		chrome_dl.ui_draw_text(ctx.dl, {ctx.modal_x + (ctx.modal_w - tw) * 0.5, row_start_y + (list_h - 13.0 * s) * 0.5, tw, 13.0 * s}, msg, chrome_with_alpha(COLOR_CHROME_TEXT_MUTED, ctx.e))
		return
	}
	ctx.cc.row_rect_count = 0
	y := row_start_y
	for r in 0..<COMMAND_CENTER_VISIBLE_CAP {
		idx := ctx.cc.scroll_offset + r
		if idx >= ctx.cc.row_count do break
		row := ctx.cc.rows[idx]
		rh: f32 = 28.0 * s if row.kind == .Header else (36.0 * s if row.kind == .Tab else 44.0 * s)
		if y + rh - row_start_y > cap_h && ctx.cc.row_rect_count > 0 do break
		rrect := [4]f32{ctx.modal_x + P, y, ctx.modal_w - 2.0 * P, rh}
		if ctx.cc.visible && ctx.cc.row_rect_count < COMMAND_CENTER_VISIBLE_CAP {
			ctx.cc.row_rects[ctx.cc.row_rect_count], ctx.cc.row_rect_idx[ctx.cc.row_rect_count] = rrect, idx
			ctx.cc.row_rect_count += 1
		}
		is_sel := idx == ctx.cc.selected_idx
		if row.kind != .Header {
			if is_sel do chrome_dl.ui_draw_rounded_rect(ctx.dl, rrect, chrome_with_alpha(COLOR_CHROME_ACCENT_SOFT, ctx.e), 8.0 * s)
			else if idx == ctx.cc.hover_idx do chrome_dl.ui_draw_rounded_rect(ctx.dl, rrect, chrome_with_alpha(COLOR_CHROME_HOVER, ctx.e), 8.0 * s)
		}
		switch row.kind {
		case .Header:
			t := ACTION_CATEGORY_TITLES[row.category]
			chrome_dl.ui_draw_text(ctx.dl, {rrect[0] + 14.0 * s, rrect[1] + 12.0 * s, rrect[2] - 28.0 * s, 10.5 * s}, t, chrome_with_alpha(COLOR_CHROME_TEXT_FAINT, ctx.e))
		case .Action:  _cc_draw_action_row(ctx, row.action, rrect)
		case .Tab:     _cc_draw_tab_row(ctx, row.tab_index, rrect)
		case .Session: _cc_draw_session_row(ctx, row.session_id, rrect)
		}
		y += rh
	}
}

@(private = "file")
_cc_draw_footer :: proc(ctx: Cc_Ctx, P, row_start_y, list_h: f32) {
	s := ctx.s
	fdiv_y := row_start_y + list_h
	chrome_dl.ui_draw_rect(ctx.dl, {ctx.modal_x + P, fdiv_y, ctx.modal_w - 2.0 * P, 1.0 * s}, chrome_with_alpha(COLOR_CHROME_BORDER, ctx.e))
	fy, fx := fdiv_y + 1.0 * s, ctx.modal_x + 14.0 * s
	HINTS := [4][2]string{{"↵", "Open"}, {"⇥", "Mode"}, {"⌘⌫", "Kill"}, {"esc", "Close"}}
	for h, i in HINTS {
		if i == 2 && ctx.cc.mode != .Sessions do continue
		k, l := h[0], h[1]
		kw, lw := _cc_keycap_w(ctx.m, k), chrome_text_width(ctx.m, l, 11.0 * s)
		_cc_draw_keycap(ctx.dl, ctx.m, ctx.e, {fx, fy + 8.0 * s, kw, 18.0 * s}, k, 10.0 * s)
		chrome_dl.ui_draw_text(ctx.dl, {fx + kw + 4.0 * s, fy + 11.5 * s, lw, 11.0 * s}, l, chrome_with_alpha(COLOR_CHROME_TEXT_FAINT, ctx.e))
		fx += kw + 4.0 * s + lw + 14.0 * s
	}
}

command_center_emit_draw_list :: proc(cc: ^Command_Center_State, src: Command_Center_Sources, dl: ^chrome_dl.Ui_Draw_List, layout: ^Layout_State) {
	if cc == nil || dl == nil || layout == nil || (!cc.visible && !cc.closing) do return
	s := max(1.0, layout.metrics.scale)
	e := 1.0 - (1.0 - cc.anim_t) * (1.0 - cc.anim_t) * (1.0 - cc.anim_t)
	chrome_dl.ui_draw_rect(dl, {0, 0, layout.screen_w, layout.screen_h}, chrome_with_alpha(COLOR_CHROME_BACKDROP, e))

	mw := min(clamp(layout.screen_w * 0.46, 560.0 * s, 720.0 * s), layout.screen_w - 32.0 * s)
	mx, my := (layout.screen_w - mw) * 0.5, max(72.0 * s, layout.screen_h * 0.16) + (1.0 - e) * 8.0 * s
	cap_h := layout.screen_h * 0.55
	list_h := _cc_calc_list_h(cc, s, cap_h)
	mh := 124.0 * s + list_h

	if cc.visible do cc.modal_rect = {mx, my, mw, mh}
	else do cc.modal_rect, cc.search_rect, cc.chip_rects, cc.row_rect_count = {}, {}, {}, 0

	chrome_dl.ui_draw_shadow(dl, {mx - 4.0 * s, my + 4.0 * s, mw + 8.0 * s, mh + 8.0 * s}, chrome_with_alpha(COLOR_CHROME_SHADOW, e), 24.0 * s)
	chrome_dl.ui_draw_rounded_rect(dl, {mx, my, mw, mh}, chrome_with_alpha(COLOR_CHROME_SURFACE, e), 14.0 * s)
	chrome_dl.ui_draw_border(dl, {mx, my, mw, mh}, chrome_with_alpha(COLOR_CHROME_BORDER, e), 14.0 * s, 1.0 * s)

	ctx := Cc_Ctx{cc = cc, src = src, dl = dl, m = layout.metrics, s = s, e = e, modal_x = mx, modal_y = my, modal_w = mw, modal_h = mh}
	P := 6.0 * s
	_cc_draw_chips(ctx)
	_cc_draw_search(ctx, P)
	row_start_y := my + 83.0 * s
	_cc_draw_list_rows(ctx, P, row_start_y, cap_h, list_h)
	if cc.row_count > COMMAND_CENTER_VISIBLE_CAP {
		th, max_s := max(24.0 * s, list_h * (f32(COMMAND_CENTER_VISIBLE_CAP) / f32(cc.row_count))), f32(cc.row_count - COMMAND_CENTER_VISIBLE_CAP)
		chrome_dl.ui_draw_rounded_rect(dl, {mx + mw - 5.0 * s, row_start_y + (list_h - th) * (f32(cc.scroll_offset) / max_s if max_s > 0 else 0), 3.0 * s, th}, chrome_with_alpha(COLOR_CHROME_TEXT_FAINT, e), 1.5 * s)
	}
	_cc_draw_footer(ctx, P, row_start_y, list_h)
}
