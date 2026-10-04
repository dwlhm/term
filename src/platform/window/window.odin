package window

// SDL3 window management for the terminal emulator.
// Creates and manages an SDL3 window with a WGPU-compatible surface.

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strings"
import "vendor:sdl3"

// DEFAULT_WIDTH is the default window width in pixels.
DEFAULT_WIDTH :: 800

// DEFAULT_HEIGHT is the default window height in pixels.
DEFAULT_HEIGHT :: 600

// Window wraps an SDL3 window handle with metadata.
Window :: struct {
	handle:  ^sdl3.Window,
	width:   i32,
	height:  i32,
	pixel_w: i32,
	pixel_h: i32,
	title:   string,
	is_open: bool,
	paste_shadow_text: string, // owned clipboard text awaiting SDL's TEXT_INPUT shadow
	resize_cursors: [2]^sdl3.Cursor,
	resize_cursor_attempted: [2]bool,
	cursor_error_reported: bool,
	_title_buf: [256]u8, // buffer for C string title
}

// window_init initializes SDL3 and creates a window.
// Returns true on success.
window_init :: proc(w: ^Window, title: string, width, height: i32, allow_screensaver: bool = true) -> bool {
	// Initialize SDL3 video subsystem
	if !sdl3.Init(sdl3.INIT_VIDEO) {
		return false
	}

	// Modern terminals allow display sleep/screensaver by default.
	// SDL disables screensaver by default, so we explicitly enable it unless configured otherwise.
	if allow_screensaver {
		_ = sdl3.EnableScreenSaver()
	} else {
		_ = sdl3.DisableScreenSaver()
	}

	// Disable macOS Press and Hold so key repeat is enabled for terminal use
	platform_disable_press_and_hold()

	// Convert title to C string (null-terminated)
	title_len := len(title)
	if title_len > 255 {
		title_len = 255
	}
	for i in 0..<title_len {
		w._title_buf[i] = title[i]
	}
	w._title_buf[title_len] = 0

	// Create window
	w.handle = sdl3.CreateWindow(
		cstring(&w._title_buf[0]),
		c.int(width),
		c.int(height),
		sdl3.WINDOW_HIGH_PIXEL_DENSITY | sdl3.WINDOW_RESIZABLE | sdl3.WINDOW_TRANSPARENT,
	)

	if w.handle == nil {
		sdl3.Quit()
		return false
	}

	platform_setup_unified_titlebar(w.handle)

	// SDL3 delivers TEXT_INPUT only after an explicit opt-in. The input
	// pump (Phase 9) translates TEXTINPUT into Printable runes, so text
	// input starts here. Non-fatal on failure: the window still works, but
	// printable typing will not arrive.
	_ = sdl3.StartTextInput(w.handle)

	w.title   = title
	w.width   = width
	w.height  = height
	w.is_open = true

	// Query actual pixel size (may differ on HiDPI displays)
	window_update_pixel_size(w)

	return true
}

// window_destroy closes the window and shuts down SDL3.
window_destroy :: proc(w: ^Window) {
	if w == nil do return
	if w.handle != nil do _ = window_set_pointer_cursor(w, .Default)
	for &cursor in w.resize_cursors {
		if cursor != nil {
			sdl3.DestroyCursor(cursor)
			cursor = nil
		}
	}
	w.resize_cursor_attempted = {}
	w.cursor_error_reported = false
	if len(w.paste_shadow_text) > 0 {
		delete(w.paste_shadow_text)
		w.paste_shadow_text = ""
	}
	if w.handle != nil {
		window_capture_mouse(w, false)
		sdl3.DestroyWindow(w.handle)
		w.handle = nil
	}
	w.is_open = false
	sdl3.Quit()
}

// Pointer_Cursor is window-owned presentation feedback, independent of terminal input.
Pointer_Cursor :: enum {
	Default,
	Resize_EW,
	Resize_NS,
}

_window_report_cursor_failure :: proc(w: ^Window) {
	if !w.cursor_error_reported {
		fmt.eprintf("window cursor unavailable: %s\n", sdl3.GetError())
		w.cursor_error_reported = true
	}
}

// Main-thread only. The native default is borrowed; resize handles are cached and owned.
window_set_pointer_cursor :: proc(w: ^Window, shape: Pointer_Cursor) -> bool {
	if w == nil || w.handle == nil do return false
	cursor := sdl3.GetDefaultCursor()
	if shape != .Default {
		idx := 0 if shape == .Resize_EW else 1
		if !w.resize_cursor_attempted[idx] {
			w.resize_cursor_attempted[idx] = true
			kind := sdl3.SystemCursor.EW_RESIZE if shape == .Resize_EW else sdl3.SystemCursor.NS_RESIZE
			w.resize_cursors[idx] = sdl3.CreateSystemCursor(kind)
			if w.resize_cursors[idx] == nil do _window_report_cursor_failure(w)
		}
		if w.resize_cursors[idx] != nil do cursor = w.resize_cursors[idx]
	}
	if cursor == nil {
		_window_report_cursor_failure(w)
		return false
	}
	if sdl3.GetCursor() == cursor do return true
	if sdl3.SetCursor(cursor) do return true
	_window_report_cursor_failure(w)
	fallback := sdl3.GetDefaultCursor()
	if fallback != nil && sdl3.GetCursor() != fallback do _ = sdl3.SetCursor(fallback)
	return false
}

// window_capture_mouse enables or releases SDL's global mouse capture.
// Invalid windows return false without touching SDL.
window_capture_mouse :: proc(w: ^Window, enabled: bool) -> bool {
	if w == nil || w.handle == nil {
		return false
	}
	return sdl3.CaptureMouse(enabled)
}

// window_set_title updates the SDL window title (e.g. from OSC 0/1/2).
// The title is truncated at 255 bytes into the window's title buffer.
// Invalid windows return false without touching SDL.
window_set_title :: proc(w: ^Window, title: string) -> bool {
	if w == nil || w.handle == nil {
		return false
	}
	title_len := len(title)
	if title_len > 255 {
		title_len = 255
	}
	for i in 0..<title_len {
		w._title_buf[i] = title[i]
	}
	w._title_buf[title_len] = 0
	w.title = string(w._title_buf[:title_len])
	// An empty title would hand SDL an empty C string; some SDL versions turn
	// that into a nil NSString and -[NSWindow setTitle:nil] raises. Skip it.
	if title_len == 0 {
		return true
	}
	return sdl3.SetWindowTitle(w.handle, cstring(&w._title_buf[0]))
}

// window_set_clipboard_text copies text to SDL's system clipboard.
// Invalid windows return false; the temporary C string is released locally.
window_set_clipboard_text :: proc(w: ^Window, text: string) -> bool {
	if w == nil || w.handle == nil {
		return false
	}
	c_text := strings.clone_to_cstring(text)
	defer delete(c_text)
	return sdl3.SetClipboardText(c_text)
}

// window_get_clipboard_text returns a caller-owned copy of SDL clipboard
// text. Invalid windows or an empty/unavailable clipboard return an empty
// string. SDL's returned buffer is released before this procedure returns.
window_get_clipboard_text :: proc(w: ^Window) -> string {
	if w == nil || w.handle == nil {
		return ""
	}
	raw := sdl3.GetClipboardText()
	if raw == nil {
		return ""
	}
	text := string(cast(cstring)raw)
	result := strings.clone(text)
	sdl3.free(rawptr(raw))
	return result
}

// window_poll_events processes pending SDL events.
// Returns false if a quit event was received.
window_poll_events :: proc(w: ^Window) -> bool {
	event: sdl3.Event
	for sdl3.PollEvent(&event) {
		if event.type == .QUIT {
			w.is_open = false
			return false
		}
		if event.type == .WINDOW_CLOSE_REQUESTED {
			w.is_open = false
			return false
		}
		if event.type == .WINDOW_RESIZED || event.type == .WINDOW_PIXEL_SIZE_CHANGED {
			window_update_pixel_size(w)
		}
	}
	return w.is_open
}

// window_update_pixel_size queries the current pixel dimensions of the window.
window_update_pixel_size :: proc(w: ^Window) {
	if w.handle == nil {
		return
	}
	pw: c.int
	ph: c.int
	sdl3.GetWindowSizeInPixels(w.handle, &pw, &ph)
	w.pixel_w = i32(pw)
	w.pixel_h = i32(ph)

	// Also update logical size
	lw: c.int
	lh: c.int
	sdl3.GetWindowSize(w.handle, &lw, &lh)
	w.width  = i32(lw)
	w.height = i32(lh)
}

// window_get_sdl_handle returns the raw SDL3 window pointer (for WGPU surface creation).
window_get_sdl_handle :: proc(w: ^Window) -> ^sdl3.Window {
	return w.handle
}

// window_get_size returns the current logical window size via SDL_GetWindowSize.
// Nil window or nil handle returns (0,0) without touching SDL.
window_get_size :: proc(w: ^Window) -> (width: i32, height: i32) {
	if w == nil || w.handle == nil {
		return 0, 0
	}
	lw: c.int
	lh: c.int
	sdl3.GetWindowSize(w.handle, &lw, &lh)
	return i32(lw), i32(lh)
}

// window_set_size sets the window size in pixels via SDL3 and synchronizes with the OS.
window_set_size :: proc(w: ^Window, width, height: i32) -> bool {
	if w == nil || w.handle == nil {
		return false
	}
	res := bool(sdl3.SetWindowSize(w.handle, width, height))
	sdl3.SyncWindow(w.handle)
	window_update_pixel_size(w)
	return res
}

// window_set_size_no_sync sets the window logical size without blocking on
// SyncWindow; the size change is delivered through SDL resize events (drag path).
window_set_size_no_sync :: proc(w: ^Window, width, height: i32) -> bool {
	if w == nil || w.handle == nil { return false }
	res := bool(sdl3.SetWindowSize(w.handle, width, height))
	window_update_pixel_size(w)
	return res
}

// Drag_Region describes a logical, top-left-origin rectangle the OS may use to
// move the window when the pointer drags inside it. The caller owns the value,
// and it must outlive the window it is installed on (App owns it).
Drag_Region :: struct {
	x, y, w, h: f32,
	enabled:    bool,
	pending_double_click: bool,
	last_native_event: i64, // NSEvent eventNumber + 1; zero means no event yet.
}

// _window_hit_test is the SDL hit-test callback. It reports a draggable region
// when the point lies inside an enabled drag rect, otherwise a normal region.
// Native double-clicks are queued on the caller-owned region for the event loop;
// resizing never runs reentrantly inside SDL's native mouse dispatch.
_window_hit_test :: proc "c" (win: ^sdl3.Window, area: ^sdl3.Point, data: rawptr) -> sdl3.HitTestResult {
	if data == nil || area == nil do return .NORMAL
	context = runtime.default_context()
	region := cast(^Drag_Region)data
	if !region.enabled do return .NORMAL
	px := f32(area[0])
	py := f32(area[1])
	if px >= region.x && px < region.x + region.w && py >= region.y && py < region.y + region.h {
		if platform_titlebar_double_click(win, &region.last_native_event) {
			region.pending_double_click = true
		}
		return .DRAGGABLE
	}
	return .NORMAL
}

// window_take_titlebar_double_click consumes one queued native titlebar action.
window_take_titlebar_double_click :: proc(region: ^Drag_Region) -> bool {
	if region == nil do return false
	pending := region.pending_double_click
	region.pending_double_click = false
	return pending
}

// window_zoom performs the platform's window zoom/restore action outside event callbacks.
window_zoom :: proc(w: ^Window) -> bool {
	if w == nil || w.handle == nil do return false
	when ODIN_OS == .Darwin {
		return platform_zoom_window(w.handle)
	} else {
		flags := sdl3.GetWindowFlags(w.handle)
		if .FULLSCREEN in flags do return false
		if .MAXIMIZED in flags do return bool(sdl3.RestoreWindow(w.handle))
		return bool(sdl3.MaximizeWindow(w.handle))
	}
}

// window_set_drag_region installs a live OS hit-test region so dragging the
// trailing toolbar area moves the whole window. Nil window/handle/region return
// false without touching SDL. The region must stay valid while installed.
window_set_drag_region :: proc(w: ^Window, region: ^Drag_Region) -> bool {
	if w == nil || w.handle == nil || region == nil do return false
	return sdl3.SetWindowHitTest(w.handle, _window_hit_test, rawptr(region))
}

// window_clear_drag_region removes the OS hit-test region so every area is
// normal again. Nil window/handle return false without touching SDL.
window_clear_drag_region :: proc(w: ^Window) -> bool {
	if w == nil || w.handle == nil do return false
	return sdl3.SetWindowHitTest(w.handle, nil, nil)
}

// window_restore_unified_titlebar restores macOS full-size content view titlebar styling
// if it was reset after fullscreen transitions. Safe no-op on non-Darwin platforms.
window_restore_unified_titlebar :: proc(w: ^Window) -> bool {
	if w == nil || w.handle == nil do return false
	return platform_restore_unified_titlebar(w.handle)
}

VIBRANCY_NORMALIZED_MIN: f32 : 0.0
VIBRANCY_NORMALIZED_MAX: f32 : 1.0

// window_vibrancy_is_opaque reports the exact normalized fast path shared by
// the native window and its rendering layer.
window_vibrancy_is_opaque :: proc(opacity: f32, blur: f32) -> bool {
	normalized_opacity := clamp(opacity, VIBRANCY_NORMALIZED_MIN, VIBRANCY_NORMALIZED_MAX)
	normalized_blur := clamp(blur, VIBRANCY_NORMALIZED_MIN, VIBRANCY_NORMALIZED_MAX)
	return normalized_opacity == VIBRANCY_NORMALIZED_MAX && normalized_blur == VIBRANCY_NORMALIZED_MIN
}

// window_configure_vibrancy configures window translucency and platform-specific vibrancy blur.
// On macOS, sets window opacity and attaches or detaches NSVisualEffectView.
window_configure_vibrancy :: proc(w: ^Window, opacity: f32, blur: f32) -> bool {
	if w == nil || w.handle == nil do return false
	return platform_configure_window_vibrancy(w.handle, opacity, blur)
}
