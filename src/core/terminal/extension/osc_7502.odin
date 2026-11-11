package terminal_extension

// OSC 7502 — Term Surface & Layer Protocol.
// Allows a single CLI/TUI process inside one PTY to multiplex its viewport into
// isolated VT surfaces (splits and floating popups) backed by the GPU compositor.

import "core:strconv"
import "core:strings"

OSC_SURFACE_LAYER :: 7502

Surface_Op :: enum u8 {
	Reset        = 0,
	Target       = 1,
	Split        = 2,
	Popup        = 3,
	Focus        = 4,
	Visibility   = 5,
	Close        = 6,
	Event_Input  = 7,
	Event_Focus  = 8,
	Event_Resize = 9,
}

Surface_Split_Dir :: enum u8 {
	Right = 0,
	Down  = 1,
	Left  = 2,
	Up    = 3,
}

Surface_Anchor :: enum u8 {
	Center   = 0,
	Absolute = 1,
	Cursor   = 2,
}

Surface_Chrome :: enum u8 {
	None  = 0,
	Box   = 1,
	Modal = 2,
}

MAX_SURFACE_TITLE :: 128

Osc_7502_Command :: struct {
	is_probe:  bool,
	op:        Surface_Op,
	id:        u16,
	parent:    u16,
	split_dir: Surface_Split_Dir,
	ratio:     int,
	w:         int,
	h:         int,
	anchor:    Surface_Anchor,
	x:         int,
	y:         int,
	z:         int,
	chrome:    Surface_Chrome,
	focus:     bool,
	visible:   bool,
	title_buf: [MAX_SURFACE_TITLE]u8,
	title_len: int,
}

// _next_semi_field splits `rest^` at the next `;` without allocating.
@(private = "file")
_next_semi_field :: proc(rest: ^string) -> (tok: string, ok: bool) {
	s := rest^
	if len(s) == 0 do return "", false
	idx := strings.index_byte(s, ';')
	if idx < 0 {
		rest^ = ""
		return s, true
	}
	tok = s[:idx]
	rest^ = s[idx + 1:]
	return tok, true
}

@(private = "file")
_parse_opt_int :: proc(rest: ^string, def_val: int) -> int {
	tok, ok := _next_semi_field(rest)
	if !ok || len(tok) == 0 do return def_val
	v, v_ok := strconv.parse_int(tok)
	return v if v_ok else def_val
}

@(private = "file")
_parse_req_u16 :: proc(rest: ^string, allow_zero: bool) -> (val: u16, ok: bool) {
	tok, t_ok := _next_semi_field(rest)
	if !t_ok || len(tok) == 0 do return 0, false
	v, v_ok := strconv.parse_int(tok)
	if !v_ok || v < 0 || v > 65535 do return 0, false
	if !allow_zero && v == 0 do return 0, false
	return u16(v), true
}

@(private = "file")
_parse_split_params :: proc(cmd: ^Osc_7502_Command, rest: ^string) -> bool {
	id, ok := _parse_req_u16(rest, false)
	if !ok do return false
	cmd.id = id
	parent := _parse_opt_int(rest, 0)
	if parent < 0 || parent > 65535 || u16(parent) == id do return false
	cmd.parent = u16(parent)
	dir := clamp(_parse_opt_int(rest, 0), 0, 3)
	cmd.split_dir = Surface_Split_Dir(dir)
	cmd.ratio = clamp(_parse_opt_int(rest, 50), 10, 90)
	cmd.focus = _parse_opt_int(rest, 1) != 0
	return true
}

@(private = "file")
_parse_popup_params :: proc(cmd: ^Osc_7502_Command, rest: ^string) -> bool {
	id, ok := _parse_req_u16(rest, false)
	if !ok do return false
	cmd.id = id
	cmd.w = _parse_opt_int(rest, 0)
	cmd.h = _parse_opt_int(rest, 0)
	cmd.anchor = Surface_Anchor(clamp(_parse_opt_int(rest, 0), 0, 2))
	cmd.x = _parse_opt_int(rest, 1)
	cmd.y = _parse_opt_int(rest, 1)
	cmd.z = clamp(_parse_opt_int(rest, 100), -1000, 1000)
	cmd.chrome = Surface_Chrome(clamp(_parse_opt_int(rest, 1), 0, 2))
	cmd.focus = _parse_opt_int(rest, 1) != 0
	if b64, has_t := _next_semi_field(rest); has_t && len(b64) > 0 {
		cmd.title_len = _decode_b64_into(b64, cmd.title_buf[:])
	}
	return true
}

// _decode_b64_into decodes a standard Base64 string into `dst` with 0 heap allocations.
@(private = "file")
_decode_b64_into :: proc(src: string, dst: []u8) -> int {
	out := 0
	acc := u32(0)
	bits := u32(0)
	for i in 0 ..< len(src) {
		ch := src[i]
		if ch == '=' do break
		v: u32
		switch ch {
		case 'A' ..= 'Z': v = u32(ch - 'A')
		case 'a' ..= 'z': v = u32(ch - 'a') + 26
		case '0' ..= '9': v = u32(ch - '0') + 52
		case '+', '-':    v = 62
		case '/', '_':    v = 63
		case:             continue
		}
		acc = (acc << 6) | v
		bits += 6
		if bits >= 8 {
			bits -= 8
			if out >= len(dst) do return out
			dst[out] = u8((acc >> bits) & 0xFF)
			out += 1
		}
	}
	return out
}

// osc_7502_parse parses an OSC 7502 payload into `Osc_7502_Command` with zero allocations.
osc_7502_parse :: proc(payload: string) -> (cmd: Osc_7502_Command, ok: bool) {
	if len(payload) == 0 do return {}, false
	if payload == "?" {
		return Osc_7502_Command{is_probe = true}, true
	}
	rest := payload
	op_tok, has_op := _next_semi_field(&rest)
	if !has_op || len(op_tok) == 0 do return {}, false
	op_int, op_ok := strconv.parse_int(op_tok)
	if !op_ok do return {}, false

	switch op_int {
	case 0:
		cmd.op = .Reset
		return cmd, true
	case 1:
		cmd.op = .Target
		cmd.id, ok = _parse_req_u16(&rest, true)
		return cmd, ok
	case 2:
		cmd.op = .Split
		return cmd, _parse_split_params(&cmd, &rest)
	case 3:
		cmd.op = .Popup
		return cmd, _parse_popup_params(&cmd, &rest)
	case 4:
		cmd.op = .Focus
		cmd.id, ok = _parse_req_u16(&rest, true)
		return cmd, ok
	case 5:
		cmd.op = .Visibility
		cmd.id, ok = _parse_req_u16(&rest, false)
		cmd.visible = _parse_opt_int(&rest, 1) != 0
		return cmd, ok
	case 6:
		cmd.op = .Close
		cmd.id, ok = _parse_req_u16(&rest, false)
		return cmd, ok
	}
	return {}, false
}
