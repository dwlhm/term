package term

// Tail runner for `term session read --tail` (spec 4.4, T1–T27).
// Event-driven generational polling via SNAPSHOT and SETTLE.

import "core:fmt"
import "core:strings"
import "core:time"
import proto "../../features/session_proto"
import plat_ipc "../../platform/ipc"

_cli_read_tail :: proc(
	c: ^plat_ipc.Client,
	opts: Cli_Read_Options,
) -> int {
	snap, snap_err := _fetch_snap(c, opts.id, 0, -1)
	if snap_err.kind != .None do return app_fail(snap_err)

	if init_code, done := _check_initial(opts, &snap); done {
		return init_code
	}

	_print_rows(snap.screen, opts.clean, opts.as_json)

	last_gen := snap.gen
	last_top := snap.top_line
	start := time.now()

	for {
		if code, timed_out := _check_tail_timeout(opts, start); timed_out {
			return code
		}
		res, set_err := _settle_poll(c, opts, last_gen, start)
		if set_err.kind != .None do return app_fail(set_err)
		if res.exited {
			return _handle_tail_exited(opts, res.exit_code)
		}

		snap, snap_err = _fetch_snap(c, opts.id, 1000, last_top)
		if snap_err.kind != .None do return app_fail(snap_err)

		if code, finished := _process_tail_update(
			opts, &snap, last_gen,
		); finished {
			return code
		}
		last_gen = snap.gen
		last_top = snap.top_line
	}
}

@(private = "file")
_fetch_snap :: proc(
	c: ^plat_ipc.Client,
	id: u32,
	history: u32,
	since: i64,
) -> (snap: proto.Snapshot, err: plat_ipc.Error) {
	buf: [64]u8
	w := plat_ipc.wire_writer(buf[:])
	proto.enc_snapshot_req(&w, {id = id, history = history, since = since})
	a, call_err := plat_ipc.client_call(
		c, proto.MSG_SNAPSHOT, plat_ipc.wire_bytes_written(&w),
		{timeout = 5 * time.Second},
	)
	if call_err.kind != .None do return snap, call_err
	r := plat_ipc.wire_reader(a.body)
	return proto.dec_snapshot(&r, context.temp_allocator), {}
}

@(private = "file")
_check_initial :: proc(
	opts: Cli_Read_Options,
	snap: ^proto.Snapshot,
) -> (code: int, done: bool) {
	if opts.prompt && snap.prompt_gen == 0 && snap.prompt_state == .None {
		fmt.eprintfln(
			"term: session %d does not mark commands (OSC 133)", opts.id,
		)
		return 1, true
	}
	if opts.idle && snap.status_gen == 0 && len(snap.status_app) == 0 {
		fmt.eprintfln(
			"term: session %d does not report its state (OSC 7501): use --quiet",
			opts.id,
		)
		return 1, true
	}
	if opts.exit && snap.exit_code != 0 {
		_print_exit(opts, snap.exit_code)
		return 0, true
	}
	if opts.has_until && !opts.until_new && _screen_has(snap^, opts.until) {
		_print_rows(snap.screen, opts.clean, opts.as_json)
		_print_end(opts, "until")
		return 0, true
	}
	if opts.prompt && snap.prompt_gen > snap.input_gen {
		_print_rows(snap.screen, opts.clean, opts.as_json)
		_print_end(opts, "prompt")
		return 0, true
	}
	return 0, false
}

@(private = "file")
_check_tail_timeout :: proc(
	opts: Cli_Read_Options,
	start: time.Time,
) -> (code: int, timed_out: bool) {
	if opts.timeout_sec <= 0 do return 0, false
	elapsed := time.duration_seconds(time.since(start))
	if elapsed >= opts.timeout_sec {
		fmt.eprintfln(
			"term: timed out after %vs waiting for %s",
			opts.timeout_sec, _cond_name(opts),
		)
		return 3, true
	}
	return 0, false
}

@(private = "file")
_settle_poll :: proc(
	c: ^plat_ipc.Client,
	opts: Cli_Read_Options,
	last_gen: u64,
	start: time.Time,
) -> (proto.Settle_Result, plat_ipc.Error) {
	quiet_ms := u32(opts.quiet_sec * 1000) if opts.has_quiet else u32(50)
	to_ms: u32 = 500
	if opts.timeout_sec > 0 {
		rem := opts.timeout_sec - time.duration_seconds(time.since(start))
		rem_ms := u32(max(0.0, rem * 1000.0))
		to_ms = min(to_ms, rem_ms)
	}

	buf: [64]u8
	w := plat_ipc.wire_writer(buf[:])
	proto.enc_settle_req(&w, {opts.id, last_gen, quiet_ms, to_ms})
	a, err := plat_ipc.client_call(
		c, proto.MSG_SETTLE, plat_ipc.wire_bytes_written(&w),
		{timeout = time.Duration(to_ms + 2000) * time.Millisecond},
	)
	if err.kind != .None do return {}, err
	r := plat_ipc.wire_reader(a.body)
	return proto.dec_settle_result(&r), {}
}

@(private = "file")
_handle_tail_exited :: proc(opts: Cli_Read_Options, exit_code: i32) -> int {
	if opts.exit {
		_print_exit(opts, exit_code)
		return 0
	}
	if _has_any_cond(opts) {
		fmt.eprintfln(
			"term: session %d exited (%d) before %s",
			opts.id, exit_code, _cond_name(opts),
		)
		return 4
	}
	return 0
}

@(private = "file")
_process_tail_update :: proc(
	opts: Cli_Read_Options,
	snap: ^proto.Snapshot,
	last_gen: u64,
) -> (code: int, finished: bool) {
	if opts.has_quiet && snap.gen == last_gen {
		_print_end(opts, "quiet")
		return 0, true
	}

	_print_rows(snap.history, opts.clean, opts.as_json)

	if opts.has_until && _screen_has(snap^, opts.until) {
		_print_end(opts, "until")
		return 0, true
	}
	if opts.prompt && snap.prompt_gen > snap.input_gen {
		_print_end(opts, "prompt")
		return 0, true
	}
	if opts.idle && snap.status_gen > snap.input_gen && snap.status_state == 1 {
		_print_end(opts, "idle")
		return 0, true
	}
	return 0, false
}

@(private = "file")
_screen_has :: proc(snap: proto.Snapshot, pattern: string) -> bool {
	for row in snap.screen {
		if strings.contains(_row_to_string(row), pattern) do return true
	}
	return false
}

@(private = "file")
_row_to_string :: proc(row: proto.Snap_Row) -> string {
	b := strings.builder_make(context.temp_allocator)
	for run in row.runs do strings.write_string(&b, run.text)
	return strings.to_string(b)
}

@(private = "file")
_print_rows :: proc(rows: []proto.Snap_Row, clean: bool, as_json: bool) {
	for row in rows {
		txt := _row_to_string(row)
		if clean do txt = app_clean_text(txt, context.temp_allocator)
		if as_json do fmt.printfln("{{\"ev\":\"line\",\"line\":%s}}", txt)
		else do fmt.println(txt)
	}
}

@(private = "file")
_print_exit :: proc(opts: Cli_Read_Options, exit_code: i32) {
	if opts.as_json {
		fmt.printfln("{{\"ev\":\"end\",\"reason\":\"exit\",\"exit\":%d}}", exit_code)
	} else {
		fmt.printfln("[exited %d]", exit_code)
	}
}

@(private = "file")
_print_end :: proc(opts: Cli_Read_Options, reason: string) {
	if opts.as_json {
		fmt.printfln("{{\"ev\":\"end\",\"reason\":\"%s\"}}", reason)
	}
}

@(private = "file")
_has_any_cond :: proc(opts: Cli_Read_Options) -> bool {
	return opts.has_until || opts.prompt || opts.exit ||
	       opts.idle || opts.has_quiet
}

@(private = "file")
_cond_name :: proc(opts: Cli_Read_Options) -> string {
	if opts.has_until do return fmt.tprintf("until \"%s\"", opts.until)
	if opts.prompt do return "prompt"
	if opts.exit do return "exit"
	if opts.idle do return "idle"
	if opts.has_quiet do return fmt.tprintf("quiet %vs", opts.quiet_sec)
	return "condition"
}
