package feature_session_core_tests

// Tests W1, W3: term session whoami with core verification (spec 4.8).

import "core:testing"
import proto "../../session_proto"
import ipc "../../../platform/ipc"

@(test)
test_W1_whoami_valid_session_verified :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "echo READY")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	// Verify session id exists via snapshot
	buf: [32]u8
	w := ipc.wire_writer(buf[:])
	proto.enc_snapshot_req(&w, {id = id, history = 0, since = -1})
	cli_send(&conn, proto.MSG_SNAPSHOT, ipc.wire_bytes_written(&w))
	_, got := cli_answer(&conn, proto.MSG_SNAPSHOT_RESULT, 3000)
	testing.expect(t, got, "valid session found by core")
}

@(test)
test_W3_whoami_fake_session_returns_not_found :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "echo READY")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	// Bogus session 9999
	buf: [32]u8
	w := ipc.wire_writer(buf[:])
	proto.enc_snapshot_req(&w, {id = id + 9999, history = 0, since = -1})
	cli_send(&conn, proto.MSG_SNAPSHOT, ipc.wire_bytes_written(&w))
	f, got := cli_answer(&conn, proto.MSG_FAIL, 3000)
	testing.expect(t, got, "core returns fail")
	testing.expect_value(t, cli_fail_code(f.payload), proto.Fail_Code.Not_Found)
}
