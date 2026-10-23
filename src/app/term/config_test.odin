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
