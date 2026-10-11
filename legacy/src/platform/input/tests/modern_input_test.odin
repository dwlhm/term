package input_test

import "core:testing"
import input "../"

// Helper to encode with app_cursor flag
_enc_app :: proc(kind: input.Input_Key_Kind, app_cursor: bool, shift: bool = false) -> ([input.INPUT_ENCODE_MAX]u8, int) {
	buf: [input.INPUT_ENCODE_MAX]u8
	ev := input.Input_Event{kind = kind, shift = shift}
	n := input.input_encode(ev, buf[:], 0, app_cursor)
	return buf, n
}

// --- DECCKM Tests ---

@(test)
test_decckm_unmodified_arrows :: proc(t: ^testing.T) {
	// Normal mode (app_cursor = false): ESC [ A/B/C/D
	buf, n := _enc_app(.Arrow_Up, false)
	testing.expect(t, string(buf[:n]) == "\x1b[A", "normal Up must emit ESC [ A")

	buf, n = _enc_app(.Arrow_Down, false)
	testing.expect(t, string(buf[:n]) == "\x1b[B", "normal Down must emit ESC [ B")

	buf, n = _enc_app(.Arrow_Right, false)
	testing.expect(t, string(buf[:n]) == "\x1b[C", "normal Right must emit ESC [ C")

	buf, n = _enc_app(.Arrow_Left, false)
	testing.expect(t, string(buf[:n]) == "\x1b[D", "normal Left must emit ESC [ D")

	// Application mode (app_cursor = true): ESC O A/B/C/D
	buf, n = _enc_app(.Arrow_Up, true)
	testing.expect(t, string(buf[:n]) == "\x1bOA", "app Up must emit ESC O A")

	buf, n = _enc_app(.Arrow_Down, true)
	testing.expect(t, string(buf[:n]) == "\x1bOB", "app Down must emit ESC O B")

	buf, n = _enc_app(.Arrow_Right, true)
	testing.expect(t, string(buf[:n]) == "\x1bOC", "app Right must emit ESC O C")

	buf, n = _enc_app(.Arrow_Left, true)
	testing.expect(t, string(buf[:n]) == "\x1bOD", "app Left must emit ESC O D")
}

@(test)
test_decckm_modified_arrows_stay_csi :: proc(t: ^testing.T) {
	// Modified arrows (e.g. Shift+Up) must still emit ESC [ 1 ; 2 A even in app_cursor mode
	buf, n := _enc_app(.Arrow_Up, true, shift = true)
	testing.expect(t, string(buf[:n]) == "\x1b[1;2A", "Shift+Up in app mode must emit ESC [ 1 ; 2 A")
}

// --- SGR 1006 Mouse Encoding Tests ---

@(test)
test_mouse_encode_sgr_buttons :: proc(t: ^testing.T) {
	buf: [32]u8

	// Left button press
	ptr := input.Input_Pointer_Event{kind = .Button_Down, button = 1}
	n := input.mouse_encode_sgr(ptr, 10, 5, buf[:])
	testing.expect(t, string(buf[:n]) == "\x1b[<0;10;5M", "Left button press must emit \\e[<0;10;5M")

	// Middle button press
	ptr = input.Input_Pointer_Event{kind = .Button_Down, button = 2}
	n = input.mouse_encode_sgr(ptr, 10, 5, buf[:])
	testing.expect(t, string(buf[:n]) == "\x1b[<1;10;5M", "Middle button press must emit \\e[<1;10;5M")

	// Right button press
	ptr = input.Input_Pointer_Event{kind = .Button_Down, button = 3}
	n = input.mouse_encode_sgr(ptr, 10, 5, buf[:])
	testing.expect(t, string(buf[:n]) == "\x1b[<2;10;5M", "Right button press must emit \\e[<2;10;5M")

	// Left button release (lowercase m)
	ptr = input.Input_Pointer_Event{kind = .Button_Up, button = 1}
	n = input.mouse_encode_sgr(ptr, 10, 5, buf[:])
	testing.expect(t, string(buf[:n]) == "\x1b[<0;10;5m", "Left button release must emit \\e[<0;10;5m")
}

@(test)
test_mouse_encode_sgr_wheel :: proc(t: ^testing.T) {
	buf: [32]u8

	// Wheel Up (btn 64)
	ptr := input.Input_Pointer_Event{kind = .Wheel, wheel_y = 1.0}
	n := input.mouse_encode_sgr(ptr, 15, 8, buf[:])
	testing.expect(t, string(buf[:n]) == "\x1b[<64;15;8M", "Wheel Up must emit \\e[<64;15;8M")

	// Wheel Down (btn 65)
	ptr = input.Input_Pointer_Event{kind = .Wheel, wheel_y = -1.0}
	n = input.mouse_encode_sgr(ptr, 15, 8, buf[:])
	testing.expect(t, string(buf[:n]) == "\x1b[<65;15;8M", "Wheel Down must emit \\e[<65;15;8M")
}

@(test)
test_mouse_encode_sgr_motion :: proc(t: ^testing.T) {
	buf: [32]u8

	// Left drag motion (btn 0 + 32 = 32)
	ptr := input.Input_Pointer_Event{kind = .Motion, primary_down = true}
	n := input.mouse_encode_sgr(ptr, 20, 12, buf[:])
	testing.expect(t, string(buf[:n]) == "\x1b[<32;20;12M", "Left drag motion must emit \\e[<32;20;12M")

	// Middle drag motion (btn 1 + 32 = 33)
	ptr = input.Input_Pointer_Event{kind = .Motion, button = 2}
	n = input.mouse_encode_sgr(ptr, 20, 12, buf[:])
	testing.expect(t, string(buf[:n]) == "\x1b[<33;20;12M", "Middle drag motion must emit \\e[<33;20;12M")

	// Motion without buttons (btn 3 + 32 = 35)
	ptr = input.Input_Pointer_Event{kind = .Motion}
	n = input.mouse_encode_sgr(ptr, 20, 12, buf[:])
	testing.expect(t, string(buf[:n]) == "\x1b[<35;20;12M", "Motion without buttons must emit \\e[<35;20;12M")
}

@(test)
test_mouse_encode_sgr_shift_modifier :: proc(t: ^testing.T) {
	buf: [32]u8

	// Left button press + Shift (0 + 4 = 4)
	ptr := input.Input_Pointer_Event{kind = .Button_Down, button = 1, shift = true}
	n := input.mouse_encode_sgr(ptr, 5, 5, buf[:])
	testing.expect(t, string(buf[:n]) == "\x1b[<4;5;5M", "Left press + Shift must emit \\e[<4;5;5M")

	// Explicit shift parameter overload
	ptr.shift = false
	n = input.mouse_encode_sgr(ptr, 5, 5, true, buf[:])
	testing.expect(t, string(buf[:n]) == "\x1b[<4;5;5M", "Explicit shift parameter must emit \\e[<4;5;5M")

	// Wheel Up + Shift (64 + 4 = 68)
	ptr = input.Input_Pointer_Event{kind = .Wheel, wheel_y = 1.0, shift = true}
	n = input.mouse_encode_sgr(ptr, 5, 5, buf[:])
	testing.expect(t, string(buf[:n]) == "\x1b[<68;5;5M", "Wheel Up + Shift must emit \\e[<68;5;5M")
}
