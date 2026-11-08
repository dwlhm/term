package term

// `term session wait <id> [-t seconds] [--exit | --text <substr>]`:
//   default  until the session runs no CLI/TUI ("idle") or exits ("exited <code>")
//   --exit   until the program exits; idle does not count
//   --text   until <substr> is on the visible screen ("found"). Only the screen
//            is checked (every WAIT_TEXT_POLL_MS): history would scroll a
//            full-screen program on every check. Text that scrolls past between
//            two checks is missed; wait for a line that stays, or --exit + read -n.
//   --listening [--quiet s]  until a worker of the session waits in `next`
//            (cli_agent_wait_listen.odin)
// Exit codes: 0 done · 1 error · 2 no core · 3 timed out (or --quiet) · 4
// (--text, --listening) the session exited or was removed first. Also the
// `send` unescape helper.

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"
import proto "../../features/session_proto"
import plat_ipc "../../platform/ipc"

@(private = "file")
WAIT_POLL_MS :: 500 // every LIST refreshes the foreground process in the core

@(private = "file")
WAIT_START_MS :: 1000 // a session that is idle at first gets this long to start its command

@(private = "file")
WAIT_TEXT_POLL_MS :: 100

@(private = "file")
Wait_Mode :: enum {Idle, Exit, Text, Listening}

app_cli_agent_wait :: proc(id: u32, args: []string) -> int {
	mode := Wait_Mode.Idle
	text: string
	limit, quiet := 600.0, 0.0
	for rest := args; len(rest) > 0; {
		switch {
		case rest[0] == "--exit" && mode == .Idle:
			mode, rest = .Exit, rest[1:]
		case rest[0] == "--text" && mode == .Idle && len(rest) >= 2 && len(rest[1]) > 0:
			mode, text, rest = .Text, rest[1], rest[2:]
		case rest[0] == "--listening" && mode == .Idle:
			mode, rest = .Listening, rest[1:]
		case rest[0] == "--quiet" && len(rest) >= 2:
			v, ok := app_arg_seconds(rest, 1)
			if !ok do return _wait_usage()
			quiet, rest = v, rest[2:]
		case rest[0] == "-t" && len(rest) >= 2:
			v, ok := strconv.parse_f64(rest[1])
			if !ok || v <= 0 do return _wait_usage()
			limit, rest = v, rest[2:]
		case:
			return _wait_usage()
		}
	}
	c: plat_ipc.Client
	if code := app_agent_open(&c, false); code != 0 do return code
	defer plat_ipc.client_close(&c)
	deadline := time.tick_now()._nsec + i64(limit * 1e9)
	if quiet > 0 && mode != .Listening do return _wait_usage()
	t := Row_Track{id = id}
	switch mode {
	case .Text:      return _wait_text(&c, &t, text, deadline)
	case .Listening: return app_wait_listening(&c, &t, deadline, quiet)
	case .Idle, .Exit:
	}
	return _wait_rows(&c, &t, deadline, mode == .Exit)
}

@(private = "file")
_wait_usage :: proc() -> int {
	fmt.eprintln(APP_CLI_USAGE)
	return 1
}

// _wait_rows returns once session id runs no CLI/TUI (0, prints "idle"; never
// with until_exit), has exited (0, prints "exited <code>") or is gone; 3 when
// the deadline passes.
// _wait_rows asks for the rows every WAIT_POLL_MS (each LIST refreshes the
// foreground process in the core) and watches for REMOVED in between.
@(private = "file")
_wait_rows :: proc(c: ^plat_ipc.Client, t: ^Row_Track, deadline_ns: i64, until_exit: bool) -> int {
	started := time.tick_now()._nsec
	seen_active := false
	for time.tick_now()._nsec < deadline_ns {
		row, code := app_track_list(c, t)
		switch {
		case t.removed:
			fmt.println("removed")
			return 0
		case code != 0:
			return code
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
		if !app_track_for(c, t, time.tick_now()._nsec + WAIT_POLL_MS * 1_000_000) do return app_fail({kind = .Closed})
	}
	fmt.eprintln("term: wait timed out")
	return 3
}

@(private = "file")
_wait_text :: proc(c: ^plat_ipc.Client, t: ^Row_Track, text: string, deadline_ns: i64) -> int {
	row, code := app_track_list(c, t)
	if code != 0 do return code
	t.row = row
	req: [8]u8
	w := plat_ipc.wire_writer(req[:])
	proto.enc_read_req(&w, {t.id, 0})
	for time.tick_now()._nsec < deadline_ns {
		a, err := plat_ipc.client_call(c, proto.MSG_READ, req[:], {on_event = app_track, data = t})
		switch {
		case t.removed || err.kind == .Failed:
			fmt.println("removed")
			return 4
		case err.kind != .None:
			return app_fail(err)
		case strings.contains(string(a.body), text):
			fmt.println("found")
			return 0
		case t.row.state == .Exited:
			fmt.printfln("exited %d", t.row.exit_code)
			return 4
		}
		if !app_track_for(c, t, time.tick_now()._nsec + WAIT_TEXT_POLL_MS * 1_000_000) do return app_fail({kind = .Closed})
	}
	fmt.eprintln("term: wait timed out")
	return 3
}

@(private)
_find_row :: proc(payload: []u8, id: u32) -> (row: proto.Session_Row, found: bool) {
	r := plat_ipc.wire_reader(payload)
	count := plat_ipc.wr_u32(&r)
	for _ in 0..<count {
		row = proto.dec_row(&r)
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
