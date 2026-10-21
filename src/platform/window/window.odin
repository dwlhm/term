package platform_window

import "core:c"
import "vendor:sdl3"

// Window wraps an SDL3 window handle with dimension metadata.
Window :: struct {
	handle:      ^sdl3.Window,
	width:       i32,
	height:      i32,
	pixel_w:     i32,
	pixel_h:     i32,
	pixel_ratio: f32, // pixel_w / logical_width — DPI scale factor (2.0 on Retina)
	title:       string,
	is_open:     bool,
	_title_buf:  [256]u8,
}

Platform_Menu_Item :: struct {
	title:        string,
	shortcut:     string,
	shift_mod:    bool,
	is_separator: bool,
	enabled:      bool,
	action_tag:   int,
}

// window_init initializes SDL3 and creates a window with high pixel density and transparency.
window_init :: proc(w: ^Window, title: string, width, height: i32) -> bool {
	if !sdl3.Init(sdl3.INIT_VIDEO) {
		return false
	}

	_ = sdl3.EnableScreenSaver()

	platform_disable_press_and_hold()

	title_len := len(title)
	if title_len > 255 {
		title_len = 255
	}
	for i in 0..<title_len {
		w._title_buf[i] = title[i]
	}
	w._title_buf[title_len] = 0

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

	_ = sdl3.StartTextInput(w.handle)

	w.title   = title
	w.width   = width
	w.height  = height
	w.is_open = true

	window_update_pixel_size(w)

	return true
}

// window_destroy destroys the window and shuts down SDL3.
window_destroy :: proc(w: ^Window) {
	if w == nil do return
	if w.handle != nil {
		sdl3.DestroyWindow(w.handle)
		w.handle = nil
	}
	w.is_open = false
	sdl3.Quit()
}

// window_update_pixel_size queries logical and backing pixel dimensions from SDL3.
window_update_pixel_size :: proc(w: ^Window) {
	if w == nil || w.handle == nil {
		return
	}
	pw: c.int
	ph: c.int
	sdl3.GetWindowSizeInPixels(w.handle, &pw, &ph)
	w.pixel_w = i32(pw)
	w.pixel_h = i32(ph)

	lw: c.int
	lh: c.int
	sdl3.GetWindowSize(w.handle, &lw, &lh)
	w.width  = i32(lw)
	w.height = i32(lh)

	// Compute DPI scale factor; default to 1.0 if logical width is zero.
	if lw > 0 {
		w.pixel_ratio = f32(pw) / f32(lw)
	} else {
		w.pixel_ratio = 1.0
	}
}

when ODIN_OS != .Darwin {
	platform_show_context_menu :: proc(sdl_window: ^sdl3.Window, x, y: f32, items: []Platform_Menu_Item) -> int {
		return 0
	}
	platform_disable_press_and_hold :: proc() {}
	platform_setup_unified_titlebar :: proc(sdl_window: ^sdl3.Window) -> bool { return false }
	platform_setup_metal_layer :: proc(sdl_window: ^sdl3.Window, is_opaque: bool = false) -> bool { return false }
	platform_setup_window_vibrancy :: proc(sdl_window: ^sdl3.Window, enabled: bool) -> bool { return false }
	platform_toggle_maximize :: proc(sdl_window: ^sdl3.Window) {
		if sdl_window == nil do return
		flags := sdl3.GetWindowFlags(sdl_window)
		if .MAXIMIZED in flags {
			sdl3.RestoreWindow(sdl_window)
		} else {
			sdl3.MaximizeWindow(sdl_window)
		}
	}
	platform_toggle_fullscreen :: proc(sdl_window: ^sdl3.Window) {
		if sdl_window == nil do return
		flags := sdl3.GetWindowFlags(sdl_window)
		is_fs := .FULLSCREEN in flags
		_ = sdl3.SetWindowFullscreen(sdl_window, !is_fs)
	}
	platform_is_fullscreen :: proc(sdl_window: ^sdl3.Window) -> bool {
		if sdl_window == nil do return false
		flags := sdl3.GetWindowFlags(sdl_window)
		return .FULLSCREEN in flags
	}
}

