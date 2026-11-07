package feature_session_core_tests

// Broker state machine, shell adapter side: typing at the prompt, a person
// stepping in, draining a cancelled command, limits and capping.

import "core:strings"
import "core:testing"
import core ".."

@(test)
test_broker_shell_adapter :: proc(t: ^testing.T) {
	b := broker_new()
	defer broker_free(b)
	_, rej := tell(b, 0, 5, "ls", .Starting, waiter = 1)
	testing.expect(t, rej == .None && !has(b, .Inject), "held until the first prompt")
	core.broker_shell_ready(b, 5)
	testing.expect(t, has(b, .Inject, -1, 5), "typed")
	_, rej = tell(b, 0, 5, "ls", .Ready)
	testing.expect_value(t, rej, core.Broker_Reject.Busy)
	core.broker_shell_done(b, 5, 2, "err\n")
	r := effect(b, .Result, 1)
	testing.expect(t, r != nil && r.status == .Failed && r.exit_code == 2 && core.broker_text(r) == "err\n", "result")

	tell(b, 0, 5, "sleep 9", .Ready, waiter = 2)
	core.broker_human_input(b, 5, .Interrupt, "so far")
	r = effect(b, .Result, 2)
	testing.expect(t, r != nil && r.status == .Cancelled && core.broker_text(r) == "so far", "^C: cancelled with partial")
	tell(b, 0, 5, "sleep 9", .Ready, waiter = 3)
	core.broker_human_input(b, 5, .Other)
	testing.expect(t, effect(b, .Result, 3).status == .Interrupted, "typing: taken over")
}

@(test)
test_broker_shell_drain :: proc(t: ^testing.T) {
	b := broker_new()
	defer broker_free(b)
	tell(b, 0, 5, "sleep 30", .Ready, waiter = 1)
	core.broker_viewer_gone(b, 1) // before 133;C: the typed line still runs
	testing.expect(t, !has(b, .Interrupt), "no SIGINT into the line editor")
	_, rej := tell(b, 0, 5, "true", .Ready)
	testing.expect_value(t, rej, core.Broker_Reject.Busy)
	core.broker_shell_started(b, 5)
	testing.expect(t, has(b, .Interrupt, -1, 5), "interrupted once it started")
	fake_now += core.BROKER_INT_RETRY_MS * 1_000_000
	core.broker_tick(b, fake_now)
	testing.expect(t, has(b, .Interrupt, -1, 5), "again: 133;C came before the fork")
	core.broker_shell_done(b, 5, 130, "")
	_, rej = tell(b, 0, 5, "true", .Ready)
	testing.expect_value(t, rej, core.Broker_Reject.None) // free at 133;D

	core.broker_shell_done(b, 5, 0, "")
	tell(b, 0, 5, "x", .Ready, waiter = 4)
	core.broker_viewer_gone(b, 4)
	core.broker_tick(b, fake_now + core.BROKER_DRAIN_MS * 1_000_000)
	_, rej = tell(b, 0, 5, "true", .Ready)
	testing.expect_value(t, rej, core.Broker_Reject.None) // never started: freed at the deadline
}

@(test)
test_broker_shell_only_never_goes_to_a_worker :: proc(t: ^testing.T) {
	b := broker_new()
	defer broker_free(b)
	listen(b, 5, 10)
	_, rej := core.broker_tell(b, 0, 5, "ls", 0, fake_now, .None, 1, shell_only = true)
	testing.expect_value(t, rej, core.Broker_Reject.Not_Listening) // a worker waits, but no prompt
	id, _ := core.broker_tell(b, 0, 6, "ls", 0, fake_now, .Starting, 1, shell_only = true)
	listen(b, 6, 11)
	testing.expect(t, !has(b, .Assign), "a starting shell keeps its command")
	core.broker_shell_ready(b, 6)
	testing.expect(t, has(b, .Inject, -1, 6) && core.broker_request(b, id) != nil, "typed at the prompt")
}

@(test)
test_broker_starting_goes_to_first_ready :: proc(t: ^testing.T) {
	b := broker_new()
	defer broker_free(b)
	id, _ := tell(b, 1, 5, "early", .Starting, waiter = 9)
	listen(b, 5, 10) // a worker shows up before any prompt
	r := effect(b, .Assign, 10)
	testing.expect(t, r != nil && r.id == id && r.kind == .Worker, "the worker took the held request")
	testing.expect_value(t, core.broker_row(b, 5).listening, 0)
	core.broker_shell_ready(b, 5)
	testing.expect(t, !has(b, .Inject), "nothing left for the shell")
	testing.expect_value(t, core.broker_answer(b, 5, id, "ok", false), core.Serve_Error.None)
}

@(test)
test_broker_full_and_truncation :: proc(t: ^testing.T) {
	b := broker_new()
	defer broker_free(b)
	for i in 0..<core.CORE_MAX_REQUESTS {
		_, rej := tell(b, 0, u32(200 + i), "x", .Ready)
		testing.expect_value(t, rej, core.Broker_Reject.None)
	}
	_, rej := tell(b, 0, 99, "x", .Ready)
	testing.expect_value(t, rej, core.Broker_Reject.Full)
	long := strings.repeat("é", core.BROKER_TEXT_CAP, context.temp_allocator)
	core.broker_shell_done(b, 200, 0, long)
	r := effect(b, .Row, -1, 200)
	testing.expect(t, r != nil, "finished")
	q := core.broker_result(b, 0, b.reqs[0].id) // the sender (outside term) takes it
	text := core.broker_text(q)
	testing.expect(t, len(text) <= core.BROKER_TEXT_CAP && strings.contains(text, "truncated"), "capped with marker")
	testing.expect(t, strings.has_prefix(text, "éé") && strings.has_suffix(text, "éé"), "head and tail kept")
	_, rej = tell(b, 0, 99, "x", .Ready)
	testing.expect_value(t, rej, core.Broker_Reject.None) // the slot came back
}
