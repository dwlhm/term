package feature_automation

// `term auto run <contract> <function> [args]`: load and check the contract,
// call the function (pure: params → steps), lease the session and carry the
// steps out; on.finally always runs while the lease is held. Defaults keep a
// contract short: every action waits for its target and for the screen to
// settle, a person's Esc or ^C cancels, other input is held and dropped.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import lua "../../platform/lua"
import proto "../session_proto"
import ipc "../../platform/ipc"

RUN_EXPECT_DEFAULT :: 10 * time.Second
RUN_QUIET_DEFAULT  :: 50 * time.Millisecond
RUN_LIMIT_DEFAULT  :: 600 * time.Second
// after an action the screen gets this long to answer before the next step;
// a program that does not redraw for it (it buffers a paste) does not stall
// the run: correctness rests on the next expect, not on this wait
RUN_ACT_SETTLE_MAX :: 1 * time.Second

RUN_CONTRACT_KEY :: "term.run.contract"
RUN_TERM_KEY     :: "term.run.term"

Run_Options :: struct {
	contract:   string,
	function:   string,
	args:       []string, // positional, or --name value
	session:    u32,
	trace_path: string,
	serve:      bool, // term auto serve: the contract's serve function, once per request
	adapter:    string, // serve with this adapter's own serve steps (no contract file)
}

Runner :: struct {
	vm:       ^Vm,
	conn:     ipc.Stream_Conn,
	sid:      u32,
	leased:   bool,
	stop:     Run_Code,
	stop_msg: string,
	quiet:    time.Duration,
	expect:   time.Duration,
	deadline: time.Tick,
	held:     int, // bytes a person typed that are held
	exited:   bool, // the program ended (its exit code)
	exit_code: i32,
	trace:    ^os.File,
	tracing:  bool,
	started:  time.Tick,
	step:     int,
	evidence: string, // the screen when it failed
	done:     bool,
	result:   string,
	// term auto serve: the request being served; ended once it finished
	// elsewhere (answered by the agent, cancelled by its sender)
	serving_id: u64,
	awaiting_request: bool,
	ended:      bool,
	end_status: proto.Tell_Status,
	// t.ask / t.handoff replies: the run's endpoint and a terminal stdin
	endpoint:  u32,
	listening: bool, // a `next` waits on the endpoint
	reply_id:  u64,  // the broker request a reply came in (0: stdin)
	asking:    bool,
	replied:   bool,
	reply:     string,
	stdin_tty: bool,
}

// run_running: the run goes on (not stopped, its request not ended).
run_running :: proc(r: ^Runner) -> bool { return r.stop == .Ok && !r.ended }

// run_stop ends the run with code (the first reason wins).
run_stop :: proc(r: ^Runner, code: Run_Code, msg: string) {
	if r.stop != .Ok do return
	r.stop, r.stop_msg = code, strings.clone(msg)
}

run_contract :: proc(opts: Run_Options) -> Run_Code {
	r: Runner
	r.started = time.tick_now()
	r.quiet, r.expect = RUN_QUIET_DEFAULT, RUN_EXPECT_DEFAULT
	defer _run_cleanup(&r)
	if !_run_prepare(&r, opts) do return _run_report(&r)
	r.deadline = time.tick_add(time.tick_now(), _limit(&r)) // asks for params count too
	if !run_connect(&r) {
		run_stop(&r, .No_Core, "no term session is running")
		return _run_report(&r)
	}
	if !run_push_params(&r, opts.function, opts.args) do return _run_report(&r)
	r.sid = opts.session
	if !run_pick_session(&r) do return _run_report(&r)
	owner := fmt.tprintf("%s:%s", filepath.base(opts.contract), opts.function)
	if run_lease(&r, owner) {
		run_trace(&r, "start", fmt.tprintf(`"session":%d,"owner":%q`, r.sid, owner))
		_run_function(&r)
		run_finally(&r)
		run_release(&r, run_release_flush(&r))
	}
	return _run_report(&r)
}

// _run_prepare loads and checks the contract and leaves the function on the
// stack.
@(private)
_run_prepare :: proc(r: ^Runner, opts: Run_Options) -> bool {
	vm, ok := vm_open(adapter_dirs())
	if !ok {
		run_stop(r, .Contract, "cannot start Lua")
		return false
	}
	r.vm = vm
	if len(opts.trace_path) > 0 {
		h, err := os.open(opts.trace_path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, {.Read_User, .Write_User})
		r.trace, r.tracing = h, err == nil
	}
	if err, loaded := _load_contract(vm, opts); !loaded {
		run_stop(r, .Contract, err)
		return false
	}
	info, err, valid := contract_check(vm)
	defer contract_info_destroy(&info)
	if !valid {
		run_stop(r, .Contract, fmt.tprintf("%s: %s", opts.contract, err))
		return false
	}
	L := vm.L
	lua.pushvalue(L, -1)
	lua.setfield(L, lua.REGISTRYINDEX, RUN_CONTRACT_KEY)
	_run_timeouts(r)
	lua.getglobal(L, "require")
	lua.pushstring(L, "term")
	if e, req := vm_call(vm, 1, 1); !req {
		run_stop(r, .Contract, e)
		return false
	}
	lua.pushvalue(L, -1)
	lua.setfield(L, lua.REGISTRYINDEX, RUN_TERM_KEY)
	lua.getfield(L, -2, "adapter") // matching sees the contract's adapter
	lua.setfield(L, -2, "_adapter")
	lua.pop(L, 1)
	if lua.getfield(L, -1, strings.clone_to_cstring(opts.function, context.temp_allocator)) != .Function || (opts.function == "serve") != opts.serve {
		run_stop(r, .Contract, fmt.tprintf("%s has no function %q (it has: %s)", opts.contract, opts.function, strings.join(info.functions[:], ", ", context.temp_allocator)))
		return false
	}
	return true
}

// _run_function calls the function on the stack with its params and carries
// out the steps it returns.
@(private = "file")
_run_function :: proc(r: ^Runner) {
	L := r.vm.L
	nargs := lua.gettop(L) - 2 // contract, function, params…
	if err, ok := vm_call(r.vm, nargs, 1); !ok {
		run_stop(r, .Contract, err)
		return
	}
	run_exec(r, -1)
	lua.pop(L, 1)
}

@(private = "file")
_run_timeouts :: proc(r: ^Runner) {
	L := r.vm.L
	if lua.getfield(L, -1, "timeouts") == .Table {
		if lua.getfield(L, -1, "expect") == .Number do r.expect = _seconds(lua.tonumberx(L, -1, nil))
		lua.pop(L, 1)
		if lua.getfield(L, -1, "settle") == .Number do r.quiet = _seconds(lua.tonumberx(L, -1, nil))
		lua.pop(L, 1)
	}
	lua.pop(L, 1)
}

@(private)
_limit :: proc(r: ^Runner) -> time.Duration {
	L := r.vm.L
	limit := RUN_LIMIT_DEFAULT
	lua.getfield(L, lua.REGISTRYINDEX, RUN_CONTRACT_KEY)
	if lua.getfield(L, -1, "timeouts") == .Table {
		if lua.getfield(L, -1, "run") == .Number do limit = _seconds(lua.tonumberx(L, -1, nil))
		lua.pop(L, 1)
	}
	lua.pop(L, 2)
	return limit
}

@(private = "file")
_seconds :: proc(s: lua.Number) -> time.Duration { return time.Duration(s * f64(time.Second)) }

// _run_report prints the result or the failure with its evidence.
@(private)
_run_report :: proc(r: ^Runner) -> Run_Code {
	if r.stop == .Ok {
		if r.done && len(r.result) > 0 do fmt.println(r.result)
		run_trace(r, "done", "")
		return .Ok
	}
	fmt.eprintfln("term: %v: %s", r.stop, r.stop_msg)
	if r.step > 0 do fmt.eprintfln("  at step %d", r.step)
	if r.held > 0 do fmt.eprintfln("  %d bytes a person typed were held and dropped", r.held)
	if len(r.evidence) > 0 do fmt.eprint(r.evidence)
	run_trace(r, "fail", fmt.tprintf(`"code":%q,"msg":%q,"step":%d`, fmt.tprint(r.stop), r.stop_msg, r.step))
	return r.stop
}

@(private)
_run_cleanup :: proc(r: ^Runner) {
	if r.leased do run_release(r, false)
	ipc.stream_conn_destroy(&r.conn)
	if r.tracing do os.close(r.trace)
	if r.vm != nil do vm_close(r.vm)
	delete(r.stop_msg)
	delete(r.evidence)
	delete(r.result)
}

// run_trace appends one NDJSON event when --trace is on.
run_trace :: proc(r: ^Runner, ev: string, fields: string) {
	if !r.tracing do return
	ms := time.duration_milliseconds(time.tick_since(r.started))
	sep := "," if len(fields) > 0 else ""
	line := fmt.tprintf(`{{"t_ms":%.1f,"ev":%q%s%s}}` + "\n", ms, ev, sep, fields)
	os.write_string(r.trace, line)
}


// _load_contract runs the contract file, or for `serve --adapter <name>` the
// contract made of that adapter and its own serve steps.
@(private = "file")
_load_contract :: proc(vm: ^Vm, opts: Run_Options) -> (err: string, ok: bool) {
	if len(opts.adapter) == 0 do return vm_load_file(vm, opts.contract)
	src := strings.concatenate({`local t = require "term"
local a = require("term.adapter.`, opts.adapter, `")
assert(a.steps.serve, "adapter `, opts.adapter, ` has no serve steps: write a contract with a serve function")
return t.contract { adapter = a, serve = function(text, req) return a.steps.serve(text, req) end }`}, context.temp_allocator)
	return vm_load_chunk(vm, transmute([]u8)src, strings.concatenate({"adapter ", opts.adapter}, context.temp_allocator))
}
