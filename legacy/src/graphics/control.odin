package graphics

import "core:strings"
import "core:strconv"

KGP_CONTROL_U8_MAX :: u64(0xFF)
KGP_CONTROL_U16_MAX :: u64(0xFFFF)
KGP_CONTROL_U32_MAX :: u64(0xFFFFFFFF)
KGP_CONTROL_I32_MIN :: i64(-2147483648)
KGP_CONTROL_I32_MAX :: i64(2147483647)

_kgp_parse_action :: proc(value: string) -> (Action, bool) {
	switch value {
	case "t": return .Transmit, true
	case "T": return .Transmit_Put, true
	case "p": return .Put, true
	case "q": return .Query, true
	case "d": return .Delete, true
	case "f": return .Frame, true
	case "a": return .Animate, true
	case "c": return .Compose, true
	}
	return .Transmit, false
}

// kgp_parse_control parses comma-separated key=value pairs from a KGP control
// string into a Control struct. Returns false on malformed input.
// Unknown keys are silently ignored.
kgp_parse_control :: proc(control: []u8, out: ^Control) -> bool {
	if out == nil { return false }
	out^ = Control{format = .RGBA32, medium = .Direct}

	s := string(control)
	parts := strings.split(s, ",")
	defer delete(parts)

	// Action-specific meanings are independent of key ordering in the control
	// string. Determine the action before decoding overloaded keys such as c/r.
	for part in parts {
		if len(part) == 0 { continue }
		kv := strings.split(part, "=")
		defer delete(kv)
		if len(kv) != 2 { return false }
		if kv[0] == "a" {
			action, ok := _kgp_parse_action(kv[1])
			if !ok { return false }
			out.action = action
		}
	}

	for part in parts {
		if len(part) == 0 { continue }
		kv := strings.split(part, "=")
		defer delete(kv)
		if len(kv) != 2 { return false }
		key := kv[0]
		val := kv[1]

		switch key {
		case "a":
			continue
		case "f":
			switch val {
			case "24": out.format = .RGB24
			case "32": out.format = .RGBA32
			case "100": out.format = .PNG
			case: return false
			}
		case "t":
			switch val {
			case "d": out.medium = .Direct
			case "f": out.medium = .File
			case "t": out.medium = .Temp_File
			case "s": out.medium = .Shared_Memory
			case: return false
			}
		case "o":
			if len(val) == 1 && val[0] == 'z' {
				out.compression = 'z'
			} else if len(val) == 0 {
				out.compression = 0
			} else {
				return false
			}
		case "i":
			v64, ok := strconv.parse_u64(val)
			if !ok || v64 > KGP_CONTROL_U32_MAX { return false }
			out.id = u32(v64)
		case "I":
			v64, ok := strconv.parse_u64(val)
			if !ok || v64 > KGP_CONTROL_U32_MAX { return false }
			out.number = u32(v64)
		case "p":
			v64, ok := strconv.parse_u64(val)
			if !ok || v64 > KGP_CONTROL_U32_MAX { return false }
			out.placement_id = u32(v64)
		case "q":
			v64, ok := strconv.parse_u64(val)
			if !ok || v64 > KGP_CONTROL_U8_MAX { return false }
			out.quiet = u8(v64)
		case "s":
			v64, ok := strconv.parse_u64(val)
			if !ok || v64 > KGP_CONTROL_U32_MAX { return false }
			if out.action == .Animate {
				out.animation_state = u32(v64)
			} else {
				out.src_w = u32(v64)
			}
		case "v":
			v64, ok := strconv.parse_u64(val)
			if !ok || v64 > KGP_CONTROL_U32_MAX { return false }
			if out.action == .Animate {
				out.animation_loops = u32(v64)
			} else {
				out.src_h = u32(v64)
			}
		case "S":
			v64, ok := strconv.parse_u64(val)
			if !ok || v64 > KGP_CONTROL_U32_MAX { return false }
			out.file_size = u32(v64)
		case "O":
			v64, ok := strconv.parse_u64(val)
			if !ok || v64 > KGP_CONTROL_U32_MAX { return false }
			out.file_offset = u32(v64)
		case "c":
			v64, ok := strconv.parse_u64(val)
			if !ok || v64 > KGP_CONTROL_U32_MAX { return false }
			#partial switch out.action {
			case .Frame: out.frame_background = u32(v64)
			case .Compose: out.compose_destination = u32(v64)
			case .Animate: out.animate_current = u32(v64)
			case: 
				if v64 > KGP_CONTROL_U16_MAX { return false }
				out.cols = u16(v64)
			}
		case "r":
			v64, ok := strconv.parse_u64(val)
			if !ok || v64 > KGP_CONTROL_U32_MAX { return false }
			#partial switch out.action {
			case .Frame: out.frame_edit = u32(v64)
			case .Compose: out.compose_source = u32(v64)
			case .Animate: out.animate_frame = u32(v64)
			case:
				if v64 > KGP_CONTROL_U16_MAX { return false }
				out.rows = u16(v64)
			}
		case "X":
			v64, ok := strconv.parse_u64(val)
			if !ok || v64 > KGP_CONTROL_U32_MAX { return false }
			if out.action == .Frame {
				if v64 > KGP_CONTROL_U8_MAX { return false }
				out.compose_mode = u8(v64)
			} else if out.action == .Compose {
				out.src_x = u32(v64)
			} else {
				out.cell_x = u32(v64)
			}
		case "Y":
			v64, ok := strconv.parse_u64(val)
			if !ok || v64 > KGP_CONTROL_U32_MAX { return false }
			if out.action == .Frame {
				out.background_color = u32(v64)
				out.background_color_set = true
			} else if out.action == .Compose {
				out.src_y = u32(v64)
			} else {
				out.cell_y = u32(v64)
			}
		case "z":
			if out.action == .Frame || out.action == .Animate {
				v64, ok := strconv.parse_i64(val)
				if !ok || v64 < KGP_CONTROL_I32_MIN || v64 > KGP_CONTROL_I32_MAX { return false }
				out.frame_gap = i32(v64)
				out.frame_gap_set = true
			} else {
				v64, ok := strconv.parse_i64(val)
				if !ok || v64 < KGP_CONTROL_I32_MIN || v64 > KGP_CONTROL_I32_MAX { return false }
				out.z = i32(v64)
			}
		case "x":
			v64, ok := strconv.parse_u64(val)
			if !ok || v64 > KGP_CONTROL_U32_MAX { return false }
			if out.action == .Compose {
				out.cell_x = u32(v64)
			} else {
				out.src_x = u32(v64)
			}
		case "y":
			v64, ok := strconv.parse_u64(val)
			if !ok || v64 > KGP_CONTROL_U32_MAX { return false }
			if out.action == .Compose {
				out.cell_y = u32(v64)
			} else {
				out.src_y = u32(v64)
			}
		case "w":
			v64, ok := strconv.parse_u64(val)
			if !ok || v64 > KGP_CONTROL_U32_MAX { return false }
			out.src_rect_w = u32(v64)
		case "h":
			v64, ok := strconv.parse_u64(val)
			if !ok || v64 > KGP_CONTROL_U32_MAX { return false }
			out.src_rect_h = u32(v64)
		case "P":
			v64, ok := strconv.parse_u64(val)
			if !ok || v64 > KGP_CONTROL_U32_MAX { return false }
			out.parent_id = u32(v64)
		case "Q":
			v64, ok := strconv.parse_u64(val)
			if !ok || v64 > KGP_CONTROL_U32_MAX { return false }
			out.parent_pl = u32(v64)
		case "H":
			v64, ok := strconv.parse_i64(val)
			if !ok || v64 < KGP_CONTROL_I32_MIN || v64 > KGP_CONTROL_I32_MAX { return false }
			out.rel_h = i32(v64)
		case "V":
			v64, ok := strconv.parse_i64(val)
			if !ok || v64 < KGP_CONTROL_I32_MIN || v64 > KGP_CONTROL_I32_MAX { return false }
			out.rel_v = i32(v64)
		case "C":
			v64, ok := strconv.parse_u64(val)
			if !ok || v64 > KGP_CONTROL_U8_MAX { return false }
			if out.action == .Compose {
				out.compose_mode = u8(v64)
			} else {
				out.cursor_pol = u8(v64)
			}
		case "U":
			v64, ok := strconv.parse_u64(val)
			if !ok || v64 > KGP_CONTROL_U8_MAX { return false }
			out.unicode_ph = u8(v64)
		case "N":
			v64, ok := strconv.parse_u64(val)
			if !ok || v64 > KGP_CONTROL_U32_MAX { return false }
			out.usage = u32(v64)
		case "m":
			v64, ok := strconv.parse_u64(val)
			if !ok || v64 > KGP_CONTROL_U8_MAX { return false }
			out.more = u8(v64) != 0
		case "d":
			if len(val) == 1 {
				c := val[0]
				switch c {
				case 'a', 'A', 'i', 'I', 'n', 'N', 'c', 'C', 'f', 'F', 'x', 'y', 'z', 'Z', 'w', 'W':
					out.delete_mode = c
				case 0:
					out.delete_mode = 0
				case:
					return false
				}
			} else {
				return false
			}
		case: {}
		}
	}
	return true
}

// kgp_is_continuation returns true iff the control string contains only the 'm'
// key (a subsequent chunk in a multi-chunk transmission).
kgp_is_continuation :: proc(control: []u8) -> bool {
	s := string(control)
	parts := strings.split(s, ",")
	defer delete(parts)

	has_m := false
	for part in parts {
		if len(part) == 0 { continue }
		kv := strings.split(part, "=")
		defer delete(kv)
		if len(kv) != 2 { return false }
		if kv[0] == "m" {
			has_m = true
		} else {
			return false
		}
	}
	return has_m
}
