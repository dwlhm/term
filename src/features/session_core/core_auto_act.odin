package feature_session_core

// MSG_ACT: keys, text, mouse input, and atomic batch actions for automation.
// Encoded with the modes the program asked for (input_encode).

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import terminal "../../core/terminal"
import ie "../../core/terminal/input_encode"
import model "../screen_model"
import proto "../session_proto"
import ipc "../../platform/ipc"

core_viewer_act :: proc(c: ^Core, req: ^ipc.Request) {
	m: proto.Act_Request
	if !ipc.request_decode(req, &m, proto.dec_act) do return
	s := core_session_find(c, m.id)
	if !_act_validate(c, req, s) do return

	clear(&c.act)
	code: proto.Fail_Code
	reason: string
	switch m.kind {
	case .Keys:  code, reason = _act_keys(c, s, m.keys[:m.n_keys])
	case .Text:  code, reason = _act_text(c, s, m.text, m.paste)
	case .Mouse: code, reason = _act_mouse(c, s, m.mouse)
	case .Batch: code, reason = _act_batch(c, s, m.items[:m.n_items])
	}
	if code != {} {
		clear(&c.act)
		core_viewer_fail(c, req, code, reason)
		return
	}

	gen := s.gen
	s.input_gen = gen
	core_holder_send(c, s.holder, proto.MSG_INPUT, s.id, c.act[:])
	w := ipc.wire_writer(c.msg)
	ipc.ww_u32(&w, s.id)
	ipc.ww_u64(&w, gen)
	ipc.reply(&c.srv, req^, ipc.wire_bytes_written(&w))
}

@(private = "file")
_act_validate :: proc(
	c: ^Core,
	req: ^ipc.Request,
	s: ^Core_Session,
) -> bool {
	if s == nil {
		core_viewer_fail(c, req, .Not_Found, "no such session")
		return false
	}
	if s.exited {
		core_viewer_fail(c, req, .Exited, "session has exited")
		return false
	}
	if core_lease_fail(c, s, req) do return false
	if s.stitch != nil && s.stitch.active {
		core_viewer_fail(c, req, .Busy, "a read is scrolling this session")
		return false
	}
	return true
}

@(private = "file")
_act_batch :: proc(
	c: ^Core,
	s: ^Core_Session,
	items: []proto.Act_Batch_Item,
) -> (proto.Fail_Code, string) {
	for &item in items {
		code, reason := _act_batch_item(c, s, &item)
		if code != {} do return code, reason
	}
	return {}, ""
}

@(private = "file")
_act_batch_item :: proc(
	c: ^Core,
	s: ^Core_Session,
	item: ^proto.Act_Batch_Item,
) -> (proto.Fail_Code, string) {
	switch item.kind {
	case .Keys:
		return _act_keys(c, s, item.keys[:item.n_keys])
	case .Text:
		return _act_text(c, s, item.text, item.paste)
	case .Raw:
		append(&c.act, item.text)
		return {}, ""
	case .Click:
		return _act_batch_click(c, s, item^)
	case .Scroll:
		return _act_batch_scroll(c, s, item^)
	case .Drag:
		return _act_batch_drag(c, s, item^)
	}
	return .Bad_Request, "unknown batch item kind"
}

@(private = "file")
_act_keys :: proc(
	c: ^Core,
	s: ^Core_Session,
	keys: []proto.Act_Key,
) -> (proto.Fail_Code, string) {
	t := &s.sess.term
	modes := ie.Key_Modes{
		app_cursor = t.parser.cursor_key_mode,
		kitty_flags = terminal.terminal_kitty_keyboard_flags(t),
	}
	for k in keys {
		ev, ok := _act_key_event(k)
		if !ok do return .Bad_Request, "malformed key"
		if !_act_tap(c, ev, modes) {
			return .Unsupported, "the program has no encoding for that key"
		}
	}
	return {}, ""
}

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

@(private = "file")
_act_tap :: proc(c: ^Core, key: ie.Key_Event, modes: ie.Key_Modes) -> bool {
	ev := key
	ev.kind = .Press
	if ev.key == .Char && ev.char >= 'A' && ev.char <= 'Z' {
		ev.char, ev.mods = ev.char + ('a' - 'A'), ev.mods + {.Shift}
	}
	press, ok := ie.encode_key(ev, modes)
	if ok {
		append(&c.act, ..press.bytes[:press.len])
		up := ev
		up.kind = .Release
		if release, has := ie.encode_key(up, modes); has {
			append(&c.act, ..release.bytes[:release.len])
		}
		return true
	}
	if ev.key != .Char || ev.mods - {.Shift} != {} do return false
	ch := ev.char
	if .Shift in ev.mods && ch >= 'a' && ch <= 'z' do ch -= 'a' - 'A'
	append(&c.act, u8(ch))
	return true
}

@(private = "file")
_act_text :: proc(
	c: ^Core,
	s: ^Core_Session,
	text: string,
	want_paste: bool,
) -> (proto.Fail_Code, string) {
	if len(text) == 0 || len(text) > proto.ACT_TEXT_MAX {
		return .Bad_Request, "text must be 1 byte to 64 KiB"
	}
	t := &s.sess.term
	if want_paste && t.parser.bracketed_paste {
		append(&c.act, "\x1b[200~")
		inner, _ := strings.replace_all(
			text, "\x1b[201~", "", context.temp_allocator,
		)
		_act_lines(c, inner)
		append(&c.act, "\x1b[201~")
		return {}, ""
	}
	modes := ie.Key_Modes{
		app_cursor = t.parser.cursor_key_mode,
		kitty_flags = terminal.terminal_kitty_keyboard_flags(t),
	}
	typed, _ := strings.replace_all(text, "\r\n", "\n", context.temp_allocator)
	for ch in typed {
		switch ch {
		case '\n':          _act_tap(c, {key = .Enter}, modes)
		case '\t':          _act_tap(c, {key = .Tab}, modes)
		case 0x20 ..= 0x7E: _act_tap(c, {key = .Char, char = ch}, modes)
		case:                _act_rune(c, ch)
		}
	}
	return {}, ""
}

@(private = "file")
_act_lines :: proc(c: ^Core, text: string) {
	lines, _ := strings.replace_all(text, "\r\n", "\n", context.temp_allocator)
	for i in 0 ..< len(lines) {
		append(&c.act, '\r' if lines[i] == '\n' else lines[i])
	}
}

@(private = "file")
_act_rune :: proc(c: ^Core, ch: rune) {
	b, n := utf8.encode_rune(ch)
	append(&c.act, ..b[:n])
}

@(private = "file")
_act_mouse :: proc(
	c: ^Core,
	s: ^Core_Session,
	m: proto.Act_Mouse,
) -> (proto.Fail_Code, string) {
	t := &s.sess.term
	if m.kind > u8(max(ie.Mouse_Kind)) ||
	   m.button > u8(max(ie.Mouse_Button)) ||
	   m.mods > 0xF ||
	   m.col == 0 || int(m.col) > t.cols ||
	   m.row == 0 || int(m.row) > t.rows {
		return .Bad_Request, "malformed mouse event"
	}
	cw := t.parser.cell_w if t.parser.cell_w > 0 else 1
	ch := t.parser.cell_h if t.parser.cell_h > 0 else 1
	ev := ie.Mouse_Event{
		kind = ie.Mouse_Kind(m.kind),
		button = ie.Mouse_Button(m.button),
		mods = transmute(ie.Mods)m.mods,
		col = int(m.col),
		row = int(m.row),
		px = (int(m.col) - 1) * cw + 1,
		py = (int(m.row) - 1) * ch + 1,
	}
	enc, ok := ie.encode_mouse(ev, ie.mouse_modes(&t.parser))
	if !ok {
		return .Unsupported, "the program does not report that mouse event"
	}
	append(&c.act, ..enc.bytes[:enc.len])
	return {}, ""
}
