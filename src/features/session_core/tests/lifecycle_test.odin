package feature_session_core_tests

// Create, paint, input, detach/re-attach, kill and program exit through all
// three tiers.

import "core:testing"
import "core:time"
import client "../../session_client"
import session "../../session"
import proto "../../session_proto"
import ipc "../../../platform/ipc"

// view_attached waits until the core confirmed sess; its session id or 0. The
// bound is what a loaded machine may need for the create round trip (spawn,
// attach, first paint), never a promise about speed.
view_attached :: proc(v: ^View, sess: ^session.Terminal_Session, ms := 10_000) -> u32 {
	deadline := time.tick_now()._nsec + i64(ms) * 1_000_000
	for time.tick_now()._nsec < deadline {
		if id := view_id(v, sess); id != 0 && client.client_link_of(&v.c, sess).state == .Attached do return id
		view_pump(v, 5)
	}
	return 0
}

@(test)
test_create_paint_live_input :: proc(t: ^testing.T) {
	tiers := tiers_start()
	a := view_open()
	sa := view_sh(a, "printf 'first-out'; read x; printf 'got:%s' \"$x\"; sleep 30")
	id := view_attached(a, sa)
	testing.expect(t, id != 0, "create attaches")
	testing.expect(t, view_wait_screen(a, sa, "first-out"), "output reaches the creating viewer")

	b := view_open()
	sb := client.client_attach(&b.c, {id = id, size = {cols = 80, rows = 24}})
	testing.expect(t, view_attached(b, sb) == id, "second viewer attaches")
	testing.expect(t, view_wait_screen(b, sb, "first-out"), "first paint shows earlier output")

	session.session_write_string(sa, "typed\n")
	testing.expect(t, view_wait_screen(a, sa, "typed"), "tty echo reaches the typist")
	testing.expect(t, view_wait_screen(a, sa, "got:typed"), "program read the input")
	testing.expect(t, view_wait_screen(b, sb, "got:typed"), "live output reaches the other viewer")
	view_close(b)
	view_close(a)
	testing.expect(t, tiers_stop(tiers), "tiers end and remove the dir")
}

@(test)
test_detach_reattach :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "printf 'kept-output'; sleep 30")
	id := view_attached(v, s)
	testing.expect(t, view_wait_screen(v, s, "kept-output"), "output")
	mark := len(v.log)
	client.client_release(&v.c, s, false)
	got := false
	for i := mark; !got; {
		i = view_wait(v, .Row, id, 3000, i)
		if i < 0 do break
		got = !v.log[i].attached && v.log[i].state != .Exited
		i += 1
	}
	testing.expect(t, got, "row says detached, still running")

	s2 := client.client_attach(&v.c, {id = id, size = {cols = 80, rows = 24}})
	testing.expect(t, view_attached(v, s2) == id, "re-attach")
	testing.expect(t, view_wait_screen(v, s2, "kept-output"), "paint shows prior output")
	view_close(v)
	testing.expect(t, tiers_stop(tiers), "tiers end")
}

@(test)
test_kill_removes_session :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_spawn(v, {"/bin/sleep", "30"})
	id := view_attached(v, s)
	pid := u32(0)
	for i := 0; pid == 0; i += 1 {
		i = view_wait(v, .Row, id, 3000, i)
		if i < 0 do break
		pid = v.log[i].pid
	}
	testing.expect(t, pid_alive(pid), "program runs")
	testing.expect(t, cli_kill(id), "CLI kill answered OK")
	testing.expect(t, view_wait(v, .Removed, id) >= 0, "viewer told REMOVED")
	testing.expect(t, view_wait(v, .Closed) >= 0, "attach channel closed")
	for _ in 0..<200 {
		if !pid_alive(pid) do break
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, !pid_alive(pid), "program gone")
	ids: [8]u32
	testing.expect_value(t, len(cli_list_ids(ids[:])), 0)
	view_close(v)
	testing.expect(t, tiers_stop(tiers), "tiers end")
}

@(test)
test_program_exit_closes :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "printf bye; exit 3")
	id := view_attached(v, s)
	testing.expect(t, id != 0, "attached")
	testing.expect(t, view_wait(v, .Closed) >= 0, "CLOSE on exit")
	i := view_wait_row(v, id, .Exited)
	testing.expect(t, i >= 0 && v.log[i].exit_code == 3, "row Exited with the code")
	testing.expect(t, contains(screen_text(s), "bye"), "last output arrived before CLOSE")
	view_close(v)
	testing.expect(t, tiers_stop(tiers), "tiers end")
}

@(test)
test_list_waits_for_proc_info :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_spawn(v, {"/bin/sleep", "30"})
	id := view_attached(v, s)
	for i := 0; ; i += 1 {
		i = view_wait(v, .Row, id, 3000, i)
		if i < 0 || v.log[i].pid != 0 do break
	}
	conn: Cli
	testing.expect(t, cli_conn(&conn), "CLI link")
	// The name can lag one PROC_INFO round trip on a loaded machine (before the
	// child owns the tty the holder has only its own name to report): ask LIST
	// again while it settles, but keep the same assertions on the row.
	row: proto.Session_Row
	found := false
	deadline := time.tick_now()._nsec + 5_000_000_000
	for time.tick_now()._nsec < deadline {
		r, count, ok := cli_list(&conn)
		if !ok || count != 1 do break
		row = proto.dec_row(&r)
		if row.process == "sleep" {
			found = true
			break
		}
		time.sleep(20 * time.Millisecond)
	}
	testing.expect(t, found, "LIST reports the foreground program")
	testing.expect(t, row.active, "a non-shell foreground program is active")
	testing.expect_value(t, row.state, proto.Session_State.Busy)
	cli_close(&conn)
	view_close(v)
	testing.expect(t, tiers_stop(tiers), "tiers end")
}

// A window sizes a new pane before the core answers the create: that size must
// reach the program, not the size the create asked for.
@(test)
test_resize_while_pending_reaches_program :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "sleep 0.3; stty size; sleep 30")
	session.session_resize(s, 132, 40)
	testing.expect(t, view_attached(v, s) != 0, "create attaches")
	ok := view_wait_screen(v, s, "40 132")
	testing.expect(t, ok, "the program sees the size set while pending")
	view_close(v)
	testing.expect(t, tiers_stop(tiers), "tiers end and remove the dir")
}
