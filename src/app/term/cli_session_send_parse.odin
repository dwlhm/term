package term

// Argument parsing for `term session send` (spec 4.5, S1–S31).
// Parses text, --key, --paste, --click, --double-click, --scroll, --drag,
// and --raw.

import "core:fmt"
import "core:strconv"
import "core:strings"
import auto "../../features/automation"
import proto "../../features/session_proto"

Cli_Send_Options :: struct {
	id:      u32,
	items:   [dynamic]proto.Act_Batch_Item,
	as_json: bool,
	err_msg: string,
}

app_cli_parse_send :: proc(
	args: []string,
) -> (opts: Cli_Send_Options, ok: bool) {
	if len(args) == 0 {
		opts.err_msg = "send what? text, --key, --paste, --click..."
		return opts, false
	}
	id_val, id_ok := strconv.parse_uint(args[0], 10)
	if !id_ok || id_val == 0 || id_val > uint(max(u32)) {
		opts.err_msg = "not a session id"
		return opts, false
	}
	opts.id = u32(id_val)
	opts.items = make([dynamic]proto.Act_Batch_Item, context.temp_allocator)

	i := 1
	for i < len(args) {
		a := args[i]
		if strings.has_prefix(a, "-") {
			if !_parse_send_flag(args, &i, &opts) do return opts, false
		} else {
			append(&opts.items, proto.Act_Batch_Item{
				kind = .Text, text = a,
			})
		}
		i += 1
	}
	if len(opts.items) == 0 {
		opts.err_msg = "send what? text, --key, --paste, --click..."
		return opts, false
	}
	return opts, true
}

@(private = "file")
_parse_send_flag :: proc(
	args: []string,
	i: ^int,
	opts: ^Cli_Send_Options,
) -> bool {
	a := args[i^]
	switch a {
	case "--json":
		opts.as_json = true
		return true
	case "--output":
		return _parse_output_flag(args, i, opts)
	case "--key":
		return _parse_key_flag(args, i, opts)
	case "--paste":
		return _parse_paste_flag(args, i, opts)
	case "--raw":
		return _parse_raw_flag(args, i, opts)
	case "--click", "--double-click":
		return _parse_click_flag(args, i, opts, a == "--double-click")
	case "--scroll":
		return _parse_scroll_flag(args, i, opts)
	case "--drag":
		return _parse_drag_flag(args, i, opts)
	}
	opts.err_msg = fmt.tprintf("unknown option: %s", a)
	return false
}

@(private = "file")
_parse_output_flag :: proc(
	args: []string,
	i: ^int,
	opts: ^Cli_Send_Options,
) -> bool {
	if i^ + 1 >= len(args) {
		opts.err_msg = "--output is text or json"
		return false
	}
	val := args[i^ + 1]
	i^ += 1
	if val == "json" do opts.as_json = true
	else if val == "text" do opts.as_json = false
	else {
		opts.err_msg = "--output is text or json"
		return false
	}
	return true
}

@(private = "file")
_parse_key_flag :: proc(
	args: []string,
	i: ^int,
	opts: ^Cli_Send_Options,
) -> bool {
	if i^ + 1 >= len(args) {
		opts.err_msg = "usage: --key <name>"
		return false
	}
	name := args[i^ + 1]
	i^ += 1
	k, k_ok := auto.parse_key(name)
	if !k_ok {
		opts.err_msg = fmt.tprintf("unknown key %s", name)
		return false
	}
	append(&opts.items, proto.Act_Batch_Item{
		kind = .Keys, n_keys = 1, keys = {0 = k},
	})
	return true
}

@(private = "file")
_parse_paste_flag :: proc(
	args: []string,
	i: ^int,
	opts: ^Cli_Send_Options,
) -> bool {
	if i^ + 1 >= len(args) {
		opts.err_msg = "usage: --paste <text>"
		return false
	}
	append(&opts.items, proto.Act_Batch_Item{
		kind = .Text, text = args[i^ + 1], paste = true,
	})
	i^ += 1
	return true
}

@(private = "file")
_parse_raw_flag :: proc(
	args: []string,
	i: ^int,
	opts: ^Cli_Send_Options,
) -> bool {
	if i^ + 1 >= len(args) {
		opts.err_msg = "usage: --raw <text>"
		return false
	}
	txt, bad, ok := app_cli_unescape_raw(args[i^ + 1])
	i^ += 1
	if !ok {
		opts.err_msg = fmt.tprintf("bad escape %s", bad)
		return false
	}
	append(&opts.items, proto.Act_Batch_Item{kind = .Raw, text = txt})
	return true
}

@(private = "file")
_parse_click_flag :: proc(
	args: []string,
	i: ^int,
	opts: ^Cli_Send_Options,
	double: bool,
) -> bool {
	if i^ + 1 >= len(args) {
		opts.err_msg = "usage: --click <target> [button]"
		return false
	}
	t := _parse_target(args[i^ + 1])
	i^ += 1
	btn := _parse_btn(args, i)
	append(&opts.items, proto.Act_Batch_Item{
		kind = .Click, target = t, button = btn, double = double,
	})
	return true
}

@(private = "file")
_parse_scroll_flag :: proc(
	args: []string,
	i: ^int,
	opts: ^Cli_Send_Options,
) -> bool {
	if i^ + 3 >= len(args) {
		opts.err_msg = "--scroll ROW,COL up|down N (N >= 1)"
		return false
	}
	t := _parse_target(args[i^ + 1])
	dir_str := args[i^ + 2]
	cnt_str := args[i^ + 3]
	i^ += 3
	dir: u8 = 0
	if dir_str == "up" do dir = 0
	else if dir_str == "down" do dir = 1
	else {
		opts.err_msg = "--scroll ROW,COL up|down N (N >= 1)"
		return false
	}
	cnt, ok := strconv.parse_uint(cnt_str, 10)
	if !ok || cnt < 1 || cnt > uint(max(u16)) {
		opts.err_msg = "--scroll ROW,COL up|down N (N >= 1)"
		return false
	}
	append(&opts.items, proto.Act_Batch_Item{
		kind = .Scroll, target = t, dir = dir, count = u16(cnt),
	})
	return true
}

@(private = "file")
_parse_drag_flag :: proc(
	args: []string,
	i: ^int,
	opts: ^Cli_Send_Options,
) -> bool {
	if i^ + 2 >= len(args) {
		opts.err_msg = "usage: --drag <from> <to> [button]"
		return false
	}
	from_t := _parse_target(args[i^ + 1])
	to_t := _parse_target(args[i^ + 2])
	i^ += 2
	btn := _parse_btn(args, i)
	append(&opts.items, proto.Act_Batch_Item{
		kind = .Drag, target = from_t, to_target = to_t, button = btn,
	})
	return true
}
