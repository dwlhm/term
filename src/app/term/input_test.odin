package term

// SDL keys must reach input_encode as the keys they are: the byte tables
// themselves are tested in core/terminal/tests/input_encode_key_test.odin.

import "core:strings"
import "core:testing"
import "vendor:sdl3"
import ie "../../core/terminal/input_encode"

@(private = "file")
_sdl :: proc(key: sdl3.Keycode, mod: sdl3.Keymod, flags: u8 = 0) -> string {
	ev, mapped := sdl_key_event(key, mod, .Press)
	if !mapped do return "<unmapped>"
	res, ok := ie.encode_key(ev, {kitty_flags = flags})
	if !ok do return "<none>"
	return strings.clone(string(res.bytes[:res.len]), context.temp_allocator) // res lives on this stack frame
}

@test
test_sdl_key_mapping :: proc(t: ^testing.T) {
	ev, ok := sdl_key_event(sdl3.K_A, sdl3.KMOD_LSHIFT | sdl3.KMOD_RGUI, .Repeat)
	testing.expect(t, ok)
	testing.expect_value(t, ev.key, ie.Key.Char)
	testing.expect_value(t, ev.char, 'a')
	testing.expect_value(t, ev.mods, ie.Mods{.Shift, .Super})
	testing.expect_value(t, ev.kind, ie.Key_Event_Kind.Repeat)

	ev, ok = sdl_key_event(sdl3.K_SPACE, sdl3.KMOD_NONE, .Press)
	testing.expect(t, ok && ev.key == .Char && ev.char == ' ')
	ev, ok = sdl_key_event(sdl3.K_KP_ENTER, sdl3.KMOD_NONE, .Press)
	testing.expect(t, ok && ev.key == .Enter)
	ev, ok = sdl_key_event(sdl3.K_APPLICATION, sdl3.KMOD_NONE, .Press)
	testing.expect(t, ok && ev.key == .Context_Menu)
	_, ok = sdl_key_event(sdl3.K_KP_1, sdl3.KMOD_NONE, .Press)
	testing.expect(t, !ok, "keypad digits are not encoded")
}

@test
test_sdl_keys_encode_end_to_end :: proc(t: ^testing.T) {
	testing.expect_value(t, _sdl(sdl3.K_BACKSPACE, sdl3.KMOD_GUI), "\x15")
	testing.expect_value(t, _sdl(sdl3.K_LEFT, sdl3.KMOD_GUI), "\x01")
	testing.expect_value(t, _sdl(sdl3.K_C, sdl3.KMOD_GUI), "<none>")
	testing.expect_value(t, _sdl(sdl3.K_BACKSPACE, sdl3.KMOD_ALT), "\x1b\x7f")
	testing.expect_value(t, _sdl(sdl3.K_DELETE, sdl3.KMOD_CTRL), "\x17")
	testing.expect_value(t, _sdl(sdl3.K_LEFTBRACKET, sdl3.KMOD_CTRL), "\x1b")
	testing.expect_value(t, _sdl(sdl3.K_SEMICOLON, sdl3.KMOD_CTRL, ie.KITTY_KBD_DISAMBIGUATE), "\x1b[59;5u")
	testing.expect_value(t, _sdl(sdl3.K_F5, sdl3.KMOD_NONE), "\x1b[15~")
	testing.expect_value(t, _sdl(sdl3.K_A, sdl3.KMOD_NONE), "<none>")
}
