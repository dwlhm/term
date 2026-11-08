package term

// `term session watch`: block on the next OSC 133 edge or exit of a session.

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import proto "../../features/session_proto"
import plat_ipc "../../platform/ipc"

WATCH_DEFAULT_S :: 600.0
WATCH_GRACE_MS  :: 1500 // the core answers the timeout; the CLI waits a bit longer

Watch_Args :: struct {
	req:     proto.Watch_Request,
	as_json: bool,
}

app_cli_agent_watch :: proc(id: u32, args: []string) -> int {
	cfg, ok := _parse_watch_args(args)
	if !ok {
		fmt.eprintln("usage: term session watch <id> [--prompt | --executing | --exit] [--since SEQ] [-t seconds] [--json]")
		return 1
	}
	cfg.req.id = id
	c: plat_ipc.Client
	if code := app_agent_open(&c, false); code != 0 do return code
	defer plat_ipc.client_close(&c)
	res, code := app_agent_watch(&c, cfg.req)
	if code != 0 do return code
	app_print_watch_result(res, cfg.as_json)
	return 0
}

// app_agent_watch sends one watch and waits for its answer. code: 0
// answered, 1 error, 3 timed out.
app_agent_watch :: proc(c: ^plat_ipc.Client, req: proto.Watch_Request) -> (res: proto.Watch_Result, code: int) {
	buf: [64]u8
	w := plat_ipc.wire_writer(buf[:])
	proto.enc_watch_req(&w, req)
	a, err := plat_ipc.client_call(c, proto.MSG_WATCH, plat_ipc.wire_bytes_written(&w), {timeout = app_wait_timeout(f64(req.timeout_ms) / 1000)})
	if err.kind != .None do return {}, app_fail(err)
	r := plat_ipc.wire_reader(a.body)
	res = proto.dec_watch_result(&r)
	if !r.ok {
		fmt.eprintln("term: malformed watch result from core")
		return {}, 1
	}
	return res, 0
}

app_print_watch_result :: proc(res: proto.Watch_Result, as_json: bool) {
	if as_json {
		data, err := json.marshal(res, {use_enum_names = true}, context.temp_allocator)
		fmt.println(string(data) if err == nil else "{}")
		return
	}
	switch res.event {
	case .Prompt:    fmt.printfln("prompt exit=%d cmd_seq=%d", res.exit_code, res.cmd_seq)
	case .Executing: fmt.printfln("executing cmd_seq=%d", res.cmd_seq)
	case .Exit:      fmt.printfln("exited %d", res.exit_code)
	}
}

@(private = "file")
_parse_watch_args :: proc(args: []string) -> (cfg: Watch_Args, ok: bool) {
	timeout_s := WATCH_DEFAULT_S
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--prompt":    cfg.req.events += {.Prompt}
		case "--executing": cfg.req.events += {.Executing}
		case "--exit":      cfg.req.events += {.Exit}
		case "--json":      cfg.as_json = true
		case "-t", "--since":
			if i + 1 >= len(args) do return cfg, false
			i += 1
			v, v_ok := strconv.parse_f64(args[i])
			if !v_ok || v < 0 do return cfg, false
			switch args[i - 1] {
			case "-t":       timeout_s = v
			case "--since":  cfg.req.has_since, cfg.req.since = true, u32(v)
			}
		case:
			return cfg, false
		}
	}
	if cfg.req.events == {} do cfg.req.events = {.Prompt, .Exit}
	if timeout_s <= 0 || timeout_s > f64(max(u32) / 1000) do return cfg, false
	cfg.req.timeout_ms = u32(timeout_s * 1000.0)
	return cfg, true
}
