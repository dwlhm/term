package feature_automation

// The runner's link to the session core: one ipc.Client for the whole run,
// so the lease lives exactly as long as the runner. Every request is one
// correlated call; while it waits, lease events (a person typing, a takeover,
// the program ending), late answers (a reply on the run's endpoint, the end
// of a served request) and SIGINT are handled, and they stop the run by
// setting runner.stop.

import "base:intrinsics"
import "core:c/libc"
import "core:fmt"
import "core:sync"
import "core:time"
import proto "../session_proto"
import ipc "../../platform/ipc"

@(private = "file")
_sigint: libc.sig_atomic_t

@(private = "file")
_sig_client: ^ipc.Client // the running runner's client: SIGINT interrupts its wait

@(private = "file")
_on_sigint :: proc "c" (sig: libc.int) {
	intrinsics.atomic_store(&_sigint, 1)
	if c := sync.atomic_load(&_sig_client); c != nil do ipc.client_interrupt(c)
}

run_connect :: proc(r: ^Runner) -> bool {
	if proto.session_open(&r.client, .Cli, false).kind != .None do return false
	sync.atomic_store(&_sig_client, &r.client)
	libc.signal(libc.SIGINT, _on_sigint)
	return true
}

// run_disconnect: SIGINT no longer reaches the client, then it closes.
run_disconnect :: proc(r: ^Runner) {
	sync.atomic_compare_exchange_strong(&_sig_client, &r.client, nil)
	ipc.client_close(&r.client)
}

// run_call sends one request and waits for its answer (body valid until the
// next run_call). err.kind: .Failed = the core's FAIL (code, reason); any
// other error has stopped the run.
run_call :: proc(r: ^Runner, kind: u8, body: []u8, timeout: time.Duration) -> (a: ipc.Answer, err: ipc.Error) {
	opts := ipc.Call_Opts{timeout = timeout, on_event = _on_event, data = r}
	if r.asking && r.stdin > 0 do opts.watch, opts.on_watch = r.stdin, _on_stdin
	a, err = ipc.client_call(&r.client, kind, body, opts)
	_stopped_by(r, err)
	return
}

// run_wait_events handles events until done(r), the run stops or timeout.
run_wait_events :: proc(r: ^Runner, timeout: time.Duration, done: proc(r: ^Runner) -> bool) {
	deadline := time.tick_add(time.tick_now(), timeout)
	for run_running(r) && !done(r) {
		left := time.tick_diff(time.tick_now(), deadline)
		if left <= 0 do return
		watch := r.stdin if r.asking else 0
		ev, err := ipc.client_poll(&r.client, left, watch, _on_stdin, r)
		if err.kind == .Timeout do return
		if err.kind != .None {
			_stopped_by(r, err)
			return
		}
		_on_event(r, ev)
	}
}

@(private = "file")
_on_stdin :: proc(data: rawptr) { run_reply_stdin((^Runner)(data)) }

// _stopped_by stops the run for a call that ended without an answer.
@(private = "file")
_stopped_by :: proc(r: ^Runner, err: ipc.Error) {
	#partial switch err.kind {
	case .None, .Failed, .Timeout:
	case .Interrupted:
		if intrinsics.atomic_load(&_sigint) != 0 do run_stop(r, .Cancelled, "interrupted (SIGINT)")
	case:
		run_stop(r, .No_Core, "the session core went away")
	}
}

// _on_event handles what is not the call's own answer; .Stop once the run stopped.
@(private = "file")
_on_event :: proc(data: rawptr, ev: ipc.Client_Event) -> ipc.Event_Action {
	r := (^Runner)(data)
	#partial switch e in ev {
	case ipc.Notice:
		rd := ipc.wire_reader(e.body)
		if e.kind == proto.MSG_LEASE_EVENT do _lease_event(r, proto.dec_lease_event(&rd))
	case ipc.Late_Answer:
		// Late answer not expected
	}
	return .Continue if run_running(r) else .Stop
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
	proto.enc_lease_req(&w, {r.sid, owner[:min(len(owner), proto.LEASE_OWNER_MAX)]})
	_, err := run_call(r, proto.MSG_LEASE, ipc.wire_bytes_written(&w), ipc.CALL_DEFAULT)
	if err.kind == .Failed {
		run_stop(r, .Rejected if err.code == u8(proto.Fail_Code.Busy) else .Contract, fmt.tprintf("cannot take session %d: %s", r.sid, err.reason))
	}
	r.leased = err.kind == .None
	return r.leased
}

// run_release gives the lease back; flush = held input reaches the program.
run_release :: proc(r: ^Runner, flush: bool) {
	if !r.leased do return
	b: [8]u8
	w := ipc.wire_writer(b[:])
	proto.enc_lease_flag(&w, {r.sid, flush})
	_, _ = ipc.client_call(&r.client, proto.MSG_LEASE_RELEASE, ipc.wire_bytes_written(&w))
	r.leased = false
}

// run_snapshot returns the session's current snapshot payload (valid until the next call).
run_snapshot :: proc(r: ^Runner) -> (payload: []u8, ok: bool) {
	b: [16]u8
	w := ipc.wire_writer(b[:])
	proto.enc_snapshot_req(&w, {id = r.sid, history = 0, since = -1})
	a, err := run_call(r, proto.MSG_SNAPSHOT, ipc.wire_bytes_written(&w), ipc.CALL_DEFAULT)
	if err.kind == .Failed do run_stop(r, .Exited, fmt.tprintf("cannot read the screen: %s", err.reason))
	return a.body, err.kind == .None
}

// run_settle waits until the screen moved past since and went quiet. false is
// not an error: a program that never goes quiet just ran out of time.
run_settle :: proc(r: ^Runner, since: u64, timeout: time.Duration) -> (gen: u64, settled: bool) {
	b: [24]u8
	w := ipc.wire_writer(b[:])
	ms := u32(max(timeout, 1 * time.Millisecond) / time.Millisecond)
	proto.enc_settle_req(&w, {id = r.sid, since = since, quiet_ms = u32(r.quiet / time.Millisecond), timeout_ms = ms})
	a, err := run_call(r, proto.MSG_SETTLE, ipc.wire_bytes_written(&w), timeout + 2 * time.Second)
	if err.kind != .None do return since, false
	rd := ipc.wire_reader(a.body)
	res := proto.dec_settle_result(&rd)
	return res.gen, !res.exited
}

// run_act sends one encoded MSG_ACT body; gen is the generation it went in at.
run_act :: proc(r: ^Runner, body: []u8) -> (gen: u64, ok: bool) {
	a, err := run_call(r, proto.MSG_ACT, body, ipc.CALL_DEFAULT)
	if err.kind == .Failed {
		#partial switch proto.Fail_Code(err.code) {
		case .Unsupported: run_stop(r, .Unsupported, err.reason)
		case .Exited:      run_stop(r, .Exited, err.reason)
		case .Busy:        run_stop(r, .Rejected, err.reason)
		case:              run_stop(r, .Contract, err.reason)
		}
	}
	if err.kind != .None do return 0, false
	rd := ipc.wire_reader(a.body)
	_ = ipc.wr_u32(&rd)
	return ipc.wr_u64(&rd), true
}
