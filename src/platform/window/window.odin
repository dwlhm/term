package window

// SDL3 window management for the terminal emulator.
// Creates and manages an SDL3 window with a WGPU-compatible surface.

import "core:c"
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
	_title_buf: [256]u8, // buffer for C string title
}

// window_init initializes SDL3 and creates a window.
// Returns true on success.
window_init :: proc(w: ^Window, title: string, width, height: i32) -> bool {
	// Initialize SDL3 video subsystem
	if !sdl3.Init(sdl3.INIT_VIDEO) {
		return false
	}

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
		sdl3.WINDOW_HIGH_PIXEL_DENSITY | sdl3.WINDOW_RESIZABLE,
	)

	if w.handle == nil {
		sdl3.Quit()
		return false
	}

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
	if w.handle != nil {
		window_capture_mouse(w, false)
		sdl3.DestroyWindow(w.handle)
		w.handle = nil
	}
	w.is_open = false
	sdl3.Quit()
}

// window_capture_mouse enables or releases SDL's global mouse capture.
// Invalid windows return false without touching SDL.
window_capture_mouse :: proc(w: ^Window, enabled: bool) -> bool {
	if w == nil || w.handle == nil {
		return false
	}
	return sdl3.CaptureMouse(enabled)
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
