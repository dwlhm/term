package term

// `term session ls [--json]`: a synchronous LIST to the session core (it
// outlives every window, so this works with no GUI running).
// --json prints one JSON object per session (NDJSON), every Session_Row field.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import proto "../../features/session_proto"
import plat_ipc "../../platform/ipc"

@(private = "file")
CLI_COLUMNS :: 9

@(private = "file")
CLI_WAIT :: 3 * time.Second

app_cli_session_ls :: proc(args: []string) -> int {
	as_json := len(args) == 1 && args[0] == "--json"
	if len(args) > 0 && !as_json {
		fmt.eprintln(APP_CLI_USAGE)
		return 1
	}
	c: plat_ipc.Client
	if err := proto.session_open(&c, .Cli, false); err.kind == .No_Server {
		if !as_json do fmt.println("No sessions")
		return 0
	} else if err.kind != .None {
		return app_fail(err)
	}
	defer plat_ipc.client_close(&c)
	a, err := plat_ipc.client_call(&c, proto.MSG_LIST, nil, {timeout = CLI_WAIT})
	if err.kind != .None do return app_fail(err)
	if as_json do _cli_print_json(a.body)
	else do _cli_print_sessions(a.body)
	return 0
}

@(private = "file")
_cli_print_json :: proc(payload: []u8) {
	r := plat_ipc.wire_reader(payload)
	count := int(plat_ipc.wr_u32(&r))
	for _ in 0..<count {
		row := proto.dec_row(&r)
		if !r.ok do break
		line, err := json.marshal(row, {use_enum_names = true}, context.temp_allocator)
		if err == nil do fmt.println(string(line))
	}
}

@(private = "file")
_cli_print_sessions :: proc(payload: []u8) {
	r := plat_ipc.wire_reader(payload)
	count := int(plat_ipc.wr_u32(&r))
	table := make([dynamic][CLI_COLUMNS]string, context.temp_allocator)
	append(&table, [CLI_COLUMNS]string{"ID", "STATE", "SHOWN", "PID", "ELAPSED", "PROCESS", "CWD", "REQUEST", "STATUS"})
	for _ in 0..<count {
		row := proto.dec_row(&r)
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
_cli_cells :: proc(r: proto.Session_Row) -> [CLI_COLUMNS]string {
	state := [proto.Session_State]string{.Idle = "idle", .Busy = "busy", .Exited = "exited"}
	return {
		fmt.tprintf("%d", r.id), state[r.state], "yes" if r.attached else "-", fmt.tprintf("%d", r.pid),
		_cli_elapsed(int(r.elapsed_s)), fmt.tprintf("%s (endpoint)", _cli_clean(r.process)) if r.endpoint else _cli_clean(r.process), _cli_home_relative(_cli_clean(r.cwd)), _cli_request(r.request), _cli_clean(r.status),
	}
}

// _cli_request: "serves #7" (+N more), "awaits 2", "listens 1" (free worker slots).
@(private = "file")
_cli_request :: proc(m: proto.Row_Request) -> string {
	b := strings.builder_make(context.temp_allocator)
	if m.serving > 0 do fmt.sbprintf(&b, "serves #%d%s ", m.serving_id, fmt.tprintf("+%d", m.serving - 1) if m.serving > 1 else "")
	if m.awaiting > 0 do fmt.sbprintf(&b, "awaits %d ", m.awaiting)
	if m.listening > 0 do fmt.sbprintf(&b, "listens %d ", m.listening)
	out := strings.trim_right(strings.to_string(b), " ")
	return out if len(out) > 0 else "-"
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
