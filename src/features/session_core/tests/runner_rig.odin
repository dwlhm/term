package feature_session_core_tests

// Helpers for runner_test.odin: a person typing or taking a session back, a
// caller replying, and waits on session rows.

import "core:strings"
import "core:time"
import client "../../session_client"
import proto "../../session_proto"
import ipc "../../../platform/ipc"

rig_wait_controller :: proc(id: u32, held: bool) {
	rows: [16]proto.Session_Row
	for _ in 0 ..< 200 {
		for row in cli_list_rows(rows[:]) do if row.id == id && (len(row.controller) > 0) == held do return
		time.sleep(20 * time.Millisecond)
	}
}

rig_wait_endpoint :: proc() -> u32 {
	rows: [16]proto.Session_Row
	for _ in 0 ..< 200 {
		for row in cli_list_rows(rows[:]) do if row.endpoint && row.request.listening > 0 do return row.id
		time.sleep(20 * time.Millisecond)
	}
	return 0
}

// echo_screen_has: the session's screen shows text (once it settled).
echo_screen_has :: proc(id: u32, text: string) -> bool {
	cli_settle({id = id, since = 0, quiet_ms = 150, timeout_ms = 1000})
	snap, _, _ := cli_snapshot(id)
	for row in snap.screen do for run in row.runs do if strings.contains(run.text, text) do return true
	return false
}

// session_type types like a person in a window: an attach channel's input.
session_type :: proc(id: u32, bytes: string) {
	conn: Cli
	if !cli_conn(&conn) do return
	defer cli_close(&conn)
	ch, ok := cli_attach_channel(&conn, id)
	if !ok do return
	cli_stream(&conn, ch, proto.MSG_V_INPUT, transmute([]u8)bytes)
	time.sleep(100 * time.Millisecond)
}

// session_takeover: a window takes the session back (after its confirmation).
session_takeover :: proc(id: u32) {
	conn: Cli
	if !cli_conn(&conn) do return
	defer cli_close(&conn)
	ch, ok := cli_attach_channel(&conn, id)
	if !ok do return
	cli_stream(&conn, ch, proto.MSG_V_TAKEOVER)
	time.sleep(100 * time.Millisecond)
}

// tell_body sends a waiting tell and returns when it finished.
tell_body :: proc(to: u32, body: string) {
	conn: Cli
	if !cli_conn(&conn) do return
	defer cli_close(&conn)
	b: [256]u8
	w := ipc.wire_writer(b[:])
	proto.enc_tell_req(&w, {to = to, body = body, wait = true})
	cli_send(&conn, proto.MSG_TELL, ipc.wire_bytes_written(&w))
	for _ in 0 ..< 100 {
		f, got := cli_frame(&conn, 200)
		if !got do continue
		if f.kind != proto.MSG_TELL_RESULT && f.kind != proto.MSG_TELL_PROGRESS do continue
		r := ipc.wire_reader(f.payload)
		res := proto.dec_tell_result(&r)
		if res.phase == .Finished || res.phase == .Rejected do return
	}
}

// rig_wait_listening: a worker waits in `next` for session id.
rig_wait_listening :: proc(id: u32) {
	rows: [16]proto.Session_Row
	for _ in 0 ..< 250 {
		for row in cli_list_rows(rows[:]) do if row.id == id && row.request.listening > 0 do return
		time.sleep(20 * time.Millisecond)
	}
}

// rig_answer_as answers request id as worker session by (what the agent does
// with `term session answer` from inside its session).
rig_answer_as :: proc(by: u32, id: u64, text: string) -> bool {
	conn: Cli
	if !cli_conn(&conn) do return false
	defer cli_close(&conn)
	b: [256]u8
	w := ipc.wire_writer(b[:])
	proto.enc_answer(&w, {by = by, id = id, text = text})
	cli_send(&conn, proto.MSG_ANSWER, ipc.wire_bytes_written(&w))
	for _ in 0 ..< 50 {
		f, got := cli_frame(&conn, 100)
		if got && (f.kind == proto.MSG_OK || f.kind == proto.MSG_FAIL) do return f.kind == proto.MSG_OK
	}
	return false
}

// rig_wait_screen waits (up to ms) until session id's screen shows text.
rig_wait_screen :: proc(id: u32, text: string, ms := 5000) -> bool {
	for _ in 0 ..< ms / 50 {
		snap, _, _ := cli_snapshot(id)
		for row in snap.screen do for run in row.runs do if strings.contains(run.text, text) do return true
		time.sleep(50 * time.Millisecond)
	}
	return false
}
