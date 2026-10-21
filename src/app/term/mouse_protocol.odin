package term

// Terminal Open Mouse & Focus Protocol Encoder (XTerm / SGR 1006 / SGR-Pixel 1016)
// Part of Tier 3 Application Shell (src/app/term/*).

import "core:fmt"
import "vendor:sdl3"

import cursor "../../core/cursor"
import sess_feat "../../features/session"

Mouse_Event_Kind :: enum {
	Press,
	Release,
	Motion,
	Wheel,
}

// mouse_protocol_should_handle returns true if mouse tracking is active on the session
// and the user is NOT holding Shift (universal Shift-bypass convention).
mouse_protocol_should_handle :: proc(sess: ^sess_feat.Terminal_Session, is_shift: bool) -> bool {
	if sess == nil || is_shift do return false
	return sess.term.parser.mouse_mode != .None
}

// mouse_protocol_encode serializes a mouse event into VT sequence based on active mode & format.
mouse_protocol_encode :: proc(
	sess: ^sess_feat.Terminal_Session,
	kind: Mouse_Event_Kind,
	button: u8,
	pixel_x, pixel_y: f32,
	pane_rect: [4]f32,
	cell_w, cell_h: f32,
	pad_x, pad_y: f32,
	wheel_y: f32 = 0.0,
	is_shift: bool = false,
	is_alt: bool = false,
	is_ctrl: bool = false,
) -> (res: string, ok: bool) {
	if sess == nil do return "", false
	p := &sess.term.parser
	if p.mouse_mode == .None do return "", false

	#partial switch p.mouse_mode {
	case .X10:
		if kind != .Press do return "", false
	case .Normal:
		if kind == .Motion do return "", false
	}

	rel_x := max(0.0, pixel_x - pane_rect[0] - pad_x)
	rel_y := max(0.0, pixel_y - pane_rect[1] - pad_y)
	col := clamp(int(rel_x / max(1.0, cell_w)) + 1, 1, sess.term.cols)
	row := clamp(int(rel_y / max(1.0, cell_h)) + 1, 1, sess.term.rows)

	cb := 0
	if kind == .Wheel {
		if wheel_y > 0.0 do cb = 64
		else if wheel_y < 0.0 do cb = 65
		else do return "", false
	} else {
		switch button {
		case sdl3.BUTTON_LEFT:   cb = 0
		case sdl3.BUTTON_MIDDLE: cb = 1
		case sdl3.BUTTON_RIGHT:  cb = 2
		case:                    cb = 3
		}
	}

	if kind == .Motion do cb += 32
	if is_shift do cb += 4
	if is_alt   do cb += 8
	if is_ctrl  do cb += 16

	switch p.mouse_format {
	case .Sgr:
		terminator := 'M' if (kind != .Release) else 'm'
		return fmt.tprintf("\x1b[<%d;%d;%d%c", cb, col, row, terminator), true

	case .Sgr_Pixel:
		terminator := 'M' if (kind != .Release) else 'm'
		px := int(rel_x) + 1
		py := int(rel_y) + 1
		return fmt.tprintf("\x1b[<%d;%d;%d%c", cb, px, py, terminator), true

	case .X10:
		if kind == .Release do cb = 3 + (cb & 28)
		c_byte := u8(clamp(col + 32, 33, 255))
		r_byte := u8(clamp(row + 32, 33, 255))
		cb_byte := u8(clamp(cb + 32, 32, 255))
		return fmt.tprintf("\x1b[M%c%c%c", rune(cb_byte), rune(c_byte), rune(r_byte)), true
	}

	return "", false
}

// mouse_protocol_report_focus emits Focus In (\x1b[I) or Focus Out (\x1b[O) if DECSET 1004 is active.
mouse_protocol_report_focus :: proc(sess: ^sess_feat.Terminal_Session, gained: bool) {
	if sess != nil && sess.term.parser.report_focus {
		sess_feat.session_write_string(sess, "\x1b[I" if gained else "\x1b[O")
	}
}

_cached_sdl_cursors:             [cursor.Mouse_Cursor]^sdl3.Cursor
_active_mouse_cursor:             cursor.Mouse_Cursor = .Default
_active_mouse_cursor_initialized: bool = false

// app_set_mouse_cursor applies a platform-neutral Mouse_Cursor with steady-state zero allocation caching.
app_set_mouse_cursor :: proc(cur: cursor.Mouse_Cursor) {
	if _active_mouse_cursor_initialized && _active_mouse_cursor == cur {
		return
	}

	sdl_sys: sdl3.SystemCursor = .DEFAULT
	switch cur {
	case .Default:     sdl_sys = .DEFAULT
	case .Text:        sdl_sys = .TEXT
	case .Pointer:     sdl_sys = .POINTER
	case .Col_Resize:  sdl_sys = .EW_RESIZE
	case .Row_Resize:  sdl_sys = .NS_RESIZE
	case .Crosshair:   sdl_sys = .CROSSHAIR
	case .Move:        sdl_sys = .MOVE
	case .Not_Allowed: sdl_sys = .NOT_ALLOWED
	case .Wait:        sdl_sys = .WAIT
	}

	c := _cached_sdl_cursors[cur]
	if c == nil {
		c = sdl3.CreateSystemCursor(sdl_sys)
		_cached_sdl_cursors[cur] = c
	}

	if c != nil {
		_ = sdl3.SetCursor(c)
	}

	_active_mouse_cursor = cur
	_active_mouse_cursor_initialized = true
}

// app_cleanup_mouse_cursors destroys all allocated system cursor handles during teardown.
app_cleanup_mouse_cursors :: proc() {
	for &c in _cached_sdl_cursors {
		if c != nil {
			sdl3.DestroyCursor(c)
			c = nil
		}
	}
	_active_mouse_cursor_initialized = false
}

// mouse_protocol_update_system_cursor maps OSC 22 cursor shape to neutral Mouse_Cursor.
mouse_protocol_update_system_cursor :: proc(shape: string) {
	cur: cursor.Mouse_Cursor = .Default
	switch shape {
	case "default":                                         cur = .Default
	case "pointer":                                         cur = .Pointer
	case "crosshair":                                       cur = .Crosshair
	case "col-resize", "ew-resize", "e-resize", "w-resize": cur = .Col_Resize
	case "row-resize", "ns-resize", "n-resize", "s-resize": cur = .Row_Resize
	case "move":                                            cur = .Move
	case "not-allowed":                                     cur = .Not_Allowed
	case "wait":                                            cur = .Wait
	case "text", "ibeam":                                   cur = .Text
	case:                                                   cur = .Default
	}
	app_set_mouse_cursor(cur)
}
