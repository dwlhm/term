package harness_helper

import "base:runtime"
import "core:strings"
import "vendor:sdl3"

// clipboard_set_text copies UTF-8 text to the OS clipboard via SDL3.
clipboard_set_text :: proc(text: string, user_data: rawptr = nil) -> bool {
	if len(text) == 0 do return false
	cstr := strings.clone_to_cstring(text, context.temp_allocator)
	return bool(sdl3.SetClipboardText(cstr))
}

// clipboard_get_text retrieves UTF-8 text from the OS clipboard via SDL3.
// Properly releases the SDL-allocated string buffer via sdl3.free to prevent memory leaks.
clipboard_get_text :: proc(allocator: runtime.Allocator = context.temp_allocator, user_data: rawptr = nil) -> (string, bool) {
	if !sdl3.HasClipboardText() do return "", false
	clip_ptr := sdl3.GetClipboardText()
	if clip_ptr == nil do return "", false
	defer sdl3.free(rawptr(clip_ptr))
	return strings.clone(string(cstring(rawptr(clip_ptr))), allocator), true
}

// clipboard_has_text checks if non-empty text exists on the OS clipboard.
clipboard_has_text :: proc(user_data: rawptr = nil) -> bool {
	return bool(sdl3.HasClipboardText())
}
