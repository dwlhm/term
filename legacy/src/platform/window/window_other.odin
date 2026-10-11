package window

import "vendor:sdl3"

when ODIN_OS != .Darwin {

platform_titlebar_double_click :: proc(handle: ^sdl3.Window, last_event: ^i64) -> bool {
	return false
}

platform_zoom_window :: proc(handle: ^sdl3.Window) -> bool {
	return false
}

platform_autorelease_pool_push :: proc() -> rawptr {
	return nil
}

platform_autorelease_pool_pop :: proc(pool: rawptr) {}

platform_setup_unified_titlebar :: proc(sdl_window: ^sdl3.Window) -> bool {
	return false
}

platform_restore_unified_titlebar :: proc(sdl_window: ^sdl3.Window) -> bool {
	return false
}

platform_setup_metal_layer :: proc(sdl_window: ^sdl3.Window) -> bool {
	return false
}

platform_configure_window_vibrancy :: proc(handle: ^sdl3.Window, opacity: f32, blur: f32) -> bool {
	return false
}

platform_disable_press_and_hold :: proc() {}

}
