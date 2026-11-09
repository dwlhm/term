package term

// Agent-facing session commands (served by the session core, no GUI needed):
//   term session new, kill, ls, attach, resize, whoami, read, send,
//   signal, cancel.
// Exit codes: 0 ok · 1 error · 2 no session core running · 3 timed out.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:time"
import api "../../features/session_api"
import proto "../../features/session_proto"
import plat_ipc "../../platform/ipc"


_is_help :: proc(s: string) -> bool {
	return s == "--help" || s == "-h" || s == "help"
}

@(private = "file")
_deprecated_message :: proc(verb: string) -> (string, bool) {
	switch verb {
	case "observe":
		return "observe was removed: use read (--output json)", true
	case "watch", "wait":
		return fmt.tprintf(
			"%s was removed: use read --tail --until/--prompt/--exit/--idle",
			verb,
		), true
	case "run":
		return "run was removed: send … --key Enter, " +
			"then read --tail --prompt and read --last", true
	case "tell", "result", "next", "progress", "answer":
		return fmt.tprintf(
			"%s was removed: term session no longer carries requests",
			verb,
		), true
	}
	return "", false
}

// app_cli_agent: handled = false when args[0] is not an agent verb.
app_cli_agent :: proc(args: []string) -> (handled: bool, code: int) {
	if len(args) == 0 do return false, 0
	if _is_help(args[0]) do return true, app_cli_session_help(args[1:])
	if len(args) >= 2 && _is_help(args[1]) {
		return true, app_cli_session_help([]string{args[0]})
	}
	if msg, is_dep := _deprecated_message(args[0]); is_dep {
		fmt.eprintln(msg)
		return true, 1
	}
	switch args[0] {
	case "ls":     return true, app_cli_session_ls(args[1:])
	case "new":    return true, app_cli_agent_new(args[1:])
	case "whoami": return true, _agent_whoami(args[1:])
	case "read":   return true, app_cli_session_read(args[1:])
	case "send":   return true, app_cli_session_send(args[1:])
	case "cancel", "kill", "signal", "resize":
		return _agent_dispatch_target(args)
	case:
		if args[0] != "attach" {
			fmt.eprintfln("unknown session verb %q", args[0])
			fmt.eprintln(
				"verbs: new, kill, ls, attach, resize, " +
				"whoami, read, send, signal, cancel",
			)
			return true, 1
		}
	}
	return false, 0
}

@(private = "file")
_agent_dispatch_target :: proc(args: []string) -> (bool, int) {
	id, rest, ok := _agent_target(args)
	if !ok do return true, 1
	switch args[0] {
	case "cancel": return true, app_cli_session_cancel(id, rest)
	case "kill":   return true, _agent_kill(id, rest)
	case "signal": return true, app_cli_agent_signal(id, rest)
	case "resize": return true, app_cli_agent_resize(id, rest)
	}
	return false, 0
}

// _agent_target: the session a verb acts on. Verbs that only look at a session
// (read, observe) default to the caller's own ($TERM_SESSION_ID); verbs
// that change one always need an explicit id.
_agent_target :: proc(args: []string) -> (id: u32, rest: []string, ok: bool) {
	if len(args) >= 2 {
		if v, is_id := _parse_id(args[1]); is_id {
			return v, args[2:], true
		} else {
			fmt.eprintln("not a session id")
			return 0, nil, false
		}
	}
	switch args[0] {
	case "read":
		if self, inside := app_agent_self_id(); inside {
			return self, args[1:], true
		}
		fmt.eprintfln("which session? %s <id>", args[0])
	case:
		fmt.eprintfln("usage: term session %s <id>", args[0])
	}
	return 0, nil, false
}

// app_agent_self_id is the session this process runs in ($TERM_SESSION_ID).
app_agent_self_id :: proc() -> (u32, bool) {
	return _parse_id(os.get_env(proto.SESSION_ID_ENV, context.temp_allocator))
}

@(private = "file")
_agent_verify_session :: proc(id: u32) -> int {
	c: plat_ipc.Client
	if err := proto.session_open(&c, .Cli, false); err.kind != .None {
		if err.kind == .No_Server {
			fmt.eprintln("no term session is running")
			return 2
		}
		return 1
	}
	defer plat_ipc.client_close(&c)

	buf: [32]u8
	w := plat_ipc.wire_writer(buf[:])
	proto.enc_snapshot_req(&w, {id = id, history = 0, since = -1})
	_, err := plat_ipc.client_call(
		&c, proto.MSG_SNAPSHOT,
		plat_ipc.wire_bytes_written(&w), {timeout = 2 * time.Second},
	)
	if err.kind == .Failed && proto.Fail_Code(err.code) == .Not_Found {
		fmt.eprintfln("no session %d", id)
		return 1
	}
	return 0
}

_agent_whoami :: proc(args: []string) -> int {
	if len(args) != 0 {
		fmt.eprintln(APP_CLI_USAGE)
		return 1
	}
	id, inside := app_agent_self_id()
	if !inside {
		fmt.eprintln("not inside a term session")
		return 1
	}
	if code := _agent_verify_session(id); code != 0 {
		return code
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
	c: plat_ipc.Client
	if err := api.api_open(&c, false); err.kind != .None {
		return app_fail(err)
	}
	defer plat_ipc.client_close(&c)
	return app_fail(api.api_kill(&c, id))
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
app_agent_call :: proc(
	kind: u8,
	body: []u8,
	opts := plat_ipc.Call_Opts{},
	start := false,
) -> (
	answer: []u8,
	code: int,
) {
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
	case .No_Server:
		return 2
	case .Failed:
		if err.code == plat_ipc.FAIL_TIMEOUT do return AGENT_EXIT_TIMEOUT
	}
	return 1
}
