package term

// Term Configuration, Visual Constants & Color Palette
// Part of Tier 3 Application Shell (src/app/term/*).

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
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
	scroll_multiplier: f32         `json:"scroll_multiplier"`,
	scroll_speed:      f32         `json:"scroll_speed"`,
	working_directory: string      `json:"working_directory"`,
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
		scroll_multiplier = 1.0,
		scroll_speed      = 1.0,
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

// config_resolve_scroll_multiplier extracts effective scroll speed multiplier (default 1.0).
config_resolve_scroll_multiplier :: proc(cfg: ^App_Config) -> f32 {
	if cfg == nil do return 1.0
	if cfg.scroll_multiplier > 0.0 do return cfg.scroll_multiplier
	if cfg.scroll_speed > 0.0 do return cfg.scroll_speed
	return 1.0
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

// config_resolve_path discovers the configuration file path by priority:
// 1. $TERM_CONFIG
// 2. Portable next to executable (<exec_dir>/config.json)
// 3. Portable next to .app bundle (<exec_dir>/../../../config.json)
// 4. Current working directory (./config.json)
// 5. $XDG_CONFIG_HOME/term/config.json
// 6. ~/.config/term/config.json
// 7. ~/.term/config.json
config_resolve_path :: proc() -> (string, bool) {
	if val := os.get_env("TERM_CONFIG", context.temp_allocator); len(val) > 0 {
		if os.exists(val) do return val, true
	}

	if exec_path, err := os.get_executable_path(context.temp_allocator); err == nil && len(exec_path) > 0 {
		exec_dir := filepath.dir(exec_path)
		p_exec, _ := filepath.join({exec_dir, "config.json"}, context.temp_allocator)
		if os.exists(p_exec) do return p_exec, true

		p_bundle, _ := filepath.join({exec_dir, "../../../config.json"}, context.temp_allocator)
		if os.exists(p_bundle) do return p_bundle, true
	}

	if os.exists("config.json") {
		return "config.json", true
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
