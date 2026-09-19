package config

import "core:strings"
import termgrid "../terminal"

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
	padding_x:                int,
	padding_y:                int,
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
		padding_x                = 6,
		padding_y                = 4,
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
	cfg^ = {}
}
