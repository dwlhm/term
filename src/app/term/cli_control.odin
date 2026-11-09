package term

// `term` control subcommands (client side; never creates a window).
// Session verbs served by the core live in cli_agent.odin; this file sends
// `term session attach <id>`, `term show` and `term quit` to the GUI.
// Exit codes: 0 ok · 1 error reply / bad usage · 2 Term is not running.

import "core:fmt"
import "core:strings"
import "core:time"

import proto "../../features/session_proto"
import plat_ipc "../../platform/ipc"
import ctrl_feat "../../features/control"

// app_run_control_cli: handled = false when args[1] is not "session",
// "show" or "quit" (normal GUI startup continues). Core verbs go to
// app_cli_agent; attach/show/quit go to the GUI's control socket with
// ipc.line_call and print nothing on success:
//   err reply → stderr "term: <message or code>", exit 1
//   No_Server → stderr "term: Term is not running", exit 2
//   Timeout/Busy/other → stderr "term: control socket: <reason>", exit 1
//   usage error (unknown/missing args) → stderr usage text, exit 1
app_run_control_cli :: proc(args: []string) -> (handled: bool, exit_code: int) {
	if len(args) < 2 do return false, 0
	line: string
	switch args[1] {
	case "--help", "-h", "help": return true, app_cli_help()
	case "skill":                return true, app_cli_skill(args[2:])
	case "auto":                 return true, app_cli_auto(args[2:])
	case "show", "quit": line = strings.join(args[1:], " ", context.temp_allocator)
	case "session":
		if handled, code := app_cli_agent(args[2:]); handled do return true, code
		line = strings.join(args[2:], " ", context.temp_allocator)
	case:                return false, 0
	}
	req, perr := ctrl_feat.control_parse_request(line)
	if perr != .None || (args[1] == "session") != (req.verb == .Attach) {
		fmt.eprintln(APP_CLI_USAGE)
		return true, 1
	}
	at_buf: [256]u8
	at, aerr := proto.control_endpoint(at_buf[:])
	if aerr.kind != .None do return true, _cli_fail(aerr)
	req_buf: [64]u8
	reply_buf: [proto.CONTROL_MAX_REPLY]u8
	reply, err := app_control_request(at, ctrl_feat.control_format_request(req, req_buf[:]), reply_buf[:])
	if err.kind != .None do return true, _cli_fail(err)
	ok, code, message, _, well_formed := ctrl_feat.control_split_reply(reply)
	if !well_formed || !ok {
		msg := message
		if len(msg) == 0 {
			msg = code if len(code) > 0 else "malformed reply"
		}
		fmt.eprintfln("term: %s", msg)
		if code == "exited" || strings.contains(msg, "has exited") {
			return true, 4
		}
		return true, 1
	}
	return true, 0
}

// app_control_request is ipc.line_call with a short backoff while the .Line
// server sheds load: it answers overload in-band as "err busy\n".
app_control_request :: proc(at: plat_ipc.Endpoint, line: string, out: []u8) -> (reply: string, err: plat_ipc.Error) {
	backoff := 25 * time.Millisecond
	for attempt in 0..<5 {
		reply, err = plat_ipc.line_call(at, line, out)
		if err.kind != .None || reply != "err busy\n" || attempt == 4 do return
		time.sleep(backoff)
		backoff *= 2
	}
	return
}

@(private = "file")
_cli_fail :: proc(err: plat_ipc.Error) -> int {
	if err.kind == .No_Server {
		fmt.eprintln("no window is open: run term")
		return 1
	}
	reason := err.reason if len(err.reason) > 0 else plat_ipc.error_message(err)
	fmt.eprintfln("term: control socket: %s", reason)
	return 1
}
