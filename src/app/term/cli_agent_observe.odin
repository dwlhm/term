package term

// `term session observe <id> [--json] [-n lines]`: pulls an atomic, zero-side-effect
// snapshot and screen buffer of another session from the core.
// It never alters size (never leads size), never steals focus, and never
// triggers mouse-wheel scroll on alternate screen programs.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import proto "../../features/session_proto"
import plat_ipc "../../platform/ipc"

app_cli_agent_observe :: proc(id: u32, args: []string) -> int {
	as_json, lines, ok := _parse_observe_args(args)
	if !ok {
		fmt.eprintln("usage: term session observe [id] [-n lines] [--json]")
		return 1
	}
	c: plat_ipc.Client
	if code := app_agent_open(&c, false); code != 0 do return code
	defer plat_ipc.client_close(&c)
	res, code := app_agent_observe(&c, id, lines)
	if code != 0 do return code
	if as_json do _print_observe_json(res)
	else do _print_observe_human(res)
	return 0
}

// app_agent_observe asks for one snapshot. code: 0 answered, else the exit code.
// app_agent_observe: res's strings are views valid until c's next call.
app_agent_observe :: proc(c: ^plat_ipc.Client, id: u32, lines: u32) -> (res: proto.Observe_Result, code: int) {
	b: [8]u8
	w := plat_ipc.wire_writer(b[:])
	proto.enc_observe_req(&w, {id, lines})
	a, err := plat_ipc.client_call(c, proto.MSG_OBSERVE, b[:])
	if err.kind != .None do return {}, app_fail(err)
	r := plat_ipc.wire_reader(a.body)
	res = proto.dec_observe_result(&r)
	if !r.ok {
		fmt.eprintln("term: malformed observe result from core")
		return {}, 1
	}
	return res, 0
}

@(private = "file")
_parse_observe_args :: proc(args: []string) -> (as_json: bool, lines: u32, ok: bool) {
	i := 0
	for i < len(args) {
		switch args[i] {
		case "--json":
			as_json = true
			i += 1
		case "-n":
			if i + 1 >= len(args) do return false, 0, false
			v, num_ok := strconv.parse_uint(args[i + 1], 10)
			if !num_ok do return false, 0, false
			lines = u32(min(v, uint(max(u32))))
			i += 2
		case:
			return false, 0, false
		}
	}
	return as_json, lines, true
}

@(private = "file")
_print_observe_json :: proc(res: proto.Observe_Result) {
	line, err := json.marshal(res, {use_enum_names = true}, context.temp_allocator)
	if err == nil {
		fmt.println(string(line))
	} else {
		fmt.eprintln("term: failed to encode observe json")
	}
}

@(private = "file")
_print_observe_human :: proc(res: proto.Observe_Result) {
	alt_tag := " [alt]" if res.is_alt else ""
	fmt.printfln(
		"[%d] %s (pid %d, %dx%d%s) state=%v prompt=%v cmd_seq=%d title=%q",
		res.row.id, res.row.process, res.row.pid, res.cols, res.rows,
		alt_tag, res.row.state, res.prompt_state, res.cmd_seq, res.row.title,
	)
	if res.has_cmd_exit {
		fmt.printfln("Last command exit code: %d", res.cmd_exit_code)
	}
	if len(res.row.status) > 0 {
		fmt.printfln("Status (OSC 7501): %s", res.row.status)
	}
	if len(res.text) > 0 {
		os.write(os.stdout, transmute([]u8)res.text)
		if res.text[len(res.text) - 1] != '\n' {
			fmt.println()
		}
	}
}
