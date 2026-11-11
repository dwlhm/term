package term

// Event extraction & OSC 7502 stream demuxer for `term studio`.

import "core:strconv"
import "core:strings"

Studio_Event_Kind :: enum u8 {
	None = 0,
	Raw_Key,
	Focus,
	Resize,
	Close,
	Child_Input,
	Probe,
}

Studio_Event :: struct {
	kind: Studio_Event_Kind,
	id:   u16,
	cols: int,
	rows: int,
	data: string,
}

@(private = "file")
_hex_val :: proc(c: u8) -> int {
	switch c {
	case '0' ..= '9': return int(c - '0')
	case 'a' ..= 'f': return int(c - 'a' + 10)
	case 'A' ..= 'F': return int(c - 'A' + 10)
	case: return -1
	}
}

studio_decode_hex :: proc(hex: string, alloc := context.temp_allocator) -> string {
	if len(hex) < 2 do return ""
	buf := make([]u8, len(hex) / 2, alloc)
	out := 0
	for i := 0; i + 1 < len(hex); i += 2 {
		h1 := _hex_val(hex[i])
		h2 := _hex_val(hex[i + 1])
		if h1 < 0 || h2 < 0 do break
		buf[out] = u8((h1 << 4) | h2)
		out += 1
	}
	return string(buf[:out])
}

studio_parse_osc_body :: proc(body: string, alloc := context.temp_allocator) -> (ev: Studio_Event, ok: bool) {
	if body == "?1" {
		return Studio_Event{kind = .Probe}, true
	}
	rem := body
	op, has_op := strings.split_iterator(&rem, ";")
	id_s, has_id := strings.split_iterator(&rem, ";")
	if !has_op || !has_id do return {}, false
	id_int, id_ok := strconv.parse_int(id_s)
	if !id_ok do return {}, false
	id := u16(id_int)

	switch op {
	case "6":
		return Studio_Event{kind = .Close, id = id}, true
	case "7":
		hex_s, _ := strings.split_iterator(&rem, ";")
		data := studio_decode_hex(hex_s, alloc)
		return Studio_Event{kind = .Child_Input, id = id, data = data}, true
	case "8":
		return Studio_Event{kind = .Focus, id = id}, true
	case "9":
		c_s, has_c := strings.split_iterator(&rem, ";")
		r_s, has_r := strings.split_iterator(&rem, ";")
		if !has_c || !has_r do return {}, false
		cols, _ := strconv.parse_int(c_s)
		rows, _ := strconv.parse_int(r_s)
		return Studio_Event{kind = .Resize, id = id, cols = cols, rows = rows}, true
	}
	return {}, false
}

studio_demux_chunk :: proc(
	raw: string,
	events: ^[dynamic]Studio_Event,
	alloc := context.temp_allocator,
) {
	pos := 0
	for pos < len(raw) {
		idx := strings.index(raw[pos:], "\x1b]7502;")
		if idx < 0 {
			rem := raw[pos:]
			if len(rem) > 0 {
				append(events, Studio_Event{kind = .Raw_Key, data = rem})
			}
			break
		}
		abs_idx := pos + idx
		if abs_idx > pos {
			append(events, Studio_Event{kind = .Raw_Key, data = raw[pos:abs_idx]})
		}
		body_start := abs_idx + 7
		body_end := -1
		// Check for ST (\x1b\) or BEL (\x07)
		for i := body_start; i < len(raw); i += 1 {
			if raw[i] == 0x07 {
				body_end = i
				pos = i + 1
				break
			}
			if raw[i] == 0x1b && i + 1 < len(raw) && raw[i + 1] == '\\' {
				body_end = i
				pos = i + 2
				break
			}
		}
		if body_end < 0 {
			// Incomplete sequence, emit remainder as raw
			append(events, Studio_Event{kind = .Raw_Key, data = raw[abs_idx:]})
			break
		}
		body := raw[body_start:body_end]
		if ev, ok := studio_parse_osc_body(body, alloc); ok {
			append(events, ev)
		}
	}
}
