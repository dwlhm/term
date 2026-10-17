package terminal_extension

import "core:strings"

Osc_Color_Responder :: #type proc(term: rawptr, response: []u8) -> bool
Osc_Color_Callback  :: #type proc(user_data: rawptr, r, g, b: f32)
Osc_Reset_Callback  :: #type proc(user_data: rawptr)

Osc_Color_Config :: struct {
	responder:    Osc_Color_Responder,
	on_bg_change: Osc_Color_Callback,
	on_bg_reset:  Osc_Reset_Callback,
	user_data:    rawptr,
}

// Default colors: foreground light grey/white, background dark slate #14161b
DEFAULT_OSC_FG_RESP :: "\x1b]10;rgb:c6c6/d0d0/f0f0\x1b\\"
DEFAULT_OSC_BG_RESP :: "\x1b]11;rgb:1414/1616/1b1b\x1b\\"

_parse_hex_digit :: proc(c: u8) -> (int, bool) {
	switch c {
	case '0'..='9': return int(c - '0'), true
	case 'a'..='f': return int(c - 'a' + 10), true
	case 'A'..='F': return int(c - 'A' + 10), true
	}
	return 0, false
}

_parse_hex_byte :: proc(s: string) -> (u8, bool) {
	if len(s) < 2 do return 0, false
	hi, ok1 := _parse_hex_digit(s[0])
	lo, ok2 := _parse_hex_digit(s[1])
	if !ok1 || !ok2 do return 0, false
	return u8((hi << 4) | lo), true
}

_parse_color_payload :: proc(payload: string) -> (r, g, b: f32, ok: bool) {
	p := strings.trim_space(payload)
	if len(p) == 0 do return 0, 0, 0, false

	// #RRGGBB
	if p[0] == '#' && len(p) >= 7 {
		r_byte, ok1 := _parse_hex_byte(p[1:3])
		g_byte, ok2 := _parse_hex_byte(p[3:5])
		b_byte, ok3 := _parse_hex_byte(p[5:7])
		if ok1 && ok2 && ok3 {
			return f32(r_byte) / 255.0, f32(g_byte) / 255.0, f32(b_byte) / 255.0, true
		}
	}

	// rgb:RR/GG/BB or rgb:RRRR/GGGG/BBBB
	if strings.has_prefix(p, "rgb:") {
		parts := strings.split(p[4:], "/", context.temp_allocator)
		if len(parts) >= 3 {
			r_byte, ok1 := _parse_hex_byte(parts[0])
			g_byte, ok2 := _parse_hex_byte(parts[1])
			b_byte, ok3 := _parse_hex_byte(parts[2])
			if ok1 && ok2 && ok3 {
				return f32(r_byte) / 255.0, f32(g_byte) / 255.0, f32(b_byte) / 255.0, true
			}
		}
	}

	return 0, 0, 0, false
}

// osc_color_handler handles OSC 10 (foreground color query), OSC 11 (background color query/set), and OSC 111 (reset).
osc_color_handler :: proc(user_data: rawptr, osc_id: int, payload: string, term: rawptr) -> bool {
	cfg := (^Osc_Color_Config)(user_data)
	if cfg == nil do return false

	if osc_id == 111 {
		if cfg.on_bg_reset != nil {
			cfg.on_bg_reset(cfg.user_data)
			return true
		}
		return false
	}

	// Applications query color using payload "?"
	if strings.has_prefix(payload, "?") {
		if cfg.responder == nil do return false
		if osc_id == 10 {
			return cfg.responder(term, transmute([]u8)string(DEFAULT_OSC_FG_RESP))
		} else if osc_id == 11 {
			return cfg.responder(term, transmute([]u8)string(DEFAULT_OSC_BG_RESP))
		}
		return false
	}

	// Applications set background color via OSC 11
	if osc_id == 11 && cfg.on_bg_change != nil {
		if r, g, b, ok := _parse_color_payload(payload); ok {
			cfg.on_bg_change(cfg.user_data, r, g, b)
			return true
		}
	}

	return false
}
