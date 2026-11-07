package feature_session_core_tests

// `term session tell|cancel` through a real core: a shell target with OSC 133
// integration, blocking results, rejection, cancel and a target that dies.

import "core:strings"
import "core:testing"
import session "../../session"
import ipc "../../../platform/ipc"

@(test)
test_tell_shell_blocking_result :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	id := view_attached(v, view_sh(v, TELL_REPL))
	// Sent right away: the shell may not show its first prompt yet (Starting).
	conn: ipc.Stream_Conn
	res, ok := tell_send(&conn, {to = id, body = "printf 'a\\nb\\n'; sh -c 'exit 3'"})
	testing.expect(t, ok && res.phase == .Accepted, "accepted")
	res, ok = tell_next(&conn, 5000)
	testing.expect(t, ok && res.phase == .Finished, "finished")
	testing.expect_value(t, res.status, ipc.Tell_Status.Failed)
	testing.expect_value(t, res.exit_code, 3)
	testing.expect_value(t, res.text, "a\nb\n")
	ipc.stream_conn_destroy(&conn)

	res, ok = tell_send(&conn, {to = id, body = "true"})
	res, ok = tell_next(&conn, 5000)
	testing.expect(t, ok && res.status == .Done && res.exit_code == 0, "second request on a free shell")
	ipc.stream_conn_destroy(&conn)
	view_close(v)
	testing.expect(t, tiers_stop(tiers), "tiers end and remove the dir")
}

@(test)
test_tell_rejects_and_cancel :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	id := view_attached(v, view_sh(v, TELL_REPL))
	conn, other: ipc.Stream_Conn
	res, _ := tell_send(&conn, {to = id, body = "sleep 30"})
	testing.expect(t, res.phase == .Accepted, "first accepted")
	busy, _ := tell_send(&other, {to = id, body = "true"})
	testing.expect(t, busy.phase == .Rejected && busy.reject == .Busy, "second rejected: busy")
	ipc.stream_conn_destroy(&other)
	multi, _ := tell_send(&other, {to = id + 1000, body = "x"})
	testing.expect(t, multi.phase != .Accepted, "unknown target is no request")
	ipc.stream_conn_destroy(&other)

	obs, _, _ := cli_observe(id)
	testing.expect(t, obs.row.request.serving == 1 && obs.row.request.serving_id == res.id, "row shows the served request")
	testing.expect(t, tell_cancel(res.id), "cancel")
	res, _ = tell_next(&conn, 3000)
	testing.expect(t, res.phase == .Finished && res.status == .Cancelled, "cancelled result")
	testing.expect(t, !tell_cancel(res.id), "cancel twice: no such request")
	ipc.stream_conn_destroy(&conn)
	view_close(v)
	testing.expect(t, tiers_stop(tiers), "tiers end and remove the dir")
}

@(test)
test_tell_target_dies_and_no_integration :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	id := view_attached(v, view_sh(v, TELL_REPL))
	conn: ipc.Stream_Conn
	res, _ := tell_send(&conn, {to = id, body = "sleep 30"})
	testing.expect(t, res.phase == .Accepted, "accepted")
	testing.expect(t, cli_kill(id), "kill target")
	res, _ = tell_next(&conn, 3000)
	testing.expect(t, res.phase == .Finished && res.status == .Error, "error: target gone")
	ipc.stream_conn_destroy(&conn)

	plain := view_attached(v, view_sh(v, "/bin/sleep 30")) // never shows a prompt
	res, _ = tell_send(&conn, {to = plain, body = "ls", timeout_ms = 300})
	testing.expect(t, res.phase == .Accepted, "a young session may still start its shell")
	res, _ = tell_next(&conn, 3000)
	testing.expect(t, res.status == .Error && strings.contains(res.text, "OSC 133"), "no prompt came: error")
	ipc.stream_conn_destroy(&conn)
	view_close(v)
	testing.expect(t, tiers_stop(tiers), "tiers end and remove the dir")
}

@(private = "file")
LONG :: "0123456789-abcdefghij-0123456789-abcdefghij-0123456789"

// A window that changes the session's size while a command runs reflows the
// screen: the output still starts on the command's first line.
@(test)
test_tell_output_survives_window_resize :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	tell_view_sess = view_sh(v, TELL_REPL, 80, 12)
	id := view_attached(v, tell_view_sess)
	noise := tell_run(v, id, "seq 1 8")
	testing.expect(t, noise.status == .Done && noise.text == "1\n2\n3\n4\n5\n6\n7\n8\n", "noise on screen first")
	res := tell_run(v, id, "printf '%s\\n' " + LONG + "; sleep 0.4; echo tail", proc(v: ^View) {
		session.session_resize(tell_view_sess, 20, 12) // the long line wraps over three rows
		view_pump(v, 150)
		session.session_resize(tell_view_sess, 100, 6)
		view_pump(v, 50)
	})
	testing.expect_value(t, res.status, ipc.Tell_Status.Done)
	testing.expect_value(t, res.text, LONG + "\ntail\n")
	view_close(v)
	testing.expect(t, tiers_stop(tiers), "tiers end and remove the dir")
}

// A command that opens a full-screen program: what it drew there is no output.
@(test)
test_tell_output_around_full_screen_program :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	tell_view_sess = view_sh(v, TELL_REPL, 80, 12)
	id := view_attached(v, tell_view_sess)
	res := tell_run(v, id, `printf 'pre\n\033[?1049hSCREEN'; sleep 0.2; printf '\033[?1049l'; echo post`)
	testing.expect_value(t, res.text, "pre\npost\n")
	// Resized while the program hides the main screen: the hidden screen
	// reflows with its saved cursor, so the start is still followed.
	res = tell_run(v, id, `printf 'pre\n\033[?1049h'; sleep 0.4; printf '\033[?1049l'; echo post`, proc(v: ^View) {
		session.session_resize(tell_view_sess, 30, 12)
		view_pump(v, 50)
	})
	testing.expect_value(t, res.text, "pre\npost\n")
	view_close(v)
	testing.expect(t, tiers_stop(tiers), "tiers end and remove the dir")
}

// More output than the scrollback holds: the tail, marked.
@(test)
test_tell_output_longer_than_scrollback :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	id := view_attached(v, view_sh(v, TELL_REPL))
	res := tell_run(v, id, "seq 1 3000")
	testing.expect(t, strings.has_prefix(res.text, "[… earlier output left the scrollback]\n"), "head marked")
	testing.expect(t, strings.has_suffix(res.text, "\n2999\n3000\n") && !strings.contains(res.text, "\n1\n"), "tail kept")
	view_close(v)
	testing.expect(t, tiers_stop(tiers), "tiers end and remove the dir")
}
