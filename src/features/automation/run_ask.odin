package feature_automation

// Answers from whoever runs the contract (t.ask, a missing param, the end of
// a t.handoff). The question goes to stdout as one JSON line; the answer
// comes on a terminal as a line typed on stdin.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"

// run_ask asks and waits for a valid answer (kind: string, number or boolean;
// choices, when given, lists the only valid answers).
run_ask :: proc(r: ^Runner, prompt, kind: string, choices: []string) -> (answer: string, ok: bool) {
	if r.stdin == 0 && posix.isatty(0) do r.stdin = posix.dup(0)
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"ask":%q,"type":%q`, prompt, kind)
	if len(choices) > 0 {
		strings.write_string(&b, `,"choices":[`)
		for ch, i in choices do fmt.sbprintf(&b, "%s%q", "," if i > 0 else "", ch)
		strings.write_byte(&b, ']')
	}
	strings.write_string(&b, "}")
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
	r.asking, r.replied = true, false
	defer r.asking = false
	run_wait_events(r, time.tick_diff(time.tick_now(), r.deadline), proc(r: ^Runner) -> bool { return r.replied })
	if !r.replied {
		run_stop(r, .Timeout, "no answer came before the run's time limit")
		return "", false
	}
	return r.reply, true
}

// run_reply_stdin takes a line typed on the terminal.
run_reply_stdin :: proc(r: ^Runner) {
	buf: [4096]u8
	n, err := os.read(os.stdin, buf[:])
	if err != nil || n <= 0 do return
	delete(r.reply)
	r.reply, r.replied = strings.clone(strings.trim_space(string(buf[:n]))), true
}

// run_answer_reply tells the sender of a reply how it went.
run_answer_reply :: proc(r: ^Runner, failed: bool, text: string) {
	if failed do fmt.eprintfln("term: %s", text)
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
