package feature_session_core_tests

// `term auto run` end to end: contracts driving real programs in the tiers.
// Each test writes a contract, runs it in a thread (the runner blocks) and
// acts as the person or the caller meanwhile.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import auto "../../automation"
import ipc "../../../platform/ipc"

// LINE_FIXTURE: prints READY, then for every line GOT:<line>; "go" also
// prints DONE, "quit" exits 3.
LINE_FIXTURE :: `import sys
print("READY ID=42", flush=True)
for line in sys.stdin:
    line = line.strip()
    print("GOT:" + line, flush=True)
    if line == "go":
        print("DONE", flush=True)
    if line == "quit":
        sys.exit(3)
`

@(private = "file")
Run :: struct {
	opts:   auto.Run_Options,
	code:   auto.Run_Code,
	thread: ^thread.Thread,
}

@(private = "file")
_contract :: proc(body: string) -> string {
	@(static) n: int
	n += 1
	path := fmt.tprintf("%s/tsc-contract-%d-%d.lua", os.get_env("TMPDIR", context.temp_allocator), os.get_pid(), n)
	_ = os.write_entire_file(path, transmute([]u8)strings.concatenate({"local t = require \"term\"\n", body}, context.temp_allocator))
	return path
}

@(private = "file")
_start :: proc(run: ^Run, sid: u32, contract, function: string, args: ..string) {
	run.opts = {contract = contract, function = function, args = args, session = sid}
	run.thread = thread.create_and_start_with_data(run, proc(data: rawptr) {
		r := (^Run)(data)
		r.code = auto.run_contract(r.opts)
	})
}

@(private = "file")
_finish :: proc(run: ^Run) -> auto.Run_Code {
	thread.join(run.thread)
	thread.destroy(run.thread)
	os.remove(run.opts.contract)
	return run.code
}

@(private = "file")
_run :: proc(sid: u32, body, function: string, args: ..string) -> auto.Run_Code {
	run: Run
	_start(&run, sid, _contract(body), function, ..args)
	return _finish(&run)
}

@(private = "file")
_lines :: proc(v: ^View) -> u32 {
	return view_attached(v, view_spawn(v, {"/usr/bin/env", "python3", "-I", "-c", LINE_FIXTURE}))
}

@(test)
test_runner_types_expects_reads_and_calls :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	id := _lines(v)
	defer { view_close(v); tiers_stop(tiers) }
	code := _run(id, `return t.contract {
  go = function(word)
    return {
      t.expect("READY"),
      t.read(function(s) return s:line(1):match("ID=(%d+)") end, function(n)
        return { t.type(word .. n .. "\n"), t.expect("GOT:" .. word .. n), t.call("finish") }
      end),
    }
  end,
  finish = function() return { t.type("go\n"), t.expect("DONE"), t.press("Ctrl+D") } end,
}`, "go", "w")
	testing.expect_value(t, code, auto.Run_Code.Ok)
	snap, _, _ := cli_snapshot(id)
	testing.expect_value(t, snap.exited, true) // Ctrl+D ended the fixture
}

@(test)
test_runner_fails_with_unexpected_and_contract_errors :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	id := _lines(v)
	defer { view_close(v); tiers_stop(tiers) }
	testing.expect_value(t, _run(id, `return t.contract { timeouts = { expect = 0.5 }, f = function() return t.expect("NEVER") end }`, "f"), auto.Run_Code.Unexpected)
	testing.expect_value(t, _run(id, `return t.contract { f = function() return 42 end }`, "f"), auto.Run_Code.Contract)
	testing.expect_value(t, _run(id, `return t.contract { f = function() return t.press("Hyper+Q") end }`, "f"), auto.Run_Code.Contract)
	testing.expect_value(t, _run(id, `return t.contract { f = function() return t.fail("no") end }`, "f"), auto.Run_Code.Failed)
	testing.expect_value(t, _run(id, `return t.contract { f = function() return t.click("READY") end }`, "f"), auto.Run_Code.Unsupported) // no mouse reports
	testing.expect_value(t, _run(id, `return t.contract { f = function() return {} end }`, "nope"), auto.Run_Code.Contract)
	testing.expect_value(t, _run(999_999, `return t.contract { f = function() return {} end }`, "f"), auto.Run_Code.Contract)
}

@(test)
test_runner_choose_retry_and_done :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	id := _lines(v)
	defer { view_close(v); tiers_stop(tiers) }
	code := _run(id, `return t.contract {
  f = function()
    return {
      t.choose { { "NOT HERE", t.fail("wrong case") }, { "READY", t.type("one\n") } },
      t.retry({ t.type("go\n") }, { times = 2, ["until"] = "DONE" }),
      t.choose { { "NOT HERE", t.fail("wrong case") }, default = t.done("fine") },
    }
  end,
}`, "f")
	testing.expect_value(t, code, auto.Run_Code.Ok)
	testing.expect(t, echo_screen_has(id, "GOT:one") && echo_screen_has(id, "DONE"))
}

@(test)
test_runner_person_esc_cancels_and_finally_runs :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	id := _lines(v)
	defer { view_close(v); tiers_stop(tiers) }
	run: Run
	_start(&run, id, _contract(`return t.contract {
  on = { finally = { t.type("bye\n") } },
  f = function() return t.expect("NEVER", { timeout = 20 }) end,
}`), "f")
	rig_wait_controller(id, true)
	session_type(id, "\x1b")
	testing.expect_value(t, _finish(&run), auto.Run_Code.Cancelled)
	testing.expect(t, echo_screen_has(id, "GOT:bye"), "on.finally ran while the session was still held")
	testing.expect(t, !echo_screen_has(id, "GOT:\x1b"), "the Esc itself was held and dropped")
}

@(test)
test_runner_takeover_and_exit_end_it :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	id := _lines(v)
	defer { view_close(v); tiers_stop(tiers) }
	run: Run
	_start(&run, id, _contract(`return t.contract { f = function() return t.expect("NEVER", { timeout = 20 }) end }`), "f")
	rig_wait_controller(id, true)
	session_takeover(id)
	testing.expect_value(t, _finish(&run), auto.Run_Code.Interrupted)
	testing.expect_value(t, _run(id, `return t.contract { f = function() return { t.type("quit\n"), t.expect("NEVER", { timeout = 20 }) } end }`, "f"), auto.Run_Code.Exited)
}

@(test)
test_runner_asks_and_takes_replies :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	id := _lines(v)
	defer { view_close(v); tiers_stop(tiers) }
	run: Run
	_start(&run, id, _contract(`return t.contract {
  params = { f = { count = "number" } },
  f = function(count) return t.ask({ prompt = "who?", choices = { "ada", "bob" } }, function(who)
    return { t.type(who .. (count + 1) .. "\n"), t.expect("GOT:" .. who .. (count + 1)) }
  end) end,
}`), "f")
	endpoint := rig_wait_endpoint()
	testing.expect(t, endpoint != 0, "the run opened a reply endpoint")
	tell_body(endpoint, "1")    // the missing param
	tell_body(endpoint, "carl") // not a choice: refused, asked again
	tell_body(endpoint, "ada")
	testing.expect_value(t, _finish(&run), auto.Run_Code.Ok)
	testing.expect(t, echo_screen_has(id, "GOT:ada2"))
}

@(test)
test_runner_refuses_a_held_session :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	id := _lines(v)
	defer { view_close(v); tiers_stop(tiers) }
	first: Run
	_start(&first, id, _contract(`return t.contract { f = function() return t.expect("NEVER", { timeout = 3 }) end }`), "f")
	rig_wait_controller(id, true)
	testing.expect_value(t, _run(id, `return t.contract { f = function() return {} end }`, "f"), auto.Run_Code.Rejected)
	testing.expect_value(t, _finish(&first), auto.Run_Code.Unexpected)
	rig_wait_controller(id, false)
}

@(test)
test_runner_rejects_handmade_steps :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	id := _lines(v)
	defer { view_close(v); tiers_stop(tiers) }
	for body in ([?]string{
		`return t.contract { f = function() return { op = "press", keys = 5 } end }`,
		`return t.contract { f = function() return { op = "choose", cases = { 1 } } end }`,
		`return t.contract { f = function() return { op = "warp" } end }`,
		`return t.contract { f = function() return { op = "read", target = "READY", k = 1 } end }`,
	}) {
		testing.expect_value(t, _run(id, body, "f"), auto.Run_Code.Contract)
	}
}

@(test)
test_runner_finds_its_session_with_the_adapter :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	other := view_attached(v, view_sh(v, "echo NOT IT; /bin/sleep 20"))
	id := _lines(v)
	defer { view_close(v); tiers_stop(tiers) }
	testing.expect(t, echo_screen_has(id, "READY"), "the fixture is up before detect looks")
	body := `local lines = t.adapter {
  name = "lines",
  detect = function(s) return string.find(s:line(1), "READY", 1, true) ~= nil end,
  interrupts = { { "GOT:oops", t.type("go\n") } },
}
return t.contract { adapter = lines, f = function() return { t.type("oops\n"), t.expect("DONE"), t.done("found") } end }`
	testing.expect_value(t, _run(0, body, "f"), auto.Run_Code.Ok) // no --session: detect picks it; the interrupt sends go
	testing.expect(t, echo_screen_has(id, "GOT:go"), "the adapter's interrupt ran")
	testing.expect_value(t, _run(other, body, "f"), auto.Run_Code.Failed) // --session that is not its program
	second := _lines(v)
	testing.expect(t, echo_screen_has(second, "READY"))
	testing.expect_value(t, _run(0, body, "f"), auto.Run_Code.Failed) // two candidates: it will not guess
}
