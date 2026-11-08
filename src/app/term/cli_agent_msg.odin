package term

// The sender's side of broker requests: `term session tell`, `result` and
// `cancel`. The sender is this process's own session ($TERM_SESSION_ID, none
// outside term). tell waits for the result unless --async; a result can also
// be read or waited for later by its id.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import proto "../../features/session_proto"
import plat_ipc "../../platform/ipc"

AGENT_EXIT_REJECTED :: 5
TELL_DEFAULT_S      :: 30 * 60.0

Tell_Args :: struct {
	body:      string,
	timeout_s: f64,
	parent:    u64,
	async:     bool,
	as_json:   bool,
}

app_cli_agent_tell :: proc(to_id: u32, args: []string) -> int {
	a, ok := _parse_tell_args(args)
	if !ok {
		fmt.eprintln("usage: term session tell <id> <text|-> [--async] [-t seconds] [--parent request] [--json]")
		return 1
	}
	conn: plat_ipc.Stream_Conn
	if !app_agent_conn(&conn, false) do return 2
	defer plat_ipc.stream_conn_destroy(&conn)
	from, _ := app_agent_self_id()
	msg := make([]u8, len(a.body) + 64, context.temp_allocator)
	w := plat_ipc.wire_writer(msg)
	proto.enc_tell_req(&w, {to = to_id, from = from, timeout_ms = u32(a.timeout_s * 1000), parent = a.parent, wait = !a.async, body = a.body})
	plat_ipc.stream_send(&conn, proto.MSG_TELL, 0, plat_ipc.wire_bytes_written(&w))
	res, code := app_tell_answer(&conn, AGENT_ANSWER_MS)
	if code != 0 do return code
	if res.phase == .Rejected || a.async do return app_print_tell(res, a.as_json)
	return app_follow_result(&conn, int(a.timeout_s * 1000) + WATCH_GRACE_MS, a.as_json)
}

// app_cli_agent_result: `term session result <request>… [--wait] [--follow] [-t s] [--json]`.
app_cli_agent_result :: proc(first: u32, args: []string) -> int {
	req := proto.Result_Request{ids = {0 = u64(first)}, n_ids = 1}
	timeout_s, as_json := WATCH_DEFAULT_S, false
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--wait":   req.wait = true
		case "--follow": req.wait, req.follow = true, true
		case "--json":   as_json = true
		case "-t":
			i += 1
			v, v_ok := app_arg_seconds(args, i)
			if !v_ok do return _result_usage()
			timeout_s = v
		case:
			id, is_id := strconv.parse_u64(args[i])
			if !is_id || req.n_ids == proto.RESULT_MAX_IDS do return _result_usage()
			req.ids[req.n_ids] = id
			req.n_ids += 1
		}
	}
	if (req.n_ids > 1 && !req.wait) || (req.follow && req.n_ids > 1) do return _result_usage()
	req.caller, _ = app_agent_self_id()
	req.timeout_ms = u32(timeout_s * 1000) if req.wait else 0
	conn: plat_ipc.Stream_Conn
	if !app_agent_conn(&conn, false) do return 2
	defer plat_ipc.stream_conn_destroy(&conn)
	b: [128]u8
	w := plat_ipc.wire_writer(b[:])
	proto.enc_result_req(&w, req)
	plat_ipc.stream_send(&conn, proto.MSG_RESULT, 0, plat_ipc.wire_bytes_written(&w))
	if req.wait do return app_follow_result(&conn, int(req.timeout_ms) + WATCH_GRACE_MS, as_json)
	res, code := app_tell_answer(&conn, AGENT_ANSWER_MS)
	if code != 0 do return code
	return app_print_tell(res, as_json)
}

app_cli_agent_cancel :: proc(req_id: u32, args: []string) -> int {
	if len(args) != 0 {
		fmt.eprintln("usage: term session cancel <request>")
		return 1
	}
	b: [8]u8
	w := plat_ipc.wire_writer(b[:])
	plat_ipc.ww_u64(&w, u64(req_id))
	return app_agent_request_ok(proto.MSG_CANCEL, plat_ipc.wire_bytes_written(&w))
}

// app_follow_result prints progress frames as they come, then the result.
app_follow_result :: proc(conn: ^plat_ipc.Stream_Conn, timeout_ms: int, as_json: bool) -> int {
	for {
		res, code := app_tell_answer(conn, timeout_ms)
		if code != 0 do return code
		if res.phase != .Progress do return app_print_tell(res, as_json)
		if as_json do _print_json(res)
		else do fmt.eprintfln("[#%d progress] %s", res.id, res.progress)
	}
}

app_tell_answer :: proc(conn: ^plat_ipc.Stream_Conn, timeout_ms: int) -> (res: proto.Tell_Result, code: int) {
	f: plat_ipc.Stream_Frame
	f, code = app_agent_answer(conn, proto.MSG_TELL_RESULT, timeout_ms)
	if code != 0 do return
	r := plat_ipc.wire_reader(f.payload)
	res = proto.dec_tell_result(&r)
	if !plat_ipc.wr_done(&r) {
		fmt.eprintln("term: malformed result from core")
		return {}, 1
	}
	return res, 0
}

// app_print_tell: exit 0 accepted, running or finished (the target's own exit
// is in the output), 5 rejected, 3 timed out, 1 cancelled, interrupted or error.
app_print_tell :: proc(res: proto.Tell_Result, as_json: bool) -> int {
	if as_json do _print_json(res)
	switch res.phase {
	case .Rejected:
		if !as_json do fmt.eprintfln("term: %s", _reject_reason(res))
		return AGENT_EXIT_REJECTED
	case .Accepted:
		if !as_json do fmt.printfln("%d", res.id) // ID=$(term session tell … --async)
		return 0
	case .Running, .Progress:
		if !as_json do fmt.printfln("[#%d running] %s", res.id, res.progress)
		return 0
	case .Finished:
	}
	if !as_json {
		if len(res.text) > 0 {
			os.write(os.stdout, transmute([]u8)res.text)
			if res.text[len(res.text) - 1] != '\n' do fmt.println()
		}
		fmt.printfln("[#%d %v exit %d]", res.id, res.status, res.exit_code)
	}
	switch res.status {
	case .Done, .Failed: return 0
	case .Timeout:       return AGENT_EXIT_TIMEOUT
	case .Cancelled, .Interrupted, .Error:
	}
	return 1
}

@(private = "file")
_print_json :: proc(res: proto.Tell_Result) {
	data, err := json.marshal(res, {use_enum_names = true}, context.temp_allocator)
	fmt.println(string(data) if err == nil else "{}")
}

@(private = "file")
_reject_reason :: proc(res: proto.Tell_Result) -> string {
	switch res.reject {
	case .None, .Busy:     return fmt.tprintf("session %d is busy: its workers are all taken, or its shell runs something", res.to)
	case .Not_Listening:   return fmt.tprintf("session %d takes no requests: no worker waits in `next` and no shell prompt (OSC 133)", res.to)
	case .Empty:           return "empty request"
	case .Too_Large:       return fmt.tprintf("request over %d bytes", proto.TELL_BODY_MAX)
	case .Multi_Line:      return fmt.tprintf("session %d is a shell: one single-line command per request", res.to)
	case .Full:            return "too many requests in flight"
	case .Leased:          return fmt.tprintf("session %d is held by an automation (term auto); a person can take it back in its window", res.to)
	}
	return "rejected"
}

@(private = "file")
_parse_tell_args :: proc(args: []string) -> (a: Tell_Args, ok: bool) {
	a.timeout_s = TELL_DEFAULT_S
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--json":  a.as_json = true
		case "--async": a.async = true
		case "-t":
			if i + 1 >= len(args) do return
			i += 1
			v, v_ok := strconv.parse_f64(args[i])
			if !v_ok || v <= 0 || v > f64(max(u32) / 1000) do return
			a.timeout_s = v
		case "--parent":
			if i + 1 >= len(args) do return
			i += 1
			v, v_ok := strconv.parse_u64(args[i])
			if !v_ok do return
			a.parent = v
		case:
			if len(a.body) > 0 do return
			a.body = app_arg_or_stdin(args[i])
		}
	}
	return a, len(a.body) > 0
}

@(private = "file")
_result_usage :: proc() -> int {
	fmt.eprintln("usage: term session result <request> [--follow] [--json] | result <request>… --wait [-t seconds] [--json]")
	return 1
}

// app_arg_or_stdin: "-" reads the text from stdin (long or multi-line text).
app_arg_or_stdin :: proc(arg: string) -> string {
	if arg != "-" do return arg
	data, err := os.read_entire_file(os.stdin, context.temp_allocator)
	return string(data) if err == nil else ""
}

// app_arg_seconds parses args[i] as a timeout in seconds (> 0, fits in ms as u32).
app_arg_seconds :: proc(args: []string, i: int) -> (f64, bool) {
	if i >= len(args) do return 0, false
	v, ok := strconv.parse_f64(args[i])
	return v, ok && v > 0 && v <= f64(max(u32) / 1000)
}
