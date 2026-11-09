package feature_session_core

// Implementation of MSG_ELEMENTS and session element ref table (spec 4.6).
// Core maintains a ref table per session: every @eN is bound to its role and
// text, keeping its number across queries.

import "core:strings"
import model "../screen_model"
import proto "../session_proto"
import ipc "../../platform/ipc"

core_viewer_elements :: proc(c: ^Core, req: ^ipc.Request) {
	id: u32
	if !ipc.request_decode(req, &id, proto.dec_id) do return
	s := core_session_find(c, id)
	if s == nil {
		core_viewer_fail(c, req, .Not_Found, "no such session")
		return
	}
	defer free_all(context.temp_allocator)

	elements, ok := _elements_snapshot(c, s)
	if !ok {
		core_viewer_fail(c, req, .Bad_Request, "cannot snapshot screen")
		return
	}
	ref_ids := _elements_assign_refs(s, elements)
	_elements_encode_reply(c, req, elements, ref_ids)
}

@(private = "file")
_elements_snapshot :: proc(
	c: ^Core,
	s: ^Core_Session,
) -> (elements: []model.Element, ok: bool) {
	snap_buf := make([]u8, 256 * 1024, context.temp_allocator)
	w := ipc.wire_writer(snap_buf)
	_snap_write(c, s, &w, -1, 0)
	if !w.ok do return nil, false
	sr := ipc.wire_reader(ipc.wire_bytes_written(&w))
	snap := proto.dec_snapshot(&sr, context.temp_allocator)
	screen := model.screen_build(snap, context.temp_allocator)
	return model.screen_elements(&screen, context.temp_allocator), true
}

@(private = "file")
_elements_assign_refs :: proc(
	s: ^Core_Session,
	elements: []model.Element,
) -> []u32 {
	if s.next_ref_id == 0 do s.next_ref_id = 1
	ref_ids := make([]u32, len(elements), context.temp_allocator)

	for &e, i in elements {
		label := e.name if len(e.name) > 0 else e.text
		matched: u32 = 0
		for entry in s.ref_table {
			if entry.role == u8(e.role) && entry.text == label {
				matched = entry.id
				break
			}
		}
		if matched == 0 {
			matched = s.next_ref_id
			s.next_ref_id += 1
			append(&s.ref_table, Ref_Entry{
				id   = matched,
				role = u8(e.role),
				text = strings.clone(label),
			})
		}
		ref_ids[i] = matched
	}
	return ref_ids
}

@(private = "file")
_elements_encode_reply :: proc(
	c: ^Core,
	req: ^ipc.Request,
	elements: []model.Element,
	ref_ids: []u32,
) {
	rw := ipc.wire_writer(c.msg)
	ipc.ww_u32(&rw, u32(len(elements)))
	for &e, i in elements {
		state: u8 = 0
		if e.focused do state |= 1
		if e.selected do state |= 2
		if e.checked do state |= 4
		proto.enc_element_report(&rw, {
			ref    = ref_ids[i],
			role   = u8(e.role),
			row    = u16(e.box.row),
			col    = u16(e.box.col),
			width  = u16(e.box.width),
			height = u16(e.box.height),
			state  = state,
			name   = e.name,
			text   = e.text,
		})
	}
	ipc.reply(&c.srv, req^, ipc.wire_bytes_written(&rw))
}
