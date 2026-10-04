package config

import "core:strings"
import termgrid "../terminal"

// Devtools_Anchor selects the corner of the window surface the DevTools panel
// is pinned to. The panel is draw-only chrome (see render/devtools_panel.odin),
// so the anchor is purely a geometry choice: it decides which edges the panel
// is clamped against, never which inputs it sees.
//
// The textual spelling used by the config file and by the environment override
// is the lower-case hyphenated form, e.g. "bottom-left"; devtools_anchor_parse
// is the single place that maps text to a value.
Devtools_Anchor :: enum u8 {
	Top_Right     = 0,
	Top_Left      = 1,
	Bottom_Right  = 2,
	Bottom_Left   = 3,
}

// DEVTOOLS_DEFAULT_COLUMNS is the default panel width in cells.
//
// It mirrors render.DEVTOOLS_PANEL_COLUMNS rather than importing it: render
// depends on config, not the other way round, so the constant cannot be shared
// by reference without inverting the dependency. To stop the two copies from
// drifting, render/devtools_panel.odin carries a compile-time #assert that this
// value still equals DEVTOOLS_PANEL_COLUMNS, which is where the panel's
// fallback width is actually applied.
DEVTOOLS_DEFAULT_COLUMNS :: 64

// devtools_env_enabled applies the TERM_DEVTOOLS environment value to out.
//
// Recognised values are "1"/"0" and "true"/"false", compared after trimming
// and case folding. Anything else reports ok == false and leaves out
// untouched, so a typo in the environment degrades to the config file value
// instead of silently disabling the collector.
//
// Pure by construction: it takes the value as an argument rather than reading
// the environment, which is what makes the precedence testable without
// launching the app.
devtools_env_enabled :: proc(value: string, out: ^bool) -> bool {
	s := strings.trim_space(value)
	if strings.equal_fold(s, "1") || strings.equal_fold(s, "true") {
		out^ = true
		return true
	}
	if strings.equal_fold(s, "0") || strings.equal_fold(s, "false") {
		out^ = false
		return true
	}
	return false
}

// devtools_anchor_parse maps a textual anchor name to its enum value, case
// insensitively and ignoring surrounding whitespace. An unrecognised name
// reports ok == false and yields the default anchor, which callers must not
// apply: the point of the false is that the caller's existing value survives.
devtools_anchor_parse :: proc(value: string) -> (Devtools_Anchor, bool) {
	s := strings.trim_space(value)
	if strings.equal_fold(s, "top-right") {
		return .Top_Right, true
	}
	if strings.equal_fold(s, "top-left") {
		return .Top_Left, true
	}
	if strings.equal_fold(s, "bottom-right") {
		return .Bottom_Right, true
	}
	if strings.equal_fold(s, "bottom-left") {
		return .Bottom_Left, true
	}
	return .Top_Right, false
}

// Public normalized configuration values share one closed interval.
CONFIG_NORMALIZED_MIN: f32 : 0.0
CONFIG_NORMALIZED_MAX: f32 : 1.0

// Config represents terminal configuration parameters loaded from config file or defaults.
Config :: struct {
	cols:                     int,
	rows:                     int,
	title:                    string,
	font_family:              string,
	font_size:                f32,
	shell:                    string,
	working_directory:        string,
	cursor_blink:             bool,
	cursor_blink_interval_ms: u64,
	theme_name:               string,
	foreground:               u32,
	background:               u32,
	selection_foreground:     u32,
	selection_background:     u32,
	cursor_color:             u32,
	ansi16:                   [16]u32,
	scrollback_max_lines:     int,
	alt_screen_wheel_lines:   int,
	scroll_multiplier:        f32,
	padding_x:                int,
	padding_y:                int,
	locale:                   string,
	tab_max_title_len:        int,
	opacity:                  f32,
	window_blur:              f32,
	allow_screensaver:        bool,
	devtools_enabled:         bool,
	devtools_anchor:          Devtools_Anchor,
	devtools_columns:         int,
	devtools_log_path:        string,
}

// config_default returns a default terminal configuration struct matching standard defaults.
config_default :: proc() -> Config {
	return Config{
		cols                     = 80,
		rows                     = 24,
		title                    = strings.clone("Term"),
		font_family              = strings.clone("Maple Mono NF"),
		font_size                = 13.0,
		shell                    = strings.clone(""),
		working_directory        = strings.clone("~"),
		cursor_blink             = true,
		cursor_blink_interval_ms = 530,
		theme_name               = strings.clone("Catppuccin Mocha"),
		foreground               = termgrid.CATPPUCCIN_MOCHA_TEXT,
		background               = termgrid.CATPPUCCIN_MOCHA_BASE,
		selection_foreground     = termgrid.CATPPUCCIN_MOCHA_BASE,
		selection_background     = termgrid.CATPPUCCIN_MOCHA_SURFACE2,
		cursor_color             = 0xFFFFFFFF,
		ansi16                   = termgrid.THEME_CATPPUCCIN_MOCHA.ansi16,
		scrollback_max_lines     = 1000,
		alt_screen_wheel_lines   = 3,
		scroll_multiplier        = 1.0,
		padding_x                = 6,
		padding_y                = 4,
		locale                   = strings.clone(""),
		tab_max_title_len        = 16,
		opacity                  = CONFIG_NORMALIZED_MAX,
		window_blur              = CONFIG_NORMALIZED_MIN,
		allow_screensaver        = true,
		devtools_enabled         = false,
		devtools_anchor          = .Top_Right,
		devtools_columns         = DEVTOOLS_DEFAULT_COLUMNS,
		devtools_log_path        = strings.clone(""),
	}
}

// config_destroy releases all heap-allocated string fields in cfg.
config_destroy :: proc(cfg: ^Config) {
	if cfg == nil {
		return
	}
	delete(cfg.title)
	delete(cfg.font_family)
	delete(cfg.shell)
	delete(cfg.working_directory)
	delete(cfg.theme_name)
	delete(cfg.locale)
	delete(cfg.devtools_log_path)
	cfg^ = {}
}
