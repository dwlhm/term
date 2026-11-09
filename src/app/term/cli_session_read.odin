package term

// CLI handler for `term session read` (spec 4.4, RD1–RD24).
// Reads screen text, history (-n), last command output (--last), or elements.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import api "../../features/session_api"
import model "../../features/screen_model"
import proto "../../features/session_proto"
import plat_ipc "../../platform/ipc"

_parse_read_target :: proc(
	a: string,
	opts: ^Cli_Read_Options,
	has_id: ^bool,
) -> bool {
	if has_id^ {
		opts.err_msg = "too many arguments for read"
		return false
	}
	val, ok := strconv.parse_uint(a, 10)
	if !ok || val == 0 || val > uint(max(u32)) {
		opts.err_msg = "which session? read <id>"
		return false
	}
	opts.id = u32(val)
	has_id^ = true
	return true
}

app_cli_session_read :: proc(args: []string) -> int {
	opts, ok := app_cli_parse_read(args)
	if !ok {
		fmt.eprintln(opts.err_msg)
		return 1
	}

	c: plat_ipc.Client
	if err := proto.session_open(&c, .Cli, false); err.kind != .None {
		return app_fail(err)
	}
	defer plat_ipc.client_close(&c)

	if opts.tail {
		return _cli_read_tail(&c, opts)
	}
	if opts.elements {
		return _cli_read_elements(&c, opts.id, opts.as_json)
	}
	return _cli_read_text(&c, opts)
}

@(private = "file")
_cli_read_elements :: proc(
	c: ^plat_ipc.Client,
	id: u32,
	as_json: bool,
) -> int {
	elems, err := api.api_elements(c, id, context.temp_allocator)
	if err.kind != .None do return app_fail(err)

	for e in elems {
		role := _role_name(e.role)
		name := e.name if len(e.name) > 0 else e.text
		state := _state_str(e.state)
		if len(state) > 0 {
			fmt.printfln(
				"@e%d %s \"%s\" %d,%d %dx%d %s",
				e.ref, role, name, e.row, e.col, e.width, e.height, state,
			)
		} else {
			fmt.printfln(
				"@e%d %s \"%s\" %d,%d %dx%d",
				e.ref, role, name, e.row, e.col, e.width, e.height,
			)
		}
	}
	return 0
}

@(private = "file")
_cli_read_text :: proc(
	c: ^plat_ipc.Client,
	opts: Cli_Read_Options,
) -> int {
	text, err := api.api_read(c, opts.id, opts.lines, opts.last, context.temp_allocator)
	if err.kind != .None do return app_fail(err)

	if opts.clean {
		text = app_clean_text(text, context.temp_allocator)
	}
	if opts.as_json {
		_print_json(opts.id, text)
	} else {
		os.write(os.stdout, transmute([]u8)text)
	}
	return 0
}

@(private = "file")
_print_json :: proc(id: u32, text: string) {
	lines := strings.split(text, "\n", context.temp_allocator)
	out := struct {
		session: u32,
		lines:   []string,
	}{session = id, lines = lines}
	json_bytes, _ := json.marshal(out, allocator = context.temp_allocator)
	fmt.println(string(json_bytes))
}

@(private = "file")
_role_name :: proc(r: u8) -> string {
	return model.role_name(model.Role(r))
}

@(private = "file")
_state_str :: proc(st: u8) -> string {
	if st == 0 do return ""
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	first := true
	if st & 1 != 0 {
		strings.write_string(&b, "focused")
		first = false
	}
	if st & 2 != 0 {
		if !first do strings.write_byte(&b, ' ')
		strings.write_string(&b, "selected")
		first = false
	}
	if st & 4 != 0 {
		if !first do strings.write_byte(&b, ' ')
		strings.write_string(&b, "checked")
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}
