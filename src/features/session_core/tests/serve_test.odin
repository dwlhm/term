package feature_session_core_tests

// `term auto serve` end to end with a fake agent TUI that reports its state
// with OSC 7501: requests answered by the contract, by the agent itself, not
// at all, refused while it works, and cancelled by their sender.

import "core:fmt"
import "core:os"
import "core:testing"
import "core:thread"
import "core:time"
import auto "../../automation"
import proto "../../session_proto"
import ipc "../../../platform/ipc"

// FAKE_AGENT: idle until a line comes, then working; "slow" stays working
// until Esc (which cancels the turn), anything else replies after 300 ms.
FAKE_AGENT :: `import os, sys, time, tty
tty.setraw(0)
APP = sys.argv[1] if len(sys.argv) > 1 else "fake-agent"
def st(s): os.write(1, ("\x1b]7501;state=%s:app=%s\x1b\\" % (s, APP)).encode())
def prompt(text):
    os.write(1, ("PROMPT:%s\r\n" % text[:200]).encode()); st("working")
    if "slow" not in text:
        time.sleep(0.3); os.write(1, ("REPLY:%s\r\n" % text[:40]).encode()); st("idle")
os.write(1, b"\x1b[?2004h"); st("idle"); os.write(1, b"AGENT READY\r\n")
buf, line = b"", b""
while True:
    d = os.read(0, 4096)
    if not d: break
    buf += d
    while buf:
        if buf.startswith(b"\x1b[200~"):          # one paste is one prompt line
            end = buf.find(b"\x1b[201~")
            if end < 0: break
            line += buf[6:end].replace(b"\r", b" "); buf = buf[end + 6:]
        elif buf[:1] == b"\x1b":
            os.write(1, b"CANCELLED\r\n"); st("idle"); line = b""; buf = buf[1:]
        elif buf[:1] in (b"\r", b"\n"):
            prompt(line.decode()); line = b""; buf = buf[1:]
        else:
            line += buf[:1]; buf = buf[1:]
`

@(private = "file")
SERVE_CONTRACT :: `local t = require "term"
local fake = require("term.adapter.agent").make { name = "fake", app = "fake-agent", process = "python3" }
return t.contract {
  adapter = fake,
  timeouts = { expect = 5 },
  serve = function(text, req)
    if text == "self" then return { fake.steps.ask("hello"), t.done("contract answered #" .. req.id) } end
    return fake.steps.ask(text)
  end,
}`

@(private = "file")
Served :: struct {
	opts:   auto.Run_Options,
	code:   auto.Run_Code,
	thread: ^thread.Thread,
}

@(private = "file")
_tell :: proc(to: u32, body: string, wait := true) -> (res: proto.Tell_Result, conn: Cli) {
	res, _ = tell_send(&conn, {to = to, body = body}) // it opens the connection
	if !wait || res.phase == .Rejected do return
	for res.phase != .Finished {
		next, ok := tell_next(&conn, 15_000)
		if !ok do break
		res = next
	}
	return
}

@(test)
test_serve_answers_requests_to_an_agent :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	id := view_attached(v, view_spawn(v, {"/usr/bin/env", "python3", "-I", "-c", FAKE_AGENT}))
	defer { view_close(v); tiers_stop(tiers) }
	testing.expect(t, echo_screen_has(id, "AGENT READY"))
	path := fmt.tprintf("%s/tsc-serve-%d.lua", os.get_env("TMPDIR", context.temp_allocator), os.get_pid())
	_ = os.write_entire_file(path, transmute([]u8)string(SERVE_CONTRACT))
	defer os.remove(path)
	served := Served{opts = {contract = path}}
	served.thread = thread.create_and_start_with_data(&served, proc(data: rawptr) {
		s := (^Served)(data)
		s.code = auto.run_serve(s.opts) // no --session: the adapter's detect finds it
	})
	rig_wait_listening(id)

	res, c := _tell(id, "self")
	cli_close(&c)
	testing.expect(t, res.status == .Done && res.text == fmt.tprintf("contract answered #%d", res.id), "the contract answers")
	testing.expect(t, rig_wait_screen(id, "REPLY:hello"), "the agent got the prompt")

	res, c = _tell(id, "plain")
	cli_close(&c)
	testing.expect(t, res.status == .Failed, "a turn that ends without an answer fails the request")

	// the agent answers itself while it is still working
	rig_wait_listening(id)
	pending, pc := _tell(id, "slow one", wait = false)
	testing.expect(t, rig_wait_screen(id, "PROMPT:slow one"), "serve typed the prompt")
	testing.expect(t, rig_answer_as(id, pending.id, "agent says hi"), "the agent's own answer is accepted")
	final, _ := tell_next(&pc, 10_000)
	cli_close(&pc)
	testing.expect(t, final.status == .Done && final.text == "agent says hi")

	rig_wait_listening(id)
	res, c = _tell(id, "while busy")
	cli_close(&c)
	testing.expect(t, res.status == .Failed && res.text == "the agent is busy (working or blocked): ask again when it is idle", "refused while it works")

	session_type(id, "\x1b") // a person stops the slow turn: between requests input goes through
	testing.expect(t, rig_wait_screen(id, "CANCELLED"))
	rig_wait_listening(id)
	pending, pc = _tell(id, "slow two", wait = false)
	testing.expect(t, rig_wait_screen(id, "PROMPT:slow two"), "serve typed the prompt")
	testing.expect(t, tell_cancel(pending.id), "its sender cancels it")
	final, _ = tell_next(&pc, 10_000)
	cli_close(&pc)
	testing.expect_value(t, final.status, proto.Tell_Status.Cancelled)
	for _ in 0 ..< 100 {
		if _count(id, "CANCELLED") >= 2 do break
		time.sleep(50 * time.Millisecond)
	}
	testing.expect_value(t, _count(id, "CANCELLED"), 2) // the adapter's cancel pressed Esc

	cli_kill(id) // the program is gone: serving ends
	thread.join(served.thread)
	thread.destroy(served.thread)
	testing.expect(t, served.code != .Contract, "it ended because the session went, not because of the contract")
}

@(private = "file")
_count :: proc(id: u32, text: string) -> (n: int) {
	snap, _, _ := cli_snapshot(id)
	for row in snap.screen do for run in row.runs do if run.text == text || (len(run.text) >= len(text) && run.text[:len(text)] == text) do n += 1
	return
}

@(test)
test_serve_with_a_bundled_adapter_and_no_contract :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	id := view_attached(v, view_spawn(v, {"/usr/bin/env", "python3", "-I", "-c", FAKE_AGENT, "antigravity"}))
	defer { view_close(v); tiers_stop(tiers) }
	testing.expect(t, rig_wait_screen(id, "AGENT READY"))
	testing.expect_value(t, auto.run_serve({adapter = "nope", contract = "nope"}), auto.Run_Code.Contract)
	served := Served{opts = {adapter = "agy", contract = "agy"}}
	served.thread = thread.create_and_start_with_data(&served, proc(data: rawptr) {
		s := (^Served)(data)
		s.code = auto.run_serve(s.opts)
	})
	rig_wait_listening(id)
	pending, pc := _tell(id, "slow task", wait = false)
	testing.expect(t, rig_wait_screen(id, "PROMPT:slow task"), "agy's serve steps pasted the task")
	testing.expect(t, rig_wait_screen(id, "term session answer"), "with how to answer it")
	testing.expect(t, rig_answer_as(id, pending.id, "done by agy"))
	final, _ := tell_next(&pc, 10_000)
	cli_close(&pc)
	testing.expect(t, final.status == .Done && final.text == "done by agy")
	cli_kill(id)
	thread.join(served.thread)
	thread.destroy(served.thread)
}
