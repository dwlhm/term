package term

// `term` control subcommands (client side; never creates a window).
//   term session ls | term session attach <id> | term session kill <id>
//   term show | term quit
// Exit codes: 0 ok · 1 error reply / bad usage · 2 Term is not running.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import plat_ipc "../../platform/ipc"
import ctrl_feat "../../features/control"

@(private = "file")
CLI_USAGE :: "usage: term session ls | term session attach <id> | term session kill <id> | term show | term quit"

@(private = "file")
CLI_COLUMNS :: 7

// app_run_control_cli: handled = false when args[1] is not "session",
// "show" or "quit" (normal GUI startup continues). Otherwise sends the request
// with ipc_client_request to ipc_default_socket_path and prints:
//   ls     → "No background sessions" or an aligned table with header
//            ID  STATE  PID  ELAPSED  PROCESS  CWD  STATUS (ELAPSED as 1h02m / 3m12s / 45s)
//   others → nothing on success
//   err reply → stderr "term: <message or code>", exit 1
//   Not_Running → stderr "term: Term is not running", exit 2
//   Timeout/Busy/other → stderr "term: control socket <reason>", exit 1
//   usage error (unknown/missing args) → stderr usage text, exit 1
app_run_control_cli :: proc(args: []string) -> (handled: bool, exit_code: int) {
	if len(args) < 2 do return false, 0
	line: string
	switch args[1] {
	case "show", "quit": line = strings.join(args[1:], " ", context.temp_allocator)
	case "session":      line = strings.join(args[2:], " ", context.temp_allocator)
	case:                return false, 0
	}
	req, perr := ctrl_feat.control_parse_request(line)
	session_verb := req.verb == .List || req.verb == .Attach || req.verb == .Kill
	if perr != .None || (args[1] == "session") != session_verb {
		fmt.eprintln(CLI_USAGE)
		return true, 1
	}
	path_buf: [256]u8
	path, path_err := plat_ipc.ipc_default_socket_path(path_buf[:])
	if path_err != .None do return true, _cli_fail(path_err)
	req_buf: [64]u8
	reply_buf: [plat_ipc.IPC_MAX_REPLY]u8
	reply, err := app_control_request(path, ctrl_feat.control_format_request(req, req_buf[:]), reply_buf[:])
	if err != .None do return true, _cli_fail(err)
	ok, code, message, body, well_formed := ctrl_feat.control_split_reply(reply)
	if !well_formed || !ok {
		fmt.eprintf("term: %s\n", message if len(message) > 0 else (code if len(code) > 0 else "malformed reply"))
		return true, 1
	}
	if req.verb == .List do _cli_print_sessions(body)
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

@(private = "file")
_cli_print_sessions :: proc(body: string) {
	table := make([dynamic][CLI_COLUMNS]string, context.temp_allocator)
	append(&table, [CLI_COLUMNS]string{"ID", "STATE", "PID", "ELAPSED", "PROCESS", "CWD", "STATUS"})
	rest := body
	for line in strings.split_lines_iterator(&rest) {
		if row, ok := ctrl_feat.control_parse_session_row(line); ok do append(&table, _cli_cells(row))
	}
	if len(table) == 1 {
		fmt.println("No background sessions")
		return
	}
	widths: [CLI_COLUMNS]int
	for cells in table do for cell, c in cells do widths[c] = max(widths[c], len(cell))
	for cells in table {
		b := strings.builder_make(context.temp_allocator)
		for cell, c in cells {
			strings.write_string(&b, cell)
			if c < CLI_COLUMNS - 1 do for _ in 0..<widths[c] - len(cell) + 2 do strings.write_byte(&b, ' ')
		}
		fmt.println(strings.to_string(b))
	}
}

@(private = "file")
_cli_cells :: proc(r: ctrl_feat.Control_Session_Row) -> [CLI_COLUMNS]string {
	state := [ctrl_feat.Control_Session_State]string{.Idle = "idle", .Busy = "busy", .Exited = "exited"}
	return {
		fmt.tprintf("%d", r.id), state[r.state], fmt.tprintf("%d", r.pid),
		_cli_elapsed(r.elapsed_s), r.process, _cli_home_relative(r.cwd), r.status,
	}
}

@(private = "file")
_cli_elapsed :: proc(s: int) -> string {
	if s < 60 do return fmt.tprintf("%ds", s)
	if s < 3600 do return fmt.tprintf("%dm%02ds", s / 60, s % 60)
	return fmt.tprintf("%dh%02dm", s / 3600, (s % 3600) / 60)
}

@(private = "file")
_cli_home_relative :: proc(cwd: string) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	if len(home) == 0 || !strings.has_prefix(cwd, home) do return cwd
	rest := cwd[len(home):]
	if len(rest) == 0 do return "~"
	return fmt.tprintf("~%s", rest) if rest[0] == '/' else cwd
}
