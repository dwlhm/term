package term

// `term session new [-d dir] [-s COLSxROWS] [-e KEY=VAL]… [-- prog args…]`:
// the core creates the session and the CLI prints its id. Without a program
// the session runs $SHELL; -e entries win over the inherited environment.
// `term session new --endpoint <name>`: a virtual session (no program) that
// lives until killed; an app takes its requests with `next --as <id>`.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import proto "../../features/session_proto"
import plat_ipc "../../platform/ipc"

@(private = "file")
NEW_DEFAULT_SIZE :: proto.Size_Msg{cols = 120, rows = 36}

@(private = "file")
NEW_MSG_BYTES :: 64 * 1024

// app_cli_parse_new fills spec from the `new` arguments; false on bad usage.
app_cli_parse_new :: proc(args: []string, spec: ^proto.Spawn_Msg) -> bool {
	spec^ = {cwd = os.get_env("PWD", context.temp_allocator), size = NEW_DEFAULT_SIZE}
	rest := args
	for len(rest) > 0 && rest[0] != "--" {
		if len(rest) < 2 do return false
		switch rest[0] {
		case "-d": spec.cwd = rest[1]
		case "-s":
			spec.size = app_cli_parse_size(rest[1]) or_return
		case "-e":
			if strings.index_byte(rest[1], '=') <= 0 || spec.envc == proto.STREAM_MAX_ENV do return false
			spec.env[spec.envc] = rest[1]
			spec.envc += 1
		case: return false
		}
		rest = rest[2:]
	}
	if len(rest) > 1 {
		if len(rest) - 1 > proto.STREAM_MAX_ARGV do return false
		spec.argc = len(rest) - 1
		for i in 0..<spec.argc do spec.argv[i] = rest[i + 1]
	} else {
		shell := os.get_env("SHELL", context.temp_allocator)
		spec.argv[0], spec.argv[1], spec.argc = shell if len(shell) > 0 else "/bin/sh", "-l", 2 // a login shell
	}
	return true
}

// app_cli_parse_size parses COLSxROWS (each 1..9999).
app_cli_parse_size :: proc(s: string) -> (size: proto.Size_Msg, ok: bool) {
	x := strings.index_byte(s, 'x')
	if x <= 0 do return {}, false
	cols := strconv.parse_uint(s[:x], 10) or_return
	rows := strconv.parse_uint(s[x + 1:], 10) or_return
	if cols < 1 || cols > 9999 || rows < 1 || rows > 9999 do return {}, false
	return {cols = u16(cols), rows = u16(rows)}, true
}

app_cli_agent_new :: proc(args: []string) -> int {
	if len(args) > 0 && args[0] == "--endpoint" do return _new_endpoint(args[1:])
	spec: proto.Spawn_Msg
	if !app_cli_parse_new(args, &spec) {
		fmt.eprintln(APP_CLI_USAGE)
		return 1
	}
	msg := make([]u8, NEW_MSG_BYTES, context.temp_allocator)
	w := plat_ipc.wire_writer(msg)
	proto.enc_spawn(&w, &spec)
	if !w.ok {
		fmt.eprintln("term: command line and environment too long")
		return 1
	}
	answer, code := app_agent_call(proto.MSG_CREATE, plat_ipc.wire_bytes_written(&w), start = true)
	if code != 0 do return code
	r := plat_ipc.wire_reader(answer)
	fmt.println(plat_ipc.wr_u32(&r)) // closing the connection detaches: the program keeps running
	return 0
}

@(private = "file")
_new_endpoint :: proc(args: []string) -> int {
	if len(args) != 1 || len(args[0]) == 0 || len(args[0]) > 64 {
		fmt.eprintln("usage: term session new --endpoint <name (1..64 bytes)>")
		return 1
	}
	b: [96]u8
	w := plat_ipc.wire_writer(b[:])
	proto.enc_endpoint_req(&w, {name = args[0], owned = false}) // outlives this CLI: until killed
	answer, code := app_agent_call(proto.MSG_ENDPOINT, plat_ipc.wire_bytes_written(&w), start = true)
	if code != 0 do return code
	r := plat_ipc.wire_reader(answer)
	fmt.println(plat_ipc.wr_i32(&r))
	return 0
}
