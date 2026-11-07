package feature_session_core_tests

// A person steps into a session that serves a request: ^C cancels it with
// the output so far, typing takes it over, `send` counts as typing, and the
// viewer's Terminal answering a query is no person at all.

import "core:strings"
import "core:testing"
import session "../../session"
import ipc "../../../platform/ipc"

@(test)
test_human_ctrl_c_cancels_with_partial_output :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	tell_view_sess = view_sh(v, TELL_REPL)
	id := view_attached(v, tell_view_sess)
	res := tell_run(v, id, "echo before; sleep 5; echo after", proc(v: ^View) {
		view_pump(v, 200)
		session.session_write(tell_view_sess, {0x03})
		view_pump(v, 20)
	})
	testing.expect_value(t, res.status, ipc.Tell_Status.Cancelled)
	testing.expect_value(t, res.text, "before\n")
	view_close(v)
	testing.expect(t, tiers_stop(tiers), "tiers end and remove the dir")
}

@(test)
test_human_typing_and_send_take_over :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	tell_view_sess = view_sh(v, TELL_REPL)
	id := view_attached(v, tell_view_sess)
	res := tell_run(v, id, "sleep 1", proc(v: ^View) {
		session.session_write_string(tell_view_sess, "x")
		view_pump(v, 20)
	})
	testing.expect_value(t, res.status, ipc.Tell_Status.Interrupted)
	view_pump(v, 1200) // the typed x ran after sleep: back at the prompt
	res = tell_run(v, id, "sleep 1", proc(v: ^View) {
		cli_ctl(ipc.MSG_SEND, view_id(v, tell_view_sess), transmute([]u8)string("y"))
	})
	testing.expect_value(t, res.status, ipc.Tell_Status.Interrupted)
	view_close(v)
	testing.expect(t, tiers_stop(tiers), "tiers end and remove the dir")
}

// The program asks a kitty graphics query the core passes through: the
// window's Terminal answers it, and that answer must not end the request.
@(test)
test_viewer_reply_is_no_human_input :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	tell_view_sess = view_sh(v, TELL_REPL)
	id := view_attached(v, tell_view_sess)
	res := tell_run(v, id, `printf '\033_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\033\\'; sleep 0.5; echo ok`, proc(v: ^View) {
		view_pump(v, 300) // the window draws the output and answers the query
	})
	testing.expect_value(t, res.status, ipc.Tell_Status.Done)
	// The answer reached the program (the tty echoes it: the REPL never reads it).
	testing.expectf(t, strings.contains(res.text, "_Gi=31;OK") && strings.has_suffix(res.text, "ok\n"), "answer delivered: %q", res.text)
	view_close(v)
	testing.expect(t, tiers_stop(tiers), "tiers end and remove the dir")
}
