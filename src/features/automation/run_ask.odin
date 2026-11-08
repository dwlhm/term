package feature_automation

// Answers from whoever runs the contract (t.ask, a missing param, the end of
// a t.handoff). The question goes to stdout as one JSON line; the answer
// comes as `term auto reply <id> <value>` (a broker request to the run's own
// endpoint, which ends with the run's connection) or, on a terminal, as a
// line typed on stdin.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"
import proto "../session_proto"
import ipc "../../platform/ipc"

// run_ask asks and waits for a valid answer (kind: string, number or boolean;
// choices, when given, lists the only valid answers).
run_ask :: proc(r: ^Runner, prompt, kind: string, choices: []string) -> (answer: string, ok: bool) {
	if !run_ensure_endpoint(r) do return
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"ask":%q,"type":%q`, prompt, kind)
	if len(choices) > 0 {
		strings.write_string(&b, `,"choices":[`)
		for ch, i in choices do fmt.sbprintf(&b, "%s%q", "," if i > 0 else "", ch)
		strings.write_byte(&b, ']')
	}
	fmt.sbprintf(&b, `,"reply":"term auto reply %d <answer>"}}`, r.endpoint)
	fmt.println(strings.to_string(b))
	run_trace(r, "ask", fmt.tprintf(`"prompt":%q`, prompt))
	for {
		text := run_wait_reply(r) or_return
		if why := _invalid(text, kind, choices); why != "" {
			run_answer_reply(r, true, why)
			continue
		}
		run_answer_reply(r, false, "ok")
		return text, true
	}
}

// run_wait_reply waits for the next reply until the run's deadline.
run_wait_reply :: proc(r: ^Runner) -> (text: string, ok: bool) {
	run_listen(r)
	r.asking, r.replied = true, false
	defer r.asking = false
	run_wait_events(r, time.tick_diff(time.tick_now(), r.deadline), proc(r: ^Runner) -> bool { return r.replied })
	if !r.replied {
		run_stop(r, .Timeout, "no answer came before the run's time limit")
		return "", false
	}
	return r.reply, true
}

// run_reply_request takes a broker request that reached the run's endpoint.
run_reply_request :: proc(r: ^Runner, req: proto.Next_Result) {
	delete(r.reply)
	r.reply, r.replied, r.reply_id = strings.clone(strings.trim_space(req.body)), true, req.id
}

// run_reply_stdin takes a line typed on the terminal.
run_reply_stdin :: proc(r: ^Runner) {
	buf: [4096]u8
	n, err := os.read(os.stdin, buf[:])
	if err != nil || n <= 0 do return
	delete(r.reply)
	r.reply, r.replied, r.reply_id = strings.clone(strings.trim_space(string(buf[:n]))), true, 0
}

// run_answer_reply tells the sender of a broker reply how it went.
run_answer_reply :: proc(r: ^Runner, failed: bool, text: string) {
	if r.reply_id == 0 {
		if failed do fmt.eprintfln("term: %s", text)
		return
	}
	b: [512]u8
	w := ipc.wire_writer(b[:])
	proto.enc_answer(&w, {by = r.endpoint, id = r.reply_id, failed = failed, text = text[:min(len(text), 400)]})
	_, _ = run_call(r, proto.MSG_ANSWER, ipc.wire_bytes_written(&w), ipc.CALL_DEFAULT)
	r.reply_id = 0
}

@(private = "file")
_invalid :: proc(text, kind: string, choices: []string) -> string {
	switch kind {
	case "number":
		if _, ok := strconv.parse_f64(text); !ok do return fmt.tprintf("%q is not a number", text)
	case "boolean":
		switch text {
		case "true", "false", "yes", "no", "1", "0":
		case: return fmt.tprintf("%q is not true or false", text)
		}
	}
	if len(choices) > 0 {
		for ch in choices do if ch == text do return ""
		return fmt.tprintf("%q is not one of: %s", text, strings.join(choices, ", ", context.temp_allocator))
	}
	return ""
}

// run_ensure_endpoint creates the run's endpoint (owned: it ends with the run).
run_ensure_endpoint :: proc(r: ^Runner) -> bool {
	if r.stdin == 0 && posix.isatty(0) do r.stdin = posix.dup(0)
	if r.endpoint != 0 do return true
	b: [64]u8
	w := ipc.wire_writer(b[:])
	proto.enc_endpoint_req(&w, {name = fmt.tprintf("auto-%d", posix.getpid()), owned = true})
	a, err := run_call(r, proto.MSG_ENDPOINT, ipc.wire_bytes_written(&w), ipc.CALL_DEFAULT)
	if err.kind != .None {
		run_stop(r, .Contract, "cannot open a reply endpoint")
		return false
	}
	rd := ipc.wire_reader(a.body)
	r.endpoint = ipc.wr_u32(&rd)
	return r.endpoint != 0
}

// run_listen waits in `next` on the endpoint (one slot, kept until a reply).
run_listen :: proc(r: ^Runner) {
	if r.listen != 0 do return
	b: [8]u8
	w := ipc.wire_writer(b[:])
	proto.enc_next_req(&w, {r.endpoint, 0})
	tk, err := ipc.client_start(&r.client, proto.MSG_NEXT, ipc.wire_bytes_written(&w))
	if err.kind != .None do run_stop(r, .No_Core, "the session core went away")
	r.listen = tk
}
