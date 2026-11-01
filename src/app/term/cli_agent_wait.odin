package term

// `term session wait <id> [-t seconds] [--exit | --text <substr>]`:
//   default  until the session runs no CLI/TUI ("idle") or exits ("exited <code>")
//   --exit   until the program exits; idle does not count
//   --text   until <substr> is on the visible screen ("found"). Only the screen
//            is checked (every WAIT_TEXT_POLL_MS): history would scroll a
//            full-screen program on every check. Text that scrolls past between
//            two checks is missed; wait for a line that stays, or --exit + read -n.
// Exit codes: 0 done · 1 error · 2 no core · 3 timed out · 4 (--text) the
// session exited or was removed first. Also the `send` unescape helper.

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"
import client_feat "../../features/session_client"
import plat_ipc "../../platform/ipc"

@(private = "file")
WAIT_POLL_MS :: 500 // every LIST refreshes the foreground process in the core

@(private = "file")
WAIT_START_MS :: 1000 // a session that is idle at first gets this long to start its command

@(private = "file")
WAIT_TEXT_POLL_MS :: 100

@(private = "file")
Wait_Mode :: enum {Idle, Exit, Text}

app_cli_agent_wait :: proc(id: u32, args: []string) -> int {
	mode := Wait_Mode.Idle
	text: string
	limit := 600.0
	for rest := args; len(rest) > 0; {
		switch {
		case rest[0] == "--exit" && mode == .Idle:
			mode, rest = .Exit, rest[1:]
		case rest[0] == "--text" && mode == .Idle && len(rest) >= 2 && len(rest[1]) > 0:
			mode, text, rest = .Text, rest[1], rest[2:]
		case rest[0] == "-t" && len(rest) >= 2:
			v, ok := strconv.parse_f64(rest[1])
			if !ok || v <= 0 do return _wait_usage()
			limit, rest = v, rest[2:]
		case:
			return _wait_usage()
		}
	}
	conn: plat_ipc.Stream_Conn
	if !app_agent_conn(&conn, false) do return 2
	defer plat_ipc.stream_conn_destroy(&conn)
	deadline := time.tick_now()._nsec + i64(limit * 1e9)
	if mode == .Text do return _wait_text(&conn, id, text, deadline)
	plat_ipc.stream_send(&conn, plat_ipc.MSG_LIST, 0)
	return _wait_rows(&conn, id, deadline, mode == .Exit)
}

@(private = "file")
_wait_usage :: proc() -> int {
	fmt.eprintln(APP_CLI_USAGE)
	return 1
}

// _wait_rows returns once session id runs no CLI/TUI (0, prints "idle"; never
// with until_exit), has exited (0, prints "exited <code>") or is gone; 3 when
// the deadline passes.
@(private = "file")
_wait_rows :: proc(conn: ^plat_ipc.Stream_Conn, id: u32, deadline_ns: i64, until_exit: bool) -> int {
	started := time.tick_now()._nsec
	seen_active := false
	for time.tick_now()._nsec < deadline_ns {
		f, got := client_feat.client_wait_frame(conn, WAIT_POLL_MS)
		if !got {
			if conn.err != .None do return 1
			plat_ipc.stream_send(conn, plat_ipc.MSG_LIST, 0)
			continue
		}
		if f.kind == plat_ipc.MSG_REMOVED && _removed_id(f.payload) == id {
			fmt.println("removed")
			return 0
		}
		if f.kind != plat_ipc.MSG_SESSIONS do continue
		row, found := _find_row(f.payload, id)
		switch {
		case !found:
			fmt.eprintln("term: no such session")
			return 1
		case row.state == .Exited:
			fmt.printfln("exited %d", row.exit_code)
			return 0
		case until_exit:
		case row.active:
			seen_active = true
		case seen_active || time.tick_now()._nsec - started >= WAIT_START_MS * 1_000_000:
			fmt.println("idle")
			return 0
		}
	}
	fmt.eprintln("term: wait timed out")
	return 3
}

// _wait_text reads the screen every WAIT_TEXT_POLL_MS until it holds text.
@(private = "file")
_wait_text :: proc(conn: ^plat_ipc.Stream_Conn, id: u32, text: string, deadline_ns: i64) -> int {
	plat_ipc.stream_send(conn, plat_ipc.MSG_LIST, 0)
	row, ok := _first_row(conn, id)
	if !ok do return 1
	exited, exit_code := row.state == .Exited, row.exit_code
	req: [8]u8
	w := plat_ipc.wire_writer(req[:])
	plat_ipc.ww_u32(&w, id)
	plat_ipc.ww_u32(&w, 0)
	for time.tick_now()._nsec < deadline_ns {
		plat_ipc.stream_send(conn, plat_ipc.MSG_READ, 0, req[:])
		screen, answer := _screen_answer(conn, id, &exited, &exit_code)
		switch answer {
		case .Lost:
			fmt.eprintln("term: the session core did not answer")
			return 1
		case .Removed:
			fmt.println("removed")
			return 4
		case .Text:
			if strings.contains(screen, text) {
				fmt.println("found")
				return 0
			}
		}
		if exited {
			fmt.printfln("exited %d", exit_code)
			return 4
		}
		time.sleep(WAIT_TEXT_POLL_MS * time.Millisecond)
	}
	fmt.eprintln("term: wait timed out")
	return 3
}

@(private = "file")
Screen_Answer :: enum {Text, Removed, Lost}

// _screen_answer waits for the TEXT answer of one READ. An exit seen (EVENT)
// before it means that screen is the program's last one.
@(private = "file")
_screen_answer :: proc(conn: ^plat_ipc.Stream_Conn, id: u32, exited: ^bool, exit_code: ^i32) -> (string, Screen_Answer) {
	for {
		f, got := client_feat.client_wait_frame(conn, 5000)
		if !got do return "", .Lost
		switch f.kind {
		case plat_ipc.MSG_TEXT:
			return string(f.payload), .Text
		case plat_ipc.MSG_FAIL:
			return "", .Removed
		case plat_ipc.MSG_REMOVED:
			if _removed_id(f.payload) == id do return "", .Removed
		case plat_ipc.MSG_EVENT:
			r := plat_ipc.wire_reader(f.payload)
			if ev := plat_ipc.dec_row(&r); r.ok && ev.id == id && ev.state == .Exited do exited^, exit_code^ = true, ev.exit_code
		}
	}
}

// _first_row waits for the SESSIONS answer and finds id in it.
@(private = "file")
_first_row :: proc(conn: ^plat_ipc.Stream_Conn, id: u32) -> (plat_ipc.Session_Row, bool) {
	f, ok := app_agent_answer(conn, plat_ipc.MSG_SESSIONS)
	if !ok do return {}, false
	row, found := _find_row(f.payload, id)
	if !found do fmt.eprintln("term: no such session")
	return row, found
}

@(private = "file")
_removed_id :: proc(payload: []u8) -> u32 {
	r := plat_ipc.wire_reader(payload)
	return plat_ipc.wr_u32(&r)
}

@(private = "file")
_find_row :: proc(payload: []u8, id: u32) -> (row: plat_ipc.Session_Row, found: bool) {
	r := plat_ipc.wire_reader(payload)
	count := plat_ipc.wr_u32(&r)
	for _ in 0..<count {
		row = plat_ipc.dec_row(&r)
		if !r.ok do break
		if row.id == id do return row, true
	}
	return {}, false
}

// app_cli_unescape writes s into out resolving \n \r \t \e \\ \xHH; -1 on a bad
// escape or when out is too small.
app_cli_unescape :: proc(s: string, out: []u8) -> int {
	n, i := 0, 0
	for i < len(s) {
		if n >= len(out) do return -1
		ch := s[i]
		i += 1
		if ch != '\\' {
			out[n] = ch
			n += 1
			continue
		}
		if i >= len(s) do return -1
		esc := s[i]
		i += 1
		switch esc {
		case 'n':  out[n] = '\n'
		case 'r':  out[n] = '\r'
		case 't':  out[n] = '\t'
		case 'e':  out[n] = 0x1b
		case '\\': out[n] = '\\'
		case 'x':
			if i + 2 > len(s) do return -1
			hi, lo := _hex(s[i]), _hex(s[i + 1])
			if hi < 0 || lo < 0 do return -1
			out[n] = u8(hi << 4 | lo)
			i += 2
		case:
			return -1
		}
		n += 1
	}
	return n
}

@(private = "file")
_hex :: proc(ch: u8) -> int {
	switch ch {
	case '0'..='9': return int(ch - '0')
	case 'a'..='f': return int(ch - 'a') + 10
	case 'A'..='F': return int(ch - 'A') + 10
	}
	return -1
}
