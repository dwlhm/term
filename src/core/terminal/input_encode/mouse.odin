package input_encode

// Mouse events -> the report a program asked for: tracking mode ?9/?1000/
// ?1002/?1003 decides which events are reported, the format (legacy X10 bytes,
// SGR ?1006, SGR-pixel ?1016) how. Term models no other format (urxvt 1015).

import "core:fmt"
import parser "../parser"

Mouse_Kind :: enum u8 {
	Press,
	Release,
	Motion,
	Wheel_Up,
	Wheel_Down,
}

Mouse_Button :: enum u8 {
	Left   = 0,
	Middle = 1,
	Right  = 2,
	None   = 3, // motion with no button held
}

Mouse_Event :: struct {
	kind:   Mouse_Kind,
	button: Mouse_Button,
	mods:   Mods,   // Shift, Alt and Ctrl are reported; Super is not
	col:    int,    // 1-based cell
	row:    int,
	px:     int,    // 1-based pixel, SGR-pixel only
	py:     int,
}

Mouse_Modes :: struct {
	mode:   parser.Mouse_Tracking_Mode,
	format: parser.Mouse_Format,
}

mouse_modes :: proc(p: ^parser.Parser) -> Mouse_Modes {
	return {p.mouse_mode, p.mouse_format}
}

// mouse_reports: the program's tracking mode wants this event.
mouse_reports :: proc(ev: Mouse_Event, mode: parser.Mouse_Tracking_Mode) -> bool {
	switch mode {
	case .None:         return false
	case .X10:          return ev.kind != .Release && ev.kind != .Motion // presses, wheel included
	case .Normal:       return ev.kind != .Motion
	case .Button_Event: return ev.kind != .Motion || ev.button != .None
	case .Any_Event:    return true
	}
	return false
}

// encode_mouse renders ev, or ok = false when the program does not want it.
encode_mouse :: proc(ev: Mouse_Event, modes: Mouse_Modes) -> (res: Encoded, ok: bool) {
	if !mouse_reports(ev, modes.mode) do return {}, false

	cb: int
	switch ev.kind {
	case .Wheel_Up:   cb = 64
	case .Wheel_Down: cb = 65
	case .Press, .Release, .Motion: cb = int(ev.button)
	}
	if ev.kind == .Motion do cb += 32
	if .Shift in ev.mods do cb += 4
	if .Alt in ev.mods do cb += 8
	if .Ctrl in ev.mods do cb += 16

	final := 'm' if ev.kind == .Release else 'M'
	text: string
	switch modes.format {
	case .Sgr:
		text = fmt.bprintf(res.bytes[:], "\x1b[<%d;%d;%d%c", cb, ev.col, ev.row, final)
	case .Sgr_Pixel:
		text = fmt.bprintf(res.bytes[:], "\x1b[<%d;%d;%d%c", cb, ev.px, ev.py, final)
	case .X10:
		if ev.kind == .Release do cb = 3 + (cb & 28)
		res.bytes[0], res.bytes[1], res.bytes[2] = 0x1b, '[', 'M'
		res.bytes[3] = u8(clamp(cb + 32, 32, 255))
		res.bytes[4] = u8(clamp(ev.col + 32, 33, 255))
		res.bytes[5] = u8(clamp(ev.row + 32, 33, 255))
		res.len = 6
		return res, true
	}
	res.len = len(text)
	return res, true
}
