package feature_session_core_tests

// An owned (private) session dir ends its sessions with the owner's last
// viewer link, however the owner went; an unowned dir keeps them.

import "core:os"
import "core:testing"
import "core:time"
import client "../../session_client"
import proto "../../session_proto"

// leave_a_background_session: a viewer starts a program, detaches it (nobody
// shows it) and disconnects without killing anything, as a crashed owner would.
@(private = "file")
leave_a_background_session :: proc(t: ^testing.T) -> (pid: u32) {
	v := view_open()
	s := view_sh(v, "echo up; exec /bin/sleep 30")
	id := view_attached(v, s)
	testing.expect(t, view_wait_screen(v, s, "up"), "program runs")
	for i := 0; pid == 0 && i >= 0; {
		i = view_wait(v, .Row, id, 3000, i)
		if i >= 0 {
			pid = v.log[i].pid
			i += 1
		}
	}
	client.client_release(&v.c, s, false)
	view_pump(v, 100)
	view_close(v)
	return
}

@(test)
test_owned_dir_ends_sessions_with_its_owner :: proc(t: ^testing.T) {
	os.set_env(proto.SESSION_OWNED_ENV, "1")
	defer os.unset_env(proto.SESSION_OWNED_ENV)
	tiers := tiers_start()
	pid := leave_a_background_session(t)
	testing.expect(t, pid > 0, "program pid")
	gone := false
	for _ in 0..<300 {
		if gone = !pid_alive(pid); gone do break
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, gone, "the program ended with its owner's last viewer")
	rows: [8]proto.Session_Row
	testing.expect_value(t, len(cli_list_rows(rows[:])), 0)
	testing.expect(t, tiers_stop(tiers), "tiers end and remove the dir")
}

@(test)
test_unowned_dir_keeps_background_sessions :: proc(t: ^testing.T) {
	tiers := tiers_start()
	pid := leave_a_background_session(t)
	time.sleep(300 * time.Millisecond)
	testing.expect(t, pid_alive(pid), "the program keeps running in the background")
	rows: [8]proto.Session_Row
	testing.expect_value(t, len(cli_list_rows(rows[:])), 1)
	testing.expect(t, tiers_stop(tiers), "tiers end")
}
