package feature_session_core

// Target resolution (@eN, text, pos) and mouse event encoding for automation.

import "core:fmt"
import ie "../../core/terminal/input_encode"
import model "../screen_model"
import proto "../session_proto"

_act_batch_click :: proc(
	c: ^Core,
	s: ^Core_Session,
	item: proto.Act_Batch_Item,
) -> (proto.Fail_Code, string) {
	t := &s.sess.term
	if t.parser.mouse_mode == .None {
		return .Unsupported, fmt.tprintf("session %d does not take the mouse", s.id)
	}
	row, col, code, reason := _resolve_target(c, s, item.target)
	if code != {} do return code, reason
	btn := _to_mouse_btn(item.button)
	_encode_mouse(c, s, .Press, btn, row, col)
	_encode_mouse(c, s, .Release, btn, row, col)
	if item.double {
		_encode_mouse(c, s, .Press, btn, row, col)
		_encode_mouse(c, s, .Release, btn, row, col)
	}
	return {}, ""
}

_act_batch_scroll :: proc(
	c: ^Core,
	s: ^Core_Session,
	item: proto.Act_Batch_Item,
) -> (proto.Fail_Code, string) {
	t := &s.sess.term
	if t.parser.mouse_mode == .None {
		return .Unsupported, fmt.tprintf("session %d does not take the mouse", s.id)
	}
	row, col, code, reason := _resolve_target(c, s, item.target)
	if code != {} do return code, reason
	kind := ie.Mouse_Kind.Wheel_Up if item.dir == 0 else ie.Mouse_Kind.Wheel_Down
	for _ in 0 ..< item.count {
		_encode_mouse(c, s, kind, .None, row, col)
	}
	return {}, ""
}

_act_batch_drag :: proc(
	c: ^Core,
	s: ^Core_Session,
	item: proto.Act_Batch_Item,
) -> (proto.Fail_Code, string) {
	t := &s.sess.term
	if t.parser.mouse_mode != .Button_Event &&
	   t.parser.mouse_mode != .Any_Event {
		return .Unsupported, fmt.tprintf(
			"session %d does not take mouse motion", s.id,
		)
	}
	r1, c1, code1, reason1 := _resolve_target(c, s, item.target)
	if code1 != {} do return code1, reason1
	r2, c2, code2, reason2 := _resolve_target(c, s, item.to_target)
	if code2 != {} do return code2, reason2
	btn := _to_mouse_btn(item.button)
	_encode_mouse(c, s, .Press, btn, r1, c1)
	_encode_mouse(c, s, .Motion, btn, r2, c2)
	_encode_mouse(c, s, .Release, btn, r2, c2)
	return {}, ""
}

_resolve_target :: proc(
	c: ^Core,
	s: ^Core_Session,
	target: proto.Act_Target,
) -> (row, col: int, code: proto.Fail_Code, reason: string) {
	t := &s.sess.term
	switch target.kind {
	case .Pos:
		r, cl := int(target.row), int(target.col)
		if r < 1 || r > t.rows || cl < 1 || cl > t.cols {
			return 0, 0, .Bad_Request, fmt.tprintf(
				"%d,%d is outside the %dx%d screen",
				r, cl, t.cols, t.rows,
			)
		}
		return r, cl, {}, ""
	case .Ref:
		return _resolve_ref_target(c, s, target.ref)
	case .Text:
		return _resolve_text_target(c, s, target.text)
	}
	return 0, 0, .Bad_Request, "unknown target kind"
}

@(private = "file")
_find_ref_entry :: proc(s: ^Core_Session, ref_id: u32) -> ^Ref_Entry {
	for &entry in s.ref_table {
		if entry.id == ref_id do return &entry
	}
	return nil
}

@(private = "file")
_resolve_ref_target :: proc(
	c: ^Core,
	s: ^Core_Session,
	ref_id: u32,
) -> (row, col: int, code: proto.Fail_Code, reason: string) {
	matched_entry := _find_ref_entry(s, ref_id)
	if matched_entry == nil {
		return 0, 0, .Bad_Request, fmt.tprintf(
			"no @e%d in session %d: read --elements first",
			ref_id, s.id,
		)
	}

	elements, _ := _elements_snapshot(c, s)
	matches := make([dynamic]model.Box, context.temp_allocator)
	for &e in elements {
		label := e.name if len(e.name) > 0 else e.text
		if u8(e.role) == matched_entry.role && label == matched_entry.text {
			append(&matches, e.box)
		}
	}
	role_str := _role_str(matched_entry.role)
	if len(matches) == 0 {
		return 0, 0, .Unsupported, fmt.tprintf(
			"@e%d (%s \"%s\") is not on the screen",
			ref_id, role_str, matched_entry.text,
		)
	}
	if len(matches) > 1 {
		return 0, 0, .Unsupported, fmt.tprintf(
			"@e%d (%s \"%s\") matches %d elements: at %d,%d and %d,%d",
			ref_id, role_str, matched_entry.text, len(matches),
			matches[0].row + 1, matches[0].col + 1,
			matches[1].row + 1, matches[1].col + 1,
		)
	}
	b := matches[0]
	return b.row + b.height / 2 + 1, b.col + b.width / 2 + 1, {}, ""
}

@(private = "file")
_resolve_text_target :: proc(
	c: ^Core,
	s: ^Core_Session,
	text: string,
) -> (row, col: int, code: proto.Fail_Code, reason: string) {
	elements, _ := _elements_snapshot(c, s)
	matches := make([dynamic]model.Box, context.temp_allocator)
	for &e in elements {
		label := e.name if len(e.name) > 0 else e.text
		if label == text {
			append(&matches, e.box)
		}
	}
	if len(matches) == 0 {
		return 0, 0, .Unsupported, fmt.tprintf(
			"no \"%s\" on the screen", text,
		)
	}
	if len(matches) > 1 {
		return 0, 0, .Unsupported, fmt.tprintf(
			"%d matches for \"%s\": at %d,%d and %d,%d — click by position",
			len(matches), text,
			matches[0].row + 1, matches[0].col + 1,
			matches[1].row + 1, matches[1].col + 1,
		)
	}
	b := matches[0]
	return b.row + b.height / 2 + 1, b.col + b.width / 2 + 1, {}, ""
}

_to_mouse_btn :: proc(btn: u8) -> ie.Mouse_Button {
	switch btn {
	case 1: return .Right
	case 2: return .Middle
	case:   return .Left
	}
}

_encode_mouse :: proc(
	c: ^Core,
	s: ^Core_Session,
	kind: ie.Mouse_Kind,
	btn: ie.Mouse_Button,
	row, col: int,
) {
	t := &s.sess.term
	cw := t.parser.cell_w if t.parser.cell_w > 0 else 1
	ch := t.parser.cell_h if t.parser.cell_h > 0 else 1
	ev := ie.Mouse_Event{
		kind = kind,
		button = btn,
		col = col,
		row = row,
		px = (col - 1) * cw + 1,
		py = (row - 1) * ch + 1,
	}
	enc, ok := ie.encode_mouse(ev, ie.mouse_modes(&t.parser))
	if ok {
		append(&c.act, ..enc.bytes[:enc.len])
	}
}

_role_str :: proc(r: u8) -> string {
	names := [model.Role]string{
		.Panel = "panel", .Dialog = "dialog", .Button = "button",
		.Checkbox = "checkbox", .Radio = "radio", .Input = "input",
		.Listitem = "listitem", .Tab = "tab", .Scrollbar = "scrollbar",
		.Statusbar = "statusbar", .Link = "link", .Prompt = "prompt",
		.Output = "output",
	}
	if int(r) < len(names) do return names[model.Role(r)]
	return "element"
}
