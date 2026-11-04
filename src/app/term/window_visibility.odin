package term

// A window nobody can see (minimized, fully covered, screen locked) gets no
// frames: presenting does not wait for vsync then, so rendering would spin
// the loop, parse every byte at full speed and grow GPU pools by the GB.
// app_run waits one HIDDEN_FRAME_MS instead of rendering; the event watch
// paints in full when the window is exposed again. A frame whose surface
// gives no target (occluded before, or without, a window event) waits the
// same interval, so a missing event cannot spin the loop either.

import "core:time"
import "vendor:sdl3"
import contract "../../core/render/contract"

HIDDEN_FRAME_MS :: 16 // one ~60 Hz frame: what present's vsync wait paces for a visible window
REVEAL_MAX_FRAMES :: 30 // ≈ 0.5 s of failed acquires before the window is shown regardless

// app_reveal_window shows the window window_init created hidden only once frame 0 is on
// it, so it appears styled and painted instead of passing through SDL's default, the
// titlebar restyle and an empty transparent surface. A hidden window gets no drawable,
// so it is ordered in at opacity 0 (still visible to the compositor) until a frame is
// presented and the GPU has finished it. Acquires that keep failing reveal it anyway;
// the loop retries the frame then.
app_reveal_window :: proc(app: ^Term_App) {
	win := app.window.handle
	_ = sdl3.SetWindowOpacity(win, 0)
	_ = sdl3.ShowWindow(win)
	for _ in 0..<REVEAL_MAX_FRAMES {
		sdl3.PumpEvents()
		app_render_frame(app)
		if !app.last_frame_acquire_failed do break
		time.sleep(HIDDEN_FRAME_MS * time.Millisecond)
	}
	if contract.wait_for_idle != nil do _ = contract.wait_for_idle(app.device)
	_ = sdl3.SetWindowOpacity(win, 1)
}

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
