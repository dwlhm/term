package term

// `term session ls [--output text|json]`: synchronous LIST to session core.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import api "../../features/session_api"
import proto "../../features/session_proto"
import plat_ipc "../../platform/ipc"

@(private = "file")
CLI_COLUMNS :: 8

Ls_Json_Row :: struct {
	id:        u32,
	state:     string,
	exit_code: i32,
	pid:       u32,
	process:   string,
	cwd:       string,
	cols:      u16,
	rows:      u16,
	attached:  bool,
	held_by:   string,
	title:     string,
}

app_cli_session_ls :: proc(args: []string) -> int {
	as_json, ok := _ls_parse_args(args)
	if !ok do return 1

	c: plat_ipc.Client
	if err := api.api_open(&c, false); err.kind == .No_Server {
		if as_json do fmt.println("[]")
		else do _print_empty_header()
		return 0
	} else if err.kind != .None {
		return app_fail(err)
	}
	defer plat_ipc.client_close(&c)

	rows, err := api.api_ls(&c, context.temp_allocator)
	if err.kind != .None do return app_fail(err)

	if as_json do _cli_print_json(rows)
	else do _cli_print_sessions(rows)
	return 0
}

@(private = "file")
_ls_parse_args :: proc(args: []string) -> (as_json: bool, ok: bool) {
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		switch arg {
		case "--json":
			as_json = true
		case "--output":
			if i + 1 >= len(args) {
				fmt.eprintln("--output is text or json")
				return false, false
			}
			val := args[i + 1]
			i += 1
			switch val {
			case "json": as_json = true
			case "text": as_json = false
			case:
				fmt.eprintln("--output is text or json")
				return false, false
			}
		case:
			fmt.eprintfln("unknown option: %s", arg)
			return false, false
		}
	}
	return as_json, true
}

@(private = "file")
_print_empty_header :: proc() {
	header := [CLI_COLUMNS]string{
		"ID", "STATE", "PID", "PROCESS", "CWD", "SIZE", "HELD-BY", "TITLE",
	}
	b := strings.builder_make(context.temp_allocator)
	for h, i in header {
		strings.write_string(&b, h)
		if i < CLI_COLUMNS - 1 do strings.write_string(&b, "  ")
	}
	fmt.println(strings.to_string(b))
}

@(private = "file")
_cli_print_json :: proc(rows: []proto.Session_Row) {
	json_rows := make([dynamic]Ls_Json_Row, context.temp_allocator)
	for row in rows {
		state_str := "idle"
		switch row.state {
		case .Busy: state_str = "busy"
		case .Exited: state_str = fmt.tprintf("exited %d", row.exit_code)
		case .Idle: state_str = "idle"
		}
		append(&json_rows, Ls_Json_Row{
			id        = row.id,
			state     = state_str,
			exit_code = row.exit_code,
			pid       = row.pid,
			process   = row.process,
			cwd       = row.cwd,
			cols      = row.cols,
			rows      = row.rows,
			attached  = row.attached,
			held_by   = row.controller,
			title     = row.title,
		})
	}
	bytes, err := json.marshal(json_rows[:], {pretty = false}, context.temp_allocator)
	if err == nil do fmt.println(string(bytes))
	else do fmt.println("[]")
}

@(private = "file")
_cli_print_sessions :: proc(rows: []proto.Session_Row) {
	table := make([dynamic][CLI_COLUMNS]string, context.temp_allocator)
	append(&table, [CLI_COLUMNS]string{
		"ID", "STATE", "PID", "PROCESS", "CWD", "SIZE", "HELD-BY", "TITLE",
	})
	for row in rows {
		append(&table, _cli_cells(row))
	}
	widths: [CLI_COLUMNS]int
	for cells in table {
		for cell, c in cells do widths[c] = max(widths[c], len(cell))
	}
	for cells in table {
		b := strings.builder_make(context.temp_allocator)
		for cell, c in cells {
			strings.write_string(&b, cell)
			if c < CLI_COLUMNS - 1 {
				for _ in 0..<widths[c] - len(cell) + 2 do strings.write_byte(&b, ' ')
			}
		}
		fmt.println(strings.to_string(b))
	}
}

@(private = "file")
_cli_cells :: proc(r: proto.Session_Row) -> [CLI_COLUMNS]string {
	state_str := "idle"
	switch r.state {
	case .Busy: state_str = "busy"
	case .Exited: state_str = fmt.tprintf("exited %d", r.exit_code)
	case .Idle: state_str = "idle"
	}
	size_str := "-"
	if r.cols > 0 && r.rows > 0 {
		size_str = fmt.tprintf("%dx%d", r.cols, r.rows)
	}
	held_str := r.controller if len(r.controller) > 0 else "-"
	return {
		fmt.tprintf("%d", r.id),
		state_str,
		fmt.tprintf("%d", r.pid),
		_cli_clean(r.process),
		_cli_home_relative(_cli_clean(r.cwd)),
		size_str,
		_cli_clean(held_str),
		_cli_clean(r.title),
	}
}

@(private = "file")
_cli_clean :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for ch in s {
		if ch == '\n' || ch == '\r' || ch == '\t' {
			strings.write_byte(&b, ' ')
		} else if ch >= ' ' && ch != 0x7f {
			strings.write_rune(&b, ch)
		}
	}
	return strings.to_string(b)
}

@(private = "file")
_cli_home_relative :: proc(cwd: string) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	if len(home) == 0 || !strings.has_prefix(cwd, home) do return cwd
	rest := cwd[len(home):]
	if len(rest) == 0 do return "~"
	return fmt.tprintf("~%s", rest) if rest[0] == '/' else cwd
}
