package ui

import "core:fmt"
import render "../render"
import instance "../render/instance"

UI_MAX_INSTANCES :: 512

// UI_Tab_Info carries visual metadata for a tab item.
UI_Tab_Info :: struct {
	title:     string,
	is_active: bool,
	is_exited: bool,
	has_bell:  bool,
}

emit_bg :: proc(r: ^render.Renderer, x, y, w, h: f32, col: [4]f32) {
	if w > 0 && h > 0 && r.ui_bg_count < render.RENDER_MAX_UI_INSTANCES {
		r.ui_bg_data[r.ui_bg_count] = instance.Instance_Data{
			x = x, y = y, cw = w, ch = h,
			u0 = 0, v0 = 0, u1 = 0, v1 = 0,
			r = col.r, g = col.g, b = col.b, a = 1.0,
		}
		r.ui_bg_count += 1
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

// ui_render_stage stages UI quads and glyphs directly into the Renderer instance buffer. Zero allocation steady-state.
ui_render_stage :: proc(
	r:            ^render.Renderer,
	theme:        ^UI_Theme,
	style:        UI_Style,
	tab_state:    ^Tab_Bar_State,
	tabs:         []UI_Tab_Info,
	active_idx:   int,
	tab_rects:    []Rect_f32,
	search_state: ^Search_Bar_State,
	window_w:     f32,
	window_h:     f32,
	scale:        f32 = 1,
) -> int {
	if r == nil || theme == nil || tab_state == nil {
		return 0
	}

	r.ui_staged = false
	r.ui_bg_count = 0
	r.ui_glyph_count = 0

	content_scale := scale if scale > 0 else 1
	cw := r.cell_width / content_scale if r.cell_width > 0 else 8.0
	ch := r.cell_height / content_scale if r.cell_height > 0 else 16.0

	// 1. Tab Bar Background
	emit_bg(r, tab_state.rect.x, tab_state.rect.y, tab_state.rect.w, tab_state.rect.h, theme.surface_bar)
	emit_bg(r, 0, TAB_BAR_HEIGHT - 1.0, window_w, 1.0, theme.border_subtle)

	// 2. Tabs
	tab_count := min(len(tabs), len(tab_rects))
	for i in 0 ..< tab_count {
		if r.ui_bg_count >= render.RENDER_MAX_UI_INSTANCES || r.ui_glyph_count >= render.RENDER_MAX_UI_INSTANCES do break
		rect := tab_rects[i]
		tab := tabs[i]

		bg_col := theme.surface_bar
		if tab.is_active {
			bg_col = theme.surface_card
		} else if i == tab_state.hover_tab_idx {
			bg_col = theme.surface_hover
		}
		emit_bg(r, rect.x, rect.y, rect.w, rect.h - 1.0, bg_col)

		if tab.is_active {
			emit_bg(r, rect.x, 0, rect.w, 2.0, theme.accent_primary)
		}

		if rect.w >= 1 {
			emit_bg(r, rect.x + rect.w - 1.0, 4.0, 1.0, TAB_BAR_HEIGHT - 8.0, theme.border_subtle)
		}

		text_col := theme.text_primary if tab.is_active else theme.text_muted
		if tab.has_bell {
			text_col = theme.accent_primary
		} else if tab.is_exited {
			text_col = theme.status_danger
		}

		pad_left: f32 = 12.0
		tx := rect.x + pad_left
		ty := (TAB_BAR_HEIGHT - ch) * 0.5
		close_visible := (tab.is_active || i == tab_state.hover_tab_idx || i == tab_state.hover_close_idx) && rect.w >= TAB_CLOSE_MIN_WIDTH
		close_width := CLOSE_BTN_WIDTH if close_visible else 0
		max_text_w := rect.w - close_width - 4.0

		// Title text rendering with ellipsis if exceeding max_text_w
		title_len_px: f32 = 0
		for _ in tab.title {
			title_len_px += cw
		}

		if (tx + title_len_px) <= (rect.x + max_text_w) {
			for cp in tab.title {
				if tx + cw > rect.x + max_text_w || ch > rect.h do break
				emit_char(r, tx, ty, cw, ch, cp, text_col)
				tx += cw
			}
		} else {
			ellipsis_rune: rune = '\u2026'
			_, el_s := render.atlas_get_slot(&r.atlas, u32(ellipsis_rune))
			use_single_ellipsis := el_s.valid
			ellipsis_width: f32 = cw if use_single_ellipsis else (cw * 2)

			for cp in tab.title {
				if (tx + cw + ellipsis_width) > (rect.x + max_text_w) || ch > rect.h do break
				emit_char(r, tx, ty, cw, ch, cp, text_col)
				tx += cw
			}

			if use_single_ellipsis {
				if tx + cw <= rect.x + max_text_w && ch <= rect.h {
					emit_char(r, tx, ty, cw, ch, ellipsis_rune, text_col)
				}
			} else {
				if tx + cw <= rect.x + max_text_w && ch <= rect.h {
					emit_char(r, tx, ty, cw, ch, '.', text_col)
					tx += cw
				}
				if tx + cw <= rect.x + max_text_w && ch <= rect.h {
					emit_char(r, tx, ty, cw, ch, '.', text_col)
				}
			}
		}

		if close_visible && cw <= CLOSE_BTN_WIDTH && ch <= rect.h {
			close_x := rect.x + rect.w - CLOSE_BTN_WIDTH + (CLOSE_BTN_WIDTH - cw) * 0.5
			close_col := theme.text_muted
			if i == tab_state.hover_close_idx {
				close_col = theme.status_danger
				// Rounded hover pill ala Safari
				emit_bg(r, rect.x + rect.w - CLOSE_BTN_WIDTH + 2.0, (TAB_BAR_HEIGHT - (ch + 4.0)) * 0.5, CLOSE_BTN_WIDTH - 4.0, ch + 4.0, theme.surface_hover)
			}

			close_rune: rune = '\u2715'
			_, s := render.atlas_get_slot(&r.atlas, u32(close_rune))
			if !s.valid {
				close_rune = 0x2573 // Box Drawing diagonal cross (selalu prewarmed di atlas)
				_, s = render.atlas_get_slot(&r.atlas, u32(close_rune))
				if !s.valid {
					close_rune = 'x'
				}
			}
			emit_char(r, close_x, ty, cw, ch, close_rune, close_col)
		}
	}

	// 3. New Tab Button '+'
	if r.ui_bg_count < render.RENDER_MAX_UI_INSTANCES {
		button := tab_state.new_tab_rect
		btn_col := theme.surface_hover if tab_state.hover_new_tab else theme.surface_bar
		emit_bg(r, button.x, button.y, button.w, button.h - 1, btn_col)
		if cw <= button.w && ch <= button.h {
			emit_char(r, button.x + (button.w - cw) * 0.5, button.y + (button.h - ch) * 0.5, cw, ch, '+', theme.text_muted)
		}
	}

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

