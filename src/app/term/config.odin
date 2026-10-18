package term

// Term Configuration, Visual Constants & Color Palette
// Part of Tier 3 Application Shell (src/app/term/*).

import "core:encoding/json"
import "core:os"
import "core:strings"

DEFAULT_WINDOW_WIDTH:  i32 : 1280
DEFAULT_WINDOW_HEIGHT: i32 : 800
DEFAULT_FONT_SIZE:     f32 : 13.0

Window_Config :: struct {
	width:   i32  `json:"width"`,
	height:  i32  `json:"height"`,
	blur:    bool `json:"blur"`,
	opacity: f32  `json:"opacity"`,
}

Font_Config :: struct {
	size: f32 `json:"size"`,
}

Padding_Config :: struct {
	x: f32 `json:"x"`,
	y: f32 `json:"y"`,
}

App_Config :: struct {
	window_width:   i32            `json:"window_width"`,
	window_height:  i32            `json:"window_height"`,
	width:          i32            `json:"width"`,
	height:         i32            `json:"height"`,
	window:         Window_Config  `json:"window"`,
	font_size:      f32            `json:"font_size"`,
	font:           Font_Config    `json:"font"`,
	pad_x:          f32            `json:"pad_x"`,
	pad_y:          f32            `json:"pad_y"`,
	padding:        Padding_Config `json:"padding"`,
	blur:           bool           `json:"blur"`,
	window_opacity: f32            `json:"window_opacity"`,
}

config_default :: proc() -> App_Config {
	default_blur := true when ODIN_OS == .Darwin else false
	return App_Config{
		window_width   = DEFAULT_WINDOW_WIDTH,
		window_height  = DEFAULT_WINDOW_HEIGHT,
		font_size      = 0,
		pad_x          = -1.0,
		pad_y          = -1.0,
		padding        = {x = -1.0, y = -1.0},
		blur           = default_blur,
		window_opacity = -1.0,
		window         = {
			blur    = default_blur,
			opacity = -1.0,
		},
	}
}

DEFAULT_PANE_PAD_X: f32 : 4.0
DEFAULT_PANE_PAD_Y: f32 : 4.0

// config_resolve_padding extracts configured pad_x and pad_y, falling back to default (4.0).
config_resolve_padding :: proc(cfg: ^App_Config) -> (pad_x, pad_y: f32) {
	pad_x = DEFAULT_PANE_PAD_X
	pad_y = DEFAULT_PANE_PAD_Y
	if cfg != nil {
		if cfg.padding.x >= 0 do pad_x = cfg.padding.x
		else if cfg.pad_x >= 0 do pad_x = cfg.pad_x

		if cfg.padding.y >= 0 do pad_y = cfg.padding.y
		else if cfg.pad_y >= 0 do pad_y = cfg.pad_y
	}
	return pad_x, pad_y
}

// config_resolve_font_size extracts effective font size from config,
// falling back to fallback_size (or DEFAULT_FONT_SIZE = 14.0) if unset or non-positive.
config_resolve_font_size :: proc(cfg: ^App_Config, fallback_size: f32 = DEFAULT_FONT_SIZE) -> f32 {
	if cfg != nil {
		if cfg.font.size > 0 do return cfg.font.size
		if cfg.font_size > 0 do return cfg.font_size
	}
	if fallback_size > 0 do return fallback_size
	return DEFAULT_FONT_SIZE
}

// config_resolve_window_dimensions extracts effective width & height from config,
// falling back to defaults (1280x800) if unset or non-positive.
config_resolve_window_dimensions :: proc(cfg: ^App_Config) -> (width, height: i32) {
	if cfg == nil do return DEFAULT_WINDOW_WIDTH, DEFAULT_WINDOW_HEIGHT

	w := cfg.window_width
	if cfg.width > 0 do w = cfg.width
	if cfg.window.width > 0 do w = cfg.window.width

	h := cfg.window_height
	if cfg.height > 0 do h = cfg.height
	if cfg.window.height > 0 do h = cfg.window.height

	if w <= 0 do w = DEFAULT_WINDOW_WIDTH
	if h <= 0 do h = DEFAULT_WINDOW_HEIGHT

	return w, h
}

// config_resolve_window_blur checks whether native window blur/vibrancy is enabled.
config_resolve_window_blur :: proc(cfg: ^App_Config) -> bool {
	if cfg == nil do return false
	if !cfg.blur do return false
	if !cfg.window.blur do return false
	return true
}

// config_resolve_window_opacity returns the window background opacity (0.0 = fully transparent/blur, 1.0 = solid).
config_resolve_window_opacity :: proc(cfg: ^App_Config) -> f32 {
	if cfg == nil do return 0.0
	if cfg.window.opacity >= 0.0 do return clamp(cfg.window.opacity, 0.0, 1.0)
	if cfg.window_opacity >= 0.0 do return clamp(cfg.window_opacity, 0.0, 1.0)
	return 0.0
}

// config_parse_json5 deserializes in-memory JSON5 payload into App_Config.
// It has zero knowledge of files or filesystem paths.
config_parse_json5 :: proc(data: []byte, allocator := context.temp_allocator) -> (cfg: App_Config, ok: bool) {
	cfg = config_default()
	if len(data) == 0 do return cfg, true

	err := json.unmarshal(data, &cfg, spec = .JSON5, allocator = allocator)
	if err != nil do return config_default(), false
	return cfg, true
}

// config_resolve_path discovers the configuration file path by priority:
// 1. $TERM_CONFIG
// 2. $XDG_CONFIG_HOME/term/config.json
// 3. ~/.config/term/config.json
// 4. ~/.term/config.json
config_resolve_path :: proc() -> (string, bool) {
	if val := os.get_env("TERM_CONFIG", context.temp_allocator); len(val) > 0 {
		if os.exists(val) do return val, true
	}

	if xdg := os.get_env("XDG_CONFIG_HOME", context.temp_allocator); len(xdg) > 0 {
		p := strings.concatenate({xdg, "/term/config.json"}, context.temp_allocator)
		if os.exists(p) do return p, true
	}

	if home := os.get_env("HOME", context.temp_allocator); len(home) > 0 {
		p1 := strings.concatenate({home, "/.config/term/config.json"}, context.temp_allocator)
		if os.exists(p1) do return p1, true

		p2 := strings.concatenate({home, "/.term/config.json"}, context.temp_allocator)
		if os.exists(p2) do return p2, true
	}

	return "", false
}

// config_load reads and decodes the user configuration file via config_parse_json5,
// falling back silently to config_default() if absent or unreadable.
config_load :: proc() -> App_Config {
	path, found := config_resolve_path()
	if !found do return config_default()

	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return config_default()

	cfg, ok := config_parse_json5(data)
	if !ok do return config_default()

	return cfg
}

// config_resolve_effective_font_size evaluates font size with fallback priority:
// 1. user config (config.json)
// 2. 16.0 (DEFAULT_FONT_SIZE)
config_resolve_effective_font_size :: proc(cfg: ^App_Config) -> f32 {
	return config_resolve_font_size(cfg, DEFAULT_FONT_SIZE)
}

WINDOW_MARGIN:        f32 : 8.0
PANE_GAP:             f32 : 8.0
BORDER_RADIUS:        f32 : 8.0
TAB_BAR_HEIGHT:       f32 : 38.0
AUTO_HIDE_TRIGGER_Y:  f32 : 52.0

DEFAULT_CELL_WIDTH:   f32 : 9.5
DEFAULT_CELL_HEIGHT:  f32 : 21.5

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

visual_metrics_make :: proc(scale: f32 = 1.0, pad_x: f32 = DEFAULT_PANE_PAD_X, pad_y: f32 = DEFAULT_PANE_PAD_Y) -> Visual_Metrics {
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
		pane_pad_x          = pad_x * s,
		pane_pad_y          = pad_y * s,
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
COLOR_PANE_BG         := [4]f32{0.08, 0.09, 0.12, 1.0}
COLOR_PANE_BORDER     := [4]f32{0.16, 0.19, 0.25, 0.80}
COLOR_PANE_FOCUS      := [4]f32{0.24, 0.30, 0.40, 0.70}

// Tab Colors
COLOR_TAB_INACTIVE_BG := [4]f32{0.12, 0.14, 0.19, 0.95}
COLOR_TAB_ACTIVE_BG   := [4]f32{0.18, 0.23, 0.32, 1.00}
COLOR_TAB_ACTIVE_LINE := [4]f32{0.45, 0.60, 0.80, 0.90}
COLOR_TAB_TEXT_ACTIVE := [4]f32{0.95, 0.96, 0.98, 1.00}
COLOR_TAB_TEXT_INACT  := [4]f32{0.60, 0.65, 0.72, 0.85}

// Cursor & Selection Colors
COLOR_CURSOR_BLOCK    := [4]f32{0.28, 0.68, 1.00, 0.85}
COLOR_SELECTION_BG    := [4]f32{0.24, 0.45, 0.78, 0.55}
