package feature_session_core_tests

// A core that goes away and comes back, and viewers that break protocol.

import "core:sys/posix"
import "core:testing"
import "core:time"
import client "../../session_client"
import session "../../session"
import proto "../../session_proto"
import ipc "../../../platform/ipc"

@(test)
test_core_restart_restores_screen :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "printf 'before-restart'; read x; printf 'after:%s' \"$x\"; sleep 30")
	id := view_attached(v, s)
	testing.expect(t, view_wait_screen(v, s, "before-restart"), "output before the restart")
	tiers_core_restart_stop(tiers)
	testing.expect(t, view_wait(v, .Core_Lost) >= 0, "viewer notices the core is gone")
	tiers_core_start(tiers)
	testing.expect(t, client.client_reconnect(&v.c), "reconnect")
	testing.expect(t, view_attached(v, s) == id, "the same session is attached again")
	testing.expect(t, view_wait_screen(v, s, "before-restart"), "repaint keeps the screen")
	session.session_write_string(s, "x\n")
	testing.expect(t, view_wait_screen(v, s, "after:x"), "input and output flow again")

	w := view_open()
	sw := client.client_attach(&w.c, {id = id, size = {cols = 80, rows = 24}})
	testing.expect(t, view_attached(w, sw) == id, "a new viewer attaches")
	testing.expect(t, view_wait_screen(w, sw, "before-restart"), "a new viewer sees the restored screen")
	ids: [8]u32
	testing.expect_value(t, len(cli_list_ids(ids[:])), 1)
	view_close(w)
	view_close(v)
	testing.expect(t, tiers_stop(tiers), "tiers end")
}

@(test)
test_core_restart_preserves_elapsed :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "sleep 30")
	id := view_attached(v, s)
	testing.expect(t, id > 0, "session attached")

	time.sleep(1200 * time.Millisecond)

	tiers_core_restart_stop(tiers)
	testing.expect(t, view_wait(v, .Core_Lost) >= 0, "viewer notices the core is gone")
	tiers_core_start(tiers)

	rows: [8]proto.Session_Row
	got_rows := cli_wait_rows(rows[:])
	testing.expect_value(t, len(got_rows), 1)
	if len(got_rows) == 1 {
		testing.expect_value(t, got_rows[0].id, id)
		testing.expect(t, got_rows[0].elapsed_s >= 1, "elapsed_s survives restart and is >= 1")
	}

	view_close(v)
	testing.expect(t, tiers_stop(tiers), "tiers end")
}

// hostile_dropped sends bytes on a fresh link (after HELLO when hello is set)
// and reports whether the core closed it.
@(private = "file")
hostile_dropped :: proc(hello: bool, bytes: []u8) -> bool {
	fd: posix.FD
	if hello {
		ok: bool
		if fd, ok = client.client_dial(.Viewer, false); !ok do return false
	} else {
		buf, sbuf: [128]u8
		dir, _ := proto.session_dir(buf[:])
		sock, _ := proto.session_path(sbuf[:], dir, "core.sock")
		err: ipc.Ipc_Error
		if fd, err = ipc.ipc_connect(sock, 500); err != .None do return false
	}
	defer posix.close(fd)
	posix.send(fd, raw_data(bytes), uint(len(bytes)), {.NOSIGNAL})
	// A drop under load may take the core a while to notice; the assertion is
	// that it closes the socket, not that it is fast.
	deadline := time.tick_now()._nsec + 5_000_000_000
	for time.tick_now()._nsec < deadline {
		pfd := posix.pollfd{fd = fd, events = {.IN}}
		if posix.poll(&pfd, 1, 50) <= 0 do continue
		junk: [4096]u8
		n := posix.recv(fd, &junk[0], len(junk), {})
		if n == 0 || (n < 0 && posix.errno() != .EAGAIN) do return true
	}
	return false
}

@(test)
test_hostile_viewers_dropped :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "stty -echo; while read x; do printf 'echo:%s\\n' \"$x\"; done")
	testing.expect(t, view_attached(v, s) != 0, "a good viewer")
	oversize: [ipc.STREAM_HEADER]u8
	ipc.stream_put_header(oversize[:], proto.MSG_LIST, 0, 0)
	oversize[5], oversize[6], oversize[7], oversize[8] = 0xff, 0xff, 0xff, 0x7f
	unknown: [ipc.STREAM_HEADER]u8
	ipc.stream_put_header(unknown[:], 200, 0, 0)
	bad_credit: [ipc.STREAM_HEADER + 1]u8
	ipc.stream_put_header(bad_credit[:], ipc.STREAM_CREDIT, 1, 1)
	testing.expect(t, hostile_dropped(false, transmute([]u8)string("GET / HTTP/1.1\r\n\r\n")), "garbage before HELLO")
	testing.expect(t, hostile_dropped(true, oversize[:]), "oversize frame")
	testing.expect(t, hostile_dropped(true, unknown[:]), "unknown control kind")
	testing.expect(t, hostile_dropped(true, bad_credit[:]), "malformed CREDIT")
	session.session_write_string(s, "still-here\n")
	testing.expect(t, view_wait_screen(v, s, "echo:still-here"), "the good viewer is unaffected")
	view_close(v)
	testing.expect(t, tiers_stop(tiers), "tiers end")
}
