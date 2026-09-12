package input_test

import "core:c"
import "core:testing"
import "core:time"
import posix "core:sys/posix"
import "vendor:sdl3"

import input "../"
import pty "../../pty"
import win "../../window"
import termgrid "../../../terminal"

// Langkah 9 tests. The SDL-drain loop (window_poll_input proper) needs a
// display and is NOT covered here; everything below it is: the pure
// translator (synthetic sdl3.Events, no SDL init), the resize math, and the
// encode -> pty_write -> drain-echo path plus winsize + terminal_resize
// against a live /bin/cat pty. See the headless-limits note at the bottom.

// _pump_key builds a synthetic KEYDOWN event. No SDL init required: the
// Event union is plain memory until PollEvent fills it.
_pump_key :: proc(key: sdl3.Keycode, mod: sdl3.Keymod, repeat: bool = false) -> sdl3.Event {
	ke := sdl3.KeyboardEvent{}
	ke.type = .KEY_DOWN
	ke.key = key
	ke.mod = mod
	ke.down = true
	ke.repeat = repeat
	ev: sdl3.Event
	ev.key = ke
	return ev
}

// _pump_text builds a synthetic TEXTINPUT event over a NUL-terminated
// buffer the caller keeps alive for the call.
_pump_text :: proc(text: cstring) -> sdl3.Event {
	te := sdl3.TextInputEvent{}
	te.type = .TEXT_INPUT
	te.text = text
	ev: sdl3.Event
	ev.text = te
	return ev
}

// _pump_teardown mirrors the pty suite teardown: SIGKILL, reap, close.
_pump_teardown :: proc(p: ^pty.Pty) {
	if p.pid > 0 {
		posix.kill(posix.pid_t(p.pid), .SIGKILL)
		status: c.int
		posix.waitpid(posix.pid_t(p.pid), &status, posix.Wait_Flags{})
		p.pid = -1
	}
	if p.master >= 0 {
		posix.close(posix.FD(p.master))
		p.master = -1
	}
}

// _pump_bytes reports whether haystack holds needle.
_pump_bytes :: proc(haystack: []u8, needle: []u8) -> bool {
	if len(needle) == 0 || len(haystack) < len(needle) {
		return false
	}
	for i in 0..=(len(haystack) - len(needle)) {
		match := true
		for j in 0..<len(needle) {
			if haystack[i + j] != needle[j] {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}

// _pump_drain_until collects child output until needle appears or timeout
// (500 x 10ms). Returns all bytes collected and whether needle was seen.
_pump_drain_until :: proc(p: ^pty.Pty, needle: []u8) -> (got: [dynamic]u8, found: bool) {
	got = make([dynamic]u8)
	buf := make([]u8, 65536)
	defer delete(buf)
	for _ in 0..<500 {
		n, done := pty.pty_drain(p, buf, 65536)
		if n > 0 {
			append(&got, ..buf[:n])
			if _pump_bytes(got[:], needle) {
				return got, true
			}
		}
		if done {
			return got, _pump_bytes(got[:], needle)
		}
		if n == 0 {
			time.sleep(10 * time.Millisecond)
		}
	}
	return got, _pump_bytes(got[:], needle)
}

@(test)
test_pump_translate_text_multibyte :: proc(t: ^testing.T) {
	// "A" + e-acute (C3 A9) + CJK (E4 B8 AD) + emoji (F0 9F 98 80).
	raw := [11]u8{0x41, 0xC3, 0xA9, 0xE4, 0xB8, 0xAD, 0xF0, 0x9F, 0x98, 0x80, 0x00}
	ev := _pump_text(cstring(&raw[0]))
	out: [8]input.Input_Event
	n, quit, resized := input.input_translate_sdl(ev, out[:])
	testing.expect(t, n == 4, "4 runes must yield 4 Printable events")
	testing.expect(t, !quit && !resized, "text must not set quit/resized")
	want := [4]rune{'A', 'é', '中', '😀'}
	for i in 0..<4 {
		testing.expect(t, out[i].kind == .Printable, "text rune must be Printable")
		testing.expect(t, out[i].rune == want[i], "text rune must decode intact")
	}
}

@(test)
test_pump_translate_text_skips_controls :: proc(t: ^testing.T) {
	// Lone CR (Enter's TEXTINPUT shadow) is owned by the KEYDOWN path.
	cr := [2]u8{0x0D, 0x00}
	out: [8]input.Input_Event
	n, _, _ := input.input_translate_sdl(_pump_text(cstring(&cr[0])), out[:])
	testing.expect(t, n == 0, "TEXTINPUT CR must be skipped (KEYDOWN owns Enter)")

	// Tab shadow skipped, surrounding printables kept.
	mixed := [5]u8{'a', 0x09, 'b', 0x7F, 0x00}
	n, _, _ = input.input_translate_sdl(_pump_text(cstring(&mixed[0])), out[:])
	testing.expect(t, n == 2, "TAB and DEL shadows must be skipped, a/b kept")
	if n == 2 {
		testing.expect(t, out[0].rune == 'a' && out[1].rune == 'b', "kept runes must be a, b")
	}
}

@(test)
test_pump_translate_arrows_mods :: proc(t: ^testing.T) {
	out: [4]input.Input_Event

	n, _, _ := input.input_translate_sdl(_pump_key(sdl3.K_UP, sdl3.KMOD_NONE), out[:])
	testing.expect(t, n == 1, "Up must yield one event")
	testing.expect(t, out[0].kind == .Arrow_Up, "Up must map to Arrow_Up")
	testing.expect(t, !out[0].shift && !out[0].alt && !out[0].ctrl, "bare Up must carry no flags")

	n, _, _ = input.input_translate_sdl(_pump_key(sdl3.K_DOWN, sdl3.KMOD_SHIFT), out[:])
	testing.expect(t, n == 1 && out[0].kind == .Arrow_Down && out[0].shift, "Shift+Down must map with shift flag")

	n, _, _ = input.input_translate_sdl(_pump_key(sdl3.K_LEFT, sdl3.KMOD_CTRL), out[:])
	testing.expect(t, n == 1 && out[0].kind == .Arrow_Left && out[0].ctrl, "Ctrl+Left must map with ctrl flag")

	alt := sdl3.Keymod{.LALT}
	n, _, _ = input.input_translate_sdl(_pump_key(sdl3.K_RIGHT, alt), out[:])
	testing.expect(t, n == 1 && out[0].kind == .Arrow_Right && out[0].alt, "Alt+Right must map with alt flag")
}

@(test)
test_pump_translate_special_keys :: proc(t: ^testing.T) {
	out: [2]input.Input_Event
	cases := [?]struct {
		key:  sdl3.Keycode,
		kind: input.Input_Key_Kind,
		msg:  string,
	}{
		{sdl3.K_RETURN, .Enter, "RETURN must map to Enter"},
		{sdl3.K_RETURN2, .Enter, "RETURN2 must map to Enter"},
		{sdl3.K_KP_ENTER, .Enter, "KP_ENTER must map to Enter"},
		{sdl3.K_BACKSPACE, .Backspace, "BACKSPACE must map to Backspace"},
		{sdl3.K_TAB, .Tab, "TAB must map to Tab"},
		{sdl3.K_LEFT_TAB, .Tab, "LEFT_TAB must map to Tab"},
		{sdl3.K_ESCAPE, .Escape, "ESCAPE must map to Escape"},
		{sdl3.K_HOME, .Home, "HOME must map to Home"},
		{sdl3.K_END, .End, "END must map to End"},
		{sdl3.K_PAGEUP, .PgUp, "PAGEUP must map to PgUp"},
		{sdl3.K_PAGEDOWN, .PgDn, "PAGEDOWN must map to PgDn"},
	}
	for c in cases {
		n, quit, resized := input.input_translate_sdl(_pump_key(c.key, sdl3.KMOD_NONE), out[:])
		testing.expect(t, n == 1, "special key must yield one event")
		testing.expect(t, out[0].kind == c.kind, c.msg)
		testing.expect(t, !quit && !resized, "special key must not set quit/resized")
	}
}

@(test)
test_pump_translate_repeat_is_normal_press :: proc(t: ^testing.T) {
	out: [2]input.Input_Event
	n, _, _ := input.input_translate_sdl(_pump_key(sdl3.K_UP, sdl3.KMOD_NONE, true), out[:])
	testing.expect(t, n == 1, "repeat must be treated as a normal press")
	testing.expect(t, out[0].kind == .Arrow_Up, "repeat Up must map to Arrow_Up")
}

@(test)
test_pump_translate_ctrl_alt_printable :: proc(t: ^testing.T) {
	out: [2]input.Input_Event

	// Bare printable: TEXTINPUT owns it, KEYDOWN yields nothing.
	n, _, _ := input.input_translate_sdl(_pump_key(sdl3.K_A, sdl3.KMOD_NONE), out[:])
	testing.expect(t, n == 0, "bare printable KEYDOWN must be ignored (TEXTINPUT owns it)")

	// Ctrl combos ride KEYDOWN (TEXTINPUT never fires for them), except
	// Ctrl+C, which is reserved for local copy handling.
	n, _, _ = input.input_translate_sdl(_pump_key(sdl3.K_C, sdl3.KMOD_CTRL), out[:])
	testing.expect(t, n == 1, "Ctrl+C must yield one local event")
	testing.expect(t, out[0].event_type == .Local && out[0].action == .Copy, "Ctrl+C must be Local Copy")

	n, _, _ = input.input_translate_sdl(_pump_key(sdl3.K_SPACE, sdl3.KMOD_CTRL), out[:])
	testing.expect(t, n == 1 && out[0].kind == .Ctrl && out[0].rune == ' ', "Ctrl+Space must be Ctrl{space}")

	// Ctrl+Enter folds to Enter (no Ctrl mapping for CR at encode level).
	n, _, _ = input.input_translate_sdl(_pump_key(sdl3.K_RETURN, sdl3.KMOD_CTRL), out[:])
	testing.expect(t, n == 1 && out[0].kind == .Enter, "Ctrl+Enter must fold to Enter")

	// Alt+printable keeps the Alt flag TEXTINPUT would lose.
	alt := sdl3.Keymod{.LALT}
	n, _, _ = input.input_translate_sdl(_pump_key(sdl3.K_X, alt), out[:])
	testing.expect(t, n == 1 && out[0].kind == .Alt_Mod && out[0].rune == 'x', "Alt+x must be Alt_Mod{x}")

	n, _, _ = input.input_translate_sdl(_pump_key(sdl3.K_RETURN, alt), out[:])
	testing.expect(t, n == 1 && out[0].kind == .Alt_Mod && out[0].rune == '\r', "Alt+Enter must be Alt_Mod{CR}")

	n, _, _ = input.input_translate_sdl(_pump_key(sdl3.K_BACKSPACE, alt), out[:])
	testing.expect(t, n == 1 && out[0].kind == .Alt_Mod && out[0].rune == '\x7f', "Alt+Backspace must be Alt_Mod{DEL}")

	n, _, _ = input.input_translate_sdl(_pump_key(sdl3.K_TAB, alt), out[:])
	testing.expect(t, n == 1 && out[0].kind == .Alt_Mod && out[0].rune == '\t', "Alt+Tab must be Alt_Mod{TAB}")

	n, _, _ = input.input_translate_sdl(_pump_key(sdl3.K_ESCAPE, alt), out[:])
	testing.expect(t, n == 1 && out[0].kind == .Alt_Mod && out[0].rune == '\x1b', "Alt+Escape must be Alt_Mod{ESC}")
}

@(test)
test_pump_translate_quit_resize_unknown :: proc(t: ^testing.T) {
	out: [2]input.Input_Event

	ev: sdl3.Event
	ev.type = .QUIT
	n, quit, resized := input.input_translate_sdl(ev, out[:])
	testing.expect(t, n == 0 && quit && !resized, "QUIT must report quit only")

	ev.type = .WINDOW_CLOSE_REQUESTED
	n, quit, resized = input.input_translate_sdl(ev, out[:])
	testing.expect(t, n == 0 && quit && !resized, "CLOSE_REQUESTED must report quit only")

	ev.type = .WINDOW_RESIZED
	n, quit, resized = input.input_translate_sdl(ev, out[:])
	testing.expect(t, n == 0 && !quit && resized, "RESIZED must report resized only")

	ev.type = .WINDOW_PIXEL_SIZE_CHANGED
	n, quit, resized = input.input_translate_sdl(ev, out[:])
	testing.expect(t, n == 0 && !quit && resized, "PIXEL_SIZE_CHANGED must report resized only")

	ev.type = cast(sdl3.EventType)0x7FFF
	n, quit, resized = input.input_translate_sdl(ev, out[:])
	testing.expect(t, n == 0 && !quit && !resized, "unknown event must be ignored")
}

@(test)
test_pump_translate_out_cap :: proc(t: ^testing.T) {
	raw := [5]u8{'a', 'b', 'c', 'd', 0x00}
	ev := _pump_text(cstring(&raw[0]))
	small: [2]input.Input_Event
	n, _, _ := input.input_translate_sdl(ev, small[:])
	testing.expect(t, n == 2, "translation must stop at out capacity")
	testing.expect(t, small[0].rune == 'a' && small[1].rune == 'b', "capped output must keep order")

	empty: [0]input.Input_Event
	n, _, _ = input.input_translate_sdl(ev, empty[:])
	testing.expect(t, n == 0, "empty out must yield nothing")

	n, _, _ = input.input_translate_sdl(_pump_key(sdl3.K_UP, sdl3.KMOD_NONE), empty[:])
	testing.expect(t, n == 0, "key event with empty out must yield nothing")
}

@(test)
test_pump_translate_delete_and_local_actions :: proc(t: ^testing.T) {
	out: [2]input.Input_Event

	n, _, _ := input.input_translate_sdl(_pump_key(sdl3.K_DELETE, sdl3.KMOD_SHIFT|sdl3.KMOD_CTRL|sdl3.KMOD_GUI), out[:])
	testing.expect(t, n == 1, "Delete must yield one event")
	if n == 1 {
		testing.expect(t, out[0].kind == .Delete, "Delete must map to Delete")
		testing.expect(t, out[0].shift && out[0].ctrl && out[0].gui, "Delete must preserve Shift/Ctrl/GUI")
	}

	n, _, _ = input.input_translate_sdl(_pump_key(sdl3.K_C, sdl3.KMOD_CTRL), out[:])
	testing.expect(t, n == 1 && out[0].event_type == .Local && out[0].action == .Copy, "Ctrl+C must be local Copy")

	n, _, _ = input.input_translate_sdl(_pump_key(sdl3.K_PLUS, sdl3.KMOD_GUI), out[:])
	testing.expect(t, n == 1 && out[0].event_type == .Local && out[0].action == .Zoom_In, "GUI+plus must be local zoom in")

	n, _, _ = input.input_translate_sdl(_pump_key(sdl3.K_EQUALS, sdl3.KMOD_GUI|sdl3.KMOD_SHIFT), out[:])
	testing.expect(t, n == 1 && out[0].event_type == .Local && out[0].action == .Zoom_In, "GUI+Shift+equals must be local zoom in")

	n, _, _ = input.input_translate_sdl(_pump_key(sdl3.K_EQUALS, sdl3.KMOD_NONE), out[:])
	testing.expect(t, n == 0, "bare equals must remain owned by TEXTINPUT")

	n, _, _ = input.input_translate_sdl(_pump_key(sdl3.K_KP_MINUS, sdl3.KMOD_CTRL), out[:])
	testing.expect(t, n == 1 && out[0].event_type == .Local && out[0].action == .Zoom_Out, "Ctrl+keypad minus must be local zoom out")
}

@(test)
test_pump_translate_mouse_events :: proc(t: ^testing.T) {
	out: [2]input.Input_Event

	motion := sdl3.MouseMotionEvent{
		type = .MOUSE_MOTION,
		x = 12.5,
		y = 7.25,
		xrel = 1.5,
		yrel = -2.0,
		state = sdl3.BUTTON_LMASK,
	}
	ev: sdl3.Event
	ev.motion = motion
	n, _, _ := input.input_translate_sdl(ev, out[:])
	testing.expect(t, n == 1 && out[0].event_type == .Pointer, "mouse motion must be a pointer event")
	if n == 1 {
		testing.expect(t, out[0].pointer.kind == .Motion, "motion kind must be preserved")
		testing.expect(t, out[0].pointer.x == 12.5 && out[0].pointer.y == 7.25, "motion position must use SDL coordinates")
		testing.expect(t, out[0].pointer.dx == 1.5 && out[0].pointer.dy == -2.0, "motion delta must use SDL relative fields")
		testing.expect(t, out[0].pointer.primary_down, "motion must preserve primary-button state")
	}

	button := sdl3.MouseButtonEvent{type = .MOUSE_BUTTON_DOWN, button = sdl3.BUTTON_LEFT, down = true, x = 4, y = 5}
	ev.button = button
	n, _, _ = input.input_translate_sdl(ev, out[:])
	testing.expect(t, n == 1 && out[0].pointer.kind == .Button_Down, "primary press must be a button-down event")
	testing.expect(t, out[0].pointer.button == sdl3.BUTTON_LEFT && out[0].pointer.primary_down, "button fields must be preserved")

	wheel := sdl3.MouseWheelEvent{type = .MOUSE_WHEEL, x = 0, y = -2, integer_y = -2, direction = .FLIPPED, mouse_x = 4, mouse_y = 5}
	ev.wheel = wheel
	n, _, _ = input.input_translate_sdl(ev, out[:])
	testing.expect(t, n == 1 && out[0].pointer.kind == .Wheel, "wheel must be a pointer wheel event")
	testing.expect(t, out[0].pointer.wheel_y == -2 && out[0].pointer.wheel_integer_y == -2 && out[0].pointer.wheel_flipped, "wheel deltas and direction must use SDL fields")
}

@(test)
test_pump_events_local_pointer_are_not_pty_bytes :: proc(t: ^testing.T) {
	evs := [?]input.Input_Event{
		{event_type = .Pointer, pointer = {kind = .Wheel, wheel_integer_y = 1}},
		{event_type = .Local, action = .Copy},
	}
	testing.expect(t, input.input_pump_events(nil, evs[:]), "local events must not require a PTY")
}

@(test)
test_pump_grid_math :: proc(t: ^testing.T) {
	rows, cols := input.input_grid_for_pixels(1280, 384)
	testing.expect(t, rows == 24 && cols == 80, "1280x384 @16 must be 24x80")

	rows, cols = input.input_grid_for_pixels(800, 600)
	testing.expect(t, rows == 37 && cols == 50, "800x600 @16 must be 37x50")

	rows, cols = input.input_grid_for_pixels(0, 0)
	testing.expect(t, rows == 1 && cols == 1, "zero pixels must clamp to 1x1")

	rows, cols = input.input_grid_for_pixels(-100, -50)
	testing.expect(t, rows == 1 && cols == 1, "negative pixels must clamp to 1x1")

	rows, cols = input.input_grid_for_pixels(1280, 384, 0, -4)
	testing.expect(t, rows == 24 && cols == 80, "bad cell dims must fall back to defaults")

	rows, cols = input.input_grid_for_pixels(100, 50, 10, 10)
	testing.expect(t, rows == 5 && cols == 10, "custom cell dims must divide exactly")
}

@(test)
test_pump_events_cat_echo :: proc(t: ^testing.T) {
	p: pty.Pty
	ok := pty.pty_spawn(&p, 24, 80, "/bin/cat", {})
	testing.expect(t, ok, "pty_spawn /bin/cat must succeed")
	if !ok {
		return
	}
	defer _pump_teardown(&p)

	// Typing "hi" + Enter: encoded by the pump, echoed by the pty.
	evs := [3]input.Input_Event{
		{kind = .Printable, rune = 'h'},
		{kind = .Printable, rune = 'i'},
		{kind = .Enter},
	}
	testing.expect(t, input.input_pump_events(&p, evs[:]), "pump write of hi+Enter must succeed")
	got, found := _pump_drain_until(&p, transmute([]u8)string("hi"))
	defer delete(got)
	testing.expect(t, found, "typed hi must echo back through the pty")

	// Arrow Up encodes to ESC [ A; the line flushes via the appended Enter
	// and cat outputs the raw bytes (output postprocessing never touches
	// ESC), so the exact sequence must come back.
	up := [2]input.Input_Event{{kind = .Arrow_Up}, {kind = .Enter}}
	testing.expect(t, input.input_pump_events(&p, up[:]), "pump write of Up+Enter must succeed")
	got2, found2 := _pump_drain_until(&p, []u8{0x1B, '[', 'A'})
	defer delete(got2)
	testing.expect(t, found2, "Up must round-trip as ESC[A bytes")

	// Multibyte rune passes through UTF-8 intact (C3 A9).
	e_acute := [2]input.Input_Event{{kind = .Printable, rune = 'é'}, {kind = .Enter}}
	testing.expect(t, input.input_pump_events(&p, e_acute[:]), "pump write of multibyte+Enter must succeed")
	got3, found3 := _pump_drain_until(&p, []u8{0xC3, 0xA9})
	defer delete(got3)
	testing.expect(t, found3, "multibyte rune must round-trip as UTF-8 bytes")
}

@(test)
test_pump_events_nil_and_empty :: proc(t: ^testing.T) {
	testing.expect(
		t,
		!input.input_pump_events(nil, []input.Input_Event{{kind = .Printable, rune = 'a'}}),
		"nil pty with encodable events must report failure",
	)
	testing.expect(t, input.input_pump_events(nil, {}), "nil pty with no events must succeed")
	testing.expect(
		t,
		input.input_pump_events(nil, []input.Input_Event{{kind = input.Input_Key_Kind(255)}}),
		"nil pty with only unencodable events must still succeed",
	)
}

@(test)
test_pump_resize_applies :: proc(t: ^testing.T) {
	p: pty.Pty
	ok := pty.pty_spawn(&p, 24, 80, "/bin/cat", {})
	testing.expect(t, ok, "pty_spawn /bin/cat must succeed")
	if !ok {
		return
	}
	defer _pump_teardown(&p)
	term: termgrid.Terminal
	termgrid.terminal_init(&term, 24, 80)
	defer termgrid.terminal_destroy(&term)

	// 1600x480 @16 -> 30x100: winsize + terminal_resize both fire once.
	resized, wok := input.input_pump_resize(&p, &term, 1600, 480)
	testing.expect(t, resized && wok, "pixel change to 1600x480 must resize ok")
	testing.expect(t, p.rows == 30 && p.cols == 100, "pty winsize must track 30x100")
	testing.expect(t, term.grid.row_count == 30 && term.grid.col_count == 100, "grid must track 30x100")

	// Same dims: no-op, still ok.
	resized, wok = input.input_pump_resize(&p, &term, 1600, 480)
	testing.expect(t, !resized && wok, "same dims must be a no-op success")

	// Nil guards: no syscalls, explicit failure.
	resized, wok = input.input_pump_resize(nil, &term, 1600, 480)
	testing.expect(t, !resized && !wok, "nil pty must fail without syscalls")
	resized, wok = input.input_pump_resize(&p, nil, 1600, 480)
	testing.expect(t, !resized && !wok, "nil terminal must fail without syscalls")
}

@(test)
test_pump_resize_dynamic_cell_metrics :: proc(t: ^testing.T) {
	p: pty.Pty
	ok := pty.pty_spawn(&p, 24, 80, "/bin/cat", {})
	testing.expect(t, ok, "pty_spawn /bin/cat must succeed")
	if !ok {
		return
	}
	defer _pump_teardown(&p)
	term: termgrid.Terminal
	termgrid.terminal_init(&term, 24, 80)
	defer termgrid.terminal_destroy(&term)

	// Retina cell metrics: 16x32 with 1600x960 pixels -> 30x100
	resized, wok := input.input_pump_resize(&p, &term, 1600, 960, 16, 32)
	testing.expect(t, resized && wok, "retina pixel resize with 16x32 must succeed")
	testing.expect(t, p.rows == 30 && p.cols == 100, "pty winsize must track 30x100 on retina")
	testing.expect(t, term.grid.row_count == 30 && term.grid.col_count == 100, "grid must track 30x100 on retina")

	// Standard cell metrics: 8x16 with 640x384 pixels -> 24x80
	resized, wok = input.input_pump_resize(&p, &term, 640, 384, 8, 16)
	testing.expect(t, resized && wok, "standard pixel resize with 8x16 must succeed")
	testing.expect(t, p.rows == 24 && p.cols == 80, "pty winsize must track 24x80 on standard")
	testing.expect(t, term.grid.row_count == 24 && term.grid.col_count == 80, "grid must track 24x80 on standard")
}

@(test)
test_pump_nil_window :: proc(t: ^testing.T) {
	quit, resized, ok := input.input_pump(nil, nil, nil)
	testing.expect(t, quit && !resized && !ok, "nil window must report quit with no work")

	// window_poll_input with nil window drains nothing.
	out: [4]input.Input_Event
	testing.expect(t, input.window_poll_input(nil, out[:], 4) == 0, "nil window poll must yield 0")
	testing.expect(t, input.window_poll_input(nil, out[:], 0) == 0, "nil window poll with max 0 must yield 0")
}

// Headless-limits note (partial test): window_poll_input's PollEvent drain
// needs SDL video. It runs under the dummy driver (SDL_VIDEODRIVER=dummy,
// no display server); without video init the frame test below skips and the
// drain loop is verified only by construction review: a straight
// for-PollEvent loop over the headless-tested input_translate_sdl plus the
// two window side effects (is_open=false, window_update_pixel_size, the
// latter a no-op on a nil handle). Manual verification is typing + resize
// in the app (Langkah 14).
@(test)
test_pump_full_frame_headless :: proc(t: ^testing.T) {
	w: win.Window
	if !win.window_init(&w, "pump-headless", 1280, 384) {
		testing.expect(t, true, "SKIP: no SDL video headless; translator/math/pty paths cover the rest")
		return
	}
	defer win.window_destroy(&w)

	// Idle drain: startup events (shown/exposed/...) are not input.
	out: [8]input.Input_Event
	n := input.window_poll_input(&w, out[:], 8)
	testing.expect(t, n == 0, "idle headless poll must yield no input")
	testing.expect(t, w.is_open, "idle headless poll must stay open")

	// Full pump frame against a live pty + terminal.
	p: pty.Pty
	ok := pty.pty_spawn(&p, 24, 80, "/bin/cat", {})
	testing.expect(t, ok, "pty_spawn /bin/cat must succeed")
	if !ok {
		return
	}
	defer _pump_teardown(&p)
	term: termgrid.Terminal
	termgrid.terminal_init(&term, 24, 80)
	defer termgrid.terminal_destroy(&term)
	quit, resized, pok := input.input_pump(&w, &p, &term)
	testing.expect(t, !quit, "headless pump must not quit")
	testing.expect(t, pok, "idle headless pump must report ok")
	if resized {
		erows, ecols := input.input_grid_for_pixels(int(w.pixel_w), int(w.pixel_h))
		testing.expect(
			t,
			term.grid.row_count == erows && term.grid.col_count == ecols,
			"applied resize must match pixel math",
		)
	} else {
		testing.expect(
			t,
			term.grid.row_count == 24 && term.grid.col_count == 80,
			"idle pump must leave grid at 24x80",
		)
	}
}
