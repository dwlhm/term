package feature_session_core_tests

// Automation leases: the owner's input goes in, everyone else is refused,
// what a person types is held and reported (or passed through), and the lease
// ends on release, owner disconnect, takeover, exit and removal.

import "core:encoding/hex"
import "core:strings"
import "core:testing"
import client "../../session_client"
import proto "../../session_proto"
import ipc "../../../platform/ipc"

// Driver: one connection that keeps its lease and collects lease events.
@(private = "file")
Driver :: struct {
	conn:   Cli,
	events: [dynamic]proto.Lease_Event,
}

@(private = "file")
_driver :: proc(d: ^Driver) -> bool { return cli_conn(&d.conn) }

@(private = "file")
_drop :: proc(d: ^Driver) {
	cli_close(&d.conn)
	delete(d.events)
}

// _call sends one request and returns the answer kind (MSG_OK / MSG_ACT_RESULT
// / MSG_TELL_RESULT / MSG_FAIL) and, for FAIL, its code; events are kept.
@(private = "file")
_call :: proc(d: ^Driver, kind: u8, payload: []u8) -> (answer: u8, code: proto.Fail_Code, tell: proto.Tell_Result) {
	cli_send(&d.conn, kind, payload)
	for {
		f, got := cli_frame(&d.conn, 4000)
		if !got do return
		r := ipc.wire_reader(f.payload)
		switch f.kind {
		case proto.MSG_LEASE_EVENT: append(&d.events, proto.dec_lease_event(&r))
		case proto.MSG_OK, proto.MSG_ACT_RESULT: return f.kind, {}, {}
		case proto.MSG_TELL_RESULT, proto.MSG_TELL_PROGRESS: return f.kind, {}, proto.dec_tell_result(&r)
		case proto.MSG_FAIL:
			_ = ipc.wr_u32(&r)
			return f.kind, proto.Fail_Code(ipc.wr_u8(&r)), {}
		}
	}
}

// _event waits for the next lease event of kind (true when it came).
@(private = "file")
_event :: proc(d: ^Driver, kind: proto.Lease_Event_Kind) -> (ev: proto.Lease_Event, ok: bool) {
	for {
		for e, i in d.events {
			if e.kind != kind do continue
			ordered_remove(&d.events, i)
			return e, true
		}
		f := cli_frame(&d.conn, 4000) or_return
		r := ipc.wire_reader(f.payload)
		if f.kind == proto.MSG_LEASE_EVENT do append(&d.events, proto.dec_lease_event(&r))
	}
}

@(private = "file")
_lease :: proc(d: ^Driver, id: u32, owner := "flow.lua:test") -> (u8, proto.Fail_Code) {
	b: [128]u8
	w := ipc.wire_writer(b[:])
	ipc.ww_u32(&w, id); ipc.ww_str(&w, owner)
	a, code, _ := _call(d, proto.MSG_LEASE, ipc.wire_bytes_written(&w))
	return a, code
}

@(private = "file")
_release :: proc(d: ^Driver, id: u32, flush: bool) -> u8 {
	b: [8]u8
	w := ipc.wire_writer(b[:])
	ipc.ww_u32(&w, id); ipc.ww_bool(&w, flush)
	a, _, _ := _call(d, proto.MSG_LEASE_RELEASE, ipc.wire_bytes_written(&w))
	return a
}

@(private = "file")
_pass :: proc(d: ^Driver, id: u32, pass: bool) -> u8 {
	b: [8]u8
	w := ipc.wire_writer(b[:])
	ipc.ww_u32(&w, id); ipc.ww_bool(&w, pass)
	a, _, _ := _call(d, proto.MSG_LEASE_MODE, ipc.wire_bytes_written(&w))
	return a
}

@(private = "file")
_text :: proc(d: ^Driver, id: u32, text: string) -> (u8, proto.Fail_Code) {
	b: [256]u8
	w := ipc.wire_writer(b[:])
	proto.enc_act_text(&w, id, text, false)
	a, code, _ := _call(d, proto.MSG_ACT, ipc.wire_bytes_written(&w))
	return a, code
}

@(private = "file")
_controller :: proc(id: u32) -> string {
	rows: [16]proto.Session_Row
	for row in cli_list_rows(rows[:]) do if row.id == id do return row.controller
	return "<none>"
}

// Person: a window attached to the session, typing on its channel.
@(private = "file")
Person :: struct {
	conn:    Cli,
	channel: u32,
}

@(private = "file")
_person :: proc(p: ^Person, id: u32) -> bool {
	if !cli_conn(&p.conn) do return false
	ch, ok := cli_attach_channel(&p.conn, id)
	p.channel = ch
	return ok
}

@(private = "file")
_type :: proc(p: ^Person, bytes: string) {
	cli_stream(&p.conn, p.channel, proto.MSG_V_INPUT, transmute([]u8)bytes)
}

@(test)
test_lease_owner_drives_and_others_are_refused :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	id := echo_open(v, "")
	defer { view_close(v); tiers_stop(tiers) }
	owner, other: Driver
	testing.expect(t, _driver(&owner) && _driver(&other))
	defer { _drop(&owner); _drop(&other) }

	a, code := _lease(&owner, id)
	testing.expect_value(t, a, proto.MSG_OK)
	testing.expect_value(t, _controller(id), "flow.lua:test")
	a, code = _lease(&other, id, "second")
	testing.expect(t, a == proto.MSG_FAIL && code == .Busy, "one lease per session")
	a, code = _text(&other, id, "x")
	testing.expect(t, a == proto.MSG_FAIL && code == .Busy, "another driver's input is refused")
	a, code, _ = _call(&other, proto.MSG_SEND, _id_and(id, "y"))
	testing.expect(t, a == proto.MSG_FAIL && code == .Busy, "send is refused")
	b: [64]u8
	w := ipc.wire_writer(b[:])
	proto.enc_tell_req(&w, {to = id, body = "echo hi"})
	_, _, tell := _call(&other, proto.MSG_TELL, ipc.wire_bytes_written(&w))
	testing.expect(t, tell.phase == .Rejected && tell.reject == .Leased, "broker requests are refused")
	a, _ = _text(&owner, id, "ok")
	testing.expect(t, a == proto.MSG_ACT_RESULT && echo_received(id, "ok"), "the owner's input goes in")

	testing.expect_value(t, _release(&other, id, false), proto.MSG_FAIL)
	testing.expect_value(t, _release(&owner, id, false), proto.MSG_OK)
	testing.expect_value(t, _controller(id), "")
	a, _ = _text(&other, id, "free")
	testing.expect(t, a == proto.MSG_ACT_RESULT && echo_received(id, "free"), "released: anyone may drive it")
}

@(private = "file")
_id_and :: proc(id: u32, rest: string) -> []u8 {
	out := make([]u8, 4 + len(rest), context.temp_allocator)
	w := ipc.wire_writer(out)
	ipc.ww_u32(&w, id)
	copy(out[4:], rest)
	return out
}

@(test)
test_lease_holds_and_reports_human_input :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	id := echo_open(v, "")
	defer { view_close(v); tiers_stop(tiers) }
	owner: Driver
	person: Person
	testing.expect(t, _driver(&owner) && _person(&person, id))
	defer { _drop(&owner); cli_close(&person.conn) }

	_lease(&owner, id)
	_type(&person, "abc")
	ev, got := _event(&owner, .Human)
	testing.expect(t, got && ev.bytes == "abc" && !ev.interrupt && ev.held == 3, "the owner hears what was typed")
	testing.expect(t, !_got_any(id), "held: the program has received nothing")
	_type(&person, "\x1b")
	ev, got = _event(&owner, .Human)
	testing.expect(t, got && ev.interrupt, "Esc is reported as an interrupt")
	testing.expect_value(t, _pass(&owner, id, true), proto.MSG_OK)
	_type(&person, "P")
	ev, got = _event(&owner, .Human)
	testing.expect(t, got && ev.held == 4, "pass mode reports but does not hold")
	testing.expect(t, echo_received(id, "P"), "pass mode lets it through")
	_pass(&owner, id, false)
	testing.expect_value(t, _release(&owner, id, true), proto.MSG_OK)
	testing.expect(t, echo_received(id, "abc\x1b"), "flush delivers what was held, in order")
}

@(test)
test_lease_ends_on_disconnect_takeover_exit_and_kill :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	id := echo_open(v, "")
	short := view_attached(v, view_sh(v, "/bin/sleep 0.5; exit 3"))
	doomed := view_attached(v, view_sh(v, "/bin/sleep 5"))
	defer { view_close(v); tiers_stop(tiers) }

	gone: Driver
	_driver(&gone)
	_lease(&gone, id)
	person: Person
	testing.expect(t, _person(&person, id))
	defer cli_close(&person.conn)
	_type(&person, "lost")
	_event(&gone, .Human)
	_drop(&gone)
	cli_settle({id = id, since = 0, quiet_ms = 50, timeout_ms = 500})
	testing.expect_value(t, _controller(id), "")
	_type(&person, "next")
	testing.expect(t, echo_received(id, "next"), "a closed owner releases")
	testing.expect(t, !_got(id, "lost"), "the input it held is dropped")

	owner: Driver
	_driver(&owner)
	defer _drop(&owner)
	_lease(&owner, id)
	cli_stream(&person.conn, person.channel, proto.MSG_V_TAKEOVER)
	_, took := _event(&owner, .Takeover)
	testing.expect(t, took && _controller(id) == "", "a takeover ends the lease")

	_lease(&owner, short)
	ev, exited := _event(&owner, .Exited)
	testing.expect(t, exited && ev.exit_code == 3, "the program's exit ends it")
	_lease(&owner, doomed)
	cli_kill(doomed)
	_, removed := _event(&owner, .Removed)
	testing.expect(t, removed, "killing the session ends it")
}

@(test)
test_lease_refused_while_a_request_runs :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	tell_view_sess = view_sh(v, TELL_REPL)
	id := view_attached(v, tell_view_sess)
	defer { view_close(v); tiers_stop(tiers) }
	view_wait_screen(v, tell_view_sess, "$ ", 5000)
	d: Driver
	_driver(&d)
	defer _drop(&d)
	b: [64]u8
	w := ipc.wire_writer(b[:])
	proto.enc_tell_req(&w, {to = id, body = "sleep 2", shell = true})
	_, _, tell := _call(&d, proto.MSG_TELL, ipc.wire_bytes_written(&w))
	testing.expect_value(t, tell.phase, proto.Tell_Phase.Accepted)
	a, code := _lease(&d, id)
	testing.expect(t, a == proto.MSG_FAIL && code == .Busy, "a running shell request keeps the session")
	a, code = _lease(&d, id, "")
	testing.expect(t, a == proto.MSG_FAIL && code == .Bad_Request, "an owner name is required")
}

// _got_any: the echo fixture printed an input line (after the screen settled).
@(private = "file")
_got_any :: proc(id: u32) -> bool {
	return _got(id, "")
}

@(private = "file")
_got :: proc(id: u32, bytes: string) -> bool {
	cli_settle({id = id, since = 0, quiet_ms = 200, timeout_ms = 1000})
	snap, _, _ := cli_snapshot(id)
	want := strings.concatenate({"IN:", string(hex.encode(transmute([]u8)bytes, context.temp_allocator))}, context.temp_allocator)
	for row in snap.screen do for run in row.runs do if strings.contains(run.text, want) do return true
	return false
}

@(test)
test_lease_window_takeover_through_the_client :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	sess := view_spawn(v, {"/usr/bin/env", "python3", "-I", "-c", ECHO_FIXTURE, ""})
	id := view_attached(v, sess)
	defer { view_close(v); tiers_stop(tiers) }
	owner: Driver
	testing.expect(t, _driver(&owner))
	defer _drop(&owner)
	_lease(&owner, id, "flow.lua:take")
	_pass(&owner, id, true)
	rows: [16]proto.Session_Row
	got_pass := false
	for row in cli_list_rows(rows[:]) do if row.id == id do got_pass = row.controller == "flow.lua:take" && row.controller_pass
	testing.expect(t, got_pass, "rows carry the controller and its pass mode")
	client.client_takeover(&v.c, sess)
	_, took := _event(&owner, .Takeover)
	testing.expect(t, took, "the window's takeover reaches the core over the pane's link")
	testing.expect_value(t, _controller(id), "")
}
