package feature_session_core_tests

// Virtual sessions: made over a connection, addressed by id, take requests
// through a worker speaking for them; refuse program-only verbs; an owned one
// ends with its owner's connection.

import "core:testing"
import client "../../session_client"
import ipc "../../../platform/ipc"

@(private = "file")
endpoint_new :: proc(conn: ^ipc.Stream_Conn, name: string, owned: bool) -> u32 {
	if !cli_conn(conn) do return 0
	b: [96]u8
	w := ipc.wire_writer(b[:])
	ipc.ww_str(&w, name); ipc.ww_bool(&w, owned)
	ipc.stream_send(conn, ipc.MSG_ENDPOINT, 0, ipc.wire_bytes_written(&w))
	for {
		f, got := client.client_wait_frame(conn, 3000)
		if !got || f.kind == ipc.MSG_FAIL do return 0
		if f.kind != ipc.MSG_OK do continue
		r := ipc.wire_reader(f.payload)
		return u32(ipc.wr_i32(&r))
	}
}

@(test)
test_endpoint_takes_requests_through_a_worker :: proc(t: ^testing.T) {
	tiers := tiers_start()
	ec, sc: ipc.Stream_Conn
	id := endpoint_new(&ec, "indexer", false)
	ipc.stream_conn_destroy(&ec) // not owned: stays
	testing.expect(t, id > 0, "made")
	obs, ok, _ := cli_observe(id)
	testing.expect(t, ok && obs.row.endpoint && obs.row.process == "indexer" && obs.row.state == .Idle, "its row")

	r0, _ := tell_send(&sc, {to = id, body = "x"})
	ipc.stream_conn_destroy(&sc)
	testing.expect_value(t, r0.reject, ipc.Tell_Reject.Not_Listening) // never a starting shell
	ok2, code := cli_ctl(ipc.MSG_SEND, id, transmute([]u8)string("ls\r"))
	testing.expect(t, !ok2 && code == .Bad_Request, "no program to type into")

	wc: ipc.Stream_Conn
	cli_conn(&wc)
	b: [8]u8
	w := ipc.wire_writer(b[:])
	ipc.ww_u32(&w, id); ipc.ww_u32(&w, 0)
	ipc.stream_send(&wc, ipc.MSG_NEXT, 0, ipc.wire_bytes_written(&w))
	ipc.stream_flush(&wc)
	for i := 0; i < 200; i += 1 {
		o, _, _ := cli_observe(id)
		if o.row.request.listening > 0 do break
	}
	res, _ := tell_send(&sc, {to = id, body = "index src/"})
	testing.expect(t, res.phase == .Accepted, "the app's worker took it")
	ipc.stream_conn_destroy(&sc)
	ipc.stream_conn_destroy(&wc)
	testing.expect(t, cli_kill(id), "killed")
	_, ok, _ = cli_observe(id)
	testing.expect(t, !ok, "gone")
	testing.expect(t, tiers_stop(tiers), "tiers end and remove the dir")
}

@(test)
test_endpoint_owned_ends_with_its_connection :: proc(t: ^testing.T) {
	tiers := tiers_start()
	ec: ipc.Stream_Conn
	id := endpoint_new(&ec, "app", true)
	_, ok, _ := cli_observe(id)
	testing.expect(t, ok, "alive while its owner is connected")
	ipc.stream_conn_destroy(&ec)
	gone := false
	for i := 0; i < 200 && !gone; i += 1 {
		_, still, _ := cli_observe(id)
		gone = !still
	}
	testing.expect(t, gone, "removed with its owner")
	testing.expect(t, tiers_stop(tiers), "tiers end and remove the dir")
}

// A planned restart keeps unowned endpoints under their ids, and with them
// the requests they work on; an owned one ended with the old core.
@(test)
test_endpoint_survives_planned_restart :: proc(t: ^testing.T) {
	tiers := tiers_start()
	ec, oc, wc, sc: ipc.Stream_Conn
	kept := endpoint_new(&ec, "kept", false)
	ipc.stream_conn_destroy(&ec)
	temp := endpoint_new(&oc, "temp", true)
	cli_conn(&wc)
	b: [8]u8
	w := ipc.wire_writer(b[:])
	ipc.ww_u32(&w, kept); ipc.ww_u32(&w, 0)
	ipc.stream_send(&wc, ipc.MSG_NEXT, 0, ipc.wire_bytes_written(&w))
	ipc.stream_flush(&wc)
	for i := 0; i < 200; i += 1 {
		o, _, _ := cli_observe(kept)
		if o.row.request.listening > 0 do break
	}
	cli_conn(&sc)
	bb: [64]u8
	ww := ipc.wire_writer(bb[:])
	ipc.enc_tell_req(&ww, {to = kept, body = "long job"}) // async
	ipc.stream_send(&sc, ipc.MSG_TELL, 0, ipc.wire_bytes_written(&ww))
	acc, _ := tell_next(&sc, 3000)
	ipc.stream_conn_destroy(&sc)
	testing.expect(t, acc.phase == .Accepted, "taken before the restart")

	tiers_core_restart_stop(tiers)
	ipc.stream_conn_destroy(&wc)
	ipc.stream_conn_destroy(&oc)
	tiers_core_start(tiers)
	obs, ok, _ := cli_observe(kept)
	testing.expect(t, ok && obs.row.endpoint && obs.row.process == "kept", "kept under its id")
	testing.expect_value(t, obs.row.request.serving, 1)
	_, temp_ok, _ := cli_observe(temp)
	testing.expect(t, !temp_ok, "the owned one ended with its owner")
	testing.expect(t, cli_kill(kept), "kill")
	testing.expect(t, tiers_stop(tiers), "tiers end and remove the dir")
}
