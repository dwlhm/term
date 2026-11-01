package term

// `term` control subcommands (client side; never creates a window).
//   term session ls | term session attach <id> | term session kill <id>
//   term show | term quit
// Exit codes: 0 ok · 1 error reply / bad usage · 2 Term is not running.

import "core:fmt"
import "core:strings"
import "core:time"

import plat_ipc "../../platform/ipc"
import ctrl_feat "../../features/control"

@(private = "file")
CLI_USAGE :: "usage: term session ls | attach <id> | kill <id> | new [-d dir] [-- prog args…] | read <id> [-n lines] | send <id> <text> | wait <id> [-t seconds] · term show · term quit"

// app_run_control_cli: handled = false when args[1] is not "session",
// "show" or "quit" (normal GUI startup continues). `session ls|kill` talk to
// the session core (app_cli_session). attach/show/quit go to the GUI's
// control socket with ipc_client_request and print nothing on success:
//   err reply → stderr "term: <message or code>", exit 1
//   Not_Running → stderr "term: Term is not running", exit 2
//   Timeout/Busy/other → stderr "term: control socket <reason>", exit 1
//   usage error (unknown/missing args) → stderr usage text, exit 1
app_run_control_cli :: proc(args: []string) -> (handled: bool, exit_code: int) {
	if len(args) < 2 do return false, 0
	line: string
	switch args[1] {
	case "show", "quit": line = strings.join(args[1:], " ", context.temp_allocator)
	case "session":
		if handled, code := app_cli_agent(args[2:]); handled do return true, code
		line = strings.join(args[2:], " ", context.temp_allocator)
	case:                return false, 0
	}
	req, perr := ctrl_feat.control_parse_request(line)
	session_verb := req.verb == .List || req.verb == .Attach || req.verb == .Kill
	if perr != .None || (args[1] == "session") != session_verb {
		fmt.eprintln(CLI_USAGE)
		return true, 1
	}
	if req.verb == .List || req.verb == .Kill do return true, app_cli_session(req)
	path_buf: [256]u8
	path, path_err := plat_ipc.ipc_default_socket_path(path_buf[:])
	if path_err != .None do return true, _cli_fail(path_err)
	req_buf: [64]u8
	reply_buf: [plat_ipc.IPC_MAX_REPLY]u8
	reply, err := app_control_request(path, ctrl_feat.control_format_request(req, req_buf[:]), reply_buf[:])
	if err != .None do return true, _cli_fail(err)
	ok, code, message, _, well_formed := ctrl_feat.control_split_reply(reply)
	if !well_formed || !ok {
		fmt.eprintf("term: %s\n", message if len(message) > 0 else (code if len(code) > 0 else "malformed reply"))
		return true, 1
	}
	return true, 0
}

// app_control_request is ipc_client_request with a short backoff on Busy
// (the server sheds load beyond IPC_MAILBOX_CAP instead of queueing it).
app_control_request :: proc(path, line: string, out: []u8) -> (reply: string, err: plat_ipc.Ipc_Error) {
	backoff := 25 * time.Millisecond
	for attempt in 0..<5 {
		reply, err = plat_ipc.ipc_client_request(path, line, out)
		if err != .Busy || attempt == 4 do return
		time.sleep(backoff)
		backoff *= 2
	}
	return
}

@(private = "file")
_cli_fail :: proc(err: plat_ipc.Ipc_Error) -> int {
	if err == .Not_Running {
		fmt.eprintln("term: Term is not running")
		return 2
	}
	fmt.eprintf("term: %s\n", plat_ipc.ipc_error_message(err))
	return 1
}
