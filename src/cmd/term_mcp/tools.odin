package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"

import session_core "../../session_core"

TOOLS_LIST_JSON :: `{"tools":[` +
	`{"name":"terminal_create_session","description":"Create a new headless pseudo-terminal session.",` +
	`"inputSchema":{"type":"object","properties":{` +
		`"rows":{"type":"integer","description":"Terminal rows (default: 24)"},` +
		`"cols":{"type":"integer","description":"Terminal columns (default: 80)"},` +
		`"shell":{"type":"string","description":"Shell executable path (default: $SHELL or /bin/zsh)"},` +
		`"cwd":{"type":"string","description":"Working directory for the session"},` +
		`"mode":{"type":"string","enum":["fast","interactive"],"description":"Session mode: fast (headless promptless) or interactive (standard shell)"}` +
	`}}},` +
	`{"name":"terminal_close_session","description":"Close an active terminal session and terminate child processes.",` +
	`"inputSchema":{"type":"object","properties":{` +
		`"session_id":{"type":"string","description":"Target session ID"}` +
	`},"required":["session_id"]}},` +
	`{"name":"terminal_run_command","description":"Execute a command synchronously with deterministic exit code and clean output.",` +
	`"inputSchema":{"type":"object","properties":{` +
		`"session_id":{"type":"string","description":"Target session ID"},` +
		`"command":{"type":"string","description":"Shell command to execute"},` +
		`"timeout_ms":{"type":"integer","description":"Execution timeout in milliseconds (default: 30000)"}` +
	`},"required":["session_id","command"]}},` +
	`{"name":"terminal_send_input","description":"Send raw text input into a terminal session.",` +
	`"inputSchema":{"type":"object","properties":{` +
		`"session_id":{"type":"string","description":"Target session ID"},` +
		`"text":{"type":"string","description":"Raw text to write to terminal stdin"}` +
	`},"required":["session_id","text"]}},` +
	`{"name":"terminal_send_key","description":"Send special control keypresses (Enter, Tab, Backspace, Ctrl+C, arrows, etc.).",` +
	`"inputSchema":{"type":"object","properties":{` +
		`"session_id":{"type":"string","description":"Target session ID"},` +
		`"key":{"type":"string","enum":["Enter","Tab","Backspace","Escape","Ctrl+C","Ctrl+D","Ctrl+Z","Up","Down","Left","Right"],"description":"Special key identifier"}` +
	`},"required":["session_id","key"]}},` +
	`{"name":"terminal_get_screen","description":"Capture clean 2D visual viewport snapshot from the virtual grid without escape codes.",` +
	`"inputSchema":{"type":"object","properties":{` +
		`"session_id":{"type":"string","description":"Target session ID"},` +
		`"scrollback_lines":{"type":"integer","description":"Additional scrollback lines above the viewport to include (default: 0)"}` +
	`},"required":["session_id"]}},` +
	`{"name":"terminal_resize","description":"Resize terminal virtual grid and PTY window dimensions.",` +
	`"inputSchema":{"type":"object","properties":{` +
		`"session_id":{"type":"string","description":"Target session ID"},` +
		`"rows":{"type":"integer","description":"New row count"},` +
		`"cols":{"type":"integer","description":"New column count"}` +
	`},"required":["session_id","rows","cols"]}}` +
`]}`

// Helper to extract string from json object
_json_get_string :: proc(obj: json.Object, key: string, default_val: string = "") -> string {
	if v, ok := obj[key]; ok {
		if s, is_str := v.(json.String); is_str {
			return s
		}
	}
	return default_val
}

// Helper to extract int from json object
_json_get_int :: proc(obj: json.Object, key: string, default_val: int = 0) -> int {
	if v, ok := obj[key]; ok {
		if i, is_int := v.(json.Integer); is_int {
			return int(i)
		}
		if f, is_float := v.(json.Float); is_float {
			return int(f)
		}
	}
	return default_val
}

// tools_dispatch_call routes a tools/call request to the corresponding tool handler.
tools_dispatch_call :: proc(sm: ^Session_Manager, name: string, args_val: json.Value, allocator := context.allocator) -> (result_json: string, is_error: bool, err_msg: string) {
	args, is_obj := args_val.(json.Object)
	if !is_obj && args_val != nil {
		return "", true, "Invalid params: arguments must be an object"
	}

	switch name {
	case "terminal_create_session":
		rows := _json_get_int(args, "rows", 24)
		cols := _json_get_int(args, "cols", 80)
		shell := _json_get_string(args, "shell", "")
		cwd := _json_get_string(args, "cwd", "")
		mode_str := _json_get_string(args, "mode", "fast")
		mode: session_core.Session_Mode = .Interactive_GUI if mode_str == "interactive" else .Fast_Headless

		id, _, ok := session_manager_create(sm, rows, cols, shell, cwd, mode)
		if !ok {
			return "", true, "Failed to spawn terminal session"
		}

		b := strings.builder_make(allocator)
		strings.write_string(&b, "{\"session_id\":\"")
		escape_json_string(&b, id)
		strings.write_string(&b, "\",\"content\":[{\"type\":\"text\",\"text\":\"Session created: ")
		escape_json_string(&b, id)
		strings.write_string(&b, "\"}]}")
		return strings.to_string(b), false, ""

	case "terminal_close_session":
		id := _json_get_string(args, "session_id", "")
		if len(id) == 0 {
			return "", true, "Missing required parameter 'session_id'"
		}

		closed := session_manager_close(sm, id)
		if !closed {
			return "", true, fmt.tprintf("Session not found: '%s'", id)
		}

		return strings.clone("{\"closed\":true,\"content\":[{\"type\":\"text\",\"text\":\"Session closed\"}]}", allocator), false, ""

	case "terminal_run_command":
		id := _json_get_string(args, "session_id", "")
		cmd := _json_get_string(args, "command", "")
		timeout_ms := _json_get_int(args, "timeout_ms", 30000)

		if len(id) == 0 {
			return "", true, "Missing required parameter 'session_id'"
		}
		if len(cmd) == 0 {
			return "", true, "Missing required parameter 'command'"
		}

		s, found := session_manager_get(sm, id)
		if !found {
			return "", true, fmt.tprintf("Session not found: '%s'", id)
		}

		out, exit_code, completed := mcp_session_run_command(s, cmd, timeout_ms, allocator)
		defer delete(out, allocator)

		b := strings.builder_make(allocator)
		strings.write_string(&b, "{\"output\":\"")
		escape_json_string(&b, out)
		strings.write_string(&b, "\",\"exit_code\":")
		strings.write_int(&b, exit_code)
		strings.write_string(&b, ",\"completed\":")
		strings.write_string(&b, "true" if completed else "false")
		strings.write_string(&b, ",\"content\":[{\"type\":\"text\",\"text\":\"")
		escape_json_string(&b, out)
		strings.write_string(&b, "\"}]}")
		return strings.to_string(b), false, ""

	case "terminal_send_input":
		id := _json_get_string(args, "session_id", "")
		text := _json_get_string(args, "text", "")

		if len(id) == 0 {
			return "", true, "Missing required parameter 'session_id'"
		}

		s, found := session_manager_get(sm, id)
		if !found {
			return "", true, fmt.tprintf("Session not found: '%s'", id)
		}

		n, ok := mcp_session_send_input(s, text)
		if !ok {
			return "", true, "Failed to write input to terminal PTY"
		}

		b := strings.builder_make(allocator)
		strings.write_string(&b, fmt.tprintf(`{{"bytes_written":%d,"content":[{{"type":"text","text":"Wrote %d bytes"}}]}}`, n, n))
		return strings.to_string(b), false, ""

	case "terminal_send_key":
		id := _json_get_string(args, "session_id", "")
		key := _json_get_string(args, "key", "")

		if len(id) == 0 {
			return "", true, "Missing required parameter 'session_id'"
		}
		if len(key) == 0 {
			return "", true, "Missing required parameter 'key'"
		}

		s, found := session_manager_get(sm, id)
		if !found {
			return "", true, fmt.tprintf("Session not found: '%s'", id)
		}

		ok := mcp_session_send_key(s, key)
		if !ok {
			return "", true, fmt.tprintf("Unknown key or failed to send key: '%s'", key)
		}

		return strings.clone("{\"sent\":true,\"content\":[{\"type\":\"text\",\"text\":\"Key sent\"}]}", allocator), false, ""

	case "terminal_get_screen":
		id := _json_get_string(args, "session_id", "")
		scrollback := _json_get_int(args, "scrollback_lines", 0)

		if len(id) == 0 {
			return "", true, "Missing required parameter 'session_id'"
		}

		s, found := session_manager_get(sm, id)
		if !found {
			return "", true, fmt.tprintf("Session not found: '%s'", id)
		}

		screen_text := mcp_session_extract_screen(s, scrollback, allocator)
		defer delete(screen_text, allocator)
		cur_row := s.term.cursor.row
		cur_col := s.term.cursor.col
		rows := s.term.grid.row_count
		cols := s.term.grid.col_count

		b := strings.builder_make(allocator)
		strings.write_string(&b, "{\"text\":\"")
		escape_json_string(&b, screen_text)
		strings.write_string(&b, "\",\"cursor_row\":")
		strings.write_int(&b, cur_row)
		strings.write_string(&b, ",\"cursor_col\":")
		strings.write_int(&b, cur_col)
		strings.write_string(&b, ",\"rows\":")
		strings.write_int(&b, rows)
		strings.write_string(&b, ",\"cols\":")
		strings.write_int(&b, cols)
		strings.write_string(&b, ",\"content\":[{\"type\":\"text\",\"text\":\"")
		escape_json_string(&b, screen_text)
		strings.write_string(&b, "\"}]}")
		return strings.to_string(b), false, ""

	case "terminal_resize":
		id := _json_get_string(args, "session_id", "")
		rows := _json_get_int(args, "rows", 0)
		cols := _json_get_int(args, "cols", 0)

		if len(id) == 0 {
			return "", true, "Missing required parameter 'session_id'"
		}
		if rows <= 0 || cols <= 0 {
			return "", true, "Parameters 'rows' and 'cols' must be positive integers"
		}

		s, found := session_manager_get(sm, id)
		if !found {
			return "", true, fmt.tprintf("Session not found: '%s'", id)
		}

		ok := mcp_session_resize(s, rows, cols)
		if !ok {
			return "", true, "Failed to resize terminal"
		}

		return strings.clone("{\"resized\":true,\"content\":[{\"type\":\"text\",\"text\":\"Resized\"}]}", allocator), false, ""

	case:
		return "", true, fmt.tprintf("Unknown tool: '%s'", name)
	}
}
