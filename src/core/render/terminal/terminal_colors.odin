package render_terminal

// Terminal Palette, Direct Color, Selection & Hyperlink Highlight Resolution.

import "core:math"
import core_terminal "../../terminal"
import cell "../../terminal/cell"

COLOR_WORDS_PER_CELL :: 3 // fg ARGB, bg ARGB, underline ARGB (0 = use fg)
COLOR_BYTES_PER_CELL :: COLOR_WORDS_PER_CELL * size_of(u32)

RAW_PALETTE_COLORS: [16][3]u8 = {
	{20, 23, 31},    // 0: Default Dark Background ({0.08, 0.09, 0.12})
	{224, 108, 117}, // 1: Red
	{152, 195, 121}, // 2: Green
	{229, 192, 123}, // 3: Yellow
	{97, 175, 239},  // 4: Blue
	{198, 120, 221}, // 5: Magenta
	{86, 182, 194},  // 6: Cyan
	{171, 178, 191}, // 7: Light Gray
	{92, 99, 112},   // 8: Dark Gray
	{255, 120, 130}, // 9: Bright Red
	{170, 220, 130}, // 10: Bright Green
	{255, 210, 130}, // 11: Bright Yellow
	{110, 190, 255}, // 12: Bright Blue
	{220, 140, 240}, // 13: Bright Magenta
	{100, 200, 220}, // 14: Bright Cyan
	{240, 240, 245}, // 15: Bright White
}

PALETTE_PRECOMPUTED: [16][4]f32

// Hyperlink_Highlight marks the contiguous OSC 8 run under the pointer.
// `row` is a logical grid row and the column range is inclusive.
Hyperlink_Highlight :: struct {
	active:    bool,
	row:       int,
	col_start: int,
	col_end:   int,
	blocked:   bool,
}

HOVER_OPENABLE_BG: [4]f32 : {0.141, 0.322, 0.220, 1.0} // dark green
HOVER_BLOCKED_BG:  [4]f32 : {0.380, 0.161, 0.149, 1.0} // dark red

COLOR_CURSOR_BLOCK_DEFAULT: [4]f32 : {0.28, 0.68, 1.00, 0.90}
COLOR_CURSOR_TEXT_DEFAULT:  [4]f32 : {0.08, 0.09, 0.12, 1.00}

rgb_to_r5g6b5 :: #force_inline proc "contextless" (r, g, b: u8) -> u16 {
	r5 := (u16(r) * 31 + 127) / 255
	g6 := (u16(g) * 63 + 127) / 255
	b5 := (u16(b) * 31 + 127) / 255
	return (r5 << 11) | (g6 << 5) | b5
}

unpack_r5g6b5 :: #force_inline proc "contextless" (packed: u16) -> [4]f32 {
	r := math.round(f32((packed >> 11) & 0x1F) / 31.0 * 255.0) / 255.0
	g := math.round(f32((packed >> 5) & 0x3F) / 63.0 * 255.0) / 255.0
	b := math.round(f32(packed & 0x1F) / 31.0 * 255.0) / 255.0
	return {r, g, b, 1.0}
}

init_palette_colors :: proc() {
	for i in 0..<16 {
		c := RAW_PALETTE_COLORS[i]
		PALETTE_PRECOMPUTED[i] = unpack_r5g6b5(rgb_to_r5g6b5(c[0], c[1], c[2]))
	}
}

_terminal_renderer_resolve_active_bg :: proc(
	term: ^core_terminal.Terminal,
	scroll_offset: int,
	has_custom_bg: bool,
	custom_bg: [4]f32,
	is_focused: bool,
	pane_opacity: f32,
) -> [4]f32 {
	eff_opacity := clamp(pane_opacity, 0.0, 1.0)
	active_bg: [4]f32 = {0.08, 0.09, 0.12, eff_opacity}
	if has_custom_bg {
		active_bg = {custom_bg[0], custom_bg[1], custom_bg[2], custom_bg[3] * eff_opacity}
	} else if dc, pal, ok := core_terminal.terminal_sample_bg(term, scroll_offset); ok {
		if dc.has_bg {
			active_bg = {f32(dc.bg[0]) / 255.0, f32(dc.bg[1]) / 255.0, f32(dc.bg[2]) / 255.0, eff_opacity}
		} else if pal != 0 {
			p_col := PALETTE_PRECOMPUTED[pal & 15]
			active_bg = {p_col[0], p_col[1], p_col[2], eff_opacity}
		}
	}
	if !is_focused {
		active_bg = {active_bg[0] * 0.70, active_bg[1] * 0.70, active_bg[2] * 0.70, eff_opacity}
	}
	return active_bg
}

_terminal_renderer_resolve_colors :: #force_inline proc(
	cell_val: cell.Semantic_Cell,
	dc: cell.Direct_Color,
	is_selected: bool,
	default_bg: [4]f32,
	is_focused: bool = true,
) -> (fg, bg: [4]f32) {
	has_direct_fg := .Has_Direct_Color in cell_val.flags && dc.has_fg
	has_direct_bg := .Has_Direct_Color in cell_val.flags && dc.has_bg

	fg = {f32(dc.fg[0]) / 255.0, f32(dc.fg[1]) / 255.0, f32(dc.fg[2]) / 255.0, 1.0} if has_direct_fg else PALETTE_PRECOMPUTED[cell_val.fg & 15]
	bg = {f32(dc.bg[0]) / 255.0, f32(dc.bg[1]) / 255.0, f32(dc.bg[2]) / 255.0, 1.0} if has_direct_bg else (PALETTE_PRECOMPUTED[cell_val.bg & 15] if cell_val.bg != 0 else default_bg)

	if .Bold in cell_val.style && cell_val.fg < 8 && !has_direct_fg {
		fg = PALETTE_PRECOMPUTED[(cell_val.fg + 8) & 15]
	}
	if .Dim in cell_val.style {
		fg[0] *= 0.6; fg[1] *= 0.6; fg[2] *= 0.6
	}
	if .Invert in cell_val.style {
		fg, bg = bg, fg
	}
	if is_selected {
		fg = {1.0, 1.0, 1.0, 1.0}
		bg = {0.23, 0.39, 0.70, 0.60}
	} else if !is_focused {
		fg[0] *= 0.55
		fg[1] *= 0.55
		fg[2] *= 0.55
		fg[3] = 1.0

		if has_direct_bg || cell_val.bg != 0 {
			bg[0] *= 0.70
			bg[1] *= 0.70
			bg[2] *= 0.70
			bg[3] = 1.0
		}
	}
	return fg, bg
}

// _terminal_renderer_underline_rgb resolves the stored SGR 58 colour, falling
// back to the cell's foreground for the default pen colour (SGR 59).
_terminal_renderer_underline_rgb :: #force_inline proc(
	dc: cell.Direct_Color,
	fg: [4]f32,
) -> [4]f32 {
	switch dc.underline.mode {
	case .Rgb:
		return {f32(dc.underline.rgb[0]) / 255.0, f32(dc.underline.rgb[1]) / 255.0, f32(dc.underline.rgb[2]) / 255.0, fg[3]}
	case .Palette:
		return PALETTE_PRECOMPUTED[dc.underline.index & 15]
	case .Default:
	}
	return fg
}

_terminal_renderer_is_cell_selected :: #force_inline proc "contextless" (
	logical_r, c: int,
	selection_active: bool,
	sel_r_start, sel_c_start, sel_r_end, sel_c_end: int,
) -> bool {
	if !selection_active || logical_r < sel_r_start || logical_r > sel_r_end do return false
	if sel_r_start == sel_r_end && sel_c_start >= 0 && sel_c_end >= 0 {
		return c >= min(sel_c_start, sel_c_end) && c <= max(sel_c_start, sel_c_end)
	}
	if logical_r == sel_r_start && sel_c_start >= 0 do return c >= sel_c_start
	if logical_r == sel_r_end && sel_c_end >= 0 do return c <= sel_c_end
	return true
}

_terminal_renderer_is_cell_hovered :: #force_inline proc "contextless" (
	logical_r, c: int,
	hover: Hyperlink_Highlight,
) -> bool {
	if !hover.active || logical_r != hover.row do return false
	return c >= hover.col_start && c <= hover.col_end
}
