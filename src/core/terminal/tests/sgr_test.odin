package terminal_tests

// Regression tests for SGR (Select Graphic Rendition) parsing.
//
// The previous implementation collapsed ':' and ';' into one parameter list
// without remembering which separator was used, so the ITU T.416 colon form
// `38:2::<r>:<g>:<b>` lost its colour and mis-aligned every following code.

import "core:testing"
import term "../"
import cell "../cell"

// _sgr_cell renders one sequence into a fresh terminal and reports the styled
// cell together with its 24-bit colour payload.
_sgr_cell :: proc(sequence: string) -> (c: cell.Semantic_Cell, dc: cell.Direct_Color) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 4, 40)
	defer term.terminal_destroy(&terminal)
	term.terminal_feed_string(&terminal, sequence)
	return term.terminal_get_cell(&terminal, 0, 0), term.terminal_get_direct_color(&terminal, 0, 0)
}

@test
test_sgr_truecolor_semicolon_and_colon_forms :: proc(t: ^testing.T) {
	cases := [?]struct {
		sequence: string,
		rgb:      [3]u8,
	}{
		{"\x1b[38;2;255;0;0mX", {255, 0, 0}},
		{"\x1b[38:2::255:0:0mX", {255, 0, 0}},
		{"\x1b[38:2:0:255:0:0mX", {255, 0, 0}},
		{"\x1b[38:2:255:0:0mX", {255, 0, 0}},
		{"\x1b[38:2::10:20:30mX", {10, 20, 30}},
	}
	for entry in cases {
		_, dc := _sgr_cell(entry.sequence)
		testing.expect(t, dc.has_fg, "extended foreground must be stored")
		testing.expect_value(t, dc.fg, entry.rgb)
	}

	_, background := _sgr_cell("\x1b[48:2::0:255:0mX")
	testing.expect(t, background.has_bg, "colon-form background must be stored")
	testing.expect_value(t, background.bg, [3]u8{0, 255, 0})
}

@test
test_sgr_256_color_range :: proc(t: ^testing.T) {
	c, _ := _sgr_cell("\x1b[38;5;196mX")
	testing.expect_value(t, c.fg, 196)

	// Out-of-range palette indices must be ignored, never wrapped modulo 256.
	c, _ = _sgr_cell("\x1b[38;5;300mX")
	testing.expect_value(t, c.fg, 7)
}

@test
test_sgr_consumes_colon_subparameters :: proc(t: ^testing.T) {
	// 4:3 (curly underline) must not swallow the following truecolor code.
	c, dc := _sgr_cell("\x1b[4:3m\x1b[38:2::9:8:7mX")
	testing.expect(t, dc.has_fg, "colour after 4:3 must still apply")
	testing.expect_value(t, dc.fg, [3]u8{9, 8, 7})
	testing.expect(t, .Underline in c.style, "4:3 must enable underline")

	y, _ := _sgr_cell("\x1b[4:3mY")
	z, _ := _sgr_cell("\x1b[4:0mZ")
	testing.expect(t, .Underline in y.style)
	testing.expect(t, .Underline not_in z.style)

	// Underline colour (58/59) must be consumed without leaking into the next SGR.
	a, _ := _sgr_cell("\x1b[58:2::255:0:0mA")
	b, _ := _sgr_cell("\x1b[58:2::255:0:0m\x1b[59m\x1b[32mB")
	testing.expect_value(t, a.fg, 7)
	testing.expect_value(t, b.fg, 2)
}

@test
test_sgr_extended_style_flags :: proc(t: ^testing.T) {
	c, _ := _sgr_cell("\x1b[5;8mX")
	testing.expect(t, .Blink in c.style, "SGR 5 must set blink")
	testing.expect(t, .Hidden in c.style, "SGR 8 must set conceal")

	c, _ = _sgr_cell("\x1b[21;53mX")
	testing.expect(t, .Underline in c.style, "SGR 21 must map to underline")

	c, _ = _sgr_cell("\x1b[5;8m\x1b[25;28mX")
	testing.expect(t, .Blink not_in c.style, "SGR 25 must clear blink")
	testing.expect(t, .Hidden not_in c.style, "SGR 28 must reveal")
}

@test
test_sgr_ignores_private_prefixed_forms :: proc(t: ^testing.T) {
	// OpenCode/xterm emit `CSI > 4 ; 1 m` (XTMODKEYS). Its parameters must never
	// leak into SGR state, otherwise every following cell becomes underlined.
	c, _ := _sgr_cell("\x1b[>4;1mX")
	testing.expect(t, .Underline not_in c.style, "XTMODKEYS must not enable underline")
	testing.expect(t, .Bold not_in c.style, "XTMODKEYS must not enable bold")

	c, _ = _sgr_cell("\x1b[?4mX")
	testing.expect(t, .Underline not_in c.style, "private-prefixed SGR is not SGR")

	// A genuine SGR underline still works.
	c, _ = _sgr_cell("\x1b[4mX")
	testing.expect(t, .Underline in c.style)
}
