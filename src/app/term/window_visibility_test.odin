package term

import "core:testing"
import "vendor:sdl3"

@test
test_window_visibility_follows_window_events :: proc(t: ^testing.T) {
	v := true
	for ev in ([]sdl3.EventType{.WINDOW_MINIMIZED, .WINDOW_OCCLUDED}) do v = app_window_visible_after(v, ev)
	testing.expect(t, !v, "minimizing hides the window")
	v = app_window_visible_after(v, .WINDOW_FOCUS_GAINED)
	testing.expect(t, !v, "focus alone does not make it visible")
	for ev in ([]sdl3.EventType{.WINDOW_RESTORED, .WINDOW_EXPOSED}) do v = app_window_visible_after(v, ev)
	testing.expect(t, v, "restoring shows it")
	testing.expect(t, !app_window_visible_after(true, .WINDOW_HIDDEN), "hidden (app hidden, closed to background)")
	testing.expect(t, app_window_visible_after(false, .WINDOW_SHOWN), "shown again (term show)")
	testing.expect(t, !app_window_visible_after(true, .WINDOW_OCCLUDED), "covered or screen locked")
	testing.expect(t, app_window_visible_after(true, .KEY_DOWN), "other events keep the state")
}
