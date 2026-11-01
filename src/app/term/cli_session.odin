package term

// `term session ls` / `term session kill <id>`: synchronous requests to the
// session core (it outlives every window, so these work with no GUI running).

import "core:fmt"
import "core:os"
import "core:strings"
import ctrl_feat "../../features/control"
import client_feat "../../features/session_client"
import plat_ipc "../../platform/ipc"

@(private = "file")
CLI_COLUMNS :: 8

@(private = "file")
CLI_WAIT_MS :: 3000

app_cli_session :: proc(req: ctrl_feat.Control_Request) -> int {
	fd, ok := client_feat.client_dial(.Cli, false)
	if !ok {
		if req.verb == .List {
			fmt.println("No sessions")
			return 0
		}
		fmt.eprintln("term: no session is running")
		return 2
	}
	conn: plat_ipc.Stream_Conn
	if !plat_ipc.stream_conn_init(&conn, fd, 0) do return 1
	defer plat_ipc.stream_conn_destroy(&conn)
	if req.verb == .List {
		plat_ipc.stream_send(&conn, plat_ipc.MSG_LIST, 0)
	} else {
		b: [4]u8
		w := plat_ipc.wire_writer(b[:])
		plat_ipc.ww_u32(&w, req.id)
		plat_ipc.stream_send(&conn, plat_ipc.MSG_KILL, 0, b[:])
	}
	for {
		f, got := client_feat.client_wait_frame(&conn, CLI_WAIT_MS)
		if !got {
			fmt.eprintln("term: the session core did not answer")
			return 1
		}
		switch f.kind {
		case plat_ipc.MSG_SESSIONS:
			_cli_print_sessions(f.payload)
			return 0
		case plat_ipc.MSG_OK:
			return 0
		case plat_ipc.MSG_FAIL:
			r := plat_ipc.wire_reader(f.payload)
			_, _ = plat_ipc.wr_u32(&r), plat_ipc.wr_u8(&r)
			fmt.eprintf("term: %s\n", plat_ipc.wr_str(&r))
			return 1
		}
	}
}

@(private = "file")
_cli_print_sessions :: proc(payload: []u8) {
	r := plat_ipc.wire_reader(payload)
	count := int(plat_ipc.wr_u32(&r))
	table := make([dynamic][CLI_COLUMNS]string, context.temp_allocator)
	append(&table, [CLI_COLUMNS]string{"ID", "STATE", "SHOWN", "PID", "ELAPSED", "PROCESS", "CWD", "STATUS"})
	for _ in 0..<count {
		row := plat_ipc.dec_row(&r)
		if !r.ok do break
		append(&table, _cli_cells(row))
	}
	if len(table) == 1 {
		fmt.println("No sessions")
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
_cli_cells :: proc(r: plat_ipc.Session_Row) -> [CLI_COLUMNS]string {
	state := [plat_ipc.Session_State]string{.Idle = "idle", .Busy = "busy", .Exited = "exited"}
	return {
		fmt.tprintf("%d", r.id), state[r.state], "yes" if r.attached else "-", fmt.tprintf("%d", r.pid),
		_cli_elapsed(int(r.elapsed_s)), _cli_clean(r.process), _cli_home_relative(_cli_clean(r.cwd)), _cli_clean(r.status),
	}
}

// _cli_clean drops control characters a program may have put in its title/status.
@(private = "file")
_cli_clean :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for ch in s do if ch >= ' ' && ch != 0x7f do strings.write_rune(&b, ch)
	return strings.to_string(b)
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
