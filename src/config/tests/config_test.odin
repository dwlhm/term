package config_tests

import "core:testing"
import config ".."
import termgrid "../../terminal"

@(test)
test_config_default :: proc(t: ^testing.T) {
	cfg := config.config_default()
	defer config.config_destroy(&cfg)

	testing.expect_value(t, cfg.cols, 80)
	testing.expect_value(t, cfg.rows, 24)
	testing.expect_value(t, cfg.title, "Term")
	testing.expect_value(t, cfg.font_family, "Maple Mono NF")
	testing.expect_value(t, cfg.font_size, f32(13.0))
	testing.expect_value(t, cfg.shell, "")
	testing.expect_value(t, cfg.working_directory, "~")
	testing.expect_value(t, cfg.cursor_blink, true)
	testing.expect_value(t, cfg.cursor_blink_interval_ms, u64(530))
	testing.expect_value(t, cfg.theme_name, "Catppuccin Mocha")
	testing.expect_value(t, cfg.foreground, termgrid.CATPPUCCIN_MOCHA_TEXT)
	testing.expect_value(t, cfg.background, termgrid.CATPPUCCIN_MOCHA_BASE)
	testing.expect_value(t, cfg.scrollback_max_lines, 1000)
	testing.expect_value(t, cfg.alt_screen_wheel_lines, 3)
	testing.expect_value(t, cfg.scroll_multiplier, f32(1.0))
	testing.expect_value(t, cfg.padding_x, 6)
	testing.expect_value(t, cfg.padding_y, 4)
	testing.expect_value(t, cfg.locale, "")
}

@(test)
test_parse_config_basic :: proc(t: ^testing.T) {
	src := `
font_family = "JetBrains Mono"
font_size   = 15.5
cols        := 120
rows        := 40
shell       = "/bin/zsh"
`
	cfg, ok, err := config.parse_config(src)
	defer config.config_destroy(&cfg)

	testing.expect(t, ok, "basic config must parse successfully")
	testing.expect_value(t, cfg.font_family, "JetBrains Mono")
	testing.expect_value(t, cfg.font_size, f32(15.5))
	testing.expect_value(t, cfg.cols, 120)
	testing.expect_value(t, cfg.rows, 40)
	testing.expect_value(t, cfg.shell, "/bin/zsh")
}

@(test)
test_parse_config_hex_colors :: proc(t: ^testing.T) {
	src := `
background = 0xFF000000
foreground = 0xFFFFFFFF
selection_background = 0x585B70
cursor_color = "#F5E0DC"
`
	cfg, ok, _ := config.parse_config(src)
	defer config.config_destroy(&cfg)

	testing.expect(t, ok, "hex colors must parse successfully")
	testing.expect_value(t, cfg.background, u32(0xFF000000))
	testing.expect_value(t, cfg.foreground, u32(0xFFFFFFFF))
	testing.expect_value(t, cfg.selection_background, u32(0xFF585B70))
	testing.expect_value(t, cfg.cursor_color, u32(0xFFF5E0DC))
}

@(test)
test_parse_config_booleans_and_numbers :: proc(t: ^testing.T) {
	src := `
cursor_blink = false
cursor_blink_interval_ms = 450
scrollback_max_lines = 5000
alt_screen_wheel_lines = 5
scroll_multiplier = 1.5
padding_x = 10
padding_y = 8
`
	cfg, ok, _ := config.parse_config(src)
	defer config.config_destroy(&cfg)

	testing.expect(t, ok, "booleans and numbers must parse successfully")
	testing.expect_value(t, cfg.cursor_blink, false)
	testing.expect_value(t, cfg.cursor_blink_interval_ms, u64(450))
	testing.expect_value(t, cfg.scrollback_max_lines, 5000)
	testing.expect_value(t, cfg.alt_screen_wheel_lines, 5)
	testing.expect_value(t, cfg.scroll_multiplier, f32(1.5))
	testing.expect_value(t, cfg.padding_x, 10)
	testing.expect_value(t, cfg.padding_y, 8)
}

@(test)
test_parse_config_empty_and_comments :: proc(t: ^testing.T) {
	empty_src := ""
	cfg1, ok1, _ := config.parse_config(empty_src)
	defer config.config_destroy(&cfg1)
	testing.expect(t, ok1, "empty config must succeed")
	testing.expect_value(t, cfg1.cols, 80)

	comment_src := `
// This is a single-line comment
/* This is a
   multi-line comment */
`
	cfg2, ok2, _ := config.parse_config(comment_src)
	defer config.config_destroy(&cfg2)
	testing.expect(t, ok2, "comment-only config must succeed")
	testing.expect_value(t, cfg2.rows, 24)
}

@(test)
test_parse_config_unknown_keys :: proc(t: ^testing.T) {
	src := `
unknown_custom_key = "some_value"
font_size = 18.0
another_unknown_var := 12345
cols = 90
`
	cfg, ok, _ := config.parse_config(src)
	defer config.config_destroy(&cfg)

	testing.expect(t, ok, "unknown keys must be ignored without failing")
	testing.expect_value(t, cfg.font_size, f32(18.0))
	testing.expect_value(t, cfg.cols, 90)
}

@(test)
test_parse_config_syntax_error :: proc(t: ^testing.T) {
	src := `font_size = = 14.5`
	cfg, ok, err := config.parse_config(src)
	defer config.config_destroy(&cfg)
	defer delete(err.message)

	testing.expect(t, !ok, "invalid syntax must return ok == false")
	testing.expect_value(t, err.line, 1)
	testing.expect(t, len(err.message) > 0, "error message must not be empty")
}

@(test)
test_parse_config_theme_preset :: proc(t: ^testing.T) {
	src := `
theme = "Catppuccin Mocha"
background = 0xFF111111 // override one color
`
	cfg, ok, _ := config.parse_config(src)
	defer config.config_destroy(&cfg)

	testing.expect(t, ok, "theme preset must parse")
	testing.expect_value(t, cfg.theme_name, "Catppuccin Mocha")
	testing.expect_value(t, cfg.background, u32(0xFF111111))
	testing.expect_value(t, cfg.foreground, termgrid.CATPPUCCIN_MOCHA_TEXT)
}

@(test)
test_parse_config_ansi16 :: proc(t: ^testing.T) {
	src := `
ansi16 = {0x01, 0x02, 0x03}
color4 = 0xFF123456
`
	cfg, ok, _ := config.parse_config(src)
	defer config.config_destroy(&cfg)

	testing.expect(t, ok, "ansi16 colors must parse")
	testing.expect_value(t, cfg.ansi16[0], u32(0xFF000001))
	testing.expect_value(t, cfg.ansi16[1], u32(0xFF000002))
	testing.expect_value(t, cfg.ansi16[2], u32(0xFF000003))
	testing.expect_value(t, cfg.ansi16[4], u32(0xFF123456))
}

@(test)
test_config_load_silent_fallback :: proc(t: ^testing.T) {
	// Calling config_load when no test config path is set returns default config
	cfg, ok := config.config_load()
	defer config.config_destroy(&cfg)

	testing.expect(t, ok, "silent fallback must return ok == true")
	testing.expect_value(t, cfg.cols, 80)
	testing.expect_value(t, cfg.rows, 24)
}

@(test)
test_parse_config_working_directory :: proc(t: ^testing.T) {
	src := `
working_directory = "~/project"
`
	cfg, ok, _ := config.parse_config(src)
	defer config.config_destroy(&cfg)

	testing.expect(t, ok, "working_directory config must parse successfully")
	testing.expect_value(t, cfg.working_directory, "~/project")

	src2 := `
cwd = "/tmp"
`
	cfg2, ok2, _ := config.parse_config(src2)
	defer config.config_destroy(&cfg2)

	testing.expect(t, ok2, "cwd alias must parse successfully")
	testing.expect_value(t, cfg2.working_directory, "/tmp")
}

@(test)
test_parse_config_locale :: proc(t: ^testing.T) {
	src := `
locale = "id"
`
	cfg, ok, _ := config.parse_config(src)
	defer config.config_destroy(&cfg)

	testing.expect(t, ok, "locale config must parse successfully")
	testing.expect_value(t, cfg.locale, "id")
}
