package term

import "core:testing"
import "vendor:sdl3"

@test
test_input_encode_cmd_shortcuts :: proc(t: ^testing.T) {
	// Cmd + Backspace -> ^U (\x15)
	res, ok := input_encode_key(sdl3.K_BACKSPACE, sdl3.KMOD_GUI)
	testing.expect(t, ok, "Cmd+Backspace must be encoded")
	testing.expect_value(t, res.len, 1)
	testing.expect_value(t, res.bytes[0], 0x15)

	// Cmd + Delete -> ^U (\x15) (Mac delete key consistently clears line)
	res_del, ok_del := input_encode_key(sdl3.K_DELETE, sdl3.KMOD_GUI)
	testing.expect(t, ok_del, "Cmd+Delete must be encoded")
	testing.expect_value(t, res_del.len, 1)
	testing.expect_value(t, res_del.bytes[0], 0x15)

	// Cmd + Left (without Shift) -> ^A (\x01)
	res_left, ok_left := input_encode_key(sdl3.K_LEFT, sdl3.KMOD_GUI)
	testing.expect(t, ok_left, "Cmd+Left must be encoded")
	testing.expect_value(t, res_left.len, 1)
	testing.expect_value(t, res_left.bytes[0], 0x01)

	// Cmd + Right (without Shift) -> ^E (\x05)
	res_right, ok_right := input_encode_key(sdl3.K_RIGHT, sdl3.KMOD_GUI)
	testing.expect(t, ok_right, "Cmd+Right must be encoded")
	testing.expect_value(t, res_right.len, 1)
	testing.expect_value(t, res_right.bytes[0], 0x05)

	// Other Cmd shortcuts must not be handled by raw input encoder
	_, ok_c := input_encode_key(sdl3.K_C, sdl3.KMOD_GUI)
	testing.expect(t, !ok_c, "Cmd+C must not be encoded by raw encoder")
}

@test
test_input_encode_word_delete :: proc(t: ^testing.T) {
	// Option + Backspace -> \x1b\x7f
	res_opt_bs, ok_opt_bs := input_encode_key(sdl3.K_BACKSPACE, sdl3.KMOD_ALT)
	testing.expect(t, ok_opt_bs, "Option+Backspace must be encoded")
	testing.expect_value(t, res_opt_bs.len, 2)
	testing.expect_value(t, res_opt_bs.bytes[0], 0x1b)
	testing.expect_value(t, res_opt_bs.bytes[1], 0x7f)

	// Option + Delete -> \x1b\x7f
	res_opt_del, ok_opt_del := input_encode_key(sdl3.K_DELETE, sdl3.KMOD_ALT)
	testing.expect(t, ok_opt_del, "Option+Delete must be encoded")
	testing.expect_value(t, res_opt_del.len, 2)
	testing.expect_value(t, res_opt_del.bytes[0], 0x1b)
	testing.expect_value(t, res_opt_del.bytes[1], 0x7f)

	// Ctrl + Backspace -> ^W (\x17)
	res_ctrl_bs, ok_ctrl_bs := input_encode_key(sdl3.K_BACKSPACE, sdl3.KMOD_CTRL)
	testing.expect(t, ok_ctrl_bs, "Ctrl+Backspace must be encoded")
	testing.expect_value(t, res_ctrl_bs.len, 1)
	testing.expect_value(t, res_ctrl_bs.bytes[0], 0x17)

	// Ctrl + Delete -> ^W (\x17)
	res_ctrl_del, ok_ctrl_del := input_encode_key(sdl3.K_DELETE, sdl3.KMOD_CTRL)
	testing.expect(t, ok_ctrl_del, "Ctrl+Delete must be encoded")
	testing.expect_value(t, res_ctrl_del.len, 1)
	testing.expect_value(t, res_ctrl_del.bytes[0], 0x17)
}
