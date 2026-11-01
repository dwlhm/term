package term

// `term session new [-d dir] [-s COLSxROWS] [-e KEY=VAL]… [-- prog args…]`:
// the core creates the session and the CLI prints its id. Without a program
// the session runs $SHELL; -e entries win over the inherited environment.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import plat_ipc "../../platform/ipc"

@(private = "file")
NEW_DEFAULT_SIZE :: plat_ipc.Size_Msg{cols = 120, rows = 36}

@(private = "file")
NEW_MSG_BYTES :: 64 * 1024

// app_cli_parse_new fills spec from the `new` arguments; false on bad usage.
app_cli_parse_new :: proc(args: []string, spec: ^plat_ipc.Spawn_Msg) -> bool {
	spec^ = {cwd = os.get_env("PWD", context.temp_allocator), size = NEW_DEFAULT_SIZE}
	rest := args
	for len(rest) > 0 && rest[0] != "--" {
		if len(rest) < 2 do return false
		switch rest[0] {
		case "-d": spec.cwd = rest[1]
		case "-s":
			spec.size = app_cli_parse_size(rest[1]) or_return
		case "-e":
			if strings.index_byte(rest[1], '=') <= 0 || spec.envc == plat_ipc.STREAM_MAX_ENV do return false
			spec.env[spec.envc] = rest[1]
			spec.envc += 1
		case: return false
		}
		rest = rest[2:]
	}
	if len(rest) > 1 {
		if len(rest) - 1 > plat_ipc.STREAM_MAX_ARGV do return false
		spec.argc = len(rest) - 1
		for i in 0..<spec.argc do spec.argv[i] = rest[i + 1]
	} else {
		shell := os.get_env("SHELL", context.temp_allocator)
		spec.argv[0], spec.argc = shell if len(shell) > 0 else "/bin/sh", 1
	}
	return true
}

// app_cli_parse_size parses COLSxROWS (each 1..9999).
app_cli_parse_size :: proc(s: string) -> (size: plat_ipc.Size_Msg, ok: bool) {
	x := strings.index_byte(s, 'x')
	if x <= 0 do return {}, false
	cols := strconv.parse_uint(s[:x], 10) or_return
	rows := strconv.parse_uint(s[x + 1:], 10) or_return
	if cols < 1 || cols > 9999 || rows < 1 || rows > 9999 do return {}, false
	return {cols = u16(cols), rows = u16(rows)}, true
}

app_cli_agent_new :: proc(args: []string) -> int {
	spec: plat_ipc.Spawn_Msg
	if !app_cli_parse_new(args, &spec) {
		fmt.eprintln(APP_CLI_USAGE)
		return 1
	}
	msg := make([]u8, NEW_MSG_BYTES, context.temp_allocator)
	w := plat_ipc.wire_writer(msg)
	plat_ipc.ww_u32(&w, 1)
	plat_ipc.enc_spawn(&w, &spec)
	if !w.ok {
		fmt.eprintln("term: command line and environment too long")
		return 1
	}
	conn: plat_ipc.Stream_Conn
	if !app_agent_conn(&conn, true) do return 2
	defer plat_ipc.stream_conn_destroy(&conn)
	plat_ipc.stream_send(&conn, plat_ipc.MSG_CREATE, 0, plat_ipc.wire_bytes_written(&w))
	f, ok := app_agent_answer(&conn, plat_ipc.MSG_ATTACHED)
	if !ok do return 1
	r := plat_ipc.wire_reader(f.payload)
	_, id := plat_ipc.wr_u32(&r), plat_ipc.wr_u32(&r)
	fmt.println(id) // closing the connection detaches: the program keeps running
	return 0
}
