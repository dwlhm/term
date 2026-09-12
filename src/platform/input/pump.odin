package input

import "core:unicode/utf8"
import "vendor:sdl3"

import win "../window"
import pty "../pty"
import termgrid "../../terminal"

// Input pump (Phase 9): SDL event -> Input_Event -> VT bytes -> PTY write,
// plus terminal-local pointer/actions and window-resize -> winsize +
// terminal_resize.
//
// Call discipline (SDL pump ownership): window_poll_input and
// window_poll_events BOTH drain the SDL PollEvent queue. The app must call
// exactly one of them per frame, never both — calling both splits the event
// stream (key events vanish into the wrong drain). window_poll_events stays
// the owner for phases without text input; input frames use
// window_poll_input (via input_pump), which forwards quit/resize side
// effects onto the Window (is_open, pixel size) instead of consuming them
// silently.
//
// This file lives in package input rather than package window because Odin
// forbids import cycles: window_poll_input's out slice is []Input_Event
// (needs an input edge) while input_pump takes ^win.Window (needs a window
// edge). A single input -> window edge keeps the graph acyclic.

// INPUT_PUMP_MAX_EVENTS caps the Input_Events collected per input_pump call.
// The buffer lives on the caller's stack; 64 covers burst typing plus IME
// commits within one frame without allocation.
INPUT_PUMP_MAX_EVENTS :: 64

// INPUT_DEFAULT_CELL_W/H are the fallback cell pixel dimensions for the
// pixel -> grid resize math. They mirror CELL_WIDTH/CELL_HEIGHT in
// src/app/main.odin (the renderer-owned metrics replace them in Phase 13;
// until then the pump and the app must agree or the grid and the window
// drift apart).
INPUT_DEFAULT_CELL_W :: 16
INPUT_DEFAULT_CELL_H :: 16

// window_poll_input drains pending SDL events, translating key/text input
// into out (up to min(len(out), max) events) and returning the count.
//
// quit/resize events are NOT reported as Input_Events: QUIT and
// WINDOW_CLOSE_REQUESTED set w.is_open = false, WINDOW_RESIZED and
// WINDOW_PIXEL_SIZE_CHANGED refresh the pixel size via
// window_update_pixel_size. Callers observe quit via !w.is_open and resize
// by comparing w.pixel_w/h before/after (input_pump does both).
//
// TEXTINPUT feeds Printable runes (UTF-8 decoded, multibyte intact);
// KEYDOWN feeds non-printable keys plus Ctrl/Alt combos with Shift/Alt/Ctrl
// flags from the SDL keymod. Key repeat is treated as a normal press (see
// input_translate_sdl). Unknown event types are ignored.
window_poll_input :: proc(w: ^win.Window, out: []Input_Event, max: int) -> int {
	if w == nil {
		return 0
	}
	cap := min(len(out), max)
	if cap <= 0 {
		return 0
	}
	count := 0
	ev: sdl3.Event
	for sdl3.PollEvent(&ev) {
		n, quit, resized := input_translate_sdl(ev, out[count:cap])
		count += n
		if quit {
			w.is_open = false
		}
		if resized {
			win.window_update_pixel_size(w)
		}
	}
	return count
}

// input_translate_sdl converts ONE SDL event into Input_Events, returning
// the events written plus quit/resized flags for window-level events.
//
// Translation rules:
//   TEXTINPUT text -> one Printable per decoded rune. Runes below 0x20 and
//     0x7F (DEL) are skipped: control keys are owned by the KEYDOWN path,
//     and emitting both would double Enter/Tab/Backspace.
//   KEYDOWN special keys -> mapped kinds with live Shift/Alt/Ctrl/GUI flags:
//     arrows, Home, End, PgUp, PgDn, Enter (K_RETURN, K_RETURN2,
//     K_KP_ENTER), Backspace, Delete, Tab (K_TAB, K_LEFT_TAB), Escape.
//     Ctrl+Enter folds to plain Enter (input_encode has no Ctrl mapping
//     for CR); Ctrl+arrows keep arrow kind with the ctrl flag (xterm
//     modifier parameter, handled by input_encode). Alt+Enter/Backspace/
//     Tab/Escape (no Ctrl) fold to Alt_Mod carrying '\r'/'\x7f'/'\t'/
//     '\x1b', preserving the Alt prefix input_encode emits (ESC CR,
//     ESC DEL, ESC TAB, ESC ESC); Ctrl wins when both are held.
//   KEYDOWN Ctrl/GUI+C -> Local Copy (copy never reaches the PTY).
//   KEYDOWN Ctrl/GUI+plus/minus -> Local Zoom_In/Zoom_Out.
//   KEYDOWN printable + Ctrl -> Ctrl event (TEXTINPUT never fires for
//     Ctrl combos, so KEYDOWN is the only source). Encodability is decided
//     by input_encode at write time: unmapped runes encode to 0 bytes and
//     are skipped, never written.
//   KEYDOWN printable + Alt (no Ctrl) -> Alt_Mod event. Known limit: on
//     platforms where the OS ALSO delivers TEXTINPUT for an Alt combo, the
//     key arrives twice (once prefixed, once plain). Alt is preserved
//     because TEXTINPUT alone would lose it.
//   KEYDOWN printable without Ctrl/Alt -> ignored (TEXTINPUT owns
//     delivery, including Shift-produced capitals).
//   MOUSE_MOTION / MOUSE_BUTTON_DOWN / MOUSE_BUTTON_UP / MOUSE_WHEEL ->
//     pointer events carrying the verified SDL event fields.
//   QUIT / WINDOW_CLOSE_REQUESTED -> quit = true.
//   WINDOW_RESIZED / WINDOW_PIXEL_SIZE_CHANGED -> resized = true.
//   Anything else -> ignored (0, false, false).
//
// Key repeat (ev.key.repeat) is deliberately ignored: repeats are normal
// presses, and the OS/SDL repeat rate governs them — terminals must echo
// held keys.
//
// At most len(out) events are written; excess TEXTINPUT runes are dropped
// (callers size out for a full frame: INPUT_PUMP_MAX_EVENTS).
input_translate_sdl :: proc(ev: sdl3.Event, out: []Input_Event) -> (n: int, quit: bool, resized: bool) {
	#partial switch ev.type {
	case .QUIT, .WINDOW_CLOSE_REQUESTED:
		return 0, true, false
	case .WINDOW_RESIZED, .WINDOW_PIXEL_SIZE_CHANGED:
		return 0, false, true
	case .TEXT_INPUT:
		return _translate_text(ev.text.text, out), false, false
	case .KEY_DOWN:
		if _translate_key(ev.key.key, ev.key.mod, out) {
			return 1, false, false
		}
		return 0, false, false
	case .MOUSE_MOTION:
		if len(out) == 0 {
			return 0, false, false
		}
		out[0] = Input_Event{
			event_type = .Pointer,
			pointer = Input_Pointer_Event{
				kind = .Motion,
				x = ev.motion.x,
				y = ev.motion.y,
				dx = ev.motion.xrel,
				dy = ev.motion.yrel,
				primary_down = _mouse_primary_down(ev.motion.state),
			},
		}
		return 1, false, false
	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
		if len(out) == 0 {
			return 0, false, false
		}
		out[0] = Input_Event{
			event_type = .Pointer,
			pointer = Input_Pointer_Event{
				kind = ev.button.down ? .Button_Down : .Button_Up,
				x = ev.button.x,
				y = ev.button.y,
				button = ev.button.button,
				pressed = ev.button.down,
				primary_down = ev.button.button == sdl3.BUTTON_LEFT && ev.button.down,
			},
		}
		return 1, false, false
	case .MOUSE_WHEEL:
		if len(out) == 0 {
			return 0, false, false
		}
		out[0] = Input_Event{
			event_type = .Pointer,
			pointer = Input_Pointer_Event{
				kind = .Wheel,
				x = ev.wheel.mouse_x,
				y = ev.wheel.mouse_y,
				wheel_x = ev.wheel.x,
				wheel_y = ev.wheel.y,
				wheel_integer_x = ev.wheel.integer_x,
				wheel_integer_y = ev.wheel.integer_y,
				wheel_flipped = ev.wheel.direction == .FLIPPED,
			},
		}
		return 1, false, false
	case:
		return 0, false, false
	}
}

// _mouse_primary_down reports whether SDL's current mouse state contains the
// primary button. The state is only used for local drag-selection handling.
_mouse_primary_down :: proc(state: sdl3.MouseButtonFlags) -> bool {
	return (state & sdl3.BUTTON_LMASK) != sdl3.MouseButtonFlags{}
}

// _translate_text decodes a TEXTINPUT cstring (UTF-8) into Printable events.
// Control runes (< 0x20, 0x7F) are skipped per input_translate_sdl. Stops at
// NUL, on empty out, or on a zero-width decode (defensive: never spin).
_translate_text :: proc(text: cstring, out: []Input_Event) -> int {
	if len(out) == 0 {
		return 0
	}
	s := string(text)
	count := 0
	i := 0
	for i < len(s) {
		if count >= len(out) {
			break
		}
		r, size := utf8.decode_rune_in_string(s[i:])
		if size <= 0 {
			break
		}
		i += size
		if r < 0x20 || r == 0x7F {
			continue
		}
		out[count] = Input_Event{kind = .Printable, rune = r}
		count += 1
	}
	return count
}

// _translate_key maps one KEYDOWN (keycode + modifier state) to a single
// Input_Event in out[0]. Returns false when the key has no pump mapping
// (printable without Ctrl/Alt, or an unrepresentable keycode).
_translate_key :: proc(key: sdl3.Keycode, mod: sdl3.Keymod, out: []Input_Event) -> bool {
	if len(out) == 0 {
		return false
	}
	shift := (mod & sdl3.KMOD_SHIFT) != sdl3.KMOD_NONE
	alt := (mod & sdl3.KMOD_ALT) != sdl3.KMOD_NONE
	ctrl := (mod & sdl3.KMOD_CTRL) != sdl3.KMOD_NONE
	gui := (mod & sdl3.KMOD_GUI) != sdl3.KMOD_NONE
	if (ctrl || gui) && key == sdl3.K_C {
		out[0] = Input_Event{event_type = .Local, action = .Copy, ctrl = ctrl, gui = gui, shift = shift}
		return true
	}
	if (ctrl || gui) && shift && key == sdl3.K_EQUALS {
		out[0] = Input_Event{event_type = .Local, action = .Zoom_In, ctrl = ctrl, gui = gui, shift = shift}
		return true
	}
	if ctrl || gui {
		switch key {
		case sdl3.K_PLUS, sdl3.K_KP_PLUS, sdl3.K_EQUALS:
			out[0] = Input_Event{event_type = .Local, action = .Zoom_In, ctrl = ctrl, gui = gui, shift = shift}
			return true
		case sdl3.K_MINUS, sdl3.K_KP_MINUS:
			out[0] = Input_Event{event_type = .Local, action = .Zoom_Out, ctrl = ctrl, gui = gui, shift = shift}
			return true
		case sdl3.K_COPY:
			out[0] = Input_Event{event_type = .Local, action = .Copy, ctrl = ctrl, gui = gui, shift = shift}
			return true
		}
	}
	switch key {
	case sdl3.K_UP:
		out[0] = Input_Event{kind = .Arrow_Up, shift = shift, alt = alt, ctrl = ctrl, gui = gui}
		return true
	case sdl3.K_DOWN:
		out[0] = Input_Event{kind = .Arrow_Down, shift = shift, alt = alt, ctrl = ctrl, gui = gui}
		return true
	case sdl3.K_LEFT:
		out[0] = Input_Event{kind = .Arrow_Left, shift = shift, alt = alt, ctrl = ctrl, gui = gui}
		return true
	case sdl3.K_RIGHT:
		out[0] = Input_Event{kind = .Arrow_Right, shift = shift, alt = alt, ctrl = ctrl, gui = gui}
		return true
	case sdl3.K_HOME:
		out[0] = Input_Event{kind = .Home, shift = shift, alt = alt, ctrl = ctrl, gui = gui}
		return true
	case sdl3.K_END:
		out[0] = Input_Event{kind = .End, shift = shift, alt = alt, ctrl = ctrl, gui = gui}
		return true
	case sdl3.K_PAGEUP:
		out[0] = Input_Event{kind = .PgUp, shift = shift, alt = alt, ctrl = ctrl, gui = gui}
		return true
	case sdl3.K_PAGEDOWN:
		out[0] = Input_Event{kind = .PgDn, shift = shift, alt = alt, ctrl = ctrl, gui = gui}
		return true
	case sdl3.K_RETURN, sdl3.K_RETURN2, sdl3.K_KP_ENTER:
		if alt && !ctrl {
			out[0] = Input_Event{kind = .Alt_Mod, rune = '\r', alt = true, shift = shift}
			return true
		}
		out[0] = Input_Event{kind = .Enter}
		return true
	case sdl3.K_BACKSPACE:
		if alt && !ctrl {
			out[0] = Input_Event{kind = .Alt_Mod, rune = '\x7f', alt = true, shift = shift}
			return true
		}
		out[0] = Input_Event{kind = .Backspace, shift = shift, alt = alt, ctrl = ctrl, gui = gui}
		return true
	case sdl3.K_DELETE:
		out[0] = Input_Event{kind = .Delete, shift = shift, alt = alt, ctrl = ctrl, gui = gui}
		return true
	case sdl3.K_TAB, sdl3.K_LEFT_TAB:
		if alt && !ctrl {
			out[0] = Input_Event{kind = .Alt_Mod, rune = '\t', alt = true, shift = shift}
			return true
		}
		out[0] = Input_Event{kind = .Tab, shift = shift, alt = alt, ctrl = ctrl, gui = gui}
		return true
	case sdl3.K_ESCAPE:
		if alt && !ctrl {
			out[0] = Input_Event{kind = .Alt_Mod, rune = '\x1b', alt = true, shift = shift}
			return true
		}
		out[0] = Input_Event{kind = .Escape}
		return true
	case:
		if ctrl {
			r := rune(u32(key))
			if r > 0 && r <= utf8.MAX_RUNE {
				out[0] = Input_Event{kind = .Ctrl, rune = r, ctrl = true, alt = alt, shift = shift, gui = gui}
				return true
			}
			return false
		}
		if alt {
			r := rune(u32(key))
			if r > 0 && r <= utf8.MAX_RUNE {
				out[0] = Input_Event{kind = .Alt_Mod, rune = r, alt = true, shift = shift, gui = gui}
				return true
			}
			return false
		}
		return false
	}
}

// input_grid_for_pixels converts a pixel size to grid dims at the given
// cell size. Non-positive cell dims fall back to INPUT_DEFAULT_CELL_W/H;
// results clamp to at least 1x1 (a zero-pixel window still yields a valid
// grid). Pure function: the unit-testable core of the resize path.
input_grid_for_pixels :: proc(
	pixel_w, pixel_h: int,
	cell_w: int = INPUT_DEFAULT_CELL_W,
	cell_h: int = INPUT_DEFAULT_CELL_H,
) -> (rows, cols: int) {
	cw := cell_w
	if cw <= 0 {
		cw = INPUT_DEFAULT_CELL_W
	}
	ch := cell_h
	if ch <= 0 {
		ch = INPUT_DEFAULT_CELL_H
	}
	cols = pixel_w / cw
	rows = pixel_h / ch
	if cols < 1 {
		cols = 1
	}
	if rows < 1 {
		rows = 1
	}
	return rows, cols
}

// input_pump_events encodes each event and writes the bytes to the pty.
// Events encoding to 0 bytes (unknown kinds) are skipped, not failures.
// Write policy is count-and-continue with no global counters: every event
// is attempted, and ok = false when any encodable event was lost (nil pty
// or pty_write failure).
input_pump_events :: proc(p: ^pty.Pty, evs: []Input_Event) -> (ok: bool) {
	ok = true
	for ev in evs {
		if ev.event_type != .Key {
			continue
		}
		buf: [INPUT_ENCODE_MAX]u8
		m := input_encode(ev, buf[:])
		if m == 0 {
			continue
		}
		if p == nil || !pty.pty_write(p, buf[:m]) {
			ok = false
		}
	}
	return ok
}

// input_pump_resize applies one window resize: pixel size -> grid dims ->
// pty_set_winsize + terminal_resize. Same dims is a no-op (false, true).
// A nil pty or nil terminal returns (false, false) without syscalls. When
// the ioctl fails the grid resize still runs (the grid must track the
// window even when the child is unreachable) and ok reports the ioctl
// outcome.
input_pump_resize :: proc(
	p: ^pty.Pty,
	t: ^termgrid.Terminal,
	pixel_w, pixel_h: int,
	cell_w: int = INPUT_DEFAULT_CELL_W,
	cell_h: int = INPUT_DEFAULT_CELL_H,
) -> (resized: bool, ok: bool) {
	if p == nil || t == nil {
		return false, false
	}
	rows, cols := input_grid_for_pixels(pixel_w, pixel_h, cell_w, cell_h)
	if rows == t.grid.row_count && cols == t.grid.col_count {
		return false, true
	}
	ok = pty.pty_set_winsize(p, rows, cols)
	termgrid.terminal_resize(t, rows, cols)
	return true, ok
}

// input_pump is one input frame: poll SDL input -> encode each event ->
// pty_write; on a pixel-size change -> pty_set_winsize + terminal_resize.
//
// quit mirrors !w.is_open after the drain (a quit arriving mid-batch does
// not drop already-collected input: those events are still encoded and
// written before returning). resized is true when a pixel-size change was
// observed and applied. ok is false when any encodable event was lost or
// the winsize ioctl failed (no global counters; the status returns here).
// A nil window returns (true, false, false) without touching SDL.
input_pump :: proc(
	w: ^win.Window,
	p: ^pty.Pty,
	t: ^termgrid.Terminal,
	cell_w: int = INPUT_DEFAULT_CELL_W,
	cell_h: int = INPUT_DEFAULT_CELL_H,
) -> (quit: bool, resized: bool, ok: bool) {
	if w == nil {
		return true, false, false
	}
	prev_pw := w.pixel_w
	prev_ph := w.pixel_h
	evs: [INPUT_PUMP_MAX_EVENTS]Input_Event
	n := window_poll_input(w, evs[:], INPUT_PUMP_MAX_EVENTS)
	ok = input_pump_events(p, evs[:n])
	quit = !w.is_open
	if (w.pixel_w != prev_pw || w.pixel_h != prev_ph) && t != nil {
		r, wins_ok := input_pump_resize(p, t, int(w.pixel_w), int(w.pixel_h), cell_w, cell_h)
		resized = r
		ok = ok && wins_ok
	}
	return quit, resized, ok
}
