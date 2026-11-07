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
import "core:strconv"
import "core:time"
import client_feat "../../features/session_client"
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
	case "ls":   return true, app_cli_session_ls(args[1:])
	case "new":  return true, app_cli_agent_new(args[1:])
	case "whoami": return true, _agent_whoami(args[1:])
	case "next":   return true, app_cli_agent_next(args[1:])
	case "read", "observe", "tell", "cancel", "result", "answer", "progress", "watch", "run", "send", "wait", "kill", "signal", "resize":
		id, rest, ok := _agent_target(args)
		if !ok do return true, 1
		switch args[0] {
		case "read":    return true, _agent_read(id, rest)
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
		fmt.eprintfln("term: %s needs a session id: term session %s <id> (inside a term session it defaults to $%s)", args[0], args[0], plat_ipc.SESSION_ID_ENV)
	case:
		fmt.eprintfln("term: %s needs a session id: term session %s <id> … (see term session %s --help)", args[0], args[0], args[0])
	}
	return 0, nil, false
}

// app_agent_self_id is the session this process runs in ($TERM_SESSION_ID).
app_agent_self_id :: proc() -> (u32, bool) {
	return _parse_id(os.get_env(plat_ipc.SESSION_ID_ENV, context.temp_allocator))
}

@(private = "file")
_agent_whoami :: proc(args: []string) -> int {
	if len(args) != 0 {
		fmt.eprintln(APP_CLI_USAGE)
		return 1
	}
	id, inside := app_agent_self_id()
	if !inside {
		fmt.eprintfln("term: not inside a term session ($%s is not set)", plat_ipc.SESSION_ID_ENV)
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
	return app_agent_request_ok(plat_ipc.MSG_KILL, b[:])
}

@(private = "file")
_parse_id :: proc(s: string) -> (u32, bool) {
	v, ok := strconv.parse_uint(s, 10)
	return u32(v), ok && v > 0 && v <= uint(max(u32))
}

// app_agent_conn dials the core; start = new sessions may start one.
app_agent_conn :: proc(conn: ^plat_ipc.Stream_Conn, start: bool) -> bool {
	fd, ok := client_feat.client_dial(.Cli, start)
	if !ok {
		fmt.eprintln("term: no session is running")
		return false
	}
	return plat_ipc.stream_conn_init(conn, fd, 0)
}

// app_agent_request_ok sends one channel-0 request that is answered OK/FAIL.
app_agent_request_ok :: proc(kind: u8, payload: []u8) -> int {
	conn: plat_ipc.Stream_Conn
	if !app_agent_conn(&conn, false) do return 2
	defer plat_ipc.stream_conn_destroy(&conn)
	plat_ipc.stream_send(&conn, kind, 0, payload)
	_, code := app_agent_answer(&conn, plat_ipc.MSG_OK)
	return code
}

AGENT_ANSWER_MS :: 5000
AGENT_WAIT_CHUNK_MS :: 60_000 // an unbounded wait checks its connection this often
AGENT_EXIT_TIMEOUT :: 3

// app_agent_answer waits up to timeout_ms for the reply kind. Frames meant for
// someone else (row EVENTs the core broadcasts) are skipped. code is the CLI
// exit code: 0 answered, 1 FAIL or no answer, 3 FAIL Timeout (reason printed).
// timeout_ms <= 0 waits until the answer comes or the connection ends.
app_agent_answer :: proc(conn: ^plat_ipc.Stream_Conn, want: u8, timeout_ms := AGENT_ANSWER_MS) -> (f: plat_ipc.Stream_Frame, code: int) {
	forever := timeout_ms <= 0
	deadline := time.tick_now()._nsec + i64(max(timeout_ms, 0)) * 1_000_000
	for {
		left := AGENT_WAIT_CHUNK_MS if forever else int((deadline - time.tick_now()._nsec) / 1_000_000)
		got: bool
		if left > 0 do f, got = client_feat.client_wait_frame(conn, left)
		if !got && forever && conn.err == .None do continue
		if !got {
			fmt.eprintln("term: the session core did not answer")
			return {}, 1
		}
		if f.kind == want do return f, 0
		if f.kind != plat_ipc.MSG_FAIL do continue
		r := plat_ipc.wire_reader(f.payload)
		_ = plat_ipc.wr_u32(&r)
		fail := plat_ipc.Fail_Code(plat_ipc.wr_u8(&r))
		fmt.eprintf("term: %s\n", plat_ipc.wr_str(&r))
		return {}, AGENT_EXIT_TIMEOUT if fail == .Timeout else 1
	}
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
	conn: plat_ipc.Stream_Conn
	if !app_agent_conn(&conn, false) do return 2
	defer plat_ipc.stream_conn_destroy(&conn)
	b: [8]u8
	w := plat_ipc.wire_writer(b[:])
	plat_ipc.ww_u32(&w, id)
	plat_ipc.ww_u32(&w, lines)
	plat_ipc.stream_send(&conn, plat_ipc.MSG_READ, 0, b[:])
	f, code := app_agent_answer(&conn, plat_ipc.MSG_TEXT)
	if code != 0 do return code
	os.write(os.stdout, f.payload)
	return 0
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
	return app_agent_request_ok(plat_ipc.MSG_SEND, payload)
}

// app_agent_send_payload encodes a SEND of text (escapes decoded) + suffix.
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
