package terminal_tests

// Behavioral unit tests for the Sixel Graphics Protocol (B7).

import "core:testing"
import term "../"
import extension "../extension"

@test
test_sixel_rgb_color_and_drawing :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	kitty_ext := extension.kitty_graphics_extension_make()
	term.terminal_register_extension(&terminal, kitty_ext)

	var_kstate: ^extension.Kitty_Extension
	for i in 0..<terminal.extensions.ext_count {
		e := &terminal.extensions.extensions[i]
		if e.name == "kitty_graphics" && e.user_data != nil {
			var_kstate = (^extension.Kitty_Extension)(e.user_data)
			break
		}
	}
	testing.expect(t, var_kstate != nil, "kitty/sixel extension must be registered")

	// Sixel sequence:
	// DCS q (introducer)
	// #1;2;100;0;0 (define color 1 as 100% Red)
	// #1 (select color 1)
	// ~ (sixel char 126 - 63 = 63 = 0b111111: all 6 vertical pixels on)
	// ST (\x1b\)
	term.terminal_feed_string(&terminal, "\x1bPq#1;2;100;0;0#1~\x1b\\")

	testing.expect(t, len(var_kstate.placements) > 0, "sixel image placement must be created")
	img := extension.kitty_graphics_get_image(rawptr(var_kstate), var_kstate.placements[0].image_id)
	testing.expect(t, img != nil, "sixel image must be stored")
	testing.expect_value(t, img.width, 1)
	testing.expect_value(t, img.height, 6)
	testing.expect(t, len(img.pixels) >= 24, "pixel buffer must hold at least 6 RGBA pixels")

	// Verify pure red RGBA: [255, 0, 0, 255]
	testing.expect_value(t, img.pixels[0], 255)
	testing.expect_value(t, img.pixels[1], 0)
	testing.expect_value(t, img.pixels[2], 0)
	testing.expect_value(t, img.pixels[3], 255)
}

@test
test_sixel_hls_color_and_rle_decompression :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	kitty_ext := extension.kitty_graphics_extension_make()
	term.terminal_register_extension(&terminal, kitty_ext)

	var_kstate: ^extension.Kitty_Extension
	for i in 0..<terminal.extensions.ext_count {
		e := &terminal.extensions.extensions[i]
		if e.name == "kitty_graphics" && e.user_data != nil {
			var_kstate = (^extension.Kitty_Extension)(e.user_data)
			break
		}
	}

	// Sixel sequence:
	// #2;1;120;50;100 (define color 2 as HLS: 120 deg Green, 50% Lightness, 100% Saturation)
	// #2 (select color 2)
	// !40~ (RLE repeat 40 times)
	term.terminal_feed_string(&terminal, "\x1bPq#2;1;120;50;100#2!40~\x1b\\")

	testing.expect(t, len(var_kstate.placements) > 0)
	last_p := var_kstate.placements[len(var_kstate.placements) - 1]
	img := extension.kitty_graphics_get_image(rawptr(var_kstate), last_p.image_id)
	testing.expect(t, img != nil)
	testing.expect_value(t, img.width, 40)
	testing.expect_value(t, img.height, 6)

	// Verify pure green RGBA: [0, 255, 0, 255]
	testing.expect_value(t, img.pixels[0], 0)
	testing.expect_value(t, img.pixels[1], 255)
	testing.expect_value(t, img.pixels[2], 0)
	testing.expect_value(t, img.pixels[3], 255)
}

@test
test_sixel_raster_attributes_explicit_dimensions :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	kitty_ext := extension.kitty_graphics_extension_make()
	term.terminal_register_extension(&terminal, kitty_ext)

	var_kstate: ^extension.Kitty_Extension
	for i in 0..<terminal.extensions.ext_count {
		e := &terminal.extensions.extensions[i]
		if e.name == "kitty_graphics" && e.user_data != nil {
			var_kstate = (^extension.Kitty_Extension)(e.user_data)
			break
		}
	}

	// Sixel sequence with raster attributes: " 1 ; 1 ; 100 ; 60
	term.terminal_feed_string(&terminal, "\x1bPq\"1;1;100;60#1!50~\x1b\\")

	testing.expect(t, len(var_kstate.placements) > 0)
	last_p := var_kstate.placements[len(var_kstate.placements) - 1]
	img := extension.kitty_graphics_get_image(rawptr(var_kstate), last_p.image_id)
	testing.expect(t, img != nil)
	testing.expect_value(t, img.width, 100)
	testing.expect_value(t, img.height, 60)
}

@test
test_sixel_band_newlines_and_cursor_advancement :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	kitty_ext := extension.kitty_graphics_extension_make()
	term.terminal_register_extension(&terminal, kitty_ext)

	terminal.parser.cursor.row = 2
	terminal.parser.cursor.col = 0

	// 3 bands of 6 pixels = 18 pixels high.
	// Band 1: ~ (6px)
	// - (newline)
	// Band 2: ~ (6px)
	// - (newline)
	// Band 3: ~ (6px)
	term.terminal_feed_string(&terminal, "\x1bPq#1~-~-~\x1b\\")

	// Cursor must have advanced down past the image
	testing.expect(t, terminal.parser.cursor.row > 2, "terminal cursor must advance after sixel placement")
}
