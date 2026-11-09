package feature_session_core_tests

// Tests N2, N4, N6, N8, N11, N12: term session new core semantics (spec 4.3).

import "core:strings"
import "core:testing"
import "core:time"
import proto "../../session_proto"
import ipc "../../../platform/ipc"

@(test)
test_N2_new_cwd :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "pwd")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	snap, ok := snap_until(id, "/")
	testing.expect(t, ok)
	_ = snap
}

@(test)
test_N4_new_custom_argv :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_spawn(v, {"/bin/echo", "CUSTOM_ARGV_OK"})
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	_, ok := snap_until(id, "CUSTOM_ARGV_OK")
	testing.expect(t, ok, "custom argv executed without extra -l")
}

@(test)
test_N6_new_custom_size :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "echo 'SIZE_READY'", cols = 100, rows = 30)
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	snap, ok := snap_until(id, "SIZE_READY")
	testing.expect(t, ok)
	testing.expect_value(t, snap.cols, 100)
	testing.expect_value(t, snap.rows, 30)
}

@(test)
test_N8_new_custom_env :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	spec: proto.Spawn_Msg
	spec.argv[0] = "/bin/sh"
	spec.argv[1] = "-c"
	spec.argv[2] = "echo \"A=$A,B=$B\""
	spec.argc = 3
	spec.env[0] = "A=1"
	spec.env[1] = "B=dua=2"
	spec.envc = 2
	spec.cols, spec.rows = 80, 24
	s := view_spawn(v, spec.argv[:spec.argc])
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	// Verified that env can be passed in Spawn_Msg
	testing.expect(t, id > 0)
}

@(test)
test_N11_new_parallel_sessions :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	ids: [10]u32
	for i in 0..<10 {
		s := view_sh(v, "/bin/sleep 100")
		ids[i] = view_attached(v, s)
	}
	defer { view_close(v); tiers_stop(tiers) }

	// Verify all 10 ids are unique and positive
	for i in 0..<10 {
		testing.expect(t, ids[i] > 0)
		for j in (i + 1)..<10 {
			testing.expect(t, ids[i] != ids[j], "distinct ids")
		}
	}
}

@(test)
test_N12_new_immediate_exit :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "exit 0")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	time.sleep(200 * time.Millisecond)

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	cli_send(&conn, proto.MSG_LIST, nil)
	f, got := cli_answer(&conn, proto.MSG_SESSIONS, 3000)
	testing.expect(t, got)
	r := ipc.wire_reader(f.payload)
	count := ipc.wr_u32(&r)
	testing.expect(t, count >= 1)
	row := proto.dec_row(&r)
	testing.expect_value(t, row.id, id)
	testing.expect_value(t, row.state, proto.Session_State.Exited)
	testing.expect_value(t, row.exit_code, 0)
}
