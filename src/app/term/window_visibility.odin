package term

// A window nobody can see (minimized, fully covered, screen locked) gets no
// frames: presenting does not wait for vsync then, so rendering would spin
// the loop, parse every byte at full speed and grow GPU pools by the GB.
// app_run waits one HIDDEN_FRAME_MS instead of rendering; the event watch
// paints in full when the window is exposed again. A frame whose surface
// gives no target (occluded before, or without, a window event) waits the
// same interval, so a missing event cannot spin the loop either.

import "vendor:sdl3"

HIDDEN_FRAME_MS :: 16 // one ~60 Hz frame: what present's vsync wait paces for a visible window

// app_window_visible_after is the visibility a window event leaves behind;
// every other event keeps `visible`.
app_window_visible_after :: proc(visible: bool, t: sdl3.EventType) -> bool {
	#partial switch t {
	case .WINDOW_OCCLUDED, .WINDOW_HIDDEN, .WINDOW_MINIMIZED:
		return false
	case .WINDOW_EXPOSED, .WINDOW_SHOWN, .WINDOW_RESTORED:
		return true
	}
	return visible
}
