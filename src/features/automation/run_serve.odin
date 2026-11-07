package feature_automation

// `term auto serve <contract> [--session id]`: the contract answers broker
// requests sent to a session (`term session tell <id> …`) for the program in
// it — an agent TUI. The runner waits in `next` as that session, so the agent
// can answer a request itself (`term session answer <id> …` from inside the
// session is that worker). Per request: refused while the program reports
// working or blocked (OSC 7501); otherwise the session is leased, serve(text,
// request) returns the steps, and the request ends when the agent answers,
// when the steps end (done(value) answers, else it failed), or when its
// sender cancels it (then the adapter's cancel steps stop the agent).

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:time"
import lua "../../platform/lua"
import ipc "../../platform/ipc"

@(private = "file")
STATUS_WORKING :: 2
@(private = "file")
STATUS_BLOCKED :: 3

run_serve :: proc(opts: Run_Options) -> Run_Code {
	opts := opts
	opts.function, opts.serve = "serve", true
	r: Runner
	r.started = time.tick_now()
	r.quiet, r.expect = RUN_QUIET_DEFAULT, RUN_EXPECT_DEFAULT
	defer _run_cleanup(&r)
	if !_run_prepare(&r, opts) do return _run_report(&r)
	if !run_connect(&r) {
		run_stop(&r, .No_Core, "no term session is running")
		return _run_report(&r)
	}
	r.sid = opts.session
	if !run_pick_session(&r) do return _run_report(&r)
	owner := fmt.tprintf("serve:%s", filepath.base(opts.contract))
	fmt.eprintfln("term: serving session %d; ask it with: term session tell %d '<text>'", r.sid, r.sid)
	for {
		req, ok := _next_request(&r)
		if !ok do break
		_serve_one(&r, owner, req)
		_reset(&r)
	}
	if r.stop == .Cancelled do r.stop = .Ok // ^C ends serving: that is how it stops
	return _run_report(&r)
}

// _next_request waits in `next` as the session for its next request.
@(private = "file")
_next_request :: proc(r: ^Runner) -> (req: ipc.Next_Result, ok: bool) {
	b: [8]u8
	w := ipc.wire_writer(b[:])
	ipc.ww_u32(&w, r.sid); ipc.ww_u32(&w, 0)
	r.awaiting_request = true
	defer r.awaiting_request = false
	f := run_request(r, ipc.MSG_NEXT, ipc.wire_bytes_written(&w), ipc.MSG_REQUEST, 365 * 24 * time.Hour) or_return // until one comes
	if f.kind == ipc.MSG_FAIL {
		_, reason := run_fail_code(f)
		run_stop(r, .Rejected, fmt.tprintf("cannot take session %d's requests: %s", r.sid, reason))
		return {}, false
	}
	rd := ipc.wire_reader(f.payload)
	req = ipc.dec_next_result(&rd)
	req.body = strings.clone(req.body, context.temp_allocator)
	return req, rd.ok
}

@(private = "file")
_serve_one :: proc(r: ^Runner, owner: string, req: ipc.Next_Result) {
	r.serving_id = req.id
	_watch_request(r, req.id)
	if status := _status(r); status == STATUS_WORKING || status == STATUS_BLOCKED {
		_answer(r, req.id, true, "the agent is busy (working or blocked): ask again when it is idle")
		return
	}
	if !run_lease(r, owner) {
		_answer(r, req.id, true, r.stop_msg)
		return
	}
	r.deadline = time.tick_add(time.tick_now(), _limit(r))
	run_trace(r, "request", fmt.tprintf(`"id":%d,"from":%d`, req.id, req.from))
	_call_serve(r, req)
	if (r.ended && r.end_status == .Cancelled) || r.stop == .Cancelled do run_cancel_steps(r)
	switch {
	case r.ended:
	case r.stop == .Ok && r.done: _answer(r, req.id, false, r.result)
	case r.stop == .Ok:           _answer(r, req.id, true, "the agent's turn ended without an answer")
	case:                         _answer(r, req.id, true, fmt.tprintf("%v: %s", r.stop, r.stop_msg))
	}
	run_finally(r)
	run_release(r, run_release_flush(r))
	fmt.eprintfln("term: request #%d %s", req.id, _outcome(r))
}

// _call_serve: serve(text, {id, from}) → steps, carried out.
@(private = "file")
_call_serve :: proc(r: ^Runner, req: ipc.Next_Result) {
	L := r.vm.L
	lua.getfield(L, lua.REGISTRYINDEX, RUN_CONTRACT_KEY)
	lua.getfield(L, -1, "serve")
	lua.pushstring(L, req.body)
	lua.createtable(L, 0, 2)
	lua.pushinteger(L, lua.Integer(req.id))
	lua.setfield(L, -2, "id")
	lua.pushinteger(L, lua.Integer(req.from))
	lua.setfield(L, -2, "from")
	if err, ok := vm_call(r.vm, 2, 1); !ok {
		run_stop(r, .Contract, err)
		lua.pop(L, 1)
		return
	}
	run_exec(r, -1)
	lua.pop(L, 2)
}

// run_cancel_steps runs the adapter's cancel() while the session is held.
run_cancel_steps :: proc(r: ^Runner) {
	L := r.vm.L
	top := lua.gettop(L)
	defer lua.settop(L, top)
	lua.getfield(L, lua.REGISTRYINDEX, RUN_CONTRACT_KEY)
	if lua.getfield(L, -1, "adapter") != .Table || lua.getfield(L, -1, "cancel") != .Function || !r.leased do return
	stop, msg, ended := r.stop, r.stop_msg, r.ended
	r.stop, r.stop_msg, r.ended = .Ok, "", false
	run_trace(r, "cancel", "")
	if _, ok := vm_call(r.vm, 0, 1); ok do run_exec(r, -1)
	delete(r.stop_msg)
	r.stop, r.stop_msg, r.ended = stop, msg, ended
}

// _watch_request asks the core to say when the request ends (an answer from
// the agent, a cancel from its sender): a TELL_RESULT the pump takes.
@(private = "file")
_watch_request :: proc(r: ^Runner, id: u64) {
	b: [128]u8
	w := ipc.wire_writer(b[:])
	ipc.enc_result_req(&w, {wait = true, ids = {0 = id}, n_ids = 1})
	ipc.stream_send(&r.conn, ipc.MSG_RESULT, 0, ipc.wire_bytes_written(&w))
}

@(private = "file")
_status :: proc(r: ^Runner) -> u8 {
	payload, ok := run_snapshot(r)
	if !ok do return 0
	rd := ipc.wire_reader(payload)
	snap := ipc.dec_snapshot(&rd, context.temp_allocator)
	return snap.status_state
}

@(private = "file")
_answer :: proc(r: ^Runner, id: u64, failed: bool, text: string) {
	b := make([]u8, len(text) + 64, context.temp_allocator)
	w := ipc.wire_writer(b)
	ipc.enc_answer(&w, {by = r.sid, id = id, failed = failed, text = text})
	keep := r.stop
	r.stop = .Ok // a failed request is still answered
	_, _ = run_request(r, ipc.MSG_ANSWER, ipc.wire_bytes_written(&w), ipc.MSG_OK, 5 * time.Second)
	if r.stop == .Ok do r.stop = keep
}

@(private = "file")
_outcome :: proc(r: ^Runner) -> string {
	switch {
	case r.ended:                  return fmt.tprintf("ended: %v", r.end_status)
	case r.stop == .Ok && r.done:  return "answered"
	case r.stop == .Ok:            return "failed: the turn ended without an answer"
	}
	return fmt.tprintf("failed: %v: %s", r.stop, r.stop_msg)
}

// _reset clears what one request left, keeping the run.
@(private = "file")
_reset :: proc(r: ^Runner) {
	if r.stop == .Cancelled && r.stop_msg == "interrupted (SIGINT)" do return // stop serving
	if r.stop == .Exited || r.stop == .No_Core do return
	if r.exited {
		run_stop(r, .Exited, fmt.tprintf("the program exited (%d)", r.exit_code))
		return
	}
	delete(r.stop_msg)
	delete(r.result)
	delete(r.evidence)
	r.stop, r.stop_msg, r.done, r.result, r.evidence = .Ok, "", false, "", ""
	r.step, r.held, r.ended, r.serving_id = 0, 0, false, 0
}

