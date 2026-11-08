package feature_session_core_tests

// Helpers for broker tests through a real core: a shell with OSC 133
// integration and blocking `tell` requests.

import "core:strings"
import client "../../session_client"
import session "../../session"
import proto "../../session_proto"
import ipc "../../../platform/ipc"

// TELL_REPL is a shell with OSC 133 integration: prompt, read, run, report.
TELL_REPL :: `while :; do printf '\033]133;A\007$ \033]133;B\007'; IFS= read -r line || exit; printf '\033]133;C\007'; eval "$line"; printf '\033]133;D;%d\007' $?; done`

// tell_send opens a connection, sends one waiting tell and returns its first
// answer; the connection stays open for its Finished result.
tell_send :: proc(conn: ^Cli, req: proto.Tell_Request) -> (res: proto.Tell_Result, ok: bool) {
	req := req
	req.wait = true // these tests read the result on the same connection
	if !cli_conn(conn) do return
	buf: [1024]u8
	w := ipc.wire_writer(buf[:])
	proto.enc_tell_req(&w, req)
	cli_send(conn, proto.MSG_TELL, ipc.wire_bytes_written(&w))
	return tell_next(conn, 3000)
}

tell_next :: proc(conn: ^Cli, ms: int) -> (res: proto.Tell_Result, ok: bool) {
	for {
		f, got := cli_frame(conn, ms)
		if !got || f.kind == proto.MSG_FAIL do return
		if f.kind != proto.MSG_TELL_RESULT && f.kind != proto.MSG_TELL_PROGRESS do continue // a waiting tell hears Accepted as progress
		r := ipc.wire_reader(f.payload)
		res = proto.dec_tell_result(&r)
		res.text = strings.clone(res.text, context.temp_allocator)
		return res, ipc.wr_done(&r)
	}
}

tell_cancel :: proc(id: u64) -> bool {
	conn: Cli
	if !cli_conn(&conn) do return false
	defer cli_close(&conn)
	b: [8]u8
	w := ipc.wire_writer(b[:])
	ipc.ww_u64(&w, id)
	cli_send(&conn, proto.MSG_CANCEL, ipc.wire_bytes_written(&w))
	for {
		f, got := cli_frame(&conn, 3000)
		if !got || f.kind == proto.MSG_FAIL do return false
		if f.kind == proto.MSG_OK do return true
	}
}

// tell_run sends one blocking tell and waits for its result; between is run
// once the command started (a window resize, say).
tell_run :: proc(v: ^View, id: u32, body: string, between: proc(v: ^View) = nil) -> proto.Tell_Result {
	conn: Cli
	defer cli_close(&conn)
	res, ok := tell_send(&conn, {to = id, body = body})
	if !ok || res.phase != .Accepted do return res
	if between != nil {
		for i := 0; i < 300; i += 1 {
			obs, _, _ := cli_observe(id)
			if obs.prompt_state == .Executing do break
			view_pump(v, 5)
		}
		between(v)
	}
	res, _ = tell_next(&conn, 8000)
	return res
}

tell_view_sess: ^session.Terminal_Session
