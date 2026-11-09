package term

// `term` control subcommands (client side; never creates a window).
// Session verbs served by the core live in cli_agent.odin; this file sends
// `term session attach <id>`, `term show` and `term quit` to the GUI.
// Exit codes: 0 ok · 1 error reply / bad usage · 2 Term is not running.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import proto "../../features/session_proto"
import plat_ipc "../../platform/ipc"
import ctrl_feat "../../features/control"

// app_run_control_cli: handled = false when args[1] is not "session",
// "show", "quit" or "kill" (normal GUI startup continues). Core verbs go to
// app_cli_agent; attach/show/quit/kill go to the control sockets.
app_run_control_cli :: proc(args: []string) -> (handled: bool, exit_code: int) {
	if len(args) < 2 do return false, 0
	line: string
	switch args[1] {
	case "--help", "-h", "help": return true, app_cli_help()
	case "skill":                return true, app_cli_skill(args[2:])
	case "run":                  return true, app_cli_run(args[2:])
	case "auto":                 return true, app_cli_auto(args[2:])
	case "quit", "kill":         return true, app_cli_quit(args[1:])
	case "show", "split", "tab":
		if len(args) > 2 && (args[2] == "--help" || args[2] == "-h") {
			if args[1] == "split" {
				fmt.println("usage: term split <right|down> [session_id]\n\nSplit the active window pane and optionally attach a session.")
			} else if args[1] == "tab" {
				fmt.println("usage: term tab [session_id]\n\nOpen a new tab and optionally attach a session.")
			} else {
				fmt.println("usage: term show\n\nBring the term window to the front.")
			}
			return true, 0
		}
		line = strings.join(args[1:], " ", context.temp_allocator)
	case "session":
		if handled, code := app_cli_agent(args[2:]); handled do return true, code
		line = strings.join(args[2:], " ", context.temp_allocator)
	case:                        return false, 0
	}
	req, perr := ctrl_feat.control_parse_request(line)
	if perr != .None {
		fmt.eprintfln("term: %s", ctrl_feat.control_parse_error_message(perr))
		return true, 1
	}
	if (args[1] == "session") != (req.verb == .Attach) {
		fmt.eprintln(APP_CLI_USAGE)
		return true, 1
	}
	at_buf: [256]u8
	at, aerr := proto.control_endpoint(at_buf[:])
	if aerr.kind != .None do return true, _cli_fail(aerr)
	req_buf: [64]u8
	reply_buf: [proto.CONTROL_MAX_REPLY]u8
	reply, err := app_control_request(at, ctrl_feat.control_format_request(req, req_buf[:]), reply_buf[:])
	if err.kind != .None do return true, _cli_fail(err)
	ok, code, message, _, well_formed := ctrl_feat.control_split_reply(reply)
	if !well_formed || !ok {
		msg := message
		if len(msg) == 0 {
			msg = code if len(code) > 0 else "malformed reply"
		}
		fmt.eprintfln("term: %s", msg)
		if code == "exited" || strings.contains(msg, "has exited") {
			return true, 4
		}
		return true, 1
	}
	return true, 0
}

// app_cli_quit stops GUI windows, Core, Holder and background sessions.
app_cli_quit :: proc(args: []string) -> int {
	force := false
	if len(args) > 0 && args[0] == "kill" {
		force = true
	}
	for a in args {
		switch a {
		case "-h", "--help":
			fmt.println("usage: term quit [-f|--force]")
			fmt.println("       term kill")
			fmt.println("\nEnd all Term windows, background sessions, and tiers.")
			fmt.println("Options:")
			fmt.println("  -f, --force, -y    Skip confirmation prompt even if programs are running")
			return 0
		case "-f", "--force", "-y", "--all", "-a":
			force = true
		}
	}

	core_client: plat_ipc.Client
	core_running := false
	if err := proto.session_open(&core_client, .Cli, false); err.kind == .None {
		core_running = true
	}

	at_buf: [256]u8
	at, aerr := proto.control_endpoint(at_buf[:])
	gui_running := false
	if aerr.kind == .None {
		reply_buf: [proto.CONTROL_MAX_REPLY]u8
		reply, rerr := app_control_request(at, "ping", reply_buf[:])
		if rerr.kind == .None && strings.has_prefix(reply, "ok") {
			gui_running = true
		}
	}

	if !core_running && !gui_running {
		fmt.println("term: not running")
		return 0
	}

	if core_running && !force {
		a, lerr := plat_ipc.client_call(&core_client, proto.MSG_LIST, nil, {timeout = 1000 * time.Millisecond})
		if lerr.kind == .None {
			r := plat_ipc.wire_reader(a.body)
			count := int(plat_ipc.wr_u32(&r))
			active_count := 0
			active_desc := make([dynamic]string, context.temp_allocator)
			for _ in 0..<count {
				row := proto.dec_row(&r)
				if !r.ok do break
				if row.active {
					active_count += 1
					proc_name := row.process if len(row.process) > 0 else "unknown"
					append(&active_desc, fmt.tprintf("  • [%d] %s (pid %d)", row.id, proc_name, row.pid))
				}
			}
			if active_count > 0 {
				fmt.printfln("Term has %d running program(s):", active_count)
				for line in active_desc {
					fmt.println(line)
				}
				fmt.print("Quit Term and terminate all? [y/N]: ")
				buf: [64]u8
				n, nerr := os.read(os.stdin, buf[:])
				if nerr != nil || n <= 0 {
					fmt.println("\nCancelled.")
					plat_ipc.client_close(&core_client)
					return 0
				}
				ans := strings.to_lower(strings.trim_space(string(buf[:n])))
				if ans != "y" && ans != "yes" {
					fmt.println("Cancelled.")
					plat_ipc.client_close(&core_client)
					return 0
				}
			}
		}
	}

	if gui_running {
		reply_buf: [proto.CONTROL_MAX_REPLY]u8
		_, _ = app_control_request(at, "quit --force", reply_buf[:])
	}

	if core_running {
		_, _ = plat_ipc.client_call(&core_client, proto.MSG_SHUTDOWN, nil, {timeout = 2000 * time.Millisecond})
		plat_ipc.client_close(&core_client)
	}

	fmt.println("term stopped.")
	return 0
}

// app_control_request is ipc.line_call with a short backoff while the .Line
// server sheds load: it answers overload in-band as "err busy\n".
app_control_request :: proc(at: plat_ipc.Endpoint, line: string, out: []u8) -> (reply: string, err: plat_ipc.Error) {
	backoff := 25 * time.Millisecond
	for attempt in 0..<5 {
		reply, err = plat_ipc.line_call(at, line, out)
		if err.kind != .None || reply != "err busy\n" || attempt == 4 do return
		time.sleep(backoff)
		backoff *= 2
	}
	return
}

@(private = "file")
_cli_fail :: proc(err: plat_ipc.Error) -> int {
	if err.kind == .No_Server {
		fmt.eprintln("no window is open: run term")
		return 1
	}
	reason := err.reason if len(err.reason) > 0 else plat_ipc.error_message(err)
	fmt.eprintfln("term: control socket: %s", reason)
	return 1
}
