package term

// CLI handler for `term session cancel <id> [-t sec]` (spec 4.7, C1–C9).

import "core:fmt"
import "core:strconv"
import "core:time"
import api "../../features/session_api"
import proto "../../features/session_proto"
import plat_ipc "../../platform/ipc"

app_cli_session_cancel :: proc(id: u32, args: []string) -> int {
	timeout_sec, ok := _cancel_parse_args(args)
	if !ok do return 1

	c: plat_ipc.Client
	if err := proto.session_open(&c, .Cli, false); err.kind != .None {
		return _cancel_fail_exit(err, id)
	}
	defer plat_ipc.client_close(&c)

	snap, code, snap_ok := _cancel_snapshot(&c, id)
	if !snap_ok do return code

	stop_code, should_stop := _cancel_check_preconditions(id, snap)
	if should_stop do return stop_code

	return _cancel_loop(&c, id, timeout_sec)
}

_cancel_parse_args :: proc(args: []string) -> (timeout_sec: int, ok: bool) {
	timeout_sec = 3
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		if arg == "-t" || arg == "--timeout" {
			if i + 1 >= len(args) {
				fmt.eprintln("usage: term session cancel <id> [-t sec]")
				return 0, false
			}
			sec, parse_ok := strconv.parse_int(args[i + 1], 10)
			if !parse_ok || sec <= 0 {
				fmt.eprintln("-t takes a positive number of seconds")
				return 0, false
			}
			timeout_sec = sec
			i += 1
		} else {
			fmt.eprintfln("unknown option: %s", arg)
			return 0, false
		}
	}
	return timeout_sec, true
}

@(private = "file")
_cancel_check_preconditions :: proc(
	id: u32,
	snap: proto.Snapshot,
) -> (code: int, should_stop: bool) {
	if snap.exited {
		fmt.eprintfln("session %d has exited", id)
		return 4, true
	}
	if snap.alt_screen || snap.prompt_state == .None {
		pname := snap.process if len(snap.process) > 0 else "this program"
		fmt.printfln(
			"cancel stops shell commands: for %s use send --key Escape, or signal",
			pname,
		)
		return 1, true
	}
	if (snap.prompt_state == .Prompt || snap.prompt_state == .Input) &&
	   snap.output_end != -1 {
		fmt.println("nothing is running")
		return 0, true
	}
	return 0, false
}

@(private = "file")
_cancel_fail_exit :: proc(err: plat_ipc.Error, id: u32) -> int {
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
	#partial switch err.kind {
	case .Failed:
		switch proto.Fail_Code(err.code) {
		case .Not_Found:
			fmt.eprintfln("no session %d", id)
			return 1
		case .Exited:
			fmt.eprintfln("session %d has exited", id)
			return 4
		case .Busy:
			fmt.eprintfln("held by %s", proto.error_text(err))
			return 5
		case .Bad_Request, .Spawn_Failed: return 1
		case .Unsupported: return 5
		case .Timeout: return 3
		}
	}
	fmt.eprintfln("term: %s", proto.error_text(err))
	return 1
}

@(private = "file")
_cancel_send_sigint :: proc(
	cli: ^plat_ipc.Client,
	id: u32,
) -> (code: int, ok: bool) {
	err := api.api_signal(cli, id, 2, 2 * time.Second)
	if err.kind != .None {
		return _cancel_fail_exit(err, id), false
	}
	return 0, true
}

@(private = "file")
_cancel_snapshot :: proc(
	cli: ^plat_ipc.Client,
	id: u32,
) -> (snap: proto.Snapshot, code: int, ok: bool) {
	err: plat_ipc.Error
	snap, err = api.api_snapshot(cli, id, 0, -1, context.temp_allocator, 2 * time.Second)
	if err.kind != .None {
		return {}, _cancel_fail_exit(err, id), false
	}
	return snap, 0, true
}

@(private = "file")
_cancel_loop :: proc(cli: ^plat_ipc.Client, id: u32, timeout_sec: int) -> int {
	deadline := time.now()._nsec + i64(timeout_sec) * 1_000_000_000
	next_sig_ns := time.now()._nsec
	for {
		now := time.now()._nsec
		if now >= next_sig_ns {
			code, ok := _cancel_send_sigint(cli, id)
			if !ok do return code
			next_sig_ns = now + 500 * 1_000_000
		}
		time.sleep(50 * time.Millisecond)
		snap, code, ok := _cancel_snapshot(cli, id)
		if !ok do return code
		if snap.exited {
			fmt.printfln("stopped (exited %d)", snap.exit_code)
			return 0
		}
		stopped := (snap.prompt_state == .Prompt || snap.prompt_state == .Input) ||
			(snap.has_cmd_exit && snap.output_end != -1)
		if stopped {
			fmt.printfln("stopped (exit %d)", snap.cmd_exit_code)
			return 0
		}
		if time.now()._nsec >= deadline {
			fmt.printfln(
				"did not stop after %ds: signal %d TERM or KILL",
				timeout_sec,
				id,
			)
			return 6
		}
	}
}
