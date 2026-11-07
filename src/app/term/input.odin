package term

// SDL keyboard events -> input_encode.Key_Event: the window's half of key
// encoding. The bytes come from core/terminal/input_encode, which the session
// core uses for automation keys too.

import "vendor:sdl3"
import ie "../../core/terminal/input_encode"

@(private = "file")
_SDL_KEYS := [?]struct {
	sdl: sdl3.Keycode,
	key: ie.Key,
}{
	{sdl3.K_RETURN, .Enter}, {sdl3.K_KP_ENTER, .Enter}, {sdl3.K_TAB, .Tab},
	{sdl3.K_BACKSPACE, .Backspace}, {sdl3.K_ESCAPE, .Escape},
	{sdl3.K_INSERT, .Insert}, {sdl3.K_DELETE, .Delete}, {sdl3.K_HOME, .Home}, {sdl3.K_END, .End},
	{sdl3.K_PAGEUP, .Page_Up}, {sdl3.K_PAGEDOWN, .Page_Down},
	{sdl3.K_UP, .Up}, {sdl3.K_DOWN, .Down}, {sdl3.K_LEFT, .Left}, {sdl3.K_RIGHT, .Right},
	{sdl3.K_F1, .F1}, {sdl3.K_F2, .F2}, {sdl3.K_F3, .F3}, {sdl3.K_F4, .F4},
	{sdl3.K_F5, .F5}, {sdl3.K_F6, .F6}, {sdl3.K_F7, .F7}, {sdl3.K_F8, .F8},
	{sdl3.K_F9, .F9}, {sdl3.K_F10, .F10}, {sdl3.K_F11, .F11}, {sdl3.K_F12, .F12},
	{sdl3.K_CAPSLOCK, .Caps_Lock}, {sdl3.K_SCROLLLOCK, .Scroll_Lock},
	{sdl3.K_NUMLOCKCLEAR, .Num_Lock}, {sdl3.K_PRINTSCREEN, .Print_Screen},
	{sdl3.K_PAUSE, .Pause}, {sdl3.K_APPLICATION, .Context_Menu},
}

// sdl_key_event maps an SDL key; ok = false for keys term does not encode
// (keypad digits, media keys, …).
sdl_key_event :: proc(key: sdl3.Keycode, mod: sdl3.Keymod, kind: ie.Key_Event_Kind) -> (ev: ie.Key_Event, ok: bool) {
	ev.kind = kind
	ev.mods = sdl_mods(mod)
	// Character keycodes are their unshifted ASCII value (letters lowercase).
	if key >= 0x20 && key <= 0x7E {
		ev.key, ev.char = .Char, rune(key)
		return ev, true
	}
	for entry in _SDL_KEYS {
		if entry.sdl == key {
			ev.key = entry.key
			return ev, true
		}
	}
	return {}, false
}

sdl_mods :: proc(mod: sdl3.Keymod) -> (mods: ie.Mods) {
	if mod & sdl3.KMOD_SHIFT != sdl3.KMOD_NONE do mods += {.Shift}
	if mod & sdl3.KMOD_ALT != sdl3.KMOD_NONE do mods += {.Alt}
	if mod & sdl3.KMOD_CTRL != sdl3.KMOD_NONE do mods += {.Ctrl}
	if mod & sdl3.KMOD_GUI != sdl3.KMOD_NONE do mods += {.Super}
	return mods
}
