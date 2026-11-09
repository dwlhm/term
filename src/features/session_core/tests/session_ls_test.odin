package feature_session_core_tests

// Tests L1, L4, L6: term session ls core mechanics (spec 4.5, L1, L4, L6).

import "core:testing"
import "core:time"
import proto "../../session_proto"
import ipc "../../../platform/ipc"

@(test)
test_L1_ls_empty_sessions :: proc(t: ^testing.T) {
	tiers := tiers_start()
	defer tiers_stop(tiers)

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	cli_send(&conn, proto.MSG_LIST, nil)
	f, got := cli_answer(&conn, proto.MSG_SESSIONS, 3000)
	testing.expect(t, got)
	r := ipc.wire_reader(f.payload)
	count := ipc.wr_u32(&r)
	testing.expect_value(t, count, 0)
}

@(test)
test_L4_ls_held_by_controller :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "echo READY; /bin/sleep 100")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	_, ready := snap_until(id, "READY")
	testing.expect(t, ready)
	time.sleep(100 * time.Millisecond)

	conn1, conn2: Cli
	testing.expect(t, cli_conn(&conn1))
	testing.expect(t, cli_conn(&conn2))
	defer { cli_close(&conn1); cli_close(&conn2) }

	// conn1 holds lease
	lbuf: [64]u8
	lw := ipc.wire_writer(lbuf[:])
	proto.enc_lease_req(&lw, {id = id, owner = "agent:auto"})
	cli_send(&conn1, proto.MSG_LEASE, ipc.wire_bytes_written(&lw))
	_, leased := cli_answer(&conn1, proto.MSG_OK, 3000)
	testing.expect(t, leased, "leased")

	// conn2 requests list
	cli_send(&conn2, proto.MSG_LIST, nil)
	f, got := cli_answer(&conn2, proto.MSG_SESSIONS, 3000)
	testing.expect(t, got)
	r := ipc.wire_reader(f.payload)
	count := ipc.wr_u32(&r)
	testing.expect(t, count >= 1)
	row := proto.dec_row(&r)
	testing.expect_value(t, row.controller, "agent:auto")
}

@(private = "file")
_get_snap_gen :: proc(conn: ^Cli, id: u32) -> (u64, bool) {
	buf: [32]u8
	w := ipc.wire_writer(buf[:])
	proto.enc_snapshot_req(&w, {id = id, history = 0, since = -1})
	cli_send(conn, proto.MSG_SNAPSHOT, ipc.wire_bytes_written(&w))
	f, got := cli_answer(conn, proto.MSG_SNAPSHOT_RESULT, 3000)
	if !got do return 0, false
	r := ipc.wire_reader(f.payload)
	snap := proto.dec_snapshot(&r, context.temp_allocator)
	return snap.gen, true
}

@(test)
test_L6_ls_does_not_mutate_session :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "echo 'STABLE'; /bin/sleep 100")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	_, ready := snap_until(id, "STABLE")
	testing.expect(t, ready)
	time.sleep(100 * time.Millisecond)

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	gen1, ok1 := _get_snap_gen(&conn, id)
	testing.expect(t, ok1)

	cli_send(&conn, proto.MSG_LIST, nil)
	_, got_list := cli_answer(&conn, proto.MSG_SESSIONS, 3000)
	testing.expect(t, got_list)

	gen2, ok2 := _get_snap_gen(&conn, id)
	testing.expect(t, ok2)
	testing.expect_value(t, gen1, gen2)
}
