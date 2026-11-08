package feature_automation

// The runner's link to the session core: one connection for the whole run,
// so the lease lives exactly as long as the runner. Lease events (a person
// typing, a takeover, the program ending) and SIGINT are handled while it
// waits for any answer; they stop the run by setting runner.stop.

import "base:intrinsics"
import "core:c/libc"
import "core:fmt"
import "core:sys/posix"
import "core:time"
import client "../session_client"
import proto "../session_proto"
import ipc "../../platform/ipc"

@(private = "file")
_sigint: libc.sig_atomic_t

@(private = "file")
_on_sigint :: proc "c" (sig: libc.int) { intrinsics.atomic_store(&_sigint, 1) }

RUN_WAIT_CHUNK :: 200 * time.Millisecond // how often a wait looks at SIGINT

run_connect :: proc(r: ^Runner) -> bool {
	fd, ok := client.client_dial(.Cli, false)
	if !ok do return false
	libc.signal(libc.SIGINT, _on_sigint)
	return ipc.stream_conn_init(&r.conn, fd, 0)
}

// run_request sends one request and returns its answer frame (want or FAIL).
// ok = false: no answer came in time, or the run was stopped meanwhile.
run_request :: proc(r: ^Runner, kind: u8, payload: []u8, want: u8, timeout: time.Duration) -> (f: ipc.Stream_Frame, ok: bool) {
	ipc.stream_send(&r.conn, kind, 0, payload)
	return run_pump(r, want, timeout)
}

// run_pump reads frames until want (or FAIL) arrives — want 0: until a reply
// (t.ask, t.handoff) arrives — handling lease events, replies on the run's
// endpoint and lines typed on a terminal stdin meanwhile.
run_pump :: proc(r: ^Runner, want: u8, timeout: time.Duration) -> (f: ipc.Stream_Frame, ok: bool) {
	deadline := time.tick_add(time.tick_now(), timeout)
	for {
		if intrinsics.atomic_load(&_sigint) != 0 do run_stop(r, .Cancelled, "interrupted (SIGINT)")
		if !run_running(r) || (want == 0 && r.replied) do return {}, false
		ipc.stream_flush(&r.conn)
		if frame, got := ipc.stream_next(&r.conn); got {
			if _dispatch(r, frame) do continue
			if frame.kind == want || frame.kind == proto.MSG_FAIL do return frame, true
			continue
		}
		if r.conn.err != .None {
			run_stop(r, .No_Core, "the session core went away")
			return {}, false
		}
		left := time.tick_diff(time.tick_now(), deadline)
		if left <= 0 do return {}, false
		_poll(r, min(left, RUN_WAIT_CHUNK))
	}
}

// _dispatch handles frames that are not answers; true = it was one of those.
@(private = "file")
_dispatch :: proc(r: ^Runner, f: ipc.Stream_Frame) -> bool {
	rd := ipc.wire_reader(f.payload)
	switch f.kind {
	case proto.MSG_LEASE_EVENT: _lease_event(r, proto.dec_lease_event(&rd))
	case proto.MSG_REQUEST:
		if r.awaiting_request do return false // serve: a request for the agent, the answer it waits for
		run_reply_request(r, proto.dec_next_result(&rd))
	case proto.MSG_TELL_RESULT:
		res := proto.dec_tell_result(&rd)
		if r.serving_id == 0 || res.id != r.serving_id || res.phase != .Finished do return false
		r.ended, r.end_status = true, res.status // answered or cancelled elsewhere
	case proto.MSG_EVENT:       // a session row changed: not for the runner
	case:                     return false
	}
	return true
}

@(private = "file")
_poll :: proc(r: ^Runner, wait: time.Duration) {
	fds := [2]posix.pollfd{{fd = r.conn.fd, events = {.IN, .OUT} if ipc.stream_wants_write(&r.conn) else {.IN}}, {fd = 0, events = {.IN}}}
	n := 2 if r.stdin_tty && r.asking else 1
	if posix.poll(raw_data(fds[:]), posix.nfds_t(n), i32(wait / time.Millisecond) + 1) <= 0 do return
	if fds[0].revents != {} do ipc.stream_fill(&r.conn)
	if n == 2 && fds[1].revents != {} do run_reply_stdin(r)
}

// run_fail_code reads a FAIL frame's code and reason.
run_fail_code :: proc(f: ipc.Stream_Frame) -> (code: proto.Fail_Code, reason: string) {
	rd := ipc.wire_reader(f.payload)
	_ = ipc.wr_u32(&rd)
	return proto.Fail_Code(ipc.wr_u8(&rd)), ipc.wr_str(&rd)
}

@(private = "file")
_lease_event :: proc(r: ^Runner, ev: proto.Lease_Event) {
	switch ev.kind {
	case .Human:
		run_trace(r, "human", fmt.tprintf(`"bytes":%d,"interrupt":%v`, len(ev.bytes), ev.interrupt))
		r.held = int(ev.held)
		if run_human_says_cancel(r, ev) do run_stop(r, .Cancelled, "a person pressed Esc or ^C")
	case .Takeover:
		r.leased = false
		run_stop(r, .Interrupted, "a person took the session back")
	case .Exited:
		// Not a failure by itself: the last step may have ended it. A step
		// that still needs the program stops the run (run_wait_for, run_act).
		r.leased, r.exited, r.exit_code = false, true, ev.exit_code
	case .Removed:
		r.leased = false
		run_stop(r, .Exited, "the session was killed")
	}
}

run_lease :: proc(r: ^Runner, owner: string) -> bool {
	b: [128]u8
	w := ipc.wire_writer(b[:])
	ipc.ww_u32(&w, r.sid); ipc.ww_str(&w, owner[:min(len(owner), proto.LEASE_OWNER_MAX)])
	f, ok := run_request(r, proto.MSG_LEASE, ipc.wire_bytes_written(&w), proto.MSG_OK, 5 * time.Second)
	if !ok do return false
	if f.kind == proto.MSG_FAIL {
		code, reason := run_fail_code(f)
		run_stop(r, .Rejected if code == .Busy else .Contract, fmt.tprintf("cannot take session %d: %s", r.sid, reason))
		return false
	}
	r.leased = true
	return true
}

run_release :: proc(r: ^Runner, flush: bool) {
	if !r.leased do return
	b: [8]u8
	w := ipc.wire_writer(b[:])
	ipc.ww_u32(&w, r.sid); ipc.ww_bool(&w, flush)
	ipc.stream_send(&r.conn, proto.MSG_LEASE_RELEASE, 0, ipc.wire_bytes_written(&w))
	ipc.stream_flush(&r.conn)
	r.leased = false
}

// run_snapshot returns the session's current snapshot payload.
run_snapshot :: proc(r: ^Runner) -> (payload: []u8, ok: bool) {
	b: [16]u8
	w := ipc.wire_writer(b[:])
	proto.enc_snapshot_req(&w, {id = r.sid, history = 0, since = -1})
	f := run_request(r, proto.MSG_SNAPSHOT, ipc.wire_bytes_written(&w), proto.MSG_SNAPSHOT_RESULT, 5 * time.Second) or_return
	if f.kind == proto.MSG_FAIL {
		_, reason := run_fail_code(f)
		run_stop(r, .Exited, fmt.tprintf("cannot read the screen: %s", reason))
		return nil, false
	}
	return f.payload, true
}

// run_settle waits until the screen moved past since and went quiet. false is
// not an error: a program that never goes quiet just ran out of time.
run_settle :: proc(r: ^Runner, since: u64, timeout: time.Duration) -> (gen: u64, settled: bool) {
	b: [24]u8
	w := ipc.wire_writer(b[:])
	ms := u32(max(timeout, 1 * time.Millisecond) / time.Millisecond)
	proto.enc_settle_req(&w, {id = r.sid, since = since, quiet_ms = u32(r.quiet / time.Millisecond), timeout_ms = ms})
	f := run_request(r, proto.MSG_SETTLE, ipc.wire_bytes_written(&w), proto.MSG_SETTLE_RESULT, timeout + 2 * time.Second) or_return
	if f.kind == proto.MSG_FAIL do return since, false
	rd := ipc.wire_reader(f.payload)
	res := proto.dec_settle_result(&rd)
	return res.gen, !res.exited
}

// run_act sends one encoded MSG_ACT body; gen is the generation it went in at.
run_act :: proc(r: ^Runner, body: []u8) -> (gen: u64, ok: bool) {
	f := run_request(r, proto.MSG_ACT, body, proto.MSG_ACT_RESULT, 5 * time.Second) or_return
	if f.kind == proto.MSG_FAIL {
		code, reason := run_fail_code(f)
		#partial switch code {
		case .Unsupported: run_stop(r, .Unsupported, reason)
		case .Exited:      run_stop(r, .Exited, reason)
		case .Busy:        run_stop(r, .Rejected, reason)
		case:              run_stop(r, .Contract, reason)
		}
		return 0, false
	}
	rd := ipc.wire_reader(f.payload)
	_ = ipc.wr_u32(&rd)
	return ipc.wr_u64(&rd), true
}
