package feature_session_core

// MSG_ACT: keys, text and mouse input for automation, encoded here with the
// modes the program asked for at this moment (input_encode). It reaches the
// program like `send`: as typing, which ends a shell-adapter request.

import "core:strings"
import "core:unicode/utf8"
import terminal "../../core/terminal"
import ie "../../core/terminal/input_encode"
import proto "../session_proto"
import ipc "../../platform/ipc"

core_viewer_act :: proc(c: ^Core, vi: int, r: ^ipc.Wire_Reader) {
	s := _target(c, vi, r, true, false)
	if s == nil || _no_program(c, vi, s) || core_lease_fail(c, s, vi) do return
	k := ipc.wr_u8(r)
	if k < u8(proto.Act_Kind.Keys) || k > u8(proto.Act_Kind.Mouse) {
		core_viewer_fail(c, vi, 0, .Bad_Request, "malformed act request")
		return
	}
	if s.stitch != nil && s.stitch.active {
		core_viewer_fail(c, vi, 0, .Busy, "a read is scrolling this session")
		return
	}
	clear(&c.act)
	code: proto.Fail_Code
	reason: string
	switch proto.Act_Kind(k) {
	case .Keys:  code, reason = _act_keys(c, s, r)
	case .Text:  code, reason = _act_text(c, s, r)
	case .Mouse: code, reason = _act_mouse(c, s, r)
	}
	if code == {} && !ipc.wr_done(r) do code, reason = .Bad_Request, "malformed act request"
	if code != {} {
		core_viewer_fail(c, vi, 0, code, reason)
		return
	}
	gen := s.gen
	core_broker_human_input(c, s, c.act[:])
	core_holder_send(c, s.holder, proto.MSG_INPUT, s.id, c.act[:])
	w := ipc.wire_writer(c.msg)
	ipc.ww_u32(&w, s.id)
	ipc.ww_u64(&w, gen)
	ipc.stream_send(&c.viewers[vi].conn, proto.MSG_ACT_RESULT, 0, ipc.wire_bytes_written(&w))
}

@(private = "file")
_act_keys :: proc(c: ^Core, s: ^Core_Session, r: ^ipc.Wire_Reader) -> (proto.Fail_Code, string) {
	n := ipc.wr_u32(r)
	if !r.ok || n == 0 || n > proto.ACT_KEYS_MAX do return .Bad_Request, "1 to 64 keys per act"
	t := &s.sess.term
	modes := ie.Key_Modes{app_cursor = t.parser.cursor_key_mode, kitty_flags = terminal.terminal_kitty_keyboard_flags(t)}
	for _ in 0 ..< n {
		ev, ok := _act_key_event(proto.dec_act_key(r))
		if !ok || !r.ok do return .Bad_Request, "malformed key"
		if !_act_tap(c, ev, modes) do return .Unsupported, "the program has no encoding for that key"
	}
	return {}, ""
}

// _act_key_event checks a wire key against input_encode's enums.
@(private = "file")
_act_key_event :: proc(k: proto.Act_Key) -> (ev: ie.Key_Event, ok: bool) {
	if k.key == 0 || k.key > u8(max(ie.Key)) || k.mods > 0xF do return {}, false
	ev = {key = ie.Key(k.key), mods = transmute(ie.Mods)k.mods, kind = .Press}
	if ev.key == .Char {
		if k.char < 0x20 || k.char > 0x7E do return {}, false
		ev.char = rune(k.char)
	}
	return ev, true
}

// _act_tap appends a press and, when the program reports them, its release. A
// character the encoder leaves to text input goes in as that character.
@(private = "file")
_act_tap :: proc(c: ^Core, key: ie.Key_Event, modes: ie.Key_Modes) -> bool {
	ev := key
	ev.kind = .Press
	// An uppercase letter is Shift + its key, as a keyboard sends it.
	if ev.key == .Char && ev.char >= 'A' && ev.char <= 'Z' do ev.char, ev.mods = ev.char + ('a' - 'A'), ev.mods + {.Shift}
	press, ok := ie.encode_key(ev, modes)
	if ok {
		append(&c.act, ..press.bytes[:press.len])
		up := ev
		up.kind = .Release
		if release, has := ie.encode_key(up, modes); has do append(&c.act, ..release.bytes[:release.len])
		return true
	}
	if ev.key != .Char || ev.mods - {.Shift} != {} do return false
	ch := ev.char
	if .Shift in ev.mods && ch >= 'a' && ch <= 'z' do ch -= 'a' - 'A'
	append(&c.act, u8(ch))
	return true
}

// _act_text types text key by key (so Kitty-mode programs get key events) or
// pastes it as one bracketed paste when the program enabled ?2004. \n and
// \r\n are Enter. A paste cannot end itself early: an embedded end marker is
// dropped.
@(private = "file")
_act_text :: proc(c: ^Core, s: ^Core_Session, r: ^ipc.Wire_Reader) -> (proto.Fail_Code, string) {
	want_paste := ipc.wr_bool(r)
	text := ipc.wr_str(r)
	if !r.ok || len(text) == 0 || len(text) > proto.ACT_TEXT_MAX do return .Bad_Request, "text must be 1 byte to 64 KiB"
	t := &s.sess.term
	if want_paste && t.parser.bracketed_paste {
		append(&c.act, "\x1b[200~")
		inner, _ := strings.replace_all(text, "\x1b[201~", "", context.temp_allocator)
		_act_lines(c, inner)
		append(&c.act, "\x1b[201~")
		return {}, ""
	}
	modes := ie.Key_Modes{app_cursor = t.parser.cursor_key_mode, kitty_flags = terminal.terminal_kitty_keyboard_flags(t)}
	typed, _ := strings.replace_all(text, "\r\n", "\n", context.temp_allocator)
	for ch in typed {
		switch ch {
		case '\n':        _act_tap(c, {key = .Enter}, modes)
		case '\t':        _act_tap(c, {key = .Tab}, modes)
		case 0x20 ..= 0x7E: _act_tap(c, {key = .Char, char = ch}, modes)
		case:              _act_rune(c, ch) // controls and non-ASCII go in as their bytes
		}
	}
	return {}, ""
}

// _act_lines appends pasted text with each newline as \r, the way a terminal
// pastes.
@(private = "file")
_act_lines :: proc(c: ^Core, text: string) {
	lines, _ := strings.replace_all(text, "\r\n", "\n", context.temp_allocator)
	for i in 0 ..< len(lines) do append(&c.act, '\r' if lines[i] == '\n' else lines[i])
}

@(private = "file")
_act_rune :: proc(c: ^Core, ch: rune) {
	b, n := utf8.encode_rune(ch)
	append(&c.act, ..b[:n])
}

@(private = "file")
_act_mouse :: proc(c: ^Core, s: ^Core_Session, r: ^ipc.Wire_Reader) -> (proto.Fail_Code, string) {
	m := proto.dec_act_mouse(r)
	t := &s.sess.term
	if !r.ok || m.kind > u8(max(ie.Mouse_Kind)) || m.button > u8(max(ie.Mouse_Button)) || m.mods > 0xF ||
	   m.col == 0 || int(m.col) > t.cols || m.row == 0 || int(m.row) > t.rows {
		return .Bad_Request, "malformed mouse event"
	}
	cw := t.parser.cell_w if t.parser.cell_w > 0 else 1
	ch := t.parser.cell_h if t.parser.cell_h > 0 else 1
	ev := ie.Mouse_Event{
		kind = ie.Mouse_Kind(m.kind), button = ie.Mouse_Button(m.button), mods = transmute(ie.Mods)m.mods,
		col = int(m.col), row = int(m.row), px = (int(m.col) - 1) * cw + 1, py = (int(m.row) - 1) * ch + 1,
	}
	enc, ok := ie.encode_mouse(ev, ie.mouse_modes(&t.parser))
	if !ok do return .Unsupported, "the program does not report that mouse event"
	append(&c.act, ..enc.bytes[:enc.len])
	return {}, ""
}
