package render_terminal

// Instanced Cell Batch Encoding & Render Pass Submission.

import "core:time"
import contract "../contract"
import "instance"
import kitty "kitty"
import core_terminal "../../terminal"
import cell "../../terminal/cell"
import grid "../../terminal/grid"
import plat_font "../../../platform/font"
import uw "../../unicode_width"

@(private = "file")
_encode_egc_cell :: proc(
	r: ^Terminal_Renderer, term: ^core_terminal.Terminal,
	gam: ^plat_font.Glyph_Atlas_Manager, emoji_atlas: ^plat_font.Emoji_Atlas_Manager,
	ch: rune, cell_style: cell.Style_Flags, dc: cell.Direct_Color,
	x_pos, y_pos, gw, cell_h: f32, fg, bg: [4]f32, is_wide, is_italic, is_bold, is_focused: bool,
) -> (handled: bool, fallback_ch: rune) {
	runes := core_terminal.terminal_get_egc_runes(term, ch)
	if len(runes) == 0 || runes[0] == 0x10EEEE do return true, 0
	if emoji_atlas != nil && plat_font.is_emoji_cluster(runes) {
		if eg, eok := plat_font.emoji_atlas_get_runes(emoji_atlas, runes); eok {
			_terminal_renderer_push_emoji(r, eg, x_pos, y_pos, gw, cell_h, bg, is_focused)
			return true, 0
		}
	}
	if slot, sok := plat_font.glyph_atlas_get_or_rasterize_cluster(gam, runes, is_wide); sok {
		_terminal_renderer_push_glyph(r, gam, slot, x_pos, y_pos, cell_h, fg, bg, is_italic, is_bold)
		_terminal_renderer_push_decorations(r, cell_style, dc, x_pos, y_pos, gw, cell_h, fg)
		return true, 0
	}
	return false, runes[0]
}

@(private = "file")
_encode_cell :: proc(
	r: ^Terminal_Renderer, term: ^core_terminal.Terminal,
	gam: ^plat_font.Glyph_Atlas_Manager, emoji_atlas: ^plat_font.Emoji_Atlas_Manager,
	row: ^grid.Row, c: int, lig_char: u32, x_pos, y_pos, cell_w, cell_h: f32,
	active_bg, hover_openable_bg, hover_blocked_bg: [4]f32,
	is_selected, is_hovered, hover_blocked, is_focused: bool,
) {
	cell_val := row.cells[c]
	if .Wide_Continuation in cell_val.flags && c > 0 && .Wide_Lead in row.cells[c - 1].flags do return
	dc := row.direct_colors[c] if (.Has_Direct_Color in cell_val.flags || .Has_Underline_Decor in cell_val.flags) && c < len(row.direct_colors) else cell.Direct_Color{}
	cell_style := cell_val.style + ({.Underline} if is_hovered || .Has_Hyperlink in cell_val.flags else {})
	if !is_selected && cell_val.char <= ' ' && cell_val.bg == 0 && cell_style == {} && .Has_Hyperlink not_in cell_val.flags && !dc.has_bg do return

	ch, is_wide, is_italic, is_bold := cell_val.char, .Wide_Lead in cell_val.flags, .Italic in cell_style, .Bold in cell_style
	gw := cell_w * 2.0 if is_wide else cell_w
	fg, bg := _terminal_renderer_resolve_colors(cell_val, dc, is_selected, active_bg, is_focused)
	if is_hovered do bg = hover_blocked_bg if hover_blocked else hover_openable_bg
	if !((.Has_Direct_Color in cell_val.flags && dc.has_bg) || cell_val.bg != 0 || is_selected || is_hovered || (.Invert in cell_val.style)) do bg = {0, 0, 0, 0}
	if .Hidden in cell_val.style do fg = bg

	if lig_char >= plat_font.CONTENT_LIGATURE_BASE {
		slot, ok := plat_font.glyph_atlas_get_or_rasterize(gam, rune(lig_char), false)
		_terminal_renderer_push_glyph(r, gam, slot if ok else 0, x_pos, y_pos, cell_h, fg, bg, is_italic, is_bold)
		_terminal_renderer_push_decorations(r, cell_style, dc, x_pos, y_pos, gw, cell_h, fg)
		return
	}
	if .Has_Egc in cell_val.flags {
		handled: bool
		if handled, ch = _encode_egc_cell(r, term, gam, emoji_atlas, ch, cell_style, dc, x_pos, y_pos, gw, cell_h, fg, bg, is_wide, is_italic, is_bold, is_focused); handled do return
	}
	if ch == 0x10EEEE do return
	if emoji_atlas != nil && uw.is_emoji_presentation(ch) {
		if eg, eok := plat_font.emoji_atlas_get(emoji_atlas, ch); eok do _terminal_renderer_push_emoji(r, eg, x_pos, y_pos, gw, cell_h, bg, is_focused)
		return
	}
	slot, ok := plat_font.glyph_atlas_get_or_rasterize(gam, ch, is_wide)
	_terminal_renderer_push_glyph(r, gam, slot if ok else 0, x_pos, y_pos, cell_h, fg, bg, is_italic, is_bold)
	_terminal_renderer_push_decorations(r, cell_style, dc, x_pos, y_pos, gw, cell_h, fg)
}

@(private = "file")
_submit_terminal_pass :: proc(
	r: ^Terminal_Renderer,
	enc: contract.Gpu_CommandEncoder,
	term: ^core_terminal.Terminal,
	target_view: contract.Gpu_TextureView,
	pane_rect: [4]f32,
	screen_w, screen_h: f32,
	load_op: contract.Gpu_Load_Op,
) {
	has_kitty := kitty.kitty_renderer_has_images(&r.kitty_rend, term)
	if r.inst_rend.active_count == 0 && r.emoji_rend.active_count == 0 && load_op != .Clear && !has_kitty do return
	pass := contract.begin_render_pass(enc, target_view, {0.0, 0.0, 0.0, 0.0}, load_op)
	if rawptr(pass) == nil do return

	sc_x, sc_y := u32(clamp(pane_rect[0], 0.0, screen_w)), u32(clamp(pane_rect[1], 0.0, screen_h))
	sc_w := max(1, u32(clamp(pane_rect[2], 1.0, max(1.0, screen_w - f32(sc_x)))))
	sc_h := max(1, u32(clamp(pane_rect[3], 1.0, max(1.0, screen_h - f32(sc_y)))))
	if contract.render_set_scissor_rect != nil do contract.render_set_scissor_rect(pass, sc_x, sc_y, sc_w, sc_h)

	front_count := instance.instance_renderer_front_count(&r.inst_rend)
	if front_count > 0 {
		contract.render_set_pipeline(pass, r.bg_pipeline)
		contract.render_set_bind_group(pass, 0, r.inst_rend.bg_bind_group)
		contract.render_set_vertex_buffer(pass, 0, r.inst_rend.instance_buffer, 0)
		contract.render_draw(pass, 6, front_count)
	}
	kitty.kitty_renderer_draw(&r.kitty_rend, pass, term)
	if front_count > 0 do instance.instance_renderer_draw(&r.inst_rend, pass)
	if r.inst_rend.overlay_count > 0 {
		contract.render_set_pipeline(pass, r.bg_pipeline)
		contract.render_set_bind_group(pass, 0, r.inst_rend.bg_bind_group)
		instance.instance_renderer_draw_overlays(&r.inst_rend, pass)
	}
	if r.emoji_rend.active_count > 0 do instance.instance_renderer_draw(&r.emoji_rend, pass)
	if contract.render_set_scissor_rect != nil do contract.render_set_scissor_rect(pass, 0, 0, max(1, u32(screen_w)), max(1, u32(screen_h)))
	contract.end_render_pass(pass)
}

terminal_renderer_encode :: proc(
	r: ^Terminal_Renderer,
	enc: contract.Gpu_CommandEncoder,
	term: ^core_terminal.Terminal,
	target_view: contract.Gpu_TextureView,
	text_atlas: ^plat_font.Text_Atlas,
	pane_rect: [4]f32,
	cell_w, cell_h, pad_x, pad_y: f32,
	scroll_offset: int,
	screen_w, screen_h: f32,
	has_custom_bg: bool,
	custom_bg: [4]f32,
	selected_logical_r_start: int = -1,
	selected_c_start: int = -1,
	selected_logical_r_end: int = -1,
	selected_c_end: int = -1,
	selection_active: bool = false,
	hover: Hyperlink_Highlight = {},
	hover_openable_bg: [4]f32 = HOVER_OPENABLE_BG,
	hover_blocked_bg:  [4]f32 = HOVER_BLOCKED_BG,
	load_op: contract.Gpu_Load_Op = .Load,
	border_radius: f32 = 0.0,
	is_focused: bool = true,
	pane_opacity: f32 = 0.45,
) {
	if r == nil || rawptr(enc) == nil || term == nil || rawptr(target_view) == nil || text_atlas == nil do return

	journal := core_terminal.terminal_consume_damage(term)
	rows := max(1, min(term.rows, int((pane_rect[3] - 2.0 * pad_y) / cell_h)))
	cols := max(1, min(term.cols, int((pane_rect[2] - 2.0 * pad_x) / cell_w)))
	_terminal_renderer_ensure_resources(r, u32(cols), u32(rows), text_atlas.glyph_view, text_atlas.emoji_view)

	dirty_cells := 0
	if journal.has_damage {
		dirty_w := max(1, min(journal.max_col, cols) - max(journal.min_col, 0))
		dirty_h := max(1, min(journal.max_row, rows - 1) - max(journal.min_row, 0) + 1)
		dirty_cells = min(max(1, rows * cols), dirty_w * dirty_h)
	}
	r.last_dirty_cells = dirty_cells

	t_start := time.tick_now()
	active_bg := _terminal_renderer_resolve_active_bg(term, scroll_offset, has_custom_bg, custom_bg, is_focused, pane_opacity)

	instance.instance_renderer_begin(&r.inst_rend)
	instance.instance_renderer_begin(&r.emoji_rend)
	u_data := [4]f32{screen_w, screen_h, cell_w, cell_h}
	contract.write_buffer(r.queue, r.inst_rend.uniform_buffer, 0, &u_data, size_of([4]f32))
	contract.write_buffer(r.queue, r.emoji_rend.uniform_buffer, 0, &u_data, size_of([4]f32))

	pane_bg := contract.Instance_Record{
		pos_size = pane_rect,
		uv_rect  = {pane_rect[2], pane_rect[3], border_radius, 1.0 if border_radius > 0.0 else 0.0},
		fg_color = {0, 0, 0, 0},
		bg_color = active_bg,
	}
	instance.instance_renderer_push(&r.inst_rend, pane_bg)
	kitty.kitty_renderer_prepare(&r.kitty_rend, term, pane_rect, cell_w, cell_h, pad_x, pad_y, scroll_offset)

	gam, emoji_atlas := &text_atlas.glyph_atlas, &text_atlas.emoji_atlas
	row_chars: [512]u32
	for r_idx in 0..<rows {
		logical_r := r_idx - scroll_offset
		row := core_terminal.terminal_get_row(term, logical_r)
		if row == nil do continue

		row_has_selection := selection_active && (
			(selected_logical_r_start <= logical_r && logical_r <= selected_logical_r_end) ||
			(selected_logical_r_end <= logical_r && logical_r <= selected_logical_r_start)
		)
		row_has_hover := hover.active && (logical_r == hover.row)

		// Fast path: completely empty row with no selection or hover
		if row.occ == 0 && !row_has_selection && !row_has_hover {
			continue
		}

		max_c := int(row.occ)
		if row_has_hover {
			max_c = max(max_c, hover.col_end + 1)
		}
		if row_has_selection {
			max_c = cols
		}
		limit_c := min(cols, min(len(row.cells), max_c))

		y_pos := pane_rect[1] + pad_y + f32(r_idx) * cell_h
		if gam.fc != nil {
			_apply_row_ligatures(&r.ligature_cache, &gam.fc.rasterizer, row, limit_c, row_chars[:min(limit_c, 512)])
		} else {
			for c in 0..<min(limit_c, 512) do row_chars[c] = u32(row.cells[c].char)
		}
		for c in 0..<limit_c {
			x_pos := pane_rect[0] + pad_x + f32(c) * cell_w
			is_sel := _terminal_renderer_is_cell_selected(logical_r, c, selection_active, selected_logical_r_start, selected_c_start, selected_logical_r_end, selected_c_end)
			is_hov := !is_sel && _terminal_renderer_is_cell_hovered(logical_r, c, hover)
			_encode_cell(
				r, term, gam, emoji_atlas, row, c,
				row_chars[c] if c < 512 else 0,
				x_pos, y_pos, cell_w, cell_h,
				active_bg, hover_openable_bg, hover_blocked_bg,
				is_sel, is_hov, hover.blocked, is_focused,
			)
		}
	}

	if plat_font.text_atlas_sync_gpu(text_atlas, r.device, r.queue) {
		_terminal_renderer_ensure_resources(r, u32(cols), u32(rows), text_atlas.glyph_view, text_atlas.emoji_view)
	}
	instance.instance_renderer_flush(&r.inst_rend)
	instance.instance_renderer_flush(&r.emoji_rend)

	_submit_terminal_pass(r, enc, term, target_view, pane_rect, screen_w, screen_h, load_op)
	r.last_duration_ns = u64(time.tick_since(t_start))
}

terminal_renderer_render :: proc(
	r: ^Terminal_Renderer,
	term: ^core_terminal.Terminal,
	target_view: contract.Gpu_TextureView,
	text_atlas: ^plat_font.Text_Atlas,
	pane_rect: [4]f32,
	cell_w, cell_h, pad_x, pad_y: f32,
	scroll_offset: int,
	screen_w, screen_h: f32,
	has_custom_bg: bool,
	custom_bg: [4]f32,
	selected_logical_r_start: int = -1,
	selected_c_start: int = -1,
	selected_logical_r_end: int = -1,
	selected_c_end: int = -1,
	selection_active: bool = false,
	hover: Hyperlink_Highlight = {},
	hover_openable_bg: [4]f32 = HOVER_OPENABLE_BG,
	hover_blocked_bg:  [4]f32 = HOVER_BLOCKED_BG,
	border_radius: f32 = 0.0,
	is_focused: bool = true,
	pane_opacity: f32 = 0.45,
) {
	if r == nil || term == nil || rawptr(target_view) == nil || text_atlas == nil do return
	enc := contract.create_command_encoder(r.device)
	if rawptr(enc) == nil do return
	defer contract.release_command_encoder(enc)

	terminal_renderer_encode(
		r, enc, term, target_view, text_atlas, pane_rect, cell_w, cell_h, pad_x, pad_y,
		scroll_offset, screen_w, screen_h, has_custom_bg, custom_bg,
		selected_logical_r_start, selected_c_start, selected_logical_r_end, selected_c_end,
		selection_active, hover, hover_openable_bg, hover_blocked_bg, .Load, border_radius, is_focused, pane_opacity,
	)

	cmd := contract.finish_command_buffer(enc)
	if rawptr(cmd) != nil {
		contract.submit(r.queue, cmd)
		contract.release_command_buffer(cmd)
	}
}
