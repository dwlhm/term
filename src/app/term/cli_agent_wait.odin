package term

// `term session wait` and `send` helpers.

import "core:fmt"
import "core:time"
import client_feat "../../features/session_client"
import plat_ipc "../../platform/ipc"

@(private = "file")
WAIT_POLL_MS :: 500 // every LIST refreshes the foreground process in the core

@(private = "file")
WAIT_START_MS :: 1000 // a session that is idle at first gets this long to start its command

// app_cli_wait_rows returns once session id runs no CLI/TUI (0, prints "idle"),
// has exited (0, prints "exited <code>") or is gone; 3 when deadline passes.
app_cli_wait_rows :: proc(conn: ^plat_ipc.Stream_Conn, id: u32, deadline_ns: i64) -> int {
	started := time.tick_now()._nsec
	seen_active := false
	for time.tick_now()._nsec < deadline_ns {
		f, got := client_feat.client_wait_frame(conn, WAIT_POLL_MS)
		if !got {
			if conn.err != .None do return 1
			plat_ipc.stream_send(conn, plat_ipc.MSG_LIST, 0)
			continue
		}
		if f.kind == plat_ipc.MSG_REMOVED {
			r := plat_ipc.wire_reader(f.payload)
			if plat_ipc.wr_u32(&r) == id {
				fmt.println("removed")
				return 0
			}
			continue
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
