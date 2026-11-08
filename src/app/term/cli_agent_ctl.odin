package term

// `term session signal <id> <INT|SIGINT|2|…>` and `term session resize <id> <COLSxROWS>`.
// A signal goes where ^C goes (the foreground job). A resize applies only
// while no window shows the session: a window leads its size.

import "core:fmt"
import "core:reflect"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import proto "../../features/session_proto"
import plat_ipc "../../platform/ipc"

app_cli_agent_signal :: proc(id: u32, args: []string) -> int {
	sig, ok := app_cli_parse_signal(args[0] if len(args) == 1 else "")
	if !ok {
		fmt.eprintln(APP_CLI_USAGE)
		return 1
	}
	b: [8]u8
	w := plat_ipc.wire_writer(b[:])
	plat_ipc.ww_u32(&w, id)
	plat_ipc.ww_i32(&w, sig)
	return app_agent_request_ok(proto.MSG_SESSION_SIGNAL, b[:])
}

app_cli_agent_resize :: proc(id: u32, args: []string) -> int {
	size, ok := app_cli_parse_size(args[0] if len(args) == 1 else "")
	if !ok {
		fmt.eprintln(APP_CLI_USAGE)
		return 1
	}
	b: [12]u8
	w := plat_ipc.wire_writer(b[:])
	plat_ipc.ww_u32(&w, id)
	proto.enc_size(&w, size)
	return app_agent_request_ok(proto.MSG_SESSION_SIZE, plat_ipc.wire_bytes_written(&w))
}

// app_cli_parse_signal accepts a number (1..64) or a name with or without
// SIG, any case (INT, sigterm, SIGUSR1).
app_cli_parse_signal :: proc(s: string) -> (sig: i32, ok: bool) {
	if n, is_num := strconv.parse_uint(s, 10); is_num {
		return i32(n), n >= 1 && n <= 64
	}
	if len(s) == 0 do return 0, false
	name := strings.to_upper(s, context.temp_allocator)
	if !strings.has_prefix(name, "SIG") do name = strings.concatenate({"SIG", name}, context.temp_allocator)
	v := reflect.enum_from_name(posix.Signal, name) or_return
	return i32(v), i32(v) > 0
}
