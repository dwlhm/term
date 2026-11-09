package feature_session_core_tests

// Tests R1, R2, R4, R5: term session resize core mechanics (spec 4.5, R1–R5).

import "core:fmt"
import "core:strings"
import "core:testing"
import proto "../../session_proto"
import ipc "../../../platform/ipc"

@(private = "file")
_send_size :: proc(
	conn: ^Cli,
	id: u32,
	cols, rows: u16,
) -> (ok: bool, fail_code: proto.Fail_Code, fail_msg: string) {
	buf: [32]u8
	w := ipc.wire_writer(buf[:])
	proto.enc_size_req(&w, {id = id, size = {cols = cols, rows = rows}})
	cli_send(conn, proto.MSG_SESSION_SIZE, ipc.wire_bytes_written(&w))
	f, got := cli_answer(conn, proto.MSG_OK, 3000)
	if !got do return false, .Timeout, "timeout"
	if f.kind == proto.MSG_OK do return true, .Bad_Request, ""
	return false, cli_fail_code(f.payload), cli_fail_reason(f.payload)
}

@(test)
test_R1_resize_background_session :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "echo READY")
	id := view_attached(v, s)
	// Detach view to make it a background session
	view_close(v)
	defer tiers_stop(tiers)

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	ok, _, _ := _send_size(&conn, id, 100, 30)
	testing.expect(t, ok, "resize background session ok")

	// Snapshot reflects new size
	buf: [32]u8
	w := ipc.wire_writer(buf[:])
	proto.enc_snapshot_req(&w, {id = id, history = 0, since = -1})
	cli_send(&conn, proto.MSG_SNAPSHOT, ipc.wire_bytes_written(&w))
	f, got := cli_answer(&conn, proto.MSG_SNAPSHOT_RESULT, 3000)
	testing.expect(t, got)
	r := ipc.wire_reader(f.payload)
	snap := proto.dec_snapshot(&r, context.temp_allocator)
	testing.expect_value(t, snap.cols, 100)
	testing.expect_value(t, snap.rows, 30)
}

@(test)
test_R2_resize_window_attached_fails :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "echo READY")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	// Session is attached in view v (non-observe)
	ok, code, msg := _send_size(&conn, id, 90, 25)
	testing.expect(t, !ok, "resize attached session fails")
	testing.expect_value(t, code, proto.Fail_Code.Busy)
	testing.expect(t, strings.contains(msg, "a window shows session"))
	testing.expect(t, strings.contains(msg, "resize the pane"))
}

@(test)
test_R4_resize_during_lease_rejected :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "echo READY")
	id := view_attached(v, s)
	view_close(v)
	defer tiers_stop(tiers)

	conn1, conn2: Cli
	testing.expect(t, cli_conn(&conn1))
	testing.expect(t, cli_conn(&conn2))
	defer { cli_close(&conn1); cli_close(&conn2) }

	// conn1 leases session
	lbuf: [64]u8
	lw := ipc.wire_writer(lbuf[:])
	proto.enc_lease_req(&lw, {id = id, owner = "flow:test"})
	cli_send(&conn1, proto.MSG_LEASE, ipc.wire_bytes_written(&lw))
	_, leased := cli_answer(&conn1, proto.MSG_OK, 3000)
	testing.expect(t, leased, "leased")

	// conn2 tries to resize -> rejected with Busy
	ok, code, msg := _send_size(&conn2, id, 100, 30)
	testing.expect(t, !ok, "rejected during lease")
	testing.expect_value(t, code, proto.Fail_Code.Busy)
	testing.expect(t, strings.contains(msg, "flow:test"))
}

@(test)
test_R5_resize_rapid_succession :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "echo READY; /bin/sleep 100")
	id := view_attached(v, s)
	view_close(v)
	defer tiers_stop(tiers)

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	// Send 20 rapid resizes
	for i in 1..=20 {
		cols := u16(80 + i)
		rows := u16(24 + (i % 5))
		ok, _, _ := _send_size(&conn, id, cols, rows)
		testing.expect(t, ok)
	}

	// Final size corresponds to 20th resize (cols = 100, rows = 24)
	buf: [32]u8
	w := ipc.wire_writer(buf[:])
	proto.enc_snapshot_req(&w, {id = id, history = 0, since = -1})
	cli_send(&conn, proto.MSG_SNAPSHOT, ipc.wire_bytes_written(&w))
	f, got := cli_answer(&conn, proto.MSG_SNAPSHOT_RESULT, 3000)
	testing.expect(t, got)
	r := ipc.wire_reader(f.payload)
	snap := proto.dec_snapshot(&r, context.temp_allocator)
	testing.expect_value(t, snap.cols, 100)
	testing.expect_value(t, snap.rows, 24)
}
