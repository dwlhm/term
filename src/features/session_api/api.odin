package feature_session_api

// Unified programmatic client API for term sessions.
// Single source of truth for both CLI commands and the Lua runtime.
// Pure, synchronous, and non-blocking under the hood using platform/ipc.

import "core:time"
import ipc "../../platform/ipc"
import proto "../session_proto"

DEFAULT_TIMEOUT :: 3 * time.Second

// api_open connects an ipc.Client to the session core.
// If start is true, starts the core if none is running.
api_open :: proc(c: ^ipc.Client, start := false) -> ipc.Error {
	return proto.session_open(c, .Cli, start)
}

// api_ls retrieves all active session rows from the core.
api_ls :: proc(c: ^ipc.Client, allocator := context.allocator, timeout := DEFAULT_TIMEOUT) -> (rows: []proto.Session_Row, err: ipc.Error) {
	a, call_err := ipc.client_call(c, proto.MSG_LIST, nil, {timeout = timeout})
	if call_err.kind != .None do return nil, call_err

	r := ipc.wire_reader(a.body)
	count := int(ipc.wr_u32(&r))
	out := make([]proto.Session_Row, count, allocator)
	for i in 0 ..< count {
		out[i] = proto.dec_row(&r)
	}
	return out, {}
}

// api_new requests the core to spawn a new session. Returns the new session ID.
api_new :: proc(c: ^ipc.Client, spec: ^proto.Spawn_Msg, timeout := 5 * time.Second) -> (id: u32, err: ipc.Error) {
	buf: [64 * 1024]u8
	w := ipc.wire_writer(buf[:])
	proto.enc_spawn(&w, spec)
	if !w.ok do return 0, {kind = .Failed, code = u8(proto.Fail_Code.Bad_Request), reason = "spawn message too large"}

	a, call_err := ipc.client_call(c, proto.MSG_CREATE, ipc.wire_bytes_written(&w), {timeout = timeout})
	if call_err.kind != .None do return 0, call_err

	r := ipc.wire_reader(a.body)
	id = ipc.wr_u32(&r)
	return id, {}
}

// api_kill stops and destroys a session by ID.
api_kill :: proc(c: ^ipc.Client, id: u32, timeout := DEFAULT_TIMEOUT) -> ipc.Error {
	buf: [4]u8
	w := ipc.wire_writer(buf[:])
	ipc.ww_u32(&w, id)
	_, err := ipc.client_call(c, proto.MSG_KILL, ipc.wire_bytes_written(&w), {timeout = timeout})
	return err
}

// api_signal delivers a POSIX signal to the session's foreground process.
api_signal :: proc(c: ^ipc.Client, id: u32, sig: i32, timeout := DEFAULT_TIMEOUT) -> ipc.Error {
	buf: [8]u8
	w := ipc.wire_writer(buf[:])
	proto.enc_signal_req(&w, {id, sig})
	_, err := ipc.client_call(c, proto.MSG_SESSION_SIGNAL, ipc.wire_bytes_written(&w), {timeout = timeout})
	return err
}

// api_resize updates the logical dimensions of a session.
api_resize :: proc(c: ^ipc.Client, id: u32, size: proto.Size_Msg, timeout := DEFAULT_TIMEOUT) -> ipc.Error {
	buf: [12]u8
	w := ipc.wire_writer(buf[:])
	proto.enc_size_req(&w, {id, size})
	_, err := ipc.client_call(c, proto.MSG_SESSION_SIZE, ipc.wire_bytes_written(&w), {timeout = timeout})
	return err
}

// api_read reads text or scrollback from the session.
api_read :: proc(c: ^ipc.Client, id: u32, history: u32, last: bool, allocator := context.allocator, timeout := 4 * time.Second) -> (text: string, err: ipc.Error) {
	buf: [16]u8
	w := ipc.wire_writer(buf[:])
	req := proto.Read_Request{id = id, history = history, last = last}
	proto.enc_read_req(&w, req)
	a, call_err := ipc.client_call(c, proto.MSG_READ, ipc.wire_bytes_written(&w), {timeout = timeout})
	if call_err.kind != .None do return "", call_err
	return string(a.body), {}
}

// api_elements inspects parsed and inferred UI elements on the session screen.
api_elements :: proc(c: ^ipc.Client, id: u32, allocator := context.allocator, timeout := DEFAULT_TIMEOUT) -> (elems: []proto.Element_Report, err: ipc.Error) {
	buf: [4]u8
	w := ipc.wire_writer(buf[:])
	ipc.ww_u32(&w, id)
	a, call_err := ipc.client_call(c, proto.MSG_ELEMENTS, ipc.wire_bytes_written(&w), {timeout = timeout})
	if call_err.kind != .None do return nil, call_err

	r := ipc.wire_reader(a.body)
	count := int(ipc.wr_u32(&r))
	out := make([]proto.Element_Report, count, allocator)
	for i in 0 ..< count {
		out[i] = proto.dec_element_report(&r)
	}
	return out, {}
}

// api_snapshot retrieves a full screen snapshot with cell-level attributes and history.
api_snapshot :: proc(c: ^ipc.Client, id: u32, history: u32, since: i64 = -1, allocator := context.allocator, timeout := DEFAULT_TIMEOUT) -> (snap: proto.Snapshot, err: ipc.Error) {
	buf: [16]u8
	w := ipc.wire_writer(buf[:])
	proto.enc_snapshot_req(&w, {id = id, history = history, since = since})
	a, call_err := ipc.client_call(c, proto.MSG_SNAPSHOT, ipc.wire_bytes_written(&w), {timeout = timeout})
	if call_err.kind != .None do return {}, call_err

	r := ipc.wire_reader(a.body)
	snap = proto.dec_snapshot(&r, allocator)
	return snap, {}
}

// api_settle waits for session screen generation to settle past since with quiet_ms idle time.
api_settle :: proc(c: ^ipc.Client, id: u32, since: u64, quiet_ms, timeout_ms: u32, timeout := 10 * time.Second) -> (res: proto.Settle_Result, err: ipc.Error) {
	buf: [24]u8
	w := ipc.wire_writer(buf[:])
	proto.enc_settle_req(&w, {id = id, since = since, quiet_ms = quiet_ms, timeout_ms = timeout_ms})
	a, call_err := ipc.client_call(c, proto.MSG_SETTLE, ipc.wire_bytes_written(&w), {timeout = timeout})
	if call_err.kind != .None do return {}, call_err

	r := ipc.wire_reader(a.body)
	res = proto.dec_settle_result(&r)
	return res, {}
}

// api_act_batch executes an atomic batch of input actions (keys, text, clicks). Returns the screen gen.
api_act_batch :: proc(c: ^ipc.Client, id: u32, items: []proto.Act_Batch_Item, timeout := DEFAULT_TIMEOUT) -> (gen: u64, err: ipc.Error) {
	buf: [16 * 1024]u8
	w := ipc.wire_writer(buf[:])
	proto.enc_act_batch(&w, id, items)
	a, call_err := ipc.client_call(c, proto.MSG_ACT, ipc.wire_bytes_written(&w), {timeout = timeout})
	if call_err.kind != .None do return 0, call_err

	r := ipc.wire_reader(a.body)
	gen = ipc.wr_u64(&r)
	return gen, {}
}

// api_lease acquires exclusive automation lease on a session.
api_lease :: proc(c: ^ipc.Client, id: u32, owner: string, timeout := DEFAULT_TIMEOUT) -> ipc.Error {
	buf: [128]u8
	w := ipc.wire_writer(buf[:])
	proto.enc_lease_req(&w, {id, owner[:min(len(owner), proto.LEASE_OWNER_MAX)]})
	_, err := ipc.client_call(c, proto.MSG_LEASE, ipc.wire_bytes_written(&w), {timeout = timeout})
	return err
}

// api_lease_release releases an automation lease, optionally flushing held human input.
api_lease_release :: proc(c: ^ipc.Client, id: u32, flush: bool, timeout := DEFAULT_TIMEOUT) -> ipc.Error {
	buf: [8]u8
	w := ipc.wire_writer(buf[:])
	proto.enc_lease_flag(&w, {id, flush})
	_, err := ipc.client_call(c, proto.MSG_LEASE_RELEASE, ipc.wire_bytes_written(&w), {timeout = timeout})
	return err
}
