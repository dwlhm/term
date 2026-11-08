package feature_session_core_tests

// A `term session` style link for tier tests: one ipc.Client (role Cli).
// Requests go out with client_start, so a test can have several in flight
// and read what comes back in order, as frames: an answer or progress (body
// without req), a FAIL (laid out as on the wire: u32 req · u8 code · str
// reason), a notice, or stream DATA/CLOSE on an attach channel.

import "core:time"
import proto "../../session_proto"
import ipc "../../../platform/ipc"

Cli :: struct {
	c:    ipc.Client,
	fail: [1024]u8, // the last FAIL frame's payload
}

Cli_Frame :: struct {
	kind:    u8,
	channel: u32,
	ticket:  ipc.Ticket, // the request it answers (0: a notice or stream)
	payload: []u8,       // valid until the next cli_* call
}

cli_conn :: proc(conn: ^Cli) -> bool {
	return proto.session_open(&conn.c, .Cli, false).kind == .None
}

cli_close :: proc(conn: ^Cli) { ipc.client_close(&conn.c) }

// cli_send starts one request; its answer comes as a frame.
cli_send :: proc(conn: ^Cli, kind: u8, body: ..[]u8) -> ipc.Ticket {
	buf: [64 * 1024]u8
	n := 0
	for b in body do n += copy(buf[n:], b)
	tk, _ := ipc.client_start(&conn.c, kind, buf[:n])
	return tk
}

// cli_stream sends one frame on an attach channel (CLOSE detaches).
cli_stream :: proc(conn: ^Cli, channel: u32, kind: u8, body: []u8 = nil) {
	_ = ipc.client_stream_send(&conn.c, channel, kind, body)
}

cli_ack :: proc(conn: ^Cli, channel: u32, n: int) { ipc.client_stream_ack(&conn.c, channel, n) }

// cli_frame waits up to ms for the next frame.
cli_frame :: proc(conn: ^Cli, ms: int) -> (f: Cli_Frame, ok: bool) {
	ev, err := ipc.client_poll(&conn.c, time.Duration(max(ms, 1)) * time.Millisecond)
	if err.kind != .None do return
	switch e in ev {
	case ipc.Late_Answer:
		if e.err.kind == .None do return {kind = e.answer.kind, ticket = e.ticket, payload = e.answer.body}, true
		w := ipc.wire_writer(conn.fail[:])
		ipc.ww_u32(&w, u32(e.ticket)); ipc.ww_u8(&w, e.err.code); ipc.ww_str(&w, e.err.reason[:min(len(e.err.reason), 900)])
		return {kind = proto.MSG_FAIL, ticket = e.ticket, payload = ipc.wire_bytes_written(&w)}, true
	case ipc.Progress:    return {kind = e.kind, ticket = e.ticket, payload = e.body}, true
	case ipc.Notice:      return {kind = e.kind, payload = e.body}, true
	case ipc.Stream_Data: return {kind = ipc.STREAM_DATA, channel = e.channel, payload = e.bytes}, true
	case ipc.Stream_End:  return {kind = ipc.STREAM_CLOSE, channel = e.channel, payload = transmute([]u8)e.reason}, true
	}
	return
}

cli_answer :: proc(conn: ^Cli, want: u8, ms: int) -> (f: Cli_Frame, ok: bool) {
	for {
		f = cli_frame(conn, ms) or_return
		if f.kind == want || f.kind == proto.MSG_FAIL do return f, true
	}
}

// cli_fail_code reads a FAIL frame's code.
cli_fail_code :: proc(payload: []u8) -> proto.Fail_Code {
	r := ipc.wire_reader(payload)
	_ = ipc.wr_u32(&r)
	return proto.Fail_Code(ipc.wr_u8(&r))
}

// cli_list returns the SESSIONS payload reader (positioned after the count).
cli_list :: proc(conn: ^Cli) -> (r: ipc.Wire_Reader, count: int, ok: bool) {
	cli_send(conn, proto.MSG_LIST)
	for {
		f, got := cli_frame(conn, 3000)
		if !got do return
		if f.kind != proto.MSG_SESSIONS do continue
		r = ipc.wire_reader(f.payload)
		count = int(ipc.wr_u32(&r))
		return r, count, r.ok
	}
}

cli_list_ids :: proc(out: []u32) -> []u32 {
	conn: Cli
	if !cli_conn(&conn) do return nil
	defer cli_close(&conn)
	r, count, ok := cli_list(&conn)
	n := 0
	for _ in 0..<count {
		if !ok || n == len(out) do break
		out[n] = proto.dec_row(&r).id
		n += 1
	}
	return out[:n]
}

cli_list_rows :: proc(out: []proto.Session_Row) -> []proto.Session_Row {
	conn: Cli
	if !cli_conn(&conn) do return nil
	defer cli_close(&conn)
	r, count, ok := cli_list(&conn)
	n := 0
	for _ in 0..<count {
		if !ok || n == len(out) do break
		out[n] = proto.dec_row(&r)
		n += 1
	}
	return out[:n]
}

// cli_wait_rows waits until a core lists a row: a fresh core has to adopt the
// holder's sessions first, so a single LIST right after it starts can be empty.
cli_wait_rows :: proc(out: []proto.Session_Row, ms := 3000) -> []proto.Session_Row {
	for _ in 0..<ms / 10 {
		if n := cli_list_rows(out); len(n) > 0 do return n
		time.sleep(10 * time.Millisecond)
	}
	return cli_list_rows(out)
}

// cli_kill: true = the core answered OK.
cli_kill :: proc(id: u32) -> bool {
	b: [4]u8
	w := ipc.wire_writer(b[:])
	ipc.ww_u32(&w, id)
	c: ipc.Client
	if proto.session_open(&c, .Cli, false).kind != .None do return false
	defer ipc.client_close(&c)
	_, err := ipc.client_call(&c, proto.MSG_KILL, b[:], {timeout = 3 * time.Second})
	return err.kind == .None
}

cli_attach_channel :: proc(conn: ^Cli, id: u32) -> (u32, bool) {
	b: [64]u8
	w := ipc.wire_writer(b[:])
	proto.enc_attach(&w, {id = id, size = {cols = 80, rows = 24}})
	cli_send(conn, proto.MSG_ATTACH, ipc.wire_bytes_written(&w))
	for {
		f, got := cli_frame(conn, 3000)
		if !got do return 0, false
		if f.kind != proto.MSG_ATTACHED do continue
		r := ipc.wire_reader(f.payload)
		got_id, ch := ipc.wr_u32(&r), ipc.wr_u32(&r)
		return ch, got_id == id
	}
}
