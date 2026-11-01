package feature_session_core_tests

// `term session signal|resize` requests (MSG_SESSION_SIGNAL / MSG_SESSION_SIZE).

import "core:testing"
import "core:time"
import client "../../session_client"
import ipc "../../../platform/ipc"

// cli_ctl sends one channel-0 request: id + extra bytes; OK → ok, FAIL → its code.
@(private = "file")
cli_ctl :: proc(kind: u8, id: u32, extra: []u8 = nil) -> (ok: bool, code: ipc.Fail_Code) {
	conn: ipc.Stream_Conn
	if !cli_conn(&conn) do return
	defer ipc.stream_conn_destroy(&conn)
	b: [64]u8
	w := ipc.wire_writer(b[:])
	ipc.ww_u32(&w, id)
	n := w.n + copy(b[w.n:], extra) // raw, no length prefix
	ipc.stream_send(&conn, kind, 0, b[:n])
	for {
		f, got := client.client_wait_frame(&conn, 3000)
		if !got do return
		if f.kind == ipc.MSG_OK do return true, {}
		if f.kind == ipc.MSG_FAIL {
			r := ipc.wire_reader(f.payload)
			_ = ipc.wr_u32(&r)
			return false, ipc.Fail_Code(ipc.wr_u8(&r))
		}
	}
}

@(private = "file")
sig_bytes :: proc(sig: i32) -> [4]u8 {
	b: [4]u8
	w := ipc.wire_writer(b[:])
	ipc.ww_i32(&w, sig)
	return b
}

@(private = "file")
size_bytes :: proc(cols, rows: u16) -> [8]u8 {
	b: [8]u8
	w := ipc.wire_writer(b[:])
	ipc.enc_size(&w, {cols = cols, rows = rows})
	return b
}

// cli_screen reads a session's visible screen without attaching.
@(private = "file")
cli_screen :: proc(id: u32) -> string {
	conn: ipc.Stream_Conn
	if !cli_conn(&conn) do return ""
	defer ipc.stream_conn_destroy(&conn)
	b: [8]u8
	w := ipc.wire_writer(b[:])
	ipc.ww_u32(&w, id)
	ipc.ww_u32(&w, 0)
	ipc.stream_send(&conn, ipc.MSG_READ, 0, b[:])
	for {
		f, got := client.client_wait_frame(&conn, 3000)
		if !got || f.kind == ipc.MSG_FAIL do return ""
		if f.kind == ipc.MSG_TEXT do return string(f.payload) // temp: caller checks before the next read
	}
}

@(private = "file")
wait_cli_screen :: proc(id: u32, want: string, ms := 5000) -> bool {
	for _ in 0..<ms / 20 {
		if contains(cli_screen(id), want) do return true
		time.sleep(20 * time.Millisecond)
	}
	return false
}

@(test)
test_signal_reaches_the_foreground_job :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "trap 'echo TRAPPED' INT; echo READY; /bin/sleep 30; echo AFTER; /bin/sleep 30")
	id := view_attached(v, s)
	testing.expect(t, view_wait_screen(v, s, "READY"), "ready")
	time.sleep(100 * time.Millisecond)
	int_b := sig_bytes(2)
	ok, _ := cli_ctl(ipc.MSG_SESSION_SIGNAL, id, int_b[:])
	testing.expect(t, ok, "signal answered OK")
	testing.expect(t, view_wait_screen(v, s, "AFTER"), "sleep (the foreground job) got SIGINT")

	bad := sig_bytes(0)
	_, code := cli_ctl(ipc.MSG_SESSION_SIGNAL, id, bad[:])
	testing.expect_value(t, code, ipc.Fail_Code.Bad_Request)
	_, code = cli_ctl(ipc.MSG_SESSION_SIGNAL, id) // no signal number
	testing.expect_value(t, code, ipc.Fail_Code.Bad_Request)
	_, code = cli_ctl(ipc.MSG_SESSION_SIGNAL, 999, int_b[:])
	testing.expect_value(t, code, ipc.Fail_Code.Not_Found)

	// A window shows it: its size leads, a resize request is refused.
	size := size_bytes(100, 30)
	_, code = cli_ctl(ipc.MSG_SESSION_SIZE, id, size[:])
	testing.expect_value(t, code, ipc.Fail_Code.Busy)

	term_b := sig_bytes(15)
	ok, _ = cli_ctl(ipc.MSG_SESSION_SIGNAL, id, term_b[:])
	testing.expect(t, ok, "TERM answered OK")
	testing.expect(t, view_wait_row(v, id, .Exited) >= 0, "TERM ends the program")
	_, code = cli_ctl(ipc.MSG_SESSION_SIGNAL, id, term_b[:])
	testing.expect_value(t, code, ipc.Fail_Code.Exited)
	_, code = cli_ctl(ipc.MSG_SESSION_SIZE, id, size[:])
	testing.expect_value(t, code, ipc.Fail_Code.Exited)
	view_close(v)
	testing.expect(t, tiers_stop(tiers), "tiers end")
}

@(test)
test_resize_a_background_session :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "trap 'stty size' WINCH; echo READY; while :; do /bin/sleep 0.05; done")
	id := view_attached(v, s)
	testing.expect(t, view_wait_screen(v, s, "READY"), "ready")
	client.client_release(&v.c, s, false)

	// The DETACH travels on the viewer's link: Busy until the core handled it.
	size := size_bytes(100, 30)
	ok: bool
	code: ipc.Fail_Code
	for _ in 0..<150 {
		ok, code = cli_ctl(ipc.MSG_SESSION_SIZE, id, size[:])
		if ok || code != .Busy do break
		view_pump(v, 20)
	}
	testing.expect(t, ok, "resize answered OK once nobody shows it")
	testing.expect(t, wait_cli_screen(id, "30 100"), "the program sees 100x30")

	zero := size_bytes(0, 30)
	_, code = cli_ctl(ipc.MSG_SESSION_SIZE, id, zero[:])
	testing.expect_value(t, code, ipc.Fail_Code.Bad_Request)
	_, code = cli_ctl(ipc.MSG_SESSION_SIZE, id, size[:4]) // short payload
	testing.expect_value(t, code, ipc.Fail_Code.Bad_Request)
	testing.expect(t, cli_kill(id), "kill")
	view_close(v)
	testing.expect(t, tiers_stop(tiers), "tiers end")
}
