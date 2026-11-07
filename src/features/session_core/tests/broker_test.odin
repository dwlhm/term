package feature_session_core_tests

// Request broker state machine (no sessions, no PTY): who takes a request,
// how it ends, and what reaches whom.

import "core:strings"
import "core:testing"
import core ".."
import ipc "../../../platform/ipc"

@(test)
test_broker_rejects :: proc(t: ^testing.T) {
	b := broker_new()
	defer broker_free(b)
	big := strings.repeat("x", core.BROKER_BODY_CAP + 1, context.temp_allocator)
	cases := []struct{body: string, shell: core.Shell_Readiness, want: core.Broker_Reject}{
		{"", .Ready, .Empty},
		{" \t\x1b", .Ready, .Empty},
		{big, .Ready, .Too_Large},
		{"x", .None, .Not_Listening},
		{"x", .Busy, .Busy},
		{"ls\nrm", .Ready, .Multi_Line},
	}
	for c in cases {
		_, rej := tell(b, 1, 5, c.body, c.shell)
		testing.expectf(t, rej == c.want, "%q: got %v want %v", c.body[:min(len(c.body), 8)], rej, c.want)
	}
	testing.expect(t, core.broker_row(b, 5) == {}, "a rejected tell leaves no trace")
}

@(test)
test_broker_worker_slots :: proc(t: ^testing.T) {
	b := broker_new()
	defer broker_free(b)
	listen(b, 2, 10)
	listen(b, 2, 11) // two `next` calls: two free slots
	testing.expect_value(t, core.broker_row(b, 2).listening, 2)
	a, _ := tell(b, 1, 2, "task a\nline 2")
	r := effect(b, .Assign, 10)
	testing.expect(t, r != nil && r.id == a && core.broker_body(r) == "task a\nline 2", "first worker took it, newlines kept")
	c, _ := tell(b, 3, 2, "task c")
	testing.expect(t, effect(b, .Assign, 11) != nil && c > a, "second worker took the next one")
	_, rej := tell(b, 4, 2, "task d")
	testing.expect_value(t, rej, core.Broker_Reject.Busy) // both taken, no queue
	row := core.broker_row(b, 2)
	testing.expect(t, row.serving == 2 && row.listening == 0 && core.broker_row(b, 1).awaiting == 1, "rows")
}

@(test)
test_broker_answer_progress_and_who_may :: proc(t: ^testing.T) {
	b := broker_new()
	defer broker_free(b)
	listen(b, 2, 10)
	id, _ := tell(b, 1, 2, waiter = 20)
	testing.expect_value(t, core.broker_answer(b, 3, id, "x", false), core.Serve_Error.Not_Yours)
	testing.expect_value(t, core.broker_answer(b, 2, id + 99, "x", false), core.Serve_Error.Unknown)
	core.broker_watch(b, 30, 7, {id}, true, 0, fake_now)  // someone else follows it
	core.broker_watch(b, 31, 7, {id}, false, 0, fake_now) // and someone only waits for the end
	testing.expect_value(t, core.broker_progress(b, 2, id, "half\x1b[2J done"), core.Serve_Error.None)
	p := effect(b, .Progress, 20)
	testing.expect(t, p != nil && core.broker_progress_text(p) == "half[2J done", "the waiting sender hears progress, cleaned")
	testing.expect(t, has(b, .Progress, 30) && !has(b, .Progress, 31), "only followers hear progress")
	testing.expect_value(t, core.broker_answer(b, 2, id, "result", true), core.Serve_Error.None)
	r := effect(b, .Result, 20)
	testing.expect(t, r != nil && r.status == .Failed && core.broker_text(r) == "result", "failed answer to the sender")
	testing.expect(t, has(b, .Result, 30) && has(b, .Result, 31), "every watch hears the end")
	testing.expect(t, core.broker_request(b, id) == nil, "the waiting sender took it: freed")
}

@(test)
test_broker_result_read_and_watch :: proc(t: ^testing.T) {
	b := broker_new()
	defer broker_free(b)
	listen(b, 2, 10)
	listen(b, 3, 11)
	a, _ := tell(b, 1, 2) // async: nobody waits
	c, _ := tell(b, 1, 3)
	q := core.broker_result(b, 1, a)
	testing.expect(t, q != nil && q.phase == .Running, "still running")
	core.broker_watch(b, 40, 1, {a, c}, false, 0, fake_now)
	core.broker_answer(b, 3, c, "c done", false)
	r := effect(b, .Result, 40)
	testing.expect(t, r != nil && r.id == c, "the watch ends with the first one done")
	testing.expect(t, core.broker_request(b, c) == nil, "the sender's own watch took it")
	core.broker_answer(b, 2, a, "a done", false)
	testing.expect(t, !has(b, .Result), "nobody waits any more")
	q = core.broker_result(b, 9, a)
	testing.expect(t, q != nil && core.broker_text(q) == "a done", "anyone may read it")
	testing.expect(t, core.broker_request(b, a) != nil, "kept: not the sender")
	core.broker_watch(b, 41, 1, {a}, false, 0, fake_now)
	testing.expect(t, has(b, .Result, 41), "a watch on a finished one answers at once")
	testing.expect(t, core.broker_request(b, a) == nil, "taken by its sender")

	listen(b, 2, 10)
	e, _ := tell(b, 1, 2)
	core.broker_answer(b, 2, e, "late", false)
	fake_now += core.BROKER_RESULT_TTL_MS * 1_000_000
	core.broker_tick(b, fake_now)
	testing.expect(t, core.broker_request(b, e) == nil, "never fetched: expired")
}

@(test)
test_broker_children_end_with_parent :: proc(t: ^testing.T) {
	b := broker_new()
	defer broker_free(b)
	listen(b, 2, 10)
	a, _ := tell(b, 1, 2)
	child, _ := tell(b, 2, 5, "make test", .Ready, waiter = 11) // the worker of #a uses shell 5
	testing.expect_value(t, core.broker_request(b, child).parent, a)
	core.broker_shell_started(b, 5)
	testing.expect(t, core.broker_cancel(b, a), "cancel the parent")
	testing.expect(t, has(b, .Interrupt, -1, 5), "its child's command interrupted")
	r := effect(b, .Result, 11)
	testing.expect(t, r != nil && r.status == .Cancelled, "the child's sender told")
	testing.expect_value(t, core.broker_answer(b, 2, a, "x", false), core.Serve_Error.Ended)

	listen(b, 2, 10)
	listen(b, 2, 12)
	x, _ := tell(b, 1, 2)
	y, _ := tell(b, 1, 2)
	amb, _ := tell(b, 2, 6, "ls", .Ready)
	named, _ := tell(b, 2, 7, "ls", .Ready, parent = y)
	testing.expect(t, core.broker_request(b, amb).parent == 0, "two running: no guess")
	testing.expect(t, core.broker_request(b, named).parent == y && x != y, "named parent")
}

@(test)
test_broker_sides_go_away :: proc(t: ^testing.T) {
	b := broker_new()
	defer broker_free(b)
	listen(b, 2, 10)
	a, _ := tell(b, 1, 2, waiter = 20)
	core.broker_session_gone(b, 2, 137)
	r := effect(b, .Result, 20)
	testing.expect(t, r != nil && r.status == .Error && r.exit_code == 137, "worker gone: error")

	listen(b, 2, 10)
	c, _ := tell(b, 1, 2)
	core.broker_watch(b, 30, 2, {c}, false, 0, fake_now) // the worker watches for a cancel
	core.broker_session_gone(b, 1, 0)
	testing.expect(t, has(b, .Result, 30), "sender gone: the worker hears it ended")
	testing.expect(t, core.broker_request(b, c) == nil && a != c, "and nobody keeps it")

	listen(b, 3, 40)
	core.broker_viewer_gone(b, 40)
	_, rej := tell(b, 1, 3)
	testing.expect_value(t, rej, core.Broker_Reject.Not_Listening)
	listen(b, 3, 41)
	d, _ := tell(b, 9, 3, waiter = 42)
	core.broker_viewer_gone(b, 42) // the sender's tell was killed
	testing.expect(t, core.broker_request(b, d) == nil, "its request cancelled and freed")
	testing.expect_value(t, core.broker_answer(b, 3, d, "x", false), core.Serve_Error.Unknown)
}

@(test)
test_broker_timeouts :: proc(t: ^testing.T) {
	b := broker_new()
	defer broker_free(b)
	listen(b, 2, 10, timeout_ms = 500)
	core.broker_watch(b, 11, 1, {}, false, 300, fake_now)
	testing.expect(t, core.broker_next_due(b) == NOW + 300 * 1_000_000, "nearest deadline")
	core.broker_tick(b, NOW + 600 * 1_000_000)
	testing.expect(t, has(b, .Expired, 10) && has(b, .Expired, 11), "next and wait timed out")
	listen(b, 2, 10)
	id, _ := tell(b, 1, 2, waiter = 20, timeout_ms = 1000)
	core.broker_tick(b, fake_now + 2_000_000_000)
	r := effect(b, .Result, 20)
	testing.expect(t, r != nil && r.status == .Timeout && r.id == id, "request timed out")
}

@(test)
test_broker_snapshot_roundtrip :: proc(t: ^testing.T) {
	b := broker_new()
	defer broker_free(b)
	listen(b, 2, 10)
	a, _ := tell(b, 1, 2, "review")
	core.broker_progress(b, 2, a, "half")
	child, _ := tell(b, 2, 5, "make", .Ready)
	buf := make([]u8, 4 << 20)
	defer delete(buf)
	w := ipc.wire_writer(buf)
	core.broker_encode(b, &w)
	nb := broker_new()
	defer broker_free(nb)
	r := ipc.wire_reader(ipc.wire_bytes_written(&w))
	testing.expect(t, w.ok && core.broker_decode(nb, &r), "round trip")
	q := core.broker_request(nb, a)
	testing.expect(t, q != nil && core.broker_body(q) == "review" && core.broker_progress_text(q) == "half", "request kept")
	testing.expect_value(t, core.broker_request(nb, child).parent, a)
	_, rej := tell(nb, 0, 5, "x", .Ready)
	testing.expect_value(t, rej, core.Broker_Reject.Busy) // the shell still runs the child
	testing.expect_value(t, core.broker_answer(nb, 2, a, "ok", false), core.Serve_Error.None)

	bad := ipc.wire_bytes_written(&w)
	bad[8 + 4 + 4 + 8 + 8] = 99 // first request's phase
	r = ipc.wire_reader(bad)
	nb2 := broker_new()
	defer broker_free(nb2)
	testing.expect(t, !core.broker_decode(nb2, &r), "corrupt snapshot refused")
}
