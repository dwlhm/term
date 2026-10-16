package term

// Term Configuration, Visual Constants & Color Palette
// Part of Tier 3 Application Shell (src/app/term/*).

WINDOW_MARGIN:        f32 : 8.0
PANE_GAP:             f32 : 8.0
BORDER_RADIUS:        f32 : 8.0
TAB_BAR_HEIGHT:       f32 : 38.0
AUTO_HIDE_TRIGGER_Y:  f32 : 52.0

DEFAULT_CELL_WIDTH:   f32 : 9.5
DEFAULT_CELL_HEIGHT:  f32 : 19.0

Visual_Metrics :: struct {
	scale:               f32,
	cell_w:              f32,
	cell_h:              f32,
	window_margin:       f32,
	pane_gap:            f32,
	border_radius:       f32,
	tab_bar_height:      f32,
	auto_hide_trigger_y: f32,
	traffic_clearance:   f32,
	pane_pad_x:          f32,
	pane_pad_y:          f32,
}

visual_metrics_make :: proc(scale: f32 = 1.0) -> Visual_Metrics {
	s := max(1.0, scale)
	return Visual_Metrics{
		scale               = s,
		cell_w              = DEFAULT_CELL_WIDTH * s,
		cell_h              = DEFAULT_CELL_HEIGHT * s,
		window_margin       = WINDOW_MARGIN * s,
		pane_gap            = PANE_GAP * s,
		border_radius       = BORDER_RADIUS * s,
		tab_bar_height      = TAB_BAR_HEIGHT * s,
		auto_hide_trigger_y = AUTO_HIDE_TRIGGER_Y * s,
		traffic_clearance   = 78.0 * s,
		pane_pad_x          = 10.0 * s,
		pane_pad_y          = 6.0 * s,
	}
}

// One Dark Pro 16-Color ANSI Palette
PALETTE_COLORS := [16][4]f32{
	{0.08, 0.09, 0.11, 1.0}, // 0: Black / Pane background
	{0.88, 0.42, 0.46, 1.0}, // 1: Red
	{0.60, 0.76, 0.47, 1.0}, // 2: Green
	{0.90, 0.75, 0.48, 1.0}, // 3: Yellow
	{0.38, 0.69, 0.94, 1.0}, // 4: Blue
	{0.78, 0.47, 0.87, 1.0}, // 5: Magenta
	{0.34, 0.71, 0.76, 1.0}, // 6: Cyan
	{0.67, 0.70, 0.75, 1.0}, // 7: Light Gray
	{0.36, 0.39, 0.44, 1.0}, // 8: Dark Gray
	{1.00, 0.47, 0.51, 1.0}, // 9: Bright Red
	{0.67, 0.86, 0.51, 1.0}, // 10: Bright Green
	{1.00, 0.82, 0.51, 1.0}, // 11: Bright Yellow
	{0.43, 0.75, 1.00, 1.0}, // 12: Bright Blue
	{0.86, 0.55, 0.94, 1.0}, // 13: Bright Magenta
	{0.39, 0.78, 0.86, 1.0}, // 14: Bright Cyan
	{0.94, 0.94, 0.96, 1.0}, // 15: Bright White
}

color_from_palette_256 :: proc(idx: u8) -> [4]f32 {
	if idx < 16 {
		return PALETTE_COLORS[idx]
	}

	if idx < 232 {
		// 6x6x6 RGB color cube (indices 16..231)
		c := idx - 16
		b_val := c % 6
		g_val := (c / 6) % 6
		r_val := c / 36

		r := f32(r_val == 0 ? 0 : r_val * 40 + 55) / 255.0
		g := f32(g_val == 0 ? 0 : g_val * 40 + 55) / 255.0
		b := f32(b_val == 0 ? 0 : b_val * 40 + 55) / 255.0
		return {r, g, b, 1.0}
	}

	// 24-step grayscale ramp (indices 232..255)
	gray := f32((idx - 232) * 10 + 8) / 255.0
	return {gray, gray, gray, 1.0}
}

// Background & Card Colors
COLOR_WINDOW_BG       := [4]f32{0.05, 0.06, 0.08, 1.0}
COLOR_PANE_BG         := [4]f32{0.08, 0.09, 0.12, 0.96}
COLOR_PANE_BORDER     := [4]f32{0.16, 0.19, 0.25, 0.80}
COLOR_PANE_FOCUS      := [4]f32{0.25, 0.55, 0.95, 0.90}

// Tab Colors
COLOR_TAB_INACTIVE_BG := [4]f32{0.12, 0.14, 0.19, 0.75}
COLOR_TAB_ACTIVE_BG   := [4]f32{0.20, 0.25, 0.35, 0.95}
COLOR_TAB_ACTIVE_LINE := [4]f32{0.30, 0.65, 1.00, 1.00}
COLOR_TAB_TEXT_ACTIVE := [4]f32{0.95, 0.96, 0.98, 1.00}
COLOR_TAB_TEXT_INACT  := [4]f32{0.60, 0.65, 0.72, 0.85}

// Cursor & Selection Colors
COLOR_CURSOR_BLOCK    := [4]f32{0.28, 0.68, 1.00, 0.85}
COLOR_SELECTION_BG    := [4]f32{0.24, 0.45, 0.78, 0.55}
