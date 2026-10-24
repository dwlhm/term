package term

// Term Configuration, Visual Constants & Color Palette
// Part of Tier 3 Application Shell (src/app/term/*).

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"
import plat_font "../../platform/font"

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
	size:   f32    `json:"size"`,
	family: string `json:"family"`,
	path:   string `json:"path"`,
}

Padding_Config :: struct {
	x: f32 `json:"x"`,
	y: f32 `json:"y"`,
}

Drop_Config :: struct {
	animation: bool `json:"animation"`,
}

Pane_Config :: struct {
	opacity: f32 `json:"opacity"`,
}

// Theme_Config holds color overrides driven from config.json. Colors use
// "#RRGGBB" hex strings; empty strings keep the built-in theme defaults.
Theme_Config :: struct {
	background:            string     `json:"background"`,
	foreground:            string     `json:"foreground"`,
	palette:               [16]string `json:"palette"`,
	hyperlink_openable_bg: string     `json:"hyperlink_openable_bg"`,
	hyperlink_blocked_bg:  string     `json:"hyperlink_blocked_bg"`,
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
	theme:          Theme_Config   `json:"theme"`,
	blur:           bool           `json:"blur"`,
	window_opacity: f32            `json:"window_opacity"`,
	pane_opacity:   f32            `json:"pane_opacity"`,
	pane:           Pane_Config    `json:"pane"`,
	scroll_multiplier: f32         `json:"scroll_multiplier"`,
	scroll_speed:      f32         `json:"scroll_speed"`,
	working_directory: string      `json:"working_directory"`,
	drop_animation:    bool        `json:"drop_animation"`,
	drop:              Drop_Config `json:"drop"`,
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
		pane_opacity   = -1.0,
		pane           = {
			opacity = -1.0,
		},
		scroll_multiplier = 1.0,
		scroll_speed      = 1.0,
		window         = {
			blur    = default_blur,
			opacity = -1.0,
		},
		drop_animation = false,
		drop           = {
			animation = false,
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

DEFAULT_PANE_OPACITY_BLUR: f32 : 0.45
DEFAULT_PANE_OPACITY_SOLID: f32 : 1.0

// config_resolve_pane_opacity returns the terminal pane opacity (0.0 = fully transparent, 1.0 = solid).
config_resolve_pane_opacity :: proc(cfg: ^App_Config, window_opacity: f32 = -1.0, blur_enabled: bool = false) -> f32 {
	if cfg != nil {
		if cfg.pane.opacity >= 0.0 do return clamp(cfg.pane.opacity, 0.0, 1.0)
		if cfg.pane_opacity >= 0.0 do return clamp(cfg.pane_opacity, 0.0, 1.0)
		if cfg.window.opacity >= 0.0 do return clamp(cfg.window.opacity, 0.0, 1.0)
		if cfg.window_opacity >= 0.0 do return clamp(cfg.window_opacity, 0.0, 1.0)
	}
	if window_opacity >= 0.0 do return clamp(window_opacity, 0.0, 1.0)
	return DEFAULT_PANE_OPACITY_BLUR if blur_enabled else DEFAULT_PANE_OPACITY_SOLID
}

// config_resolve_scroll_multiplier extracts effective scroll speed multiplier (default 1.0).
config_resolve_scroll_multiplier :: proc(cfg: ^App_Config) -> f32 {
	if cfg == nil do return 1.0
	if cfg.scroll_multiplier > 0.0 do return cfg.scroll_multiplier
	if cfg.scroll_speed > 0.0 do return cfg.scroll_speed
	return 1.0
}

// config_resolve_drop_animation checks whether drag & drop visual ripple & tactile animation is enabled (default false).
config_resolve_drop_animation :: proc(cfg: ^App_Config) -> bool {
	if cfg == nil do return false
	if cfg.drop.animation do return true
	if cfg.drop_animation do return true
	return false
}

_config_hex_digit :: proc(c: u8) -> (int, bool) {
	switch c {
	case '0'..='9': return int(c - '0'), true
	case 'a'..='f': return int(c - 'a' + 10), true
	case 'A'..='F': return int(c - 'A' + 10), true
	}
	return 0, false
}

_config_hex_byte :: proc(s: string) -> (u8, bool) {
	if len(s) < 2 do return 0, false
	hi, ok1 := _config_hex_digit(s[0])
	lo, ok2 := _config_hex_digit(s[1])
	if !ok1 || !ok2 do return 0, false
	return u8((hi << 4) | lo), true
}

// _config_parse_hex_color parses "#RRGGBB" (or "RRGGBB") into an opaque color.
_config_parse_hex_color :: proc(s: string) -> ([4]f32, bool) {
	p := strings.trim_space(s)
	if len(p) > 0 && p[0] == '#' do p = p[1:]
	if len(p) != 6 do return {}, false
	r, ok1 := _config_hex_byte(p[0:2])
	g, ok2 := _config_hex_byte(p[2:4])
	b, ok3 := _config_hex_byte(p[4:6])
	if !ok1 || !ok2 || !ok3 do return {}, false
	return {f32(r) / 255.0, f32(g) / 255.0, f32(b) / 255.0, 1.0}, true
}

// config_resolve_hyperlink_colors resolves the hover highlight colors, falling
// back to the built-in theme tokens when the config omits them.
config_resolve_hyperlink_colors :: proc(cfg: ^App_Config) -> (openable, blocked: [4]f32) {
	openable = COLOR_HYPERLINK_OPENABLE_BG
	blocked = COLOR_HYPERLINK_BLOCKED_BG
	if cfg == nil do return
	if len(cfg.theme.hyperlink_openable_bg) > 0 {
		if c, ok := _config_parse_hex_color(cfg.theme.hyperlink_openable_bg); ok do openable = c
	}
	if len(cfg.theme.hyperlink_blocked_bg) > 0 {
		if c, ok := _config_parse_hex_color(cfg.theme.hyperlink_blocked_bg); ok do blocked = c
	}
	return
}

// config_resolve_theme_palette resolves the 16-color ANSI palette and background
// overrides from user configuration, returning has_palette = true if modified.
config_resolve_theme_palette :: proc(cfg: ^App_Config) -> (palette: [16][4]f32, has_palette: bool) {
	if cfg == nil do return PALETTE_COLORS, false
	palette = PALETTE_COLORS
	has_palette = false
	for i in 0..<16 {
		if len(cfg.theme.palette[i]) > 0 {
			if c, ok := _config_parse_hex_color(cfg.theme.palette[i]); ok {
				palette[i] = c
				has_palette = true
			}
		}
	}
	if len(cfg.theme.foreground) > 0 {
		if c, ok := _config_parse_hex_color(cfg.theme.foreground); ok {
			palette[7] = c
			palette[15] = c
			has_palette = true
		}
	}
	if len(cfg.theme.background) > 0 {
		if c, ok := _config_parse_hex_color(cfg.theme.background); ok {
			palette[0] = c
			has_palette = true
		}
	}
	return palette, has_palette
}

// config_resolve_font_path resolves custom font configuration (explicit path or family name).
config_resolve_font_path :: proc(cfg: ^App_Config, allocator := context.temp_allocator) -> (path: string, ok: bool) {
	if cfg == nil do return "", false
	if len(cfg.font.path) > 0 {
		expanded := config_expand_path(cfg.font.path, allocator)
		if os.is_file(expanded) do return expanded, true
	}
	if len(cfg.font.family) > 0 {
		if p, found := plat_font.platform_query_font_by_name(cfg.font.family, allocator); found {
			return p, true
		}
	}
	return "", false
}

// config_expand_path resolves ~ and ~/ prefixes against user's $HOME directory.
config_expand_path :: proc(path: string, allocator := context.temp_allocator) -> string {
	if len(path) == 0 do return ""
	if path == "~" || path == "home" {
		home := os.get_env("HOME", allocator)
		if len(home) > 0 do return home
	}
	if strings.has_prefix(path, "~/") {
		home := os.get_env("HOME", allocator)
		if len(home) > 0 {
			return strings.concatenate({home, path[1:]}, allocator)
		}
	}
	return path
}

// config_resolve_working_directory extracts configured working_directory, expanding ~ if present.
config_resolve_working_directory :: proc(cfg: ^App_Config, allocator := context.temp_allocator) -> string {
	if cfg == nil || len(cfg.working_directory) == 0 do return ""
	return config_expand_path(cfg.working_directory, allocator)
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

@(private = "file")
_check_config_dir :: proc(dir: string, allocator := context.temp_allocator) -> (string, bool) {
	for name in ([?]string{"config.json5", "config.json"}) {
		p, _ := filepath.join({dir, name}, allocator)
		if os.is_file(p) do return p, true
	}
	return "", false
}

// config_resolve_path discovers the configuration file path by priority:
// 1. $TERM_CONFIG
// 2. Portable next to executable (<exec_dir>/config.json[5])
// 3. Portable next to .app bundle (<exec_dir>/../../../config.json[5])
// 4. Current working directory (./config.json[5])
// 5. $XDG_CONFIG_HOME/term/config.json[5]
// 6. ~/.config/term/config.json[5]
// 7. ~/.term/config.json[5]
config_resolve_path :: proc() -> (string, bool) {
	if val := os.get_env("TERM_CONFIG", context.temp_allocator); len(val) > 0 {
		if os.is_file(val) do return val, true
	}

	if exec_path, err := os.get_executable_path(context.temp_allocator); err == nil && len(exec_path) > 0 {
		exec_dir := filepath.dir(exec_path)
		if p, ok := _check_config_dir(exec_dir); ok do return p, true

		bundle_root, _ := filepath.join({exec_dir, "../../.."}, context.temp_allocator)
		if p, ok := _check_config_dir(bundle_root); ok do return p, true
	}

	if p, ok := _check_config_dir("."); ok do return p, true

	if xdg := os.get_env("XDG_CONFIG_HOME", context.temp_allocator); len(xdg) > 0 {
		dir := strings.concatenate({xdg, "/term"}, context.temp_allocator)
		if p, ok := _check_config_dir(dir); ok do return p, true
	}

	if home := os.get_env("HOME", context.temp_allocator); len(home) > 0 {
		dir1 := strings.concatenate({home, "/.config/term"}, context.temp_allocator)
		if p, ok := _check_config_dir(dir1); ok do return p, true

		dir2 := strings.concatenate({home, "/.term"}, context.temp_allocator)
		if p, ok := _check_config_dir(dir2); ok do return p, true
	}

	return "", false
}

// config_load reads and decodes the user configuration file via config_parse_json5.
// If absent, it automatically generates ~/.config/term/config.json5 from the default template.
// Falls back silently to config_default() if unreadable or cannot write.
config_load :: proc() -> App_Config {
	path, found := config_resolve_path()
	if !found {
		if default_path, ok := config_ensure_default_file(); ok {
			path = default_path
			found = true
		} else {
			return config_default()
		}
	}

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
