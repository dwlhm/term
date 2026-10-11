package harness_helper

import "vendor:sdl3"

when ODIN_OS != .Darwin {

platform_setup_unified_titlebar :: proc(sdl_window: ^sdl3.Window) -> bool {
	return false
}

platform_disable_press_and_hold :: proc() {}

}
