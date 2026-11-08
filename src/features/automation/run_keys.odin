package feature_automation

// Key names as contracts write them (W3C KeyboardEvent.key with Ctrl+, Alt+,
// Shift+, Super+ modifiers): "Enter", "Ctrl+C", "Shift+Tab", "ArrowUp", "F5",
// "a", "Space". Parsed into the wire's Act_Key (input_encode values).

import "core:strings"
import "core:unicode/utf8"
import ie "../../core/terminal/input_encode"
import proto "../session_proto"

@(private = "file")
_NAMES := [?]struct {
	name: string,
	key:  ie.Key,
}{
	{"enter", .Enter}, {"return", .Enter}, {"tab", .Tab}, {"backspace", .Backspace},
	{"escape", .Escape}, {"esc", .Escape}, {"insert", .Insert}, {"delete", .Delete}, {"del", .Delete},
	{"home", .Home}, {"end", .End}, {"pageup", .Page_Up}, {"pagedown", .Page_Down},
	{"arrowup", .Up}, {"up", .Up}, {"arrowdown", .Down}, {"down", .Down},
	{"arrowleft", .Left}, {"left", .Left}, {"arrowright", .Right}, {"right", .Right},
	{"f1", .F1}, {"f2", .F2}, {"f3", .F3}, {"f4", .F4}, {"f5", .F5}, {"f6", .F6},
	{"f7", .F7}, {"f8", .F8}, {"f9", .F9}, {"f10", .F10}, {"f11", .F11}, {"f12", .F12},
	{"contextmenu", .Context_Menu},
}

// parse_key reads one key name; ok = false names an unknown key.
parse_key :: proc(name: string) -> (k: proto.Act_Key, ok: bool) {
	mods: ie.Mods
	rest := name
	for {
		plus := strings.index_byte(rest, '+')
		if plus <= 0 || plus == len(rest) - 1 do break // "+" alone, or "Ctrl++"
		switch strings.to_lower(rest[:plus], context.temp_allocator) {
		case "ctrl", "control":   mods += {.Ctrl}
		case "alt", "option":     mods += {.Alt}
		case "shift":             mods += {.Shift}
		case "super", "cmd", "meta": mods += {.Super}
		case: return {}, false
		}
		rest = rest[plus + 1:]
	}
	k.mods = transmute(u8)mods
	if utf8.rune_count_in_string(rest) == 1 {
		ch, _ := utf8.decode_rune_in_string(rest)
		if ch < 0x20 || ch > 0x7E do return {}, false
		k.key, k.char = u8(ie.Key.Char), u32(ch)
		return k, true
	}
	lower := strings.to_lower(rest, context.temp_allocator)
	if lower == "space" {
		k.key, k.char = u8(ie.Key.Char), ' '
		return k, true
	}
	for n in _NAMES do if n.name == lower {
		k.key = u8(n.key)
		return k, true
	}
	return {}, false
}
