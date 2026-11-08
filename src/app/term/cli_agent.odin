package term

// Agent-facing session commands (served by the session core, no GUI needed):
//   term session new [-d dir] [-s CxR] [-e K=V]… [-- prog args…] → prints the new id
//   term session read <id> [-n <history lines>]          → plain text: history + screen
//   term session send <id> <text>                        → types text (\n \r \t \e \\ \xHH)
//   term session wait <id> [-t s] [--exit|--text <substr>] → see cli_agent_wait.odin
//   term session signal <id> <name|number>               → to the foreground job, like ^C
//   term session resize <id> <COLSxROWS>                 → only while no window shows it
// Exit codes: 0 ok · 1 error · 2 no session core running · 3 wait timed out ·
// 4 wait --text: the session ended first.
//
// `read -n N` of a windowed program that keeps its own history (alternate
// screen) scrolls it: the core sends mouse-wheel notches the way the program
// asked for them, waits for each page to settle and glues the pages, then puts
// the view back where it was. That takes up to a few seconds. A program that
// does not report mouse input cannot be scrolled: its visible screen is
// answered with a note saying so.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import proto "../../features/session_proto"
import plat_ipc "../../platform/ipc"


// app_cli_agent: handled = false when args[0] is not an agent verb.
app_cli_agent :: proc(args: []string) -> (handled: bool, code: int) {
	if len(args) == 0 do return false, 0
	if args[0] == "--help" || args[0] == "-h" || args[0] == "help" {
		return true, app_cli_session_help(args[1:])
	}
	if len(args) >= 2 && (args[1] == "--help" || args[1] == "-h" || args[1] == "help") {
		return true, app_cli_session_help([]string{args[0]})
	}
	switch args[0] {
	case "ls":     return true, app_cli_session_ls(args[1:])
	case "new":    return true, app_cli_agent_new(args[1:])
	case "whoami": return true, _agent_whoami(args[1:])
	case "next":   return true, app_cli_agent_next(args[1:])
	case "read":   return true, app_cli_session_read(args[1:])
	case "observe", "tell", "cancel", "result", "answer", "progress", "watch", "run", "send", "wait", "kill", "signal", "resize":
		id, rest, ok := _agent_target(args)
		if !ok do return true, 1
		switch args[0] {
		case "observe": return true, app_cli_agent_observe(id, rest)
		case "tell":    return true, app_cli_agent_tell(id, rest)
		case "cancel":  return true, app_cli_agent_cancel(id, rest)
		case "result":  return true, app_cli_agent_result(id, rest)
		case "answer":  return true, app_cli_agent_answer(id, rest, true)
		case "progress": return true, app_cli_agent_answer(id, rest, false)
		case "watch":   return true, app_cli_agent_watch(id, rest)
		case "run":     return true, app_cli_agent_run(id, rest)
		case "send":    return true, _agent_send(id, rest)
		case "kill":    return true, _agent_kill(id, rest)
		case "wait":    return true, app_cli_agent_wait(id, rest)
		case "signal":  return true, app_cli_agent_signal(id, rest)
		case "resize":  return true, app_cli_agent_resize(id, rest)
		}
	}
	return false, 0
}

// _agent_target: the session a verb acts on. Verbs that only look at a session
// (read, observe) default to the caller's own ($TERM_SESSION_ID); verbs
// that change one always need an explicit id.
@(private = "file")
_agent_target :: proc(args: []string) -> (id: u32, rest: []string, ok: bool) {
	if len(args) >= 2 {
		if v, is_id := _parse_id(args[1]); is_id do return v, args[2:], true
	}
	switch args[0] {
	case "read", "observe":
		if self, inside := app_agent_self_id(); inside do return self, args[1:], true
		fmt.eprintfln("term: %s needs a session id: term session %s <id> (inside a term session it defaults to $%s)", args[0], args[0], proto.SESSION_ID_ENV)
	case:
		fmt.eprintfln("term: %s needs a session id: term session %s <id> … (see term session %s --help)", args[0], args[0], args[0])
	}
	return 0, nil, false
}

// app_agent_self_id is the session this process runs in ($TERM_SESSION_ID).
app_agent_self_id :: proc() -> (u32, bool) {
	return _parse_id(os.get_env(proto.SESSION_ID_ENV, context.temp_allocator))
}

@(private = "file")
_agent_whoami :: proc(args: []string) -> int {
	if len(args) != 0 {
		fmt.eprintln(APP_CLI_USAGE)
		return 1
	}
	id, inside := app_agent_self_id()
	if !inside {
		fmt.eprintfln("term: not inside a term session ($%s is not set)", proto.SESSION_ID_ENV)
		return 1
	}
	fmt.println(id)
	return 0
}

@(private = "file")
_agent_kill :: proc(id: u32, args: []string) -> int {
	if len(args) != 0 {
		fmt.eprintln(APP_CLI_USAGE)
		return 1
	}
	b: [4]u8
	w := plat_ipc.wire_writer(b[:])
	plat_ipc.ww_u32(&w, id)
	return app_agent_request_ok(proto.MSG_KILL, b[:])
}

@(private = "file")
_parse_id :: proc(s: string) -> (u32, bool) {
	v, ok := strconv.parse_uint(s, 10)
	return u32(v), ok && v > 0 && v <= uint(max(u32))
}

// app_agent_open connects c to the session core (start: a new session may
// start one). 0, or the exit code with the reason printed.
app_agent_open :: proc(c: ^plat_ipc.Client, start: bool) -> int {
	return app_fail(proto.session_open(c, .Cli, start))
}

// app_agent_call opens a connection, sends one request and closes; the
// answer body is copied to the temp allocator. code is the exit code.
app_agent_call :: proc(kind: u8, body: []u8, opts := plat_ipc.Call_Opts{}, start := false) -> (answer: []u8, code: int) {
	c: plat_ipc.Client
	if code = app_agent_open(&c, start); code != 0 do return
	defer plat_ipc.client_close(&c)
	a, err := plat_ipc.client_call(&c, kind, body, opts)
	if err.kind != .None do return nil, app_fail(err)
	return slice.clone(a.body, context.temp_allocator), 0
}

// app_agent_request_ok sends one request answered OK or FAIL.
app_agent_request_ok :: proc(kind: u8, payload: []u8) -> int {
	_, code := app_agent_call(kind, payload)
	return code
}

AGENT_EXIT_TIMEOUT :: 3

// app_fail prints why a session link call failed and returns the CLI exit
// code: 0 none, 2 no session core, 3 the core answered Timeout (a wait ran
// out), 130 interrupted, 1 anything else.
app_fail :: proc(err: plat_ipc.Error) -> int {
	#partial switch err.kind {
	case .None:        return 0
	case .Interrupted: return 130
	}
	fmt.eprintfln("term: %s", proto.error_text(err))
	#partial switch err.kind {
	case .No_Server: return 2
	case .Failed:    if err.code == plat_ipc.FAIL_TIMEOUT do return AGENT_EXIT_TIMEOUT
	}
	return 1
}

@(private = "file")
_agent_read :: proc(id: u32, args: []string) -> int {
	lines := u32(0)
	if len(args) == 2 && args[0] == "-n" {
		v, ok := strconv.parse_uint(args[1], 10)
		if !ok {
			fmt.eprintln(APP_CLI_USAGE)
			return 1
		}
		lines = u32(min(v, uint(max(u32))))
	} else if len(args) != 0 {
		fmt.eprintln(APP_CLI_USAGE)
		return 1
	}
	b: [8]u8
	w := plat_ipc.wire_writer(b[:])
	proto.enc_read_req(&w, {id, lines, false})
	text, code := app_agent_call(proto.MSG_READ, b[:])
	if code == 0 do os.write(os.stdout, text)
	return code
}

@(private = "file")
_agent_send :: proc(id: u32, args: []string) -> int {
	if len(args) != 1 {
		fmt.eprintln(APP_CLI_USAGE)
		return 1
	}
	msg: [16 * 1024]u8
	payload, ok := app_agent_send_payload(msg[:], id, args[0], "")
	if !ok do return 1
	return app_agent_request_ok(proto.MSG_SEND, payload)
}

// app_agent_send_payload encodes a SEND (Send_Request) of text (escapes
// decoded) + suffix.
app_agent_send_payload :: proc(buf: []u8, id: u32, text, suffix: string) -> ([]u8, bool) {
	w := plat_ipc.wire_writer(buf)
	plat_ipc.ww_u32(&w, id)
	n := app_cli_unescape(text, buf[w.n:])
	if n < 0 || w.n + n + len(suffix) > len(buf) {
		fmt.eprintln("term: text too long or bad escape")
		return nil, false
	}
	n += copy(buf[w.n + n:], suffix)
	return buf[:w.n + n], true
}
