package term

// Behavioral tests for theme color config parsing & resolution.

import "core:testing"

@test
test_config_parse_hex_color :: proc(t: ^testing.T) {
	c, ok := _config_parse_hex_color("#245238")
	testing.expect(t, ok, "valid #RRGGBB must parse")
	testing.expect(t, abs(c[0] - 0.141) < 0.005, "red channel")
	testing.expect(t, abs(c[1] - 0.322) < 0.005, "green channel")
	testing.expect(t, abs(c[2] - 0.220) < 0.005, "blue channel")

	// Without the leading '#' and with surrounding whitespace.
	c2, ok2 := _config_parse_hex_color("  612926 ")
	testing.expect(t, ok2, "bare RRGGBB must parse")
	testing.expect(t, abs(c2[0] - 0.380) < 0.005)
	testing.expect(t, abs(c2[1] - 0.161) < 0.005)
	testing.expect(t, abs(c2[2] - 0.149) < 0.005)

	_, ok_bad := _config_parse_hex_color("not-a-color")
	testing.expect(t, !ok_bad, "malformed strings must be rejected")
}

@test
test_config_resolve_hyperlink_colors :: proc(t: ^testing.T) {
	// No config -> built-in theme tokens.
	openable, blocked := config_resolve_hyperlink_colors(nil)
	testing.expect_value(t, openable, COLOR_HYPERLINK_OPENABLE_BG)
	testing.expect_value(t, blocked, COLOR_HYPERLINK_BLOCKED_BG)

	// Configured colors win.
	cfg := config_default()
	cfg.theme.hyperlink_openable_bg = "#010203"
	cfg.theme.hyperlink_blocked_bg = "#0A0B0C"
	openable, blocked = config_resolve_hyperlink_colors(&cfg)
	testing.expect(t, abs(openable[0] - 1.0/255.0) < 0.005)
	testing.expect(t, abs(blocked[2] - 12.0/255.0) < 0.005)

	// Malformed value falls back to the theme token.
	cfg.theme.hyperlink_openable_bg = "bogus"
	openable, _ = config_resolve_hyperlink_colors(&cfg)
	testing.expect_value(t, openable, COLOR_HYPERLINK_OPENABLE_BG)
}

@test
test_config_json5_comments_and_trailing_commas :: proc(t: ^testing.T) {
	json5_content := `
	// Term Configuration File with JSON5 extensions
	{
		window: {
			width: 1400,
			height: 900,
			blur: true, // trailing comma allowed
		},
		font: {
			family: "Menlo",
			size: 15.5,
		},
		theme: {
			background: "#1e1e2e",
			foreground: "#cdd6f4",
			palette: [
				"#000000", "#f38ba8", "#a6e3a1", "#f9e2af",
				"#89b4fa", "#f5c2e7", "#94e2d5", "#bac2de",
				"#585b70", "#f38ba8", "#a6e3a1", "#f9e2af",
				"#89b4fa", "#f5c2e7", "#94e2d5", "#a6adc8",
			],
		},
	}
	`
	cfg, ok := config_parse_json5(transmute([]byte)json5_content)
	testing.expect(t, ok, "JSON5 config with comments and trailing commas must parse successfully")
	testing.expect_value(t, cfg.window.width, 1400)
	testing.expect_value(t, cfg.window.height, 900)
	testing.expect_value(t, cfg.font.size, 15.5)
	testing.expect_value(t, cfg.font.family, "Menlo")
	testing.expect_value(t, cfg.theme.background, "#1e1e2e")
	testing.expect_value(t, cfg.theme.foreground, "#cdd6f4")

	// Verify theme palette resolution
	palette, has_palette := config_resolve_theme_palette(&cfg)
	testing.expect(t, has_palette, "palette override must be detected")
	testing.expect(t, abs(palette[0][0] - 0.117) < 0.01, "background red")
	testing.expect(t, abs(palette[0][1] - 0.117) < 0.01, "background green")
	testing.expect(t, abs(palette[0][2] - 0.180) < 0.01, "background blue")
}

@test
test_config_font_resolution :: proc(t: ^testing.T) {
	cfg := config_default()
	cfg.font.family = "Menlo"
	path, ok := config_resolve_font_path(&cfg)
	when ODIN_OS == .Darwin {
		testing.expect(t, ok, "Menlo must resolve to file path on macOS")
		testing.expect(t, len(path) > 0)
	}
}

@test
test_config_drop_animation_resolution :: proc(t: ^testing.T) {
	// 1. Nil config falls back to default disabled (false)
	testing.expect(t, !config_resolve_drop_animation(nil), "nil config must default to disabled drop animation")

	// 2. Default config is disabled (false)
	cfg_def := config_default()
	testing.expect(t, !config_resolve_drop_animation(&cfg_def), "config_default must have drop animation disabled")

	// 3. Flat drop_animation: true in JSON5
	json_flat_true := `{ drop_animation: true }`
	cfg_flat_true, ok1 := config_parse_json5(transmute([]byte)json_flat_true)
	testing.expect(t, ok1, "flat JSON5 must parse")
	testing.expect(t, config_resolve_drop_animation(&cfg_flat_true), "flat drop_animation: true must resolve enabled")

	// 4. Flat drop_animation: false in JSON5
	json_flat_false := `{ drop_animation: false }`
	cfg_flat_false, ok2 := config_parse_json5(transmute([]byte)json_flat_false)
	testing.expect(t, ok2, "flat JSON5 must parse")
	testing.expect(t, !config_resolve_drop_animation(&cfg_flat_false), "flat drop_animation: false must resolve disabled")

	// 5. Nested drop: { animation: true } in JSON5
	json_nested_true := `{ drop: { animation: true } }`
	cfg_nested_true, ok3 := config_parse_json5(transmute([]byte)json_nested_true)
	testing.expect(t, ok3, "nested JSON5 must parse")
	testing.expect(t, config_resolve_drop_animation(&cfg_nested_true), "nested drop.animation: true must resolve enabled")

	// 6. Nested drop: { animation: false } in JSON5
	json_nested_false := `{ drop: { animation: false } }`
	cfg_nested_false, ok4 := config_parse_json5(transmute([]byte)json_nested_false)
	testing.expect(t, ok4, "nested JSON5 must parse")
	testing.expect(t, !config_resolve_drop_animation(&cfg_nested_false), "nested drop.animation: false must resolve disabled")

	// 7. Empty JSON5 config
	json_empty := `{}`
	cfg_empty, ok5 := config_parse_json5(transmute([]byte)json_empty)
	testing.expect(t, ok5, "empty JSON5 must parse")
	testing.expect(t, !config_resolve_drop_animation(&cfg_empty), "empty JSON5 config must default to disabled drop animation")
}

@test
test_config_pane_opacity_resolution :: proc(t: ^testing.T) {
	// 1. Nil config falls back to default based on blur
	testing.expect_value(t, config_resolve_pane_opacity(nil, -1.0, false), DEFAULT_PANE_OPACITY_SOLID)
	testing.expect_value(t, config_resolve_pane_opacity(nil, -1.0, true), DEFAULT_PANE_OPACITY_BLUR)

	// 2. Fall back to window_opacity if pane_opacity is unset
	testing.expect_value(t, config_resolve_pane_opacity(nil, 0.65, false), f32(0.65))

	// 3. Flat pane_opacity in JSON5
	json_flat := `{ pane_opacity: 0.72 }`
	cfg_flat, ok1 := config_parse_json5(transmute([]byte)json_flat)
	testing.expect(t, ok1, "flat JSON5 must parse")
	testing.expect(t, abs(config_resolve_pane_opacity(&cfg_flat) - 0.72) < 0.001, "flat pane_opacity must resolve to 0.72")

	// 4. Nested pane: { opacity: 0.88 } in JSON5
	json_nested := `{ pane: { opacity: 0.88 } }`
	cfg_nested, ok2 := config_parse_json5(transmute([]byte)json_nested)
	testing.expect(t, ok2, "nested JSON5 must parse")
	testing.expect(t, abs(config_resolve_pane_opacity(&cfg_nested) - 0.88) < 0.001, "nested pane.opacity must resolve to 0.88")

	// 5. Nested pane.opacity takes precedence over flat pane_opacity
	json_both := `{ pane_opacity: 0.50, pane: { opacity: 0.85 } }`
	cfg_both, ok3 := config_parse_json5(transmute([]byte)json_both)
	testing.expect(t, ok3, "both JSON5 must parse")
	testing.expect(t, abs(config_resolve_pane_opacity(&cfg_both) - 0.85) < 0.001, "nested pane.opacity must take precedence")

	// 6. CLI argument parsing for --pane-opacity
	args := []string{"term", "--pane-opacity", "0.78"}
	opts, cont := app_parse_cli_args(args)
	testing.expect(t, cont, "cli parse must continue")
	testing.expect(t, abs(opts.pane_opacity_override - 0.78) < 0.001, "CLI --pane-opacity must parse to 0.78")

	// 7. Fallback to config window.opacity when pane.opacity is unset
	json_win := `{ window: { opacity: 0.60 } }`
	cfg_win, ok_win := config_parse_json5(transmute([]byte)json_win)
	testing.expect(t, ok_win, "window.opacity JSON5 must parse")
	testing.expect(t, abs(config_resolve_pane_opacity(&cfg_win) - 0.60) < 0.001, "must fall back to window.opacity when pane.opacity unset")
}
