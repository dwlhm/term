package terminal_tests

// Mouse reports for every tracking mode and format, and the parser modes they
// are read from.

import "core:strings"
import "core:testing"
import term "../"
import ie "../input_encode"
import parser "../parser"

@(private = "file")
_m :: proc(ev: ie.Mouse_Event, mode: parser.Mouse_Tracking_Mode, format: parser.Mouse_Format) -> string {
	res, ok := ie.encode_mouse(ev, {mode, format})
	if !ok do return "<none>"
	return strings.clone(string(res.bytes[:res.len]), context.temp_allocator) // res lives on this stack frame
}

@test
test_mouse_formats :: proc(t: ^testing.T) {
	press := ie.Mouse_Event{kind = .Press, button = .Left, col = 3, row = 4, px = 17, py = 33}
	testing.expect_value(t, _m(press, .Normal, .Sgr), "\x1b[<0;3;4M")
	testing.expect_value(t, _m(press, .Normal, .Sgr_Pixel), "\x1b[<0;17;33M")
	testing.expect_value(t, _m(press, .Normal, .X10), "\x1b[M #$")
	release := press
	release.kind = .Release
	testing.expect_value(t, _m(release, .Normal, .Sgr), "\x1b[<0;3;4m")
	testing.expect_value(t, _m(release, .Normal, .X10), "\x1b[M##$")
	mods := press
	mods.mods = {.Shift, .Alt, .Ctrl, .Super}
	testing.expect_value(t, _m(mods, .Normal, .Sgr), "\x1b[<28;3;4M")
}

@test
test_mouse_x10_is_raw_bytes :: proc(t: ^testing.T) {
	// Columns past 95 are single bytes above 0x7F, never UTF-8 sequences.
	ev := ie.Mouse_Event{kind = .Press, button = .Right, col = 200, row = 300}
	res, ok := ie.encode_mouse(ev, {.Normal, .X10})
	testing.expect(t, ok)
	testing.expect_value(t, res.len, 6)
	testing.expect_value(t, res.bytes[3], 34)
	testing.expect_value(t, res.bytes[4], 232)
	testing.expect_value(t, res.bytes[5], 255)
}

@test
test_mouse_wheel :: proc(t: ^testing.T) {
	up := ie.Mouse_Event{kind = .Wheel_Up, col = 5, row = 6}
	down := up
	down.kind = .Wheel_Down
	testing.expect_value(t, _m(up, .Normal, .Sgr), "\x1b[<64;5;6M")
	testing.expect_value(t, _m(down, .Normal, .Sgr), "\x1b[<65;5;6M")
	testing.expect_value(t, _m(down, .X10, .Sgr), "\x1b[<65;5;6M") // a wheel notch is a press
}

@test
test_mouse_tracking_modes :: proc(t: ^testing.T) {
	press := ie.Mouse_Event{kind = .Press, button = .Left, col = 1, row = 1}
	release := ie.Mouse_Event{kind = .Release, button = .Left, col = 1, row = 1}
	drag := ie.Mouse_Event{kind = .Motion, button = .Left, col = 2, row = 1}
	hover := ie.Mouse_Event{kind = .Motion, button = .None, col = 2, row = 1}
	testing.expect_value(t, _m(press, .None, .Sgr), "<none>")
	testing.expect_value(t, _m(press, .X10, .Sgr), "\x1b[<0;1;1M")
	testing.expect_value(t, _m(release, .X10, .Sgr), "<none>")
	testing.expect_value(t, _m(release, .Normal, .Sgr), "\x1b[<0;1;1m")
	testing.expect_value(t, _m(drag, .Normal, .Sgr), "<none>")
	testing.expect_value(t, _m(drag, .Button_Event, .Sgr), "\x1b[<32;2;1M")
	testing.expect_value(t, _m(hover, .Button_Event, .Sgr), "<none>")
	testing.expect_value(t, _m(hover, .Any_Event, .Sgr), "\x1b[<35;2;1M")
}

@test
test_mouse_modes_follow_the_parser :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 6, 40)
	defer term.terminal_destroy(&terminal)
	testing.expect_value(t, ie.mouse_modes(&terminal.parser).mode, parser.Mouse_Tracking_Mode.None)
	term.terminal_feed_string(&terminal, "\x1b[?1002h\x1b[?1006h")
	modes := ie.mouse_modes(&terminal.parser)
	testing.expect_value(t, modes.mode, parser.Mouse_Tracking_Mode.Button_Event)
	testing.expect_value(t, modes.format, parser.Mouse_Format.Sgr)
}
