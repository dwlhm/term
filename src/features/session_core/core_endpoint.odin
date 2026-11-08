package feature_session_core

// Virtual sessions (`term session new --endpoint <name>`): an address with no
// program and no PTY, for an app outside term that takes requests (`next
// --as <id>`) or sends them. One the CLI made lives until `kill`; an owned one
// (made over a connection that asked so) ends when that connection closes. A
// planned restart keeps the unowned ones under their ids.

import "core:os"
import proto "../session_proto"
import ipc "../../platform/ipc"

CORE_ENDPOINT_NAME_MAX :: 64
CORE_ENDPOINT_SNAPSHOT :: "snap.endpoints"

Core_Endpoint :: struct {
	used:      bool,
	owner:     int, // viewer that owns it (-1 = none)
	owner_seq: u32,
	name_len:  int,
	name_buf:  [CORE_ENDPOINT_NAME_MAX]u8,
}

core_endpoint_name :: proc(s: ^Core_Session) -> string { return string(s.endpoint.name_buf[:s.endpoint.name_len]) }

core_viewer_endpoint :: proc(c: ^Core, vi: int, r: ^ipc.Wire_Reader) {
	name, owned := ipc.wr_str(r), ipc.wr_bool(r)
	if !ipc.wr_done(r) || len(name) == 0 || len(name) > CORE_ENDPOINT_NAME_MAX {
		core_viewer_fail(c, vi, 0, .Bad_Request, "an endpoint needs a name of 1..64 bytes")
		return
	}
	s := _endpoint_new(c, c.next_id, name)
	if s == nil {
		core_viewer_fail(c, vi, 0, .Busy, "no free session slot")
		return
	}
	if owned do s.endpoint.owner, s.endpoint.owner_seq = vi, c.viewers[vi].seq
	b := _i32_bytes(i32(s.id))
	ipc.stream_send(&c.viewers[vi].conn, proto.MSG_OK, 0, b[:])
	core_broadcast_row(c, s)
}

// core_endpoints_owner_gone removes the endpoints a closed connection owned.
core_endpoints_owner_gone :: proc(c: ^Core, vi: int) {
	seq := c.viewers[vi].seq
	for &s in c.sessions {
		if s.used && s.endpoint.used && s.endpoint.owner == vi && s.endpoint.owner_seq == seq do core_session_kill(c, &s)
	}
}

// core_endpoints_save writes the unowned endpoints for the next core.
core_endpoints_save :: proc(c: ^Core) {
	w := ipc.wire_writer(c.msg)
	n := 0
	for &s in c.sessions do if s.used && s.endpoint.used && s.endpoint.owner < 0 do n += 1
	ipc.ww_u32(&w, u32(n))
	for &s in c.sessions {
		if !s.used || !s.endpoint.used || s.endpoint.owner >= 0 do continue
		ipc.ww_u32(&w, s.id); ipc.ww_str(&w, core_endpoint_name(&s))
	}
	path_buf: [256]u8
	if path, ok := proto.session_path(path_buf[:], c.dir, CORE_ENDPOINT_SNAPSHOT); ok && w.ok {
		_ = os.write_entire_file(path, ipc.wire_bytes_written(&w))
	}
}

// core_endpoints_restore brings them back (before the broker's requests).
core_endpoints_restore :: proc(c: ^Core) {
	path_buf: [256]u8
	path, ok := proto.session_path(path_buf[:], c.dir, CORE_ENDPOINT_SNAPSHOT)
	if !ok do return
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil do return
	defer delete(data)
	os.remove(path)
	r := ipc.wire_reader(data)
	n := ipc.wr_u32(&r) // a range bound is evaluated every iteration
	for _ in 0..<n {
		id, name := ipc.wr_u32(&r), ipc.wr_str(&r)
		if !r.ok || id == 0 || core_session_find(c, id) != nil || len(name) == 0 || len(name) > CORE_ENDPOINT_NAME_MAX do break
		_endpoint_new(c, id, name)
	}
}

@(private = "file")
_endpoint_new :: proc(c: ^Core, id: u32, name: string) -> ^Core_Session {
	s := _session_new(c, id, -1, {cols = 80, rows = 24})
	if s == nil do return nil
	s.endpoint = {used = true, owner = -1}
	s.endpoint.name_len = copy(s.endpoint.name_buf[:], name)
	return s
}
