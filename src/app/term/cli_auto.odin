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
	{"check", "<contract.lua>", "Validate a contract without running it",
		"Loads it in the sandbox and checks its shape: api, functions, params,\non, timeouts. Prints its functions."},
	{"snapshot", "<id> [-n lines] [--json] [--save file]", "The parsed screen of a session (for writing contracts)",
		"Never resizes, scrolls or focuses the session. -n adds scrollback lines;\n--save writes the JSON snapshot to a file (term.screen.load reads it)."},
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
	case "check":    return _auto_check(args[1:])
	case "snapshot": return _auto_snapshot(args[1:])
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
	id, history, as_json, save, ok := _parse_snapshot_args(args)
	if !ok {
		fmt.eprintln("usage: term auto snapshot <id> [-n lines] [--json] [--save file]")
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
_parse_snapshot_args :: proc(args: []string) -> (id, history: u32, as_json: bool, save: string, ok: bool) {
	rest := args
	for len(rest) > 0 {
		switch rest[0] {
		case "--json":
			as_json, rest = true, rest[1:]
			continue
		case "-n", "--save":
			if len(rest) < 2 do return
			if rest[0] == "--save" do save = rest[1]
			else do history = u32(strconv.parse_uint(rest[1], 10) or_return)
			rest = rest[2:]
			continue
		}
		if id != 0 do return
		id = u32(strconv.parse_uint(rest[0], 10) or_return)
		rest = rest[1:]
	}
	return id, history, as_json, save, id != 0
}

@(private = "file")
_print_snapshot :: proc(s: plat_ipc.Snapshot) {
	alt := " · alt screen" if s.alt_screen else ""
	fmt.printfln("session %d · %dx%d · gen %d · cursor %d,%d · %s%s", s.id, s.cols, s.rows, s.gen, s.cursor_row, s.cursor_col, s.process, alt)
	for row in s.history do _print_snap_row(row, "│ ")
	for row in s.screen do _print_snap_row(row, "")
}

@(private = "file")
_print_snap_row :: proc(row: plat_ipc.Snap_Row, prefix: string) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, prefix)
	for run in row.runs do strings.write_string(&b, run.text)
	fmt.println(strings.to_string(b))
}
