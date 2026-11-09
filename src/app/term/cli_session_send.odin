package term

// CLI handler for `term session send` (spec 4.5, S1–S31).
// Connects to core, sends batch ACT, and formats output.

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"
import api "../../features/session_api"
import proto "../../features/session_proto"
import plat_ipc "../../platform/ipc"

app_cli_session_send :: proc(args: []string) -> int {
	if len(args) > 0 && (args[0] == "-h" || args[0] == "--help") {
		fmt.println("usage: term session send <id> [text] [options...]")
		return 0
	}
	opts, ok := app_cli_parse_send(args)
	if !ok {
		fmt.eprintln(opts.err_msg)
		return 1
	}

	c: plat_ipc.Client
	if err := api.api_open(&c, false); err.kind != .None {
		return _fail_exit(err)
	}
	defer plat_ipc.client_close(&c)

	gen, err := api.api_act_batch(&c, opts.id, opts.items[:], 5 * time.Second)
	if err.kind != .None do return _fail_exit(err)

	if opts.as_json {
		fmt.printfln("{{\"session\":%d,\"gen\":%d}}", opts.id, gen)
	}
	return 0
}

@(private = "file")
_fail_exit :: proc(err: plat_ipc.Error) -> int {
	#partial switch err.kind {
	case .None: return 0
	case .Interrupted: return 130
	case .No_Server:
		fmt.eprintln("term: no term session is running")
		return 2
	case .Closed:
		fmt.eprintln("term: the term session core went away")
		return 2
	}
	fmt.eprintfln("term: %s", proto.error_text(err))
	#partial switch err.kind {
	case .Failed:
		switch proto.Fail_Code(err.code) {
		case .Not_Found: return 1
		case .Exited: return 4
		case .Bad_Request, .Spawn_Failed: return 1
		case .Busy, .Unsupported: return 5
		case .Timeout: return 3
		}
	}
	return 1
}

_parse_btn :: proc(args: []string, i: ^int) -> u8 {
	if i^ + 1 < len(args) {
		switch args[i^ + 1] {
		case "left":   i^ += 1; return 0
		case "right":  i^ += 1; return 1
		case "middle": i^ += 1; return 2
		}
	}
	return 0
}

_parse_target :: proc(s: string) -> proto.Act_Target {
	if strings.has_prefix(s, "@e") {
		v, num_ok := strconv.parse_uint(s[2:], 10)
		if num_ok && v > 0 {
			return {kind = .Ref, ref = u32(v)}
		}
	}
	comma := strings.index_byte(s, ',')
	if comma > 0 {
		r, r_ok := strconv.parse_uint(s[:comma], 10)
		c, c_ok := strconv.parse_uint(s[comma + 1:], 10)
		if r_ok && c_ok {
			return {kind = .Pos, row = u16(r), col = u16(c)}
		}
	}
	return {kind = .Text, text = s}
}
