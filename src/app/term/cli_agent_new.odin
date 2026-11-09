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
import api "../../features/session_api"
import proto "../../features/session_proto"
import plat_ipc "../../platform/ipc"

@(private = "file")
NEW_DEFAULT_SIZE :: proto.Size_Msg{cols = 120, rows = 36}

@(private = "file")
NEW_MSG_BYTES :: 64 * 1024

@(private = "file")
_parse_new_dir :: proc(raw: string) -> (dir: string, ok: bool) {
	dir = raw
	if strings.has_prefix(dir, "~/") {
		home := os.get_env("HOME", context.temp_allocator)
		if len(home) > 0 {
			dir = strings.concatenate({home, dir[1:]}, context.temp_allocator)
		}
	}
	if !os.is_dir(dir) {
		fmt.eprintln("no such directory")
		return "", false
	}
	return dir, true
}

// app_cli_parse_new fills spec from the `new` arguments; false on bad usage.
app_cli_parse_new :: proc(args: []string, spec: ^proto.Spawn_Msg) -> bool {
	spec^ = {
		cwd = os.get_env("PWD", context.temp_allocator),
		size = NEW_DEFAULT_SIZE,
	}
	rest := args
	for len(rest) > 0 && rest[0] != "--" {
		if len(rest) < 2 do return false
		switch rest[0] {
		case "-d":
			spec.cwd = _parse_new_dir(rest[1]) or_return
		case "-s":
			spec.size = app_cli_parse_size(rest[1]) or_return
		case "-e":
			if strings.index_byte(rest[1], '=') <= 0 {
				fmt.eprintln("-e takes K=V")
				return false
			}
			if spec.envc == proto.STREAM_MAX_ENV do return false
			spec.env[spec.envc] = rest[1]
			spec.envc += 1
		case "--name":
			spec.name = rest[1]
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
		spec.argv[0] = shell if len(shell) > 0 else "/bin/sh"
		spec.argv[1] = "-l"
		spec.argc = 2
	}
	return true
}

// app_cli_parse_size parses COLSxROWS within 2x1..1000x500 (spec 4.5, N7, R3).
app_cli_parse_size :: proc(s: string) -> (size: proto.Size_Msg, ok: bool) {
	x := strings.index_byte(s, 'x')
	if x <= 0 do return {}, false
	cols := strconv.parse_uint(s[:x], 10) or_return
	rows := strconv.parse_uint(s[x + 1:], 10) or_return
	if cols < 2 || cols > 1000 || rows < 1 || rows > 500 do return {}, false
	return {cols = u16(cols), rows = u16(rows)}, true
}

app_cli_agent_new :: proc(args: []string) -> int {
	if len(args) > 0 && args[0] == "--endpoint" {
		fmt.eprintln(
			"--endpoint was removed: term session no longer carries requests",
		)
		return 1
	}
	spec: proto.Spawn_Msg
	if !app_cli_parse_new(args, &spec) {
		fmt.eprintln(APP_CLI_USAGE)
		return 1
	}
	c: plat_ipc.Client
	if err := api.api_open(&c, start = true); err.kind != .None {
		return app_fail(err)
	}
	defer plat_ipc.client_close(&c)

	id, err := api.api_new(&c, &spec)
	if err.kind != .None do return app_fail(err)
	fmt.println(id)
	return 0
}
