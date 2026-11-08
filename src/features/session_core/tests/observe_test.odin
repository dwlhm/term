package feature_session_core_tests

// Verification of `term session observe` (MSG_OBSERVE / MSG_OBSERVE_RESULT).

import "core:strings"
import "core:testing"
import "core:time"
import client "../../session_client"
import proto "../../session_proto"
import ipc "../../../platform/ipc"

cli_observe :: proc(id: u32, lines: u32 = 0) -> (res: proto.Observe_Result, ok: bool, code: proto.Fail_Code) {
	conn: Cli
	if !cli_conn(&conn) do return
	defer cli_close(&conn)
	b: [8]u8
	w := ipc.wire_writer(b[:])
	ipc.ww_u32(&w, id)
	ipc.ww_u32(&w, lines)
	cli_send(&conn, proto.MSG_OBSERVE, b[:])
	for {
		f, got := cli_frame(&conn, 4000)
		if !got do return
		if f.kind == proto.MSG_OBSERVE_RESULT {
			r := ipc.wire_reader(f.payload)
			res = proto.dec_observe_result(&r)
			return res, r.ok, {}
		}
		if f.kind == proto.MSG_FAIL {
			r := ipc.wire_reader(f.payload)
			_ = ipc.wr_u32(&r)
			return {}, false, proto.Fail_Code(ipc.wr_u8(&r))
		}
	}
}

@(test)
test_observe_session_metadata_and_screen :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "echo HELLO_OBSERVE_TEST; /bin/sleep 1")
	id := view_attached(v, s)
	defer {
		view_close(v)
		tiers_stop(tiers)
	}

	found := false
	for _ in 0..<50 {
		res, ok, _ := cli_observe(id)
		if ok && strings.contains(res.text, "HELLO_OBSERVE_TEST") {
			found = true
			testing.expect(t, res.row.id == id, "id matches")
			testing.expect(t, res.cols > 0 && res.rows > 0, "dimensions populated")
			testing.expect(t, !res.is_alt, "normal screen is not alt")
			break
		}
		time.sleep(20 * time.Millisecond)
	}
	testing.expect(t, found, "observe retrieved output text")
}

@(test)
test_observe_alt_screen_preserves_state :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "printf '\\033[?1049h\\033[HALT_OBSERVE_SCREEN\\n'; /bin/sleep 2; printf '\\033[?1049l'")
	id := view_attached(v, s)
	defer {
		view_close(v)
		tiers_stop(tiers)
	}

	found_alt := false
	for _ in 0..<50 {
		res, ok, _ := cli_observe(id)
		if ok && res.is_alt && strings.contains(res.text, "ALT_OBSERVE_SCREEN") {
			found_alt = true
			break
		}
		time.sleep(30 * time.Millisecond)
	}
	testing.expect(t, found_alt, "observe accurately reflected alt screen and text without side-effects")
}

@(test)
test_observe_unknown_session_returns_not_found :: proc(t: ^testing.T) {
	tiers := tiers_start()
	defer tiers_stop(tiers)

	_, ok, code := cli_observe(999999)
	testing.expect(t, !ok, "unknown session must not succeed")
	testing.expect(t, code == .Not_Found, "unknown session returns Not_Found")
}
