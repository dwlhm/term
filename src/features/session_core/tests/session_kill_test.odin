package feature_session_core_tests

// Tests K1–K6: term session kill mechanics (spec 4.4, K1–K6).

import "core:strings"
import "core:testing"
import "core:time"
import proto "../../session_proto"
import ipc "../../../platform/ipc"

@(private = "file")
_send_kill :: proc(
	conn: ^Cli,
	id: u32,
) -> (
	ok: bool,
	fail_code: proto.Fail_Code,
	reason: string,
) {
	buf: [32]u8
	w := ipc.wire_writer(buf[:])
	ipc.ww_u32(&w, id)
	cli_send(conn, proto.MSG_KILL, ipc.wire_bytes_written(&w))
	f, got := cli_answer(conn, proto.MSG_OK, 3000)
	if !got do return false, .Timeout, "timeout"
	if f.kind == proto.MSG_OK do return true, .Bad_Request, ""
	return false, cli_fail_code(f.payload), cli_fail_reason(f.payload)
}

@(test)
test_K1_kill_live_session :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "/bin/sleep 100")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	ok, _, _ := _send_kill(&conn, id)
	testing.expect(t, ok, "kill live session ok")

	// Snapshot fails with Not_Found
	buf: [32]u8
	w := ipc.wire_writer(buf[:])
	proto.enc_snapshot_req(&w, {id = id, history = 0, since = -1})
	cli_send(&conn, proto.MSG_SNAPSHOT, ipc.wire_bytes_written(&w))
	f, got := cli_answer(&conn, proto.MSG_FAIL, 3000)
	testing.expect(t, got)
	testing.expect_value(t, cli_fail_code(f.payload), proto.Fail_Code.Not_Found)
}

@(test)
test_K2_kill_twice_fails :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "/bin/sleep 100")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	ok, _, _ := _send_kill(&conn, id)
	testing.expect(t, ok, "first kill ok")

	// Second kill returns Not_Found
	ok2, code, _ := _send_kill(&conn, id)
	testing.expect(t, !ok2, "second kill fails")
	testing.expect_value(t, code, proto.Fail_Code.Not_Found)
}

@(test)
test_K3_kill_exited_session :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "echo 'DONE'; exit 0")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	_, ready := snap_until(id, "DONE")
	testing.expect(t, ready)
	time.sleep(100 * time.Millisecond)

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	// Kill exited session
	ok, _, _ := _send_kill(&conn, id)
	testing.expect(t, ok, "kill exited session ok")

	// Verify it's gone
	ok2, code, _ := _send_kill(&conn, id)
	testing.expect(t, !ok2)
	testing.expect_value(t, code, proto.Fail_Code.Not_Found)
}

@(test)
test_K5_kill_during_lease_sends_removed :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "/bin/sleep 100")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	conn1, conn2: Cli
	testing.expect(t, cli_conn(&conn1))
	testing.expect(t, cli_conn(&conn2))
	defer { cli_close(&conn1); cli_close(&conn2) }

	// conn1 holds lease
	lbuf: [64]u8
	lw := ipc.wire_writer(lbuf[:])
	proto.enc_lease_req(&lw, {id = id, owner = "flow:test"})
	cli_send(&conn1, proto.MSG_LEASE, ipc.wire_bytes_written(&lw))
	_, leased := cli_answer(&conn1, proto.MSG_OK, 3000)
	testing.expect(t, leased, "leased")

	// conn2 kills the session (allowed by lifecycle)
	ok, _, _ := _send_kill(&conn2, id)
	testing.expect(t, ok, "kill during lease allowed")

	// conn1 receives LEASE_EVENT with kind = Removed (4)
	f, got := cli_answer(&conn1, proto.MSG_LEASE_EVENT, 3000)
	testing.expect(t, got, "lease event received")
	r := ipc.wire_reader(f.payload)
	ev := proto.dec_lease_event(&r)
	testing.expect_value(t, ev.kind, proto.Lease_Event_Kind.Removed)
}

@(test)
test_K6_kill_deaf_program_terminated :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	// Ignore SIGHUP and SIGTERM
	s := view_sh(v, "trap '' HUP TERM; echo READY; /bin/sleep 100")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	_, ready := snap_until(id, "READY")
	testing.expect(t, ready)
	time.sleep(100 * time.Millisecond)

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	ok, _, _ := _send_kill(&conn, id)
	testing.expect(t, ok, "kill terminates deaf program via SIGKILL")
}
