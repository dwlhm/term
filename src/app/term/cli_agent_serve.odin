package term

// The worker's side of broker requests: `term session next` waits for the
// next request to this session, `progress` and `answer` report on one it
// took. Any program can be a worker: an agent, a script, an app. The worker's
// session is $TERM_SESSION_ID, or --as <session> (an app speaking for a
// session it owns, e.g. a virtual endpoint).

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import proto "../../features/session_proto"
import plat_ipc "../../platform/ipc"

NEXT_DEFAULT_S :: 0.0 // wait until a request comes

app_cli_agent_next :: proc(args: []string) -> int {
	sid, rest, ok := _worker_session(args)
	timeout_s, as_json := NEXT_DEFAULT_S, false
	for i := 0; ok && i < len(rest); i += 1 {
		switch rest[i] {
		case "--json": as_json = true
		case "-t":
			i += 1
			timeout_s, ok = app_arg_seconds(rest, i)
		case: ok = false
		}
	}
	if !ok {
		fmt.eprintln("usage: term session next [-t seconds] [--as session] [--json]")
		return 1
	}
	conn: plat_ipc.Stream_Conn
	if !app_agent_conn(&conn, false) do return 2
	defer plat_ipc.stream_conn_destroy(&conn)
	b: [8]u8
	w := plat_ipc.wire_writer(b[:])
	plat_ipc.ww_u32(&w, sid); plat_ipc.ww_u32(&w, u32(timeout_s * 1000))
	plat_ipc.stream_send(&conn, proto.MSG_NEXT, 0, plat_ipc.wire_bytes_written(&w))
	wait_ms := int(timeout_s * 1000) + WATCH_GRACE_MS if timeout_s > 0 else 0 // 0: until a request comes
	f, code := app_agent_answer(&conn, proto.MSG_REQUEST, wait_ms)
	if code != 0 do return code
	r := plat_ipc.wire_reader(f.payload)
	req := proto.dec_next_result(&r)
	if !plat_ipc.wr_done(&r) {
		fmt.eprintln("term: malformed request from core")
		return 1
	}
	if as_json {
		data, err := json.marshal(req, {}, context.temp_allocator)
		fmt.println(string(data) if err == nil else "{}")
	} else {
		fmt.printfln("#%d from %d", req.id, req.from)
		fmt.println(req.body)
	}
	return 0
}

// app_cli_agent_answer: `answer <request> <text|-> [--failed]`, or with
// final = false `progress <request> <text|->`.
app_cli_agent_answer :: proc(req_id: u32, args: []string, final: bool) -> int {
	sid, rest, ok := _worker_session(args)
	m := proto.Answer_Msg{by = sid, id = u64(req_id)}
	for a in rest {
		switch {
		case a == "--failed" && final: m.failed = true
		case len(m.text) == 0:         m.text = app_arg_or_stdin(a)
		case:                          ok = false
		}
	}
	if !ok || len(m.text) == 0 {
		fmt.eprintln("usage: term session answer <request> <text|-> [--failed] [--as session] | progress <request> <text|-> [--as session]")
		return 1
	}
	msg := make([]u8, len(m.text) + 64, context.temp_allocator)
	w := plat_ipc.wire_writer(msg)
	proto.enc_answer(&w, m)
	return app_agent_request_ok(proto.MSG_ANSWER if final else proto.MSG_PROGRESS, plat_ipc.wire_bytes_written(&w))
}

// _worker_session: --as <session>, else this process's own session.
@(private = "file")
_worker_session :: proc(args: []string) -> (sid: u32, rest: []string, ok: bool) {
	out := make([dynamic]string, 0, len(args), context.temp_allocator)
	for i := 0; i < len(args); i += 1 {
		if args[i] != "--as" {
			append(&out, args[i])
			continue
		}
		i += 1
		if i >= len(args) do return 0, nil, false
		v, v_ok := strconv.parse_uint(args[i], 10)
		if !v_ok || v == 0 || v > uint(max(u32)) do return 0, nil, false
		sid = u32(v)
	}
	if sid == 0 {
		self, inside := app_agent_self_id()
		if !inside {
			fmt.eprintln("term: a worker needs a session: run it inside term, or pass --as <session>")
			return 0, nil, false
		}
		sid = self
	}
	return sid, out[:], true
}
