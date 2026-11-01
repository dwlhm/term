package feature_holder_tests

import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"
import ipc "../../../platform/ipc"

@(test)
test_output_before_exit :: proc(t: ^testing.T) {
	f := fixture_start()
	c := client_connect(f.path)
	client_spawn(c, 1, {"/bin/sh", "-c", "printf hi; exit 3"})
	testing.expect(t, client_wait_kind(c, ipc.MSG_SPAWNED, 1, 3000) >= 0, "SPAWNED")
	i := client_wait_kind(c, ipc.MSG_EXITED, 1, 3000)
	testing.expect(t, i >= 0, "EXITED")
	if i >= 0 {
		testing.expect_value(t, client_output(c, 1, i), "hi")
		r := ipc.wire_reader(c.log[i].data)
		e := ipc.dec_exit(&r)
		testing.expect_value(t, e.code, 3)
		testing.expect(t, !e.signaled, "exited normally")
	}
	// SPAWN of a known id answers SPAWNED again (idempotent).
	client_spawn(c, 1, {"/bin/sh", "-c", "exit 0"})
	testing.expect(t, wait_count(c, ipc.MSG_SPAWNED, 1, 2), "second SPAWNED")
	client_close(c)
	testing.expect_value(t, fixture_stop(f), 0)
}

@(test)
test_reconnect_gets_welcome_and_tail :: proc(t: ^testing.T) {
	f := fixture_start()
	a := client_connect(f.path)
	client_spawn(a, 7, {"/bin/sh", "-c", "printf early; sleep 30"})
	testing.expect(t, client_wait_output(a, 7, "early", 3000), "first output")
	client_close(a) // drop without GOODBYE: a crash for the next core

	b := client_connect(f.path)
	testing.expect(t, client_wait_kind(b, ipc.MSG_HELLO, 0, 3000) >= 0, "HELLO back")
	wi := client_wait_kind(b, ipc.MSG_WELCOME, 0, 3000)
	testing.expect(t, wi >= 0, "WELCOME")
	if wi >= 0 {
		r := ipc.wire_reader(b.log[wi].data)
		w := ipc.dec_welcome(&r)
		testing.expect_value(t, w.previous, u8(2))
		testing.expect_value(t, w.count, u32(1))
		held := ipc.dec_held(&r)
		testing.expect(t, ipc.wr_done(&r), "WELCOME decodes")
		testing.expect_value(t, held.id, u32(7))
		testing.expect(t, held.pid > 0 && !held.exited, "held session alive")
	}
	ti := client_wait_kind(b, ipc.MSG_TAIL, 7, 3000)
	testing.expect(t, ti >= 0 && string(b.log[ti].data) == "early", "TAIL holds earlier output")
	client_close(b)
	testing.expect_value(t, fixture_stop(f), 0)
}

@(test)
test_resize_seen_by_stty :: proc(t: ^testing.T) {
	f := fixture_start()
	c := client_connect(f.path)
	client_spawn(c, 2, {"/bin/sh", "-c", "read line; stty size"})
	testing.expect(t, client_wait_kind(c, ipc.MSG_SPAWNED, 2, 3000) >= 0, "SPAWNED")
	buf: [16]u8
	w := ipc.wire_writer(buf[:])
	ipc.enc_size(&w, {cols = 100, rows = 40, xpixel = 800, ypixel = 640})
	client_send(c, ipc.MSG_RESIZE, 2, ipc.wire_bytes_written(&w))
	client_send(c, ipc.MSG_INPUT, 2, transmute([]u8)string("go\n"))
	i := client_wait_kind(c, ipc.MSG_EXITED, 2, 3000)
	testing.expect(t, i >= 0, "EXITED")
	testing.expect(t, contains(client_output(c, 2), "40 100"), "stty size sees the new size")
	client_close(c)
	testing.expect_value(t, fixture_stop(f), 0)
}

@(test)
test_signal_term :: proc(t: ^testing.T) {
	f := fixture_start()
	c := client_connect(f.path)
	client_spawn(c, 3, {"/bin/sleep", "30"})
	testing.expect(t, client_wait_kind(c, ipc.MSG_SPAWNED, 3, 3000) >= 0, "SPAWNED")
	client_signal(c, 3, .SIGTERM)
	i := client_wait_kind(c, ipc.MSG_EXITED, 3, 3000)
	testing.expect(t, i >= 0, "EXITED after SIGTERM")
	if i >= 0 {
		r := ipc.wire_reader(c.log[i].data)
		e := ipc.dec_exit(&r)
		testing.expect(t, e.signaled && e.signal == i32(posix.Signal.SIGTERM), "killed by SIGTERM")
	}
	client_close(c)
	testing.expect_value(t, fixture_stop(f), 0)
}

@(test)
test_release_with_background_grandchild :: proc(t: ^testing.T) {
	f := fixture_start()
	c := client_connect(f.path)
	client_spawn(c, 4, {"/bin/sh", "-c", "sleep 30 & echo bg=$!; wait"})
	testing.expect(t, client_wait_output(c, 4, "\n", 3000), "grandchild pid printed")
	out := client_output(c, 4)
	gpid := 0
	if k := strings.index(out, "bg="); k >= 0 {
		for ch in out[k + 3:] {
			if ch < '0' || ch > '9' do break
			gpid = gpid * 10 + int(ch - '0')
		}
	}
	testing.expect(t, gpid > 0, "grandchild pid parsed")
	start := time.tick_now()
	client_send(c, ipc.MSG_RELEASE, 4)
	// The holder must answer at once: a new spawn is served right after.
	client_spawn(c, 5, {"/bin/sh", "-c", "exit 0"})
	testing.expect(t, client_wait_kind(c, ipc.MSG_SPAWNED, 5, 2000) >= 0, "holder responsive after RELEASE")
	testing.expect(t, time.tick_since(start) < 2 * time.Second, "RELEASE does not hang")
	gone := false
	for _ in 0..<100 {
		if posix.kill(posix.pid_t(gpid), posix.Signal(0)) != .OK {
			gone = true
			break
		}
		time.sleep(20 * time.Millisecond)
	}
	testing.expect(t, gone, "grandchild holding the tty was hung up")
	client_close(c)
	testing.expect_value(t, fixture_stop(f), 0)
}

@(test)
test_newest_hello_wins :: proc(t: ^testing.T) {
	f := fixture_start()
	a := client_connect(f.path)
	client_spawn(a, 9, {"/bin/sleep", "30"})
	testing.expect(t, client_wait_kind(a, ipc.MSG_SPAWNED, 9, 3000) >= 0, "SPAWNED")
	b := client_connect(f.path)
	testing.expect(t, client_wait_kind(b, ipc.MSG_WELCOME, 0, 3000) >= 0, "new core welcomed")
	for _ in 0..<40 do if !a.closed do client_pump(a, 50)
	testing.expect(t, a.closed, "older core link closed")
	client_close(a)
	client_close(b)
	testing.expect_value(t, fixture_stop(f), 0)
}

@(test)
test_shutdown_ends_everything :: proc(t: ^testing.T) {
	f := fixture_start()
	c := client_connect(f.path)
	client_spawn(c, 1, {"/bin/sleep", "30"})
	si := client_wait_kind(c, ipc.MSG_SPAWNED, 1, 3000)
	testing.expect(t, si >= 0, "SPAWNED")
	pid := rec_u32(c.log[si]) if si >= 0 else 0
	client_goodbye(c, .Shutdown)
	testing.expect(t, client_wait_kind(c, ipc.MSG_BYE, 0, 3000) >= 0, "BYE")
	code := fixture_stop(f)
	testing.expect_value(t, code, 0)
	testing.expect(t, pid > 0 && posix.kill(posix.pid_t(pid), posix.Signal(0)) != .OK, "session process gone")
	client_close(c)
}

@(test)
test_handover_clears_tails :: proc(t: ^testing.T) {
	f := fixture_start()
	a := client_connect(f.path)
	client_spawn(a, 6, {"/bin/sh", "-c", "printf before; sleep 30"})
	testing.expect(t, client_wait_output(a, 6, "before", 3000), "output")
	client_goodbye(a, .Handover)
	testing.expect(t, client_wait_kind(a, ipc.MSG_BYE, 0, 3000) >= 0, "BYE on handover")
	client_close(a)
	b := client_connect(f.path)
	wi := client_wait_kind(b, ipc.MSG_WELCOME, 0, 3000)
	if wi >= 0 {
		r := ipc.wire_reader(b.log[wi].data)
		testing.expect_value(t, ipc.dec_welcome(&r).previous, u8(1))
	}
	ti := client_wait_kind(b, ipc.MSG_TAIL, 6, 3000)
	testing.expect(t, ti >= 0 && len(b.log[ti].data) == 0, "tail cleared by handover")
	client_close(b)
	testing.expect_value(t, fixture_stop(f), 0)
}

@(test)
test_welcome_carries_original_started_unix :: proc(t: ^testing.T) {
	f := fixture_start()
	a := client_connect(f.path)
	t0 := time.to_unix_seconds(time.now())
	client_spawn(a, 9, {"/bin/sh", "-c", "sleep 30"})
	si := client_wait_kind(a, ipc.MSG_SPAWNED, 9, 3000)
	testing.expect(t, si >= 0, "SPAWNED")
	r_sp := ipc.wire_reader(a.log[si].data)
	pid := ipc.wr_u32(&r_sp)
	spawn_started := i64(ipc.wr_u64(&r_sp))
	testing.expect(t, ipc.wr_done(&r_sp), "SPAWNED decoded")
	testing.expect(t, spawn_started >= t0, "spawn_started >= t0")

	time.sleep(1200 * time.Millisecond)
	client_close(a)

	b := client_connect(f.path)
	wi := client_wait_kind(b, ipc.MSG_WELCOME, 0, 3000)
	testing.expect(t, wi >= 0, "WELCOME")
	if wi >= 0 {
		r_wel := ipc.wire_reader(b.log[wi].data)
		_ = ipc.dec_welcome(&r_wel)
		held := ipc.dec_held(&r_wel)
		testing.expect(t, ipc.wr_done(&r_wel), "WELCOME decodes")
		testing.expect_value(t, held.id, u32(9))
		testing.expect_value(t, held.pid, pid)
		testing.expect_value(t, held.started_unix, spawn_started)
		now_unix := time.to_unix_seconds(time.now())
		testing.expect(t, held.started_unix < now_unix, "started_unix is the original spawn time, not now")
	}
	client_close(b)
	testing.expect_value(t, fixture_stop(f), 0)
}

wait_count :: proc(c: ^Client, kind: u8, channel: u32, want: int) -> bool {
	for _ in 0..<60 {
		n := 0
		for r in c.log do if r.kind == kind && r.channel == channel do n += 1
		if n >= want do return true
		client_pump(c, 50)
	}
	return false
}
