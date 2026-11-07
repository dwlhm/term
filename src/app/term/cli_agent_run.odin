package term

// `term session run <id> <command>`: a `tell` for the session's shell adapter
// only (never a worker): the command is typed at the shell prompt once it is
// there, and its output (OSC 133;C to 133;D) and exit status come back. The
// broker owns it like any request: busy shells reject it, ^C here or -t ends
// it and stops the command.

import "core:fmt"
import "core:strconv"
import "core:strings"
import plat_ipc "../../platform/ipc"

app_cli_agent_run :: proc(id: u32, args: []string) -> int {
	command, timeout_s, lines, as_json, ok := _parse_run_args(args)
	if !ok {
		fmt.eprintln("usage: term session run <id> <command> [-t seconds] [-n lines] [--json]")
		return 1
	}
	conn: plat_ipc.Stream_Conn
	if !app_agent_conn(&conn, false) do return 2
	defer plat_ipc.stream_conn_destroy(&conn)
	from, _ := app_agent_self_id()
	msg := make([]u8, len(command) + 64, context.temp_allocator)
	w := plat_ipc.wire_writer(msg)
	plat_ipc.enc_tell_req(&w, {to = id, from = from, timeout_ms = u32(timeout_s * 1000), wait = true, shell = true, body = command})
	plat_ipc.stream_send(&conn, plat_ipc.MSG_TELL, 0, plat_ipc.wire_bytes_written(&w))
	res, code := app_tell_answer(&conn, AGENT_ANSWER_MS)
	for code == 0 && (res.phase == .Accepted || res.phase == .Progress) {
		res, code = app_tell_answer(&conn, int(timeout_s * 1000) + WATCH_GRACE_MS)
	}
	if code != 0 do return code
	if lines > 0 do res.text = _tail_lines(res.text, int(lines))
	return app_print_tell(res, as_json)
}

// _tail_lines keeps the last n lines of text.
@(private = "file")
_tail_lines :: proc(text: string, n: int) -> string {
	end := len(text)
	if end > 0 && text[end - 1] == '\n' do end -= 1
	seen := 0
	for i := end - 1; i >= 0; i -= 1 {
		if text[i] != '\n' do continue
		seen += 1
		if seen == n do return text[i + 1:]
	}
	return text
}

@(private = "file")
_parse_run_args :: proc(args: []string) -> (command: string, timeout_s: f64, lines: u32, as_json, ok: bool) {
	timeout_s = WATCH_DEFAULT_S
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--json": as_json = true
		case "-t":
			i += 1
			timeout_s = app_arg_seconds(args, i) or_return
		case "-n":
			i += 1
			if i >= len(args) do return
			v, v_ok := strconv.parse_uint(args[i], 10)
			if !v_ok || v == 0 || v > uint(max(u32)) do return
			lines = u32(v)
		case:
			if len(command) > 0 do return
			command = args[i]
		}
	}
	return command, timeout_s, lines, as_json, len(strings.trim_space(command)) > 0
}
