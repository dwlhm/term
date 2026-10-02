package ui

import "core:fmt"
import "core:math"
import render "../render"
import instance "../render/instance"
import i18n "../i18n"

UI_MAX_INSTANCES :: 512
UI_CHROME_CELL_WIDTH: f32 : 8
UI_CHROME_CELL_HEIGHT: f32 : 16

UI_Render :: render.Renderer
Color :: [4]f32

emit_bg :: proc(r: ^render.Renderer, x, y, w, h: f32, col: [4]f32) {
	if w > 0 && h > 0 && r.ui_bg_count < render.RENDER_MAX_UI_INSTANCES {
		r.ui_bg_data[r.ui_bg_count] = instance.Instance_Data{
			x = x, y = y, cw = w, ch = h,
			u0 = 0, v0 = 0, u1 = 0, v1 = 0,
			r = col.r, g = col.g, b = col.b, a = col.a,
		}
		r.ui_bg_count += 1
	}
}

emit_bg_params :: proc(r: ^render.Renderer, x, y, w, h: f32, col: [4]f32, params: [4]f32) {
	if w > 0 && h > 0 && r.ui_bg_count < render.RENDER_MAX_UI_INSTANCES {
		r.ui_bg_data[r.ui_bg_count] = instance.Instance_Data{
			x = x, y = y, cw = w, ch = h,
			u0 = params[0], v0 = params[1], u1 = params[2], v1 = params[3],
			r = col.r, g = col.g, b = col.b, a = col.a,
		}
		r.ui_bg_count += 1
	}
}

// One shared surface consumes immutable logical-space wave origins.
ui_stage_water_surface :: proc(r: ^UI_Render, screen_w, screen_h, scale: f32, waves: []instance.Water_Wave, base_col: Color) {
	if r == nil do return
	r.instances.uniform_data.water_meta = {}
	r.instances.uniform_data.waves = {}
	for value in ([4]f32{screen_w, screen_h, scale, base_col.a}) {
		if math.is_nan(value) || math.is_inf(value) || value <= 0 do return
	}
	for value in base_col {
		if math.is_nan(value) || math.is_inf(value) do return
	}
	if r.ui_bg_count >= render.RENDER_MAX_UI_INSTANCES do return
	count := 0
	for wave in waves {
		valid := true
		for value in wave.origin_age_strength {
			if math.is_nan(value) || math.is_inf(value) { valid = false }
		}
		for value in wave.lifetime_params {
			if math.is_nan(value) || math.is_inf(value) { valid = false }
		}
		if !valid || wave.origin_age_strength[2] < 0 || wave.lifetime_params[0] <= 0 || wave.origin_age_strength[2] >= wave.lifetime_params[0] || wave.origin_age_strength[3] <= 0 do continue
		r.instances.uniform_data.waves[count] = wave
		count += 1
		if count == instance.WATER_MAX_WAVES do break
	}
	if count == 0 do return
	r.instances.uniform_data.water_meta = {f32(count), scale, 0, 0}
	emit_bg_params(r, 0, 0, screen_w, screen_h, base_col, {0, 0, 0, -3})
}

// ui_stage_water_3d_hover emits a full-window quad for the 3D calm water breathing effect.
ui_stage_water_3d_hover :: proc(r: ^UI_Render, screen_w, screen_h, cx, cy, hover_time: f32, base_col: Color) {
	if r == nil || screen_w <= 0 || screen_h <= 0 || base_col.a <= 0.005 do return
	params := [4]f32{cx, cy, hover_time, -1.0}
	emit_bg_params(r, 0, 0, screen_w, screen_h, base_col, params)
}

// ui_stage_water_3d_splash emits a full-window quad for the 3D water impact wave propagating across the whole window.
ui_stage_water_3d_splash :: proc(r: ^UI_Render, screen_w, screen_h, cx, cy, time, max_t: f32, base_col: Color) {
	if r == nil || screen_w <= 0 || screen_h <= 0 || max_t <= 0 || time < 0 || time >= max_t || base_col.a <= 0.005 do return
	params := [4]f32{cx, cy, time / max_t, -2.0}
	emit_bg_params(r, 0, 0, screen_w, screen_h, base_col, params)
}

// ui_draw_water_ring draws a circular ring with given center (cx, cy), radius, thickness, and color.
ui_draw_water_ring :: proc(r: ^UI_Render, cx, cy, radius, thickness: f32, col: Color) {
	if r == nil || radius < 1 || thickness <= 0 || col.a <= 0.005 do return
	// Scale number of segments with radius to keep ring smooth and continuous
	segments := int(math.clamp(radius * 1.5, 32, 72))
	step := (2.0 * math.PI) / f32(segments)
	dot_size := math.max(thickness, (2.0 * math.PI * radius / f32(segments)) * 1.2)
	for i in 0..<segments {
		ang := f32(i) * step
		x := cx + radius * math.cos(ang) - dot_size * 0.5
		y := cy + radius * math.sin(ang) - dot_size * 0.5
		emit_bg(r, x, y, dot_size, dot_size, col)
	}
}

// ui_draw_ripple_fx draws concentric circular water rings.
ui_draw_ripple_fx :: proc(
	r: ^UI_Render,
	cx, cy: f32,
	radius: f32,
	ring_count: int,
	spacing: f32,
	base_color: Color,
) {
	if r == nil || ring_count <= 0 || base_color.a <= 0.005 do return
	for i in 0..<ring_count {
		r_i := radius - f32(i) * spacing
		if r_i <= 0 do continue
		fade := 1.0 - (f32(i) / f32(ring_count)) * 0.5
		col := Color{base_color.r, base_color.g, base_color.b, base_color.a * fade}
		ui_draw_water_ring(r, cx, cy, r_i, 1.5, col)
	}
}

// ui_draw_hover_ripple renders subtle, calm breathing concentric water ripples centered at (cx, cy).
ui_draw_hover_ripple :: proc(r: ^UI_Render, cx, cy, hover_time: f32, base_col: Color) {
	if r == nil || base_col.a <= 0.005 do return
	// Calm breathing water effect: 2-3 gentle concentric rings pulsating softly around the cursor.
	// Radius breathing between ~20px and ~50px using sine wave over hover_time.
	// Alpha gentle (e.g. 0.25 to 0.45).
	for i in 0..<3 {
		pulse := 0.5 + 0.5 * math.sin(hover_time * 2.5 - f32(i) * 1.0)
		radius := 18.0 + f32(i) * 14.0 + pulse * 8.0
		alpha := base_col.a * (0.25 + 0.2 * (0.5 + 0.5 * math.cos(hover_time * 2.5 - f32(i) * 1.0)))
		ring_col := Color{base_col.r, base_col.g, base_col.b, alpha}
		ui_draw_water_ring(r, cx, cy, radius, 1.8, ring_col)
	}
	// Soft glowing center point
	emit_bg(r, cx - 2, cy - 2, 4, 4, Color{base_col.r, base_col.g, base_col.b, base_col.a * 0.35})
}

// ui_draw_splash_ripple renders an expanding shockwave ripple effect emanating from (cx, cy).
ui_draw_splash_ripple :: proc(r: ^UI_Render, cx, cy, time, max_t: f32, base_col: Color) {
	if r == nil || time >= max_t || max_t <= 0 || base_col.a <= 0.005 do return
	// Expands rapidly outward from 0 to ~200px with ease-out curve.
	// Features 2-3 concentric waves spreading out, with alpha fading to 0 as time reaches max_t.
	MAX_RADIUS: f32 : 200.0
	for wave in 0..<3 {
		delay := f32(wave) * 0.12
		if time < delay do continue
		wave_t := (time - delay) / (max_t - delay)
		if wave_t < 0 || wave_t > 1.0 do continue
		inv := 1.0 - wave_t
		ease_out := 1.0 - (inv * inv * inv) // ease-out cubic
		radius := ease_out * MAX_RADIUS
		fade := 1.0 - wave_t
		alpha := base_col.a * fade * (0.65 - f32(wave) * 0.15)
		thickness := math.max(1.2, 2.8 * fade)
		ring_col := Color{base_col.r, base_col.g, base_col.b, alpha}
		ui_draw_water_ring(r, cx, cy, radius, thickness, ring_col)
	}
}

emit_char :: proc(r: ^render.Renderer, x, y, cw, ch: f32, cp: rune, col: [4]f32) {
	if r.ui_glyph_count >= render.RENDER_MAX_UI_INSTANCES do return
	_, s := render.atlas_get_slot(&r.atlas, u32(cp))
	if s.valid {
		r.ui_glyph_data[r.ui_glyph_count] = instance.Instance_Data{
			x = x, y = y, cw = cw, ch = ch,
			u0 = s.u0, v0 = s.v0, u1 = s.u1, v1 = s.v1,
			r = col.r, g = col.g, b = col.b, a = 1.0,
		}
		r.ui_glyph_count += 1
	}
}

// _emit_runes stages a rune slice as glyphs starting at (x, y), advancing by cw.
_emit_runes :: proc(r: ^render.Renderer, runes: []rune, x, y, cw, ch: f32, col: [4]f32) {
	if r == nil do return
	tx := x
	for cp in runes {
		emit_char(r, tx, y, cw, ch, cp, col)
		tx += cw
	}
}

// _emit_text_clipped stages at most max_cols runes of text on a single line.
_emit_text_clipped :: proc(r: ^render.Renderer, text: string, x, y, cw, ch: f32, max_cols: int, col: [4]f32) {
	if r == nil || cw <= 0 || ch <= 0 || max_cols <= 0 do return
	tx := x
	n := 0
	for cp in text {
		if n >= max_cols do break
		emit_char(r, tx, y, cw, ch, cp, col)
		tx += cw
		n += 1
	}
}

// _emit_text_wrapped2 stages text on at most two lines, breaking at a space
// inside the first line and ellipsizing the tail when it still does not fit.
// A fixed 256-rune scratch buffer keeps the steady state allocation-free.
_emit_text_wrapped2 :: proc(r: ^render.Renderer, text: string, x, y, cw, ch: f32, max_cols: int, line_gap: f32, col: [4]f32) {
	if r == nil || cw <= 0 || ch <= 0 || max_cols <= 1 do return

	buf: [256]rune
	n := 0
	for cp in text {
		if n >= len(buf) do break
		buf[n] = cp
		n += 1
	}
	if n == 0 do return

	if n <= max_cols {
		_emit_runes(r, buf[:n], x, y, cw, ch, col)
		return
	}

	break_idx := -1
	for i := max_cols; i > 0; i -= 1 {
		if buf[i - 1] == ' ' {
			break_idx = i - 1
			break
		}
	}

	ellipsis := [1]rune{'\u2026'}
	if break_idx <= 0 {
		// No usable space: ellipsize the first line only.
		_emit_runes(r, buf[:max_cols - 1], x, y, cw, ch, col)
		_emit_runes(r, ellipsis[:], x + f32(max_cols - 1) * cw, y, cw, ch, col)
		return
	}

	_emit_runes(r, buf[:break_idx], x, y, cw, ch, col)
	second_y := y + ch + line_gap
	remain := n - (break_idx + 1)
	if remain <= max_cols {
		_emit_runes(r, buf[break_idx + 1:n], x, second_y, cw, ch, col)
	} else {
		_emit_runes(r, buf[break_idx + 1:break_idx + max_cols], x, second_y, cw, ch, col)
		_emit_runes(r, ellipsis[:], x + f32(max_cols - 1) * cw, second_y, cw, ch, col)
	}
}

// _emit_button_label stages a centered single-line label inside a rect.
_emit_button_label :: proc(r: ^render.Renderer, rect: Rect_f32, label: string, cw, ch: f32, col: [4]f32) {
	if r == nil || cw <= 0 || ch <= 0 || len(label) == 0 do return
	label_runes := 0
	for _ in label do label_runes += 1
	lx := rect.x + (rect.w - f32(label_runes) * cw) * 0.5
	ly := rect.y + (rect.h - ch) * 0.5
	for cp in label {
		emit_char(r, lx, ly, cw, ch, cp, col)
		lx += cw
	}
}

// _rune_count returns the number of runes in s.
_rune_count :: proc(s: string) -> int {
	n := 0
	for _ in s do n += 1
	return n
}

// _emit_button_label_pair centers "label  hint" inside rect, hint in a fainter color.
_emit_button_label_pair :: proc(r: ^render.Renderer, rect: Rect_f32, label, hint: string, cw, ch: f32, label_col, hint_col: [4]f32) {
	if r == nil || cw <= 0 || ch <= 0 do return
	lr := _rune_count(label)
	hr := _rune_count(hint)
	total := lr + hr
	if hr > 0 do total += 1
	x := rect.x + (rect.w - f32(total) * cw) * 0.5
	y := rect.y + (rect.h - ch) * 0.5
	for cp in label {
		emit_char(r, x, y, cw, ch, cp, label_col)
		x += cw
	}
	if hr > 0 {
		x += cw
		for cp in hint {
			emit_char(r, x, y, cw, ch, cp, hint_col)
			x += cw
		}
	}
}

// _tab_glyph_in_viewport reports whether a glyph spanning [x, x+cw) lies inside the visible tab strip.
_tab_glyph_in_viewport :: proc(x, cw: f32, viewport: Rect_f32) -> bool {
	return x >= viewport.x && (x + cw) <= viewport.x + viewport.w
}

// ui_render_stage stages UI quads and glyphs directly into the Renderer instance buffer. Zero allocation steady-state.
ui_render_stage :: proc(
	r:            ^render.Renderer,
	theme:        ^UI_Theme,
	copy:         ^i18n.Strings,
	tab_state:    ^Tab_Bar_State,
	tabs:         []UI_Tab_Info,
	tab_rects:    []Rect_f32,
	search_state: ^Search_Bar_State,
	window_w:     f32,
	window_h:     f32,
	scale:        f32 = 1,
	window_title: string = "",
	tab_drag:      ^Tab_Drag_State = nil,
	tab_menu:      ^Tab_Menu_State = nil,
	tab_rename:    ^Tab_Rename_State = nil,
	confirm_state: ^Confirm_Dialog_State = nil,
	tab_overflow: ^Tab_Overflow_State = nil,
	session_switcher: ^Session_Switcher_State = nil,
) -> int {
	if r == nil || theme == nil || tab_state == nil {
		return 0
	}

	r.ui_staged = false
	r.ui_bg_count = 0
	r.ui_glyph_count = 0

	content_scale := scale if scale > 0 else 1
	cw := UI_CHROME_CELL_WIDTH
	ch := UI_CHROME_CELL_HEIGHT

	// 1. Tab Bar Background
	emit_bg(r, tab_state.rect.x, tab_state.rect.y, tab_state.rect.w, tab_state.rect.h, theme.surface_bar)
	emit_bg(r, 0, TAB_BAR_HEIGHT - 1.0, window_w, 1.0, theme.border_subtle)

	// 2. Typographic Tab Strip
	tab_count := min(len(tabs), len(tab_rects))
	for i in 0 ..< tab_count {
		if r.ui_glyph_count >= render.RENDER_MAX_UI_INSTANCES do break
		rect := tab_rects[i]
		if rect.w <= 0 do continue
		tab := tabs[i]

		tx := rect.x
		ty := (TAB_BAR_HEIGHT - ch) * 0.5

		// '[' and '{i+1}' in text_faint
		emit_char(r, tx, ty, cw, ch, '[', theme.text_faint)
		tx += cw

		num_buf: [16]u8
		num_str := fmt.bprintf(num_buf[:], "%d", i + 1)
		for cp in num_str {
			emit_char(r, tx, ty, cw, ch, cp, theme.text_faint)
			tx += cw
		}

		// If tab.has_bell, · in accent_primary
		if tab.has_bell {
			emit_char(r, tx, ty, cw, ch, '\u00B7', theme.accent_primary)
			tx += cw
		}

		// ']' in text_faint
		emit_char(r, tx, ty, cw, ch, ']', theme.text_faint)
		tx += cw

		// Space
		tx += cw

		// Title color
		text_col := theme.text_primary if tab.is_active else theme.text_muted
		if tab.is_exited {
			text_col = theme.status_danger
		}

		is_editing := tab_rename != nil && tab_rename.active && i == tab_rename.tab_idx
		title_str := tab.title
		if is_editing {
			title_str = tab_rename_text(tab_rename)
		}

		max_title := tab_state.max_title_len if tab_state.max_title_len > 0 else 16
		r_count := _rune_count(title_str)

		if r_count <= max_title {
			for cp in title_str {
				emit_char(r, tx, ty, cw, ch, cp, text_col)
				tx += cw
			}
		} else {
			emitted := 0
			for cp in title_str {
				if emitted >= max_title - 1 do break
				emit_char(r, tx, ty, cw, ch, cp, text_col)
				tx += cw
				emitted += 1
			}
			emit_char(r, tx, ty, cw, ch, '\u2026', text_col)
			tx += cw
		}

		if is_editing {
			caret_x := rect.x + f32(4 + tab_rename.len) * cw
			emit_bg(r, caret_x, ty, 1.0, ch, theme.accent_primary)
		}

		// If active: 2px underline at y = TAB_BAR_HEIGHT - 2 in accent_primary
		if tab.is_active {
			emit_bg(r, rect.x, TAB_BAR_HEIGHT - 2.0, max(0, rect.w - TAB_GAP), 2.0, theme.accent_primary)
		}
	}

	// +N in accent_primary if overflow_count > 0
	if tab_state.overflow_count > 0 && tab_state.overflow_indicator_rect.w > 0 && r.ui_glyph_count < render.RENDER_MAX_UI_INSTANCES {
		btn := tab_state.overflow_indicator_rect
		buf: [16]u8
		lbl := fmt.bprintf(buf[:], "+%d", tab_state.overflow_count)
		lx := btn.x + 4.0
		ly := (TAB_BAR_HEIGHT - ch) * 0.5
		for cp in lbl {
			emit_char(r, lx, ly, cw, ch, cp, theme.accent_primary)
			lx += cw
		}
	}

	// '+' in text_muted (hover: text_primary)
	if tab_state.new_tab_rect.w > 0 && r.ui_glyph_count < render.RENDER_MAX_UI_INSTANCES {
		btn := tab_state.new_tab_rect
		col := theme.text_primary if tab_state.hover_new_tab else theme.text_muted
		emit_char(r, btn.x + (btn.w - cw) * 0.5, (TAB_BAR_HEIGHT - ch) * 0.5, cw, ch, '+', col)
	}

	// '○ N detached' badge if detached_count > 0 (clickable to open Session Switcher)
	if tab_state.detached_count > 0 && tab_state.detached_badge_rect.w > 0 && r.ui_glyph_count < render.RENDER_MAX_UI_INSTANCES {
		btn := tab_state.detached_badge_rect
		if tab_state.hover_detached {
			emit_bg(r, btn.x + 2.0, 2.0, max(0.0, btn.w - 4.0), TAB_BAR_HEIGHT - 4.0, theme.surface_hover)
		}
		bx := btn.x + 4.0
		by := (TAB_BAR_HEIGHT - ch) * 0.5
		emit_char(r, bx, by, cw, ch, '○', theme.accent_primary if tab_state.hover_detached else theme.text_muted)
		bx += cw + 4.0
		buf: [32]u8
		lbl := fmt.bprintf(buf[:], "%d detached", tab_state.detached_count)
		text_col := theme.text_primary if tab_state.hover_detached else theme.text_muted
		for cp in lbl {
			if bx + cw > btn.x + btn.w do break
			emit_char(r, bx, by, cw, ch, cp, text_col)
			bx += cw
		}
	}

	// Trailing right area is completely clean/empty.

	// 4. Floating Search Bar
	if search_state != nil && search_state.visible && r.ui_bg_count < render.RENDER_MAX_UI_INSTANCES {
		sr := search_state.rect
		emit_bg(r, sr.x, sr.y, sr.w, sr.h, theme.surface_card)

		border_col := theme.border_subtle
		if search_state.is_invalid_regex {
			border_col = theme.status_danger
		} else if search_state.match_count > 0 {
			border_col = theme.accent_primary
		}
		emit_bg(r, sr.x, sr.y, sr.w, 1.0, border_col)
		emit_bg(r, sr.x, sr.y + sr.h - 1.0, sr.w, 1.0, border_col)
		emit_bg(r, sr.x, sr.y, 1.0, sr.h, border_col)
		emit_bg(r, sr.x + sr.w - 1.0, sr.y, 1.0, sr.h, border_col)

		sy := sr.y + (sr.h - ch) * 0.5
		sx := sr.x + 8.0
		emit_char(r, sx, sy, cw, ch, '/', theme.accent_primary)
		sx += cw + 4.0

		q_text := string(search_state.query[:search_state.query_len])
		for cp in q_text {
			if sx + cw > sr.x + sr.w - 150.0 do break
			emit_char(r, sx, sy, cw, ch, cp, theme.text_primary)
			sx += cw
		}

		badge_buf: [32]u8
		badge_str: string
		if search_state.match_count > 0 {
			badge_str = fmt.bprintf(badge_buf[:], "%d/%d", search_state.match_idx + 1, search_state.match_count)
		} else if search_state.query_len > 0 {
			badge_str = "0/0"
		}
		if len(badge_str) > 0 {
			bx := sr.x + sr.w - 140.0
			for cp in badge_str {
				emit_char(r, bx, sy, cw, ch, cp, theme.text_muted)
				bx += cw
			}
		}

		// Prev button '<'
		prev_x := sr.x + sr.w - 68.0
		prev_col := theme.text_primary if search_state.hover_target == .Btn_Prev else theme.text_muted
		emit_char(r, prev_x, sy, cw, ch, '<', prev_col)

		// Next button '>'
		next_x := sr.x + sr.w - 44.0
		next_col := theme.text_primary if search_state.hover_target == .Btn_Next else theme.text_muted
		emit_char(r, next_x, sy, cw, ch, '>', next_col)

		// Close button '\u2715'
		cx := sr.x + sr.w - 20.0
		close_col := theme.status_danger if search_state.hover_target == .Btn_Close else theme.text_muted
		emit_char(r, cx, sy, cw, ch, '\u2715', close_col)

		search_hint := "\u21E7\u21B5 prev  \u21B5 next  esc close"
		hx := sr.x
		hy := sr.y + sr.h + theme.spacing.xs
		for cp in search_hint {
			emit_char(r, hx, hy, cw, ch, cp, theme.text_faint)
			hx += cw
		}
	}

	// 5. Tab drag overlay: accent drop indicator plus a ghost tab under the pointer.
	if tab_drag != nil && tab_drag.phase == .Dragging {
		gap_x := tab_bar_gap_x(tab_state, tab_count, tab_rects, tab_drag.drop_gap)
		emit_bg(r, gap_x, 0, 2.0, TAB_BAR_HEIGHT, theme.accent_primary)

		ghost_w := tab_state.tab_w if tab_state.tab_w > 0 else TAB_MIN_W
		ghost_x := tab_drag.pointer_x - ghost_w * 0.5
		emit_bg(r, ghost_x, 0, ghost_w, TAB_BAR_HEIGHT, theme.surface_card)
		emit_bg(r, ghost_x, 0, ghost_w, 2.0, theme.accent_primary)
	}

	// 6. Tab context menu: the discovery surface for every tab action.
	if tab_menu != nil && tab_menu.visible {
		mr := tab_menu.rect
		emit_bg(r, mr.x, mr.y, mr.w, mr.h, theme.surface_card)
		emit_bg(r, mr.x, mr.y, mr.w, 1.0, theme.border_subtle)
		emit_bg(r, mr.x, mr.y + mr.h - 1.0, mr.w, 1.0, theme.border_subtle)
		emit_bg(r, mr.x, mr.y, 1.0, mr.h, theme.border_subtle)
		emit_bg(r, mr.x + mr.w - 1.0, mr.y, 1.0, mr.h, theme.border_subtle)

		for k in 0 ..< TAB_MENU_ITEM_COUNT {
			item := Tab_Menu_Item(k)
			ir := tab_menu.item_rects[k]
			disabled := tab_menu.disabled[k]
			if !disabled && (k == tab_menu.hover_item || k == tab_menu.active_item) {
				emit_bg(r, ir.x, ir.y, ir.w, ir.h, theme.surface_hover)
			}

			shortcut := tab_menu_item_shortcut(item)
			sc_runes := 0
			for _ in shortcut do sc_runes += 1
			sc_w := f32(sc_runes) * cw

			label := tab_menu_item_label(copy, item)
			label_col := theme.text_muted if disabled else theme.text_primary
			lx := ir.x + theme.spacing.md
			ly := ir.y + (ir.h - ch) * 0.5
			label_max_x := ir.x + ir.w - theme.spacing.md - sc_w - theme.spacing.sm
			for cp in label {
				if lx + cw > label_max_x do break
				emit_char(r, lx, ly, cw, ch, cp, label_col)
				lx += cw
			}

			if sc_runes > 0 {
				sx := ir.x + ir.w - theme.spacing.md - sc_w
				for cp in shortcut {
					emit_char(r, sx, ly, cw, ch, cp, theme.text_muted)
					sx += cw
				}
			}
		}
	}

	// 7. Confirm dialog: a flat card raised over the content. No scrim is drawn
	// because the background pipeline is opaque and the flat design intentionally
	// omits a translucent overlay.
	if confirm_state != nil && confirm_state.visible {
		c := copy
		if c == nil do c = i18n.i18n_get()

		cr := confirm_state.rect
		emit_bg(r, cr.x, cr.y, cr.w, cr.h, theme.surface_card)
		emit_bg(r, cr.x, cr.y, cr.w, 1.0, theme.border_subtle)
		emit_bg(r, cr.x, cr.y + cr.h - 1.0, cr.w, 1.0, theme.border_subtle)
		emit_bg(r, cr.x, cr.y, 1.0, cr.h, theme.border_subtle)
		emit_bg(r, cr.x + cr.w - 1.0, cr.y, 1.0, cr.h, theme.border_subtle)

		pad := theme.spacing.md
		max_cols := 0
		if cw > 0 {
			max_cols = int(max(0, cr.w - pad * 2.0) / cw)
		}
		tx := cr.x + pad
		ty := cr.y + pad
		_emit_text_clipped(r, c.dialog_close_title, tx, ty, cw, ch, max_cols, theme.text_primary)
		_emit_text_wrapped2(r, c.dialog_close_body, tx, ty + ch + theme.spacing.sm, cw, ch, max_cols, theme.spacing.sm, theme.text_muted)

		confirm_fill := theme.surface_active
		if confirm_state.hover_target == .Btn_Confirm {
			confirm_fill = theme.surface_hover
		}
		cancel_fill := theme.surface_card
		if confirm_state.hover_target == .Btn_Cancel {
			cancel_fill = theme.surface_hover
		}
		emit_bg(r, confirm_state.confirm_rect.x, confirm_state.confirm_rect.y, confirm_state.confirm_rect.w, confirm_state.confirm_rect.h, confirm_fill)
		emit_bg(r, confirm_state.cancel_rect.x, confirm_state.cancel_rect.y, confirm_state.cancel_rect.w, confirm_state.cancel_rect.h, cancel_fill)
		_emit_button_label_pair(r, confirm_state.confirm_rect, c.dialog_confirm, ui_shortcut_label(.Confirm), cw, ch, theme.text_primary, theme.text_faint)
		_emit_button_label_pair(r, confirm_state.cancel_rect, c.dialog_cancel, ui_shortcut_label(.Cancel), cw, ch, theme.text_primary, theme.text_faint)
	}

	if tab_overflow != nil && tab_overflow.visible {
		m := tab_overflow
		emit_bg(r, m.rect.x, m.rect.y, m.rect.w, m.rect.h, theme.surface_card)
		emit_bg(r, m.rect.x, m.rect.y, m.rect.w, 1.0, theme.border_subtle)
		emit_bg(r, m.rect.x, m.rect.y + m.rect.h - 1.0, m.rect.w, 1.0, theme.border_subtle)
		emit_bg(r, m.rect.x, m.rect.y, 1.0, m.rect.h, theme.border_subtle)
		emit_bg(r, m.rect.x + m.rect.w - 1.0, m.rect.y, 1.0, m.rect.h, theme.border_subtle)
		for row in 0 ..< m.visible_rows {
			idx := m.scroll_row + row
			if idx >= len(tabs) do break
			ir := tab_overflow_row_rect(m, row)
			if tabs[idx].id == m.selected_tab_id {
				emit_bg(r, ir.x, ir.y, ir.w, ir.h, theme.surface_hover)
			}
			pad := theme.spacing.md
			col := theme.accent_primary if tabs[idx].is_active else theme.text_primary

			// Format: `[{i+1}] {title}   ⌘{i+1}`
			num_buf: [32]u8
			prefix := fmt.bprintf(num_buf[:], "[%d] ", idx + 1)
			px := ir.x + pad
			py := ir.y + (ir.h - ch) * 0.5
			for cp in prefix {
				emit_char(r, px, py, cw, ch, cp, theme.text_faint)
				px += cw
			}

			shortcut_buf: [32]u8
			shortcut_str := ""
			if idx < 9 {
				shortcut_str = fmt.bprintf(shortcut_buf[:], "⌘%d", idx + 1)
			}
			shortcut_w := f32(_rune_count(shortcut_str)) * cw

			avail_title_w := max(0, ir.w - pad * 2 - (px - ir.x - pad) - shortcut_w - cw)
			title_cols := int(avail_title_w / cw)
			_emit_text_clipped(r, tabs[idx].title, px, py, cw, ch, title_cols, col)

			if len(shortcut_str) > 0 {
				sx := ir.x + ir.w - pad - shortcut_w
				for cp in shortcut_str {
					emit_char(r, sx, py, cw, ch, cp, theme.text_faint)
					sx += cw
				}
			}
		}
	}

	if session_switcher != nil && session_switcher.visible {
		cr := session_switcher.rect
		pad := theme.spacing.md

		// 1. Backdrop card & borders
		emit_bg(r, cr.x, cr.y, cr.w, cr.h, theme.surface_card)
		emit_bg(r, cr.x, cr.y, cr.w, 1.0, theme.border_subtle)
		emit_bg(r, cr.x, cr.y + cr.h - 1.0, cr.w, 1.0, theme.border_subtle)
		emit_bg(r, cr.x, cr.y, 1.0, cr.h, theme.border_subtle)
		emit_bg(r, cr.x + cr.w - 1.0, cr.y, 1.0, cr.h, theme.border_subtle)

		// 2. Search header: "> {query}_" and right-aligned "[{match_count} matches]"
		header_h: f32 = 38.0
		hy := cr.y + (header_h - ch) * 0.5
		emit_char(r, cr.x + pad, hy, cw, ch, '>', theme.accent_primary)

		hx := cr.x + pad + cw * 2
		q_str := string(session_switcher.query[:session_switcher.query_len])
		_emit_text_clipped(r, q_str, hx, hy, cw, ch, 36, theme.text_primary)

		cursor_x := hx + f32(session_switcher.query_len) * cw
		emit_char(r, cursor_x, hy, cw, ch, '_', theme.accent_primary)

		count_buf: [48]u8
		count_str := fmt.bprintf(count_buf[:], "[%d match%s • %d detached]", session_switcher.match_count, "es" if session_switcher.match_count != 1 else "", session_switcher.detached_count)
		count_w := f32(len(count_str)) * cw
		count_x := cr.x + cr.w - pad - count_w
		_emit_text_clipped(r, count_str, count_x, hy, cw, ch, len(count_str), theme.text_faint)

		// 3. Horizontal divider below header
		emit_bg(r, cr.x, cr.y + header_h, cr.w, 1.0, theme.border_subtle)

		// 4. Matched rows
		row_h: f32 = 26.0
		if session_switcher.match_count == 0 {
			no_match_y := cr.y + header_h + (row_h - ch) * 0.5 + 4.0
			_emit_text_clipped(r, "No matching sessions", cr.x + pad, no_match_y, cw, ch, 32, theme.text_faint)
		} else {
			visible_rows := min(session_switcher.match_count, 8)
			for row in 0 ..< visible_rows {
				item_idx := session_switcher.matches[row]
				item := session_switcher.items[item_idx]
				ry := cr.y + header_h + 1.0 + f32(row) * row_h

				if row == session_switcher.selected_match_idx {
					emit_bg(r, cr.x + 4.0, ry + 1.0, cr.w - 8.0, row_h - 2.0, theme.surface_hover)
				}

				glyph_y := ry + (row_h - ch) * 0.5
				rx := cr.x + pad

				// Status glyph: ● (active tab), ○ (detached), or ⊞ (layout)
				glyph_cp: rune = '⊞' if item.is_persisted else (!item.is_detached ? '●' : '○')
				glyph_col := theme.status_success if item.is_persisted else (!item.is_detached ? theme.accent_primary : theme.text_faint)
				emit_char(r, rx, glyph_y, cw, ch, glyph_cp, glyph_col)
				rx += cw * 2

				// Item text: [{slot}] {title} ({status})
				slot_buf: [16]u8
				slot_str := fmt.bprintf(slot_buf[:], "[%d]", item.tab_idx + 1) if item.tab_idx >= 0 else (item.is_persisted ? "[L]" : "[–]")
				status_str := "layout" if item.is_persisted else (!item.is_detached ? "active" : "detached")
				title_buf: [128]u8
				title_str := fmt.bprintf(title_buf[:], "%s %s (%s)", slot_str, item.title, status_str)
				title_cols := 22
				_emit_text_clipped(r, title_str, rx, glyph_y, cw, ch, title_cols, theme.text_primary)
				rx += f32(min(len(title_str), title_cols)) * cw + cw * 2

				// PID
				if item.pid > 0 {
					pid_buf: [32]u8
					pid_str := fmt.bprintf(pid_buf[:], "PID %d", item.pid)
					_emit_text_clipped(r, pid_str, rx, glyph_y, cw, ch, 10, theme.text_faint)
					rx += f32(len(pid_str)) * cw + cw * 2
				}

				// Metrics
				if item.rss_mb > 0 {
					metric_buf: [32]u8
					metric_str := fmt.bprintf(metric_buf[:], "%d MB", item.rss_mb)
					_emit_text_clipped(r, metric_str, rx, glyph_y, cw, ch, 10, theme.text_muted)
					rx += f32(len(metric_str)) * cw + cw * 2
				}

				// CWD truncated
				if len(item.cwd) > 0 {
					rem_w := max(0.0, cr.x + cr.w - pad - rx)
					rem_cols := int(rem_w / cw)
					if rem_cols > 0 {
						_emit_text_clipped(r, item.cwd, rx, glyph_y, cw, ch, rem_cols, theme.text_faint)
					}
				}
			}
		}

		// 5. Footer divider and hint bar
		footer_h: f32 = 28.0
		footer_y := cr.y + cr.h - footer_h
		emit_bg(r, cr.x, footer_y, cr.w, 1.0, theme.border_subtle)
		hint_y := footer_y + (footer_h - ch) * 0.5
		hints := "↑/↓: Navigate  •  Enter: Open  •  ⌥⌘b: Detach  •  Esc: Close"
		hint_cols := int((cr.w - pad * 2) / cw)
		_emit_text_clipped(r, hints, cr.x + pad, hint_y, cw, ch, hint_cols, theme.text_faint)
	}

	// Convert once at the GPU boundary; hit rectangles remain in logical units.
	for &quad in r.ui_bg_data[:r.ui_bg_count] {
		quad.x *= content_scale
		quad.y *= content_scale
		quad.cw *= content_scale
		quad.ch *= content_scale
	}
	for &quad in r.ui_glyph_data[:r.ui_glyph_count] {
		quad.x *= content_scale
		quad.y *= content_scale
		quad.cw *= content_scale
		quad.ch *= content_scale
	}
	if r.ui_bg_count > 0 || r.ui_glyph_count > 0 {
		r.ui_staged = true
	}
	return int(r.ui_bg_count + r.ui_glyph_count)
}

// Pane_Divider defines geometry and hover state for multi-pane split chrome.
Pane_Divider :: struct {
	x, y, w, h: f32,
	is_hovered: bool,
}

// ui_stage_pane_chrome stages 1px hairline dividers and active pane outline border.
ui_stage_pane_chrome :: proc(
	r:                  ^UI_Render,
	theme:              ^UI_Theme,
	dividers:           []Pane_Divider,
	active_rect:        Rect_f32,
	show_active_border: bool,
	scale:              f32 = 1.0,
) {
	if r == nil || theme == nil do return
	s := scale if scale > 0 else 1.0

	// 1. Dividers
	for div in dividers {
		col := theme.surface_hover if div.is_hovered else theme.border_subtle
		emit_bg(r, div.x * s, div.y * s, max(f32(1.0), div.w * s), max(f32(1.0), div.h * s), col)
	}

	// 2. Active pane outline (1px hairline)
	if show_active_border && active_rect.w > 0 && active_rect.h > 0 {
		col := theme.accent_primary
		border_size := max(f32(1.0), 1.0 * s)
		ax := active_rect.x * s
		ay := active_rect.y * s
		aw := active_rect.w * s
		ah := active_rect.h * s

		// Top
		emit_bg(r, ax, ay, aw, border_size, col)
		// Bottom
		emit_bg(r, ax, ay + ah - border_size, aw, border_size, col)
		// Left
		emit_bg(r, ax, ay, border_size, ah, col)
		// Right
		emit_bg(r, ax + aw - border_size, ay, border_size, ah, col)
	}

	if len(dividers) > 0 || show_active_border {
		r.ui_staged = true
	}
}

// ui_stage_hollow_cursor emits a 1-cell hollow box cursor outline for inactive panes.
ui_stage_hollow_cursor :: proc(
	r:     ^UI_Render,
	x, y:  f32,
	w, h:  f32,
	col:   [4]f32 = {0.75, 0.75, 0.75, 0.75},
	scale: f32 = 1.0,
) {
	if r == nil || w <= 0 || h <= 0 do return
	s := scale if scale > 0 else 1.0
	sx := x * s
	sy := y * s
	sw := w * s
	sh := h * s
	t := max(f32(1.0), 1.0 * s)

	// Top
	emit_bg(r, sx, sy, sw, t, col)
	// Bottom
	emit_bg(r, sx, sy + sh - t, sw, t, col)
	// Left
	emit_bg(r, sx, sy, t, sh, col)
	// Right
	emit_bg(r, sx + sw - t, sy, t, sh, col)

	r.ui_staged = true
}

