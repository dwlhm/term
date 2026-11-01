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

APP_CLI_USAGE :: "usage: term session ls [--json] | new [-d dir] [-s COLSxROWS] [-e KEY=VAL]… [-- prog args…] | read <id> [-n lines] | send <id> <text> | wait <id> [-t seconds] [--exit | --text <substr>] | signal <id> <INT|TERM|…|n> | resize <id> <COLSxROWS> | kill <id> | attach <id> · term show · term quit"

// app_cli_agent: handled = false when args[0] is not an agent verb.
app_cli_agent :: proc(args: []string) -> (handled: bool, code: int) {
	if len(args) == 0 do return false, 0
	switch args[0] {
	case "ls":   return true, app_cli_session_ls(args[1:])
	case "new":  return true, app_cli_agent_new(args[1:])
	case "read", "send", "wait", "kill", "signal", "resize":
		id, ok := _agent_id(args)
		if !ok {
			fmt.eprintln(APP_CLI_USAGE)
			return true, 1
		}
		switch args[0] {
		case "read": return true, _agent_read(id, args[2:])
		case "send": return true, _agent_send(id, args[2:])
		case "kill": return true, _agent_kill(id, args[2:])
		case "wait": return true, app_cli_agent_wait(id, args[2:])
		case "signal": return true, app_cli_agent_signal(id, args[2:])
		case "resize": return true, app_cli_agent_resize(id, args[2:])
		}
	}
	return false, 0
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
_agent_id :: proc(args: []string) -> (u32, bool) {
	if len(args) < 2 do return 0, false
	v, ok := strconv.parse_uint(args[1], 10)
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
	_, ok := app_agent_answer(&conn, plat_ipc.MSG_OK)
	return 0 if ok else 1
}

// app_agent_answer waits for the reply kind, printing a FAIL reason.
app_agent_answer :: proc(conn: ^plat_ipc.Stream_Conn, want: u8) -> (plat_ipc.Stream_Frame, bool) {
	for {
		f, got := client_feat.client_wait_frame(conn, 5000)
		if !got {
			fmt.eprintln("term: the session core did not answer")
			return {}, false
		}
		if f.kind == want do return f, true
		if f.kind == plat_ipc.MSG_FAIL {
			r := plat_ipc.wire_reader(f.payload)
			_, _ = plat_ipc.wr_u32(&r), plat_ipc.wr_u8(&r)
			fmt.eprintf("term: %s\n", plat_ipc.wr_str(&r))
			return {}, false
		}
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
	f, ok := app_agent_answer(&conn, plat_ipc.MSG_TEXT)
	if !ok do return 1
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
	w := plat_ipc.wire_writer(msg[:])
	plat_ipc.ww_u32(&w, id)
	n := app_cli_unescape(args[0], msg[w.n:])
	if n < 0 {
		fmt.eprintln("term: text too long or bad escape")
		return 1
	}
	return app_agent_request_ok(plat_ipc.MSG_SEND, msg[:w.n + n])
}
