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
import ipc "../../../platform/ipc"

// FAKE_AGENT: idle until a line comes, then working; "slow" stays working
// until Esc (which cancels the turn), anything else replies after 300 ms.
FAKE_AGENT :: `import os, time, tty
tty.setraw(0)
def st(s): os.write(1, ("\x1b]7501;state=%s:app=fake-agent\x1b\\" % s).encode())
st("idle"); os.write(1, b"AGENT READY\r\n")
buf = b""
while True:
    d = os.read(0, 4096)
    if not d: break
    for ch in d:
        if ch == 0x1b:
            os.write(1, b"CANCELLED\r\n"); st("idle"); buf = b""
        elif ch in (13, 10):
            line = buf.decode(); buf = b""
            os.write(1, ("PROMPT:%s\r\n" % line[:60]).encode()); st("working")
            if "slow" not in line:
                time.sleep(0.3); os.write(1, ("REPLY:%s\r\n" % line[:40]).encode()); st("idle")
        else:
            buf += bytes([ch])
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
_tell :: proc(to: u32, body: string, wait := true) -> (res: ipc.Tell_Result, conn: ipc.Stream_Conn) {
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
	ipc.stream_conn_destroy(&c)
	testing.expect(t, res.status == .Done && res.text == fmt.tprintf("contract answered #%d", res.id), "the contract answers")
	testing.expect(t, rig_wait_screen(id, "REPLY:hello"), "the agent got the prompt")

	res, c = _tell(id, "plain")
	ipc.stream_conn_destroy(&c)
	testing.expect(t, res.status == .Failed, "a turn that ends without an answer fails the request")

	// the agent answers itself while it is still working
	rig_wait_listening(id)
	pending, pc := _tell(id, "slow one", wait = false)
	testing.expect(t, rig_wait_screen(id, "PROMPT:slow one"), "serve typed the prompt")
	testing.expect(t, rig_answer_as(id, pending.id, "agent says hi"), "the agent's own answer is accepted")
	final, _ := tell_next(&pc, 10_000)
	ipc.stream_conn_destroy(&pc)
	testing.expect(t, final.status == .Done && final.text == "agent says hi")

	rig_wait_listening(id)
	res, c = _tell(id, "while busy")
	ipc.stream_conn_destroy(&c)
	testing.expect(t, res.status == .Failed && res.text == "the agent is busy (working or blocked): ask again when it is idle", "refused while it works")

	session_type(id, "\x1b") // a person stops the slow turn: between requests input goes through
	testing.expect(t, rig_wait_screen(id, "CANCELLED"))
	rig_wait_listening(id)
	pending, pc = _tell(id, "slow two", wait = false)
	testing.expect(t, rig_wait_screen(id, "PROMPT:slow two"), "serve typed the prompt")
	testing.expect(t, tell_cancel(pending.id), "its sender cancels it")
	final, _ = tell_next(&pc, 10_000)
	ipc.stream_conn_destroy(&pc)
	testing.expect_value(t, final.status, ipc.Tell_Status.Cancelled)
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
