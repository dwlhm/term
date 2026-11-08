package term

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import proto "../../features/session_proto"
import plat_ipc "../../platform/ipc"

Cli_Read_Options :: struct {
	id:       u32,
	lines:    u32,
	last:     bool,
	clean:    bool,
	elements: bool,
	as_json:  bool,
	err_msg:  string,
}

app_cli_parse_read :: proc(args: []string) -> (opts: Cli_Read_Options, ok: bool) {
	i := 0
	has_id := false
	for i < len(args) {
		a := args[i]
		if a == "-n" {
			i += 1
			if i >= len(args) {
				opts.err_msg = "-n takes a number of lines"
				return opts, false
			}
			val, num_ok := strconv.parse_int(args[i])
			if !num_ok || val < 0 {
				opts.err_msg = "-n takes a number of lines"
				return opts, false
			}
			opts.lines = u32(val)
		} else if a == "--last" {
			opts.last = true
		} else if a == "--clean" {
			opts.clean = true
		} else if a == "--elements" {
			opts.elements = true
		} else if a == "--output" {
			i += 1
			if i >= len(args) {
				opts.err_msg = "--output takes text or json"
				return opts, false
			}
			if args[i] == "json" do opts.as_json = true
			else if args[i] == "text" do opts.as_json = false
			else {
				opts.err_msg = "--output takes text or json"
				return opts, false
			}
		} else if strings.has_prefix(a, "--output=") {
			fmt_type := a[len("--output="):]
			if fmt_type == "json" do opts.as_json = true
			else if fmt_type == "text" do opts.as_json = false
			else {
				opts.err_msg = "--output takes text or json"
				return opts, false
			}
		} else if !strings.has_prefix(a, "-") {
			if !has_id {
				val, num_ok := strconv.parse_uint(a, 10)
				if !num_ok || val == 0 || val > uint(max(u32)) {
					opts.err_msg = "which session? read <id>"
					return opts, false
				}
				opts.id = u32(val)
				has_id = true
			} else {
				opts.err_msg = "too many arguments for read"
				return opts, false
			}
		} else {
			opts.err_msg = fmt.tprintf("unknown option '%s'", a)
			return opts, false
		}
		i += 1
	}

	if !has_id {
		self_id, inside := app_agent_self_id()
		if inside {
			opts.id = self_id
		} else {
			opts.err_msg = "which session? read <id>"
			return opts, false
		}
	}
	return opts, true
}

app_clean_text :: proc(input: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	raw := input
	has_trailing_newline := strings.has_suffix(raw, "\n")
	if has_trailing_newline do raw = raw[:len(raw) - 1]
	lines := strings.split(raw, "\n", context.temp_allocator)
	empty_count := 0

	for line in lines {
		lb := strings.builder_make(context.temp_allocator)
		for r in line {
			// Box drawing: U+2500 - U+257F
			if r >= 0x2500 && r <= 0x257F do continue
			// Block elements / scrollbars: U+2580 - U+259F
			if r >= 0x2580 && r <= 0x259F do continue
			strings.write_rune(&lb, r)
		}
		cleaned_line := strings.trim_right_space(strings.to_string(lb))
		if len(cleaned_line) == 0 {
			empty_count += 1
			if empty_count == 1 && len(b.buf) > 0 {
				strings.write_byte(&b, '\n')
			}
		} else {
			empty_count = 0
			strings.write_string(&b, cleaned_line)
			strings.write_byte(&b, '\n')
		}
	}
	if !has_trailing_newline && len(b.buf) > 0 && b.buf[len(b.buf) - 1] == '\n' {
		pop(&b.buf)
	}
	return strings.to_string(b)
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

	if opts.elements {
		buf: [16]u8
		w := plat_ipc.wire_writer(buf[:])
		plat_ipc.ww_u32(&w, opts.id)
		a, err := plat_ipc.client_call(&c, proto.MSG_ELEMENTS, ipc_wire_bytes(&w), {timeout = 3 * time.Second})
		if err.kind != .None do return app_fail(err)
		r := plat_ipc.wire_reader(a.body)
		count := int(plat_ipc.wr_u32(&r))
		for _ in 0 ..< count {
			e := proto.dec_element_report(&r)
			role := _role_name(e.role)
			name := e.name if len(e.name) > 0 else e.text
			state_str := _state_str(e.state)
			if len(state_str) > 0 {
				fmt.printfln("@e%d %s \"%s\" %d,%d %dx%d %s", e.ref, role, name, e.row, e.col, e.width, e.height, state_str)
			} else {
				fmt.printfln("@e%d %s \"%s\" %d,%d %dx%d", e.ref, role, name, e.row, e.col, e.width, e.height)
			}
		}
		return 0
	}

	buf: [16]u8
	w := plat_ipc.wire_writer(buf[:])
	proto.enc_read_req(&w, {id = opts.id, history = opts.lines, last = opts.last})
	a, err := plat_ipc.client_call(&c, proto.MSG_READ, ipc_wire_bytes(&w), {timeout = 4 * time.Second})
	if err.kind != .None do return app_fail(err)

	text := string(a.body)
	if opts.clean {
		text = app_clean_text(text, context.temp_allocator)
	}
	if opts.as_json {
		// Output JSON structure: {session, lines: [...]}
		lines := strings.split(text, "\n", context.temp_allocator)
		out := struct {
			session: u32,
			lines:   []string,
		}{
			session = opts.id,
			lines   = lines,
		}
		json_bytes, _ := json.marshal(out, allocator = context.temp_allocator)
		fmt.println(string(json_bytes))
	} else {
		os.write(os.stdout, transmute([]u8)text)
	}
	return 0
}

@(private = "file")
ipc_wire_bytes :: proc(w: ^plat_ipc.Wire_Writer) -> []u8 {
	return plat_ipc.wire_bytes_written(w)
}

@(private = "file")
_role_name :: proc(r: u8) -> string {
	switch r {
	case 0: return "panel"
	case 1: return "dialog"
	case 2: return "button"
	case 3: return "checkbox"
	case 4: return "radio"
	case 5: return "input"
	case 6: return "listitem"
	case 7: return "tab"
	case 8: return "scrollbar"
	case 9: return "statusbar"
	case 10: return "link"
	case 11: return "prompt"
	case 12: return "output"
	case: return "element"
	}
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
