package term

// `term auto <verb>`: automation contracts (features/automation). Verbs and
// their help come from AUTO_VERBS.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import auto "../../features/automation"
import plat_ipc "../../platform/ipc"

AUTO_VERBS := [?]Verb_Help{
	{"run", "[--session id] [--trace file] <contract.lua> <function> [params…]", "Run a contract function on a session",
		"The function returns steps; the runner leases the session and carries them out:\nactions wait for their target and for the screen to settle, a person's Esc or\n^C cancels (on.finally still runs), other input is held. Params: positional\nor --name value; missing ones are asked for. Questions (t.ask, t.handoff) are\nJSON lines on stdout, answered with `term auto reply`. Exit: 0 ok · 1 contract\n· 2 no core · 3 timed out · 4 the program ended · 5 session taken · 6 the\nscreen did not come or t.fail · 7 taken back or cancelled."},
	{"serve", "[--session id] [--trace file] <contract.lua | --adapter name>", "Answer requests to a session's program with the contract's serve function",
		"Waits in `next` as the session (found by the adapter's detect, or --session):\neach `term session tell <id> <text>` becomes serve(text, {id, from}) → steps on\nthe leased session. A request ends when the program answers it itself\n(`term session answer`), when the steps end (t.done answers it), or when its\nsender cancels it (the adapter's cancel steps run). Refused while the program\nreports working or blocked (OSC 7501). ^C stops serving. --adapter name serves\nwith that adapter's own serve steps (claude_code, opencode, agy): no contract file."},
	{"reply", "<id> <answer>", "Answer a running contract's question (t.ask, a param, the end of a handoff)", ""},
	{"check", "<contract.lua>", "Validate a contract without running it",
		"Loads it in the sandbox and checks its shape: api, functions, params,\non, timeouts. Prints its functions."},
	{"snapshot", "<id> [-n lines] [--json] [--save file] [--adapter name]", "The parsed screen and its elements (for writing contracts)",
		"Never resizes, scrolls or focuses the session. Lists the elements found on it\n(marked by the program: OSC 133, OSC 8; inferred: panels, dialogs, buttons,\ntoggles, inputs, list items, bars) with 1-based [row,col width x height].\n--adapter shows them as that adapter refines them. -n adds scrollback lines;\n--save writes the JSON snapshot to a file (term.screen.load reads it)."},
	{"adapters", "", "List the adapters contracts can require (term.adapter.<name>)",
		"First match wins: ./.term/adapters, then ~/.config/term/adapters (or\n$XDG_CONFIG_HOME/term/adapters), then the bundled ones."},
}

AUTO_EXIT_CONTRACT :: 1 // the contract is invalid, or Lua failed

app_cli_auto :: proc(args: []string) -> int {
	if len(args) == 0 || args[0] == "--help" || args[0] == "-h" {
		fmt.println("term auto — drive programs in sessions with Lua contracts\n")
		for v in AUTO_VERBS do fmt.printfln("  %-9s %s", v.name, v.summary)
		fmt.println("\nDetails: term auto <verb> --help")
		return 0
	}
	if len(args) > 1 && (args[1] == "--help" || args[1] == "-h") do return _auto_verb_help(args[0])
	switch args[0] {
	case "run":      return _auto_run(args[1:])
	case "serve":    return _auto_serve(args[1:])
	case "reply":    return _auto_reply(args[1:])
	case "check":    return _auto_check(args[1:])
	case "snapshot": return _auto_snapshot(args[1:])
	case "adapters": return _auto_adapters()
	}
	fmt.eprintfln("term: unknown auto verb %q (term auto --help)", args[0])
	return 1
}

@(private = "file")
_auto_verb_help :: proc(name: string) -> int {
	for v in AUTO_VERBS {
		if v.name != name do continue
		fmt.printfln("usage: term auto %s %s\n\n%s", v.name, v.args, v.summary)
		if len(v.detail) > 0 do fmt.printfln("\n%s", v.detail)
		return 0
	}
	fmt.eprintfln("term: unknown auto verb %q (term auto --help)", name)
	return 1
}

@(private = "file")
_auto_check :: proc(args: []string) -> int {
	if len(args) != 1 {
		fmt.eprintln("usage: term auto check <contract.lua>")
		return 1
	}
	vm, ok := auto.vm_open(auto.adapter_dirs())
	if !ok {
		fmt.eprintln("term: cannot start Lua")
		return AUTO_EXIT_CONTRACT
	}
	defer auto.vm_close(vm)
	if err, loaded := auto.vm_load_file(vm, args[0]); !loaded {
		fmt.eprintfln("term: %s", err)
		return AUTO_EXIT_CONTRACT
	}
	info, err, valid := auto.contract_check(vm)
	defer auto.contract_info_destroy(&info)
	if !valid {
		fmt.eprintfln("term: %s: %s", args[0], err)
		return AUTO_EXIT_CONTRACT
	}
	fmt.printfln("ok: %s", strings.join(info.functions[:], ", ", context.temp_allocator))
	if info.serves do fmt.println("serves requests (term auto serve)")
	return 0
}

@(private = "file")
_auto_snapshot :: proc(args: []string) -> int {
	id, history, as_json, save, adapter, ok := _parse_snapshot_args(args)
	if !ok {
		fmt.eprintln("usage: term auto snapshot <id> [-n lines] [--json] [--save file] [--adapter name]")
		return 1
	}
	conn: plat_ipc.Stream_Conn
	if !app_agent_conn(&conn, false) do return 2
	defer plat_ipc.stream_conn_destroy(&conn)
	b: [16]u8
	w := plat_ipc.wire_writer(b[:])
	plat_ipc.enc_snapshot_req(&w, {id = id, history = history, since = -1})
	plat_ipc.stream_send(&conn, plat_ipc.MSG_SNAPSHOT, 0, plat_ipc.wire_bytes_written(&w))
	f, code := app_agent_answer(&conn, plat_ipc.MSG_SNAPSHOT_RESULT)
	if code != 0 do return code
	if len(adapter) > 0 do return _print_adapted(f.payload, adapter)
	r := plat_ipc.wire_reader(f.payload)
	snap := plat_ipc.dec_snapshot(&r, context.temp_allocator)
	if !plat_ipc.wr_done(&r) {
		fmt.eprintln("term: malformed snapshot from core")
		return 1
	}
	if as_json || len(save) > 0 {
		data, err := json.marshal(snap, {use_enum_names = true}, context.temp_allocator)
		if err != nil do return 1
		if len(save) > 0 && os.write_entire_file(save, data) != nil {
			fmt.eprintfln("term: cannot write %s", save)
			return 1
		}
		if as_json do fmt.println(string(data))
		if !as_json do fmt.printfln("saved %s", save)
		return 0
	}
	_print_snapshot(snap)
	return 0
}

@(private = "file")
_parse_snapshot_args :: proc(args: []string) -> (id, history: u32, as_json: bool, save, adapter: string, ok: bool) {
	rest := args
	for len(rest) > 0 {
		switch rest[0] {
		case "--json":
			as_json, rest = true, rest[1:]
			continue
		case "-n", "--save", "--adapter":
			if len(rest) < 2 do return
			switch rest[0] {
			case "--save":    save = rest[1]
			case "--adapter": adapter = rest[1]
			case:             history = u32(strconv.parse_uint(rest[1], 10) or_return)
			}
			rest = rest[2:]
			continue
		}
		if id != 0 do return
		id = u32(strconv.parse_uint(rest[0], 10) or_return)
		rest = rest[1:]
	}
	return id, history, as_json, save, adapter, id != 0
}

@(private = "file")
_print_snapshot :: proc(s: plat_ipc.Snapshot) {
	alt := " · alt screen" if s.alt_screen else ""
	fmt.printfln("session %d · %dx%d · gen %d · cursor %d,%d · %s%s", s.id, s.cols, s.rows, s.gen, s.cursor_row, s.cursor_col, s.process, alt)
	for row in s.history do _print_snap_row(row, "│ ")
	for row in s.screen do _print_snap_row(row, "")
	screen := auto.screen_build(s, context.temp_allocator)
	es := auto.screen_elements(&screen, context.temp_allocator)
	if len(es) > 0 do fmt.println("\nelements (refs last until the next snapshot):")
	for _, i in es do fmt.printfln("  %s", auto.element_describe(es, i))
}

@(private = "file")
_print_snap_row :: proc(row: plat_ipc.Snap_Row, prefix: string) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, prefix)
	for run in row.runs do strings.write_string(&b, run.text)
	fmt.println(strings.to_string(b))
}

// _run_options reads --session and --trace before the positional args.
@(private = "file")
_run_options :: proc(args: []string) -> (opts: auto.Run_Options, rest: []string, ok: bool) {
	rest = args
	for len(rest) >= 2 && strings.has_prefix(rest[0], "--") {
		switch rest[0] {
		case "--session":
			id, parsed := strconv.parse_uint(rest[1], 10)
			if !parsed do return
			opts.session = u32(id)
		case "--trace": opts.trace_path = rest[1]
		case:           return
		}
		rest = rest[2:]
	}
	return opts, rest, true
}

@(private = "file")
_auto_run :: proc(args: []string) -> int {
	opts, rest, ok := _run_options(args)
	if !ok || len(rest) < 2 {
		fmt.eprintln("usage: term auto run [--session id] [--trace file] <contract.lua> <function> [params…]")
		return 1
	}
	opts.contract, opts.function, opts.args = rest[0], rest[1], rest[2:]
	return auto.run_exit_code(auto.run_contract(opts))
}

@(private = "file")
_auto_serve :: proc(args: []string) -> int {
	opts, rest, ok := _run_options(args)
	switch {
	case ok && len(rest) == 2 && rest[0] == "--adapter": opts.adapter, opts.contract = rest[1], rest[1]
	case ok && len(rest) == 1:                         opts.contract = rest[0]
	case:
		fmt.eprintln("usage: term auto serve [--session id] [--trace file] <contract.lua | --adapter name>")
		return 1
	}
	return auto.run_exit_code(auto.run_serve(opts))
}

// _auto_reply answers a question: a broker request to the run's endpoint.
@(private = "file")
_auto_reply :: proc(args: []string) -> int {
	if len(args) != 2 {
		fmt.eprintln("usage: term auto reply <id> <answer>")
		return 1
	}
	id, ok := strconv.parse_uint(args[0], 10)
	if !ok {
		fmt.eprintln("usage: term auto reply <id> <answer>")
		return 1
	}
	return app_cli_agent_tell(u32(id), {args[1], "-t", "30"})
}

@(private = "file")
_print_adapted :: proc(payload: []u8, adapter: string) -> int {
	text, detected, err := auto.adapter_elements(payload, adapter)
	if len(err) > 0 {
		fmt.eprintfln("term: %s", err)
		return AUTO_EXIT_CONTRACT
	}
	fmt.printfln("adapter %s: detect %s", adapter, "accepts this screen" if detected else "says this is not its program")
	fmt.println(text)
	return 0
}

@(private = "file")
_auto_adapters :: proc() -> int {
	for a in auto.adapter_list() do fmt.printfln("  %-14s %s", a.name, a.source)
	return 0
}
