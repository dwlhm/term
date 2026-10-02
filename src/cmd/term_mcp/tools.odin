package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"

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
		`"session_id":{"type":"string","description":"Target session ID. If omitted, closes active session"}` +
	`}}},` +
	`{"name":"terminal_run_command","description":"Execute a command synchronously with deterministic exit code and clean output.",` +
	`"inputSchema":{"type":"object","properties":{` +
		`"session_id":{"type":"string","description":"Target session ID or 'auto' for smart routing. Default: auto"},` +
		`"cwd":{"type":"string","description":"Working directory for the command (optional)"},` +
		`"command":{"type":"string","description":"Shell command to execute"},` +
		`"timeout_ms":{"type":"integer","description":"Execution timeout in milliseconds (default: 30000)"},` +
		`"is_background":{"type":"boolean","description":"Run command asynchronously in background without waiting for completion"}` +
	`},"required":["command"]}},` +
	`{"name":"terminal_send_input","description":"Send raw text input into a terminal session.",` +
	`"inputSchema":{"type":"object","properties":{` +
		`"session_id":{"type":"string","description":"Target session ID (optional, default: auto)"},` +
		`"text":{"type":"string","description":"Raw text to write to terminal stdin"}` +
	`},"required":["text"]}},` +
	`{"name":"terminal_send_key","description":"Send special control keypresses (Enter, Tab, Backspace, Ctrl+C, arrows, etc.).",` +
	`"inputSchema":{"type":"object","properties":{` +
		`"session_id":{"type":"string","description":"Target session ID (optional, default: auto)"},` +
		`"key":{"type":"string","enum":["Enter","Tab","Backspace","Escape","Ctrl+C","Ctrl+D","Ctrl+Z","Up","Down","Left","Right"],"description":"Special key identifier"}` +
	`},"required":["key"]}},` +
	`{"name":"terminal_get_screen","description":"Capture clean 2D visual viewport snapshot from the virtual grid without escape codes.",` +
	`"inputSchema":{"type":"object","properties":{` +
		`"session_id":{"type":"string","description":"Target session ID (optional, default: auto)"},` +
		`"scrollback_lines":{"type":"integer","description":"Additional scrollback lines above the viewport to include (default: 0)"}` +
	`}}},` +
	`{"name":"terminal_resize","description":"Resize terminal virtual grid and PTY window dimensions.",` +
	`"inputSchema":{"type":"object","properties":{` +
		`"session_id":{"type":"string","description":"Target session ID (optional, default: auto)"},` +
		`"rows":{"type":"integer","description":"New row count"},` +
		`"cols":{"type":"integer","description":"New column count"}` +
	`},"required":["rows","cols"]}},` +
	`{"name":"terminal_list_sessions","description":"List all active terminal sessions with their busy/idle state, working directory, and running command.",` +
	`"inputSchema":{"type":"object","properties":{}}},` +
	`{"name":"terminal_switch_session","description":"Switch the default active terminal session.",` +
	`"inputSchema":{"type":"object","properties":{` +
		`"session_id":{"type":"string","description":"Target session ID to activate"}` +
	`},"required":["session_id"]}},` +
	`{"name":"terminal_list_commands","description":"List executed command history for a session.",` +
	`"inputSchema":{"type":"object","properties":{` +
		`"session_id":{"type":"string","description":"Target session ID (optional, default: auto)"}` +
	`}}},` +
	`{"name":"terminal_get_output","description":"Retrieve uncompressed command output buffer with pagination or grep filtering without re-running.",` +
	`"inputSchema":{"type":"object","properties":{` +
		`"session_id":{"type":"string","description":"Target session ID (optional, default: auto)"},` +
		`"command_id":{"type":"integer","description":"Target command ID (optional, default: latest)"},` +
		`"offset":{"type":"integer","description":"Line offset (default: 0)"},` +
		`"limit":{"type":"integer","description":"Maximum lines to return (default: 200)"},` +
		`"grep":{"type":"string","description":"Case-insensitive grep filter substring"}` +
	`}}},` +
	`{"name":"terminal_run_parallel","description":"Execute multiple commands concurrently across isolated worker sessions.",` +
	`"inputSchema":{"type":"object","properties":{` +
		`"commands":{"type":"array","items":{"type":"string"},"description":"List of shell commands to execute concurrently"},` +
		`"cwd":{"type":"string","description":"Working directory for worker sessions (optional)"},` +
		`"timeout_ms":{"type":"integer","description":"Execution timeout in milliseconds (default: 60000)"}` +
	`},"required":["commands"]}}` +
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

// Helper to extract bool from json object
_json_get_bool :: proc(obj: json.Object, key: string, default_val: bool = false) -> bool {
	if v, ok := obj[key]; ok {
		if b, is_b := v.(json.Boolean); is_b {
			return b
		}
	}
	return default_val
}

// Parallel_Worker encapsulates state for concurrent command execution in terminal_run_parallel.
Parallel_Worker :: struct {
	worker_index: int,
	command:      string,
	cwd:          string,
	timeout_ms:   int,
	thread:       ^thread.Thread,
	output:       string,
	exit_code:    int,
	completed:    bool,
	total_lines:  int,
	truncated:    bool,
	allocator:    runtime.Allocator,
}

// parallel_worker_proc executes a command in a freshly spawned isolated session.
parallel_worker_proc :: proc(t: ^thread.Thread) {
	w := (^Parallel_Worker)(t.data)
	worker_id := fmt.tprintf("worker_%d_%p", w.worker_index, t)
	sess, ok := mcp_session_create(worker_id, cwd = w.cwd)
	if !ok {
		w.output = strings.clone("Failed to spawn worker session", w.allocator)
		w.exit_code = -1
		w.completed = false
		return
	}
	defer {
		mcp_session_destroy(sess)
		free(sess)
	}
	out, code, comp, tot, trunc := mcp_session_run_command(sess, w.command, w.timeout_ms, w.allocator)
	w.output = out
	w.exit_code = code
	w.completed = comp
	w.total_lines = tot
	w.truncated = trunc
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
			id = sm.active_session_id
		}
		if len(id) == 0 {
			return "", true, "No active session to close"
		}

		closed := session_manager_close(sm, id)
		if !closed {
			return "", true, fmt.tprintf("Session not found: '%s'", id)
		}

		return strings.clone("{\"closed\":true,\"content\":[{\"type\":\"text\",\"text\":\"Session closed\"}]}", allocator), false, ""

	case "terminal_run_command":
		id := _json_get_string(args, "session_id", "auto")
		cmd_raw := _json_get_string(args, "command", "")
		cwd_val := _json_get_string(args, "cwd", "")
		timeout_ms := _json_get_int(args, "timeout_ms", 30000)
		is_bg := _json_get_bool(args, "is_background", false)

		if len(cmd_raw) == 0 {
			return "", true, "Missing required parameter 'command'"
		}

		cmd := cmd_raw
		if len(cwd_val) > 0 {
			cmd = fmt.tprintf("cd \"%s\" && %s", cwd_val, cmd_raw)
		}

		id_used, s, ok := session_manager_get_or_route(sm, id)
		if !ok {
			return "", true, fmt.tprintf("Failed to route or create session: '%s'", id)
		}

		if is_bg {
			s.is_busy = true
			if len(s.active_cmd) > 0 do delete(s.active_cmd)
			s.active_cmd = strings.clone(cmd)
			_, _ = mcp_session_send_input(s, fmt.tprintf("%s\n", cmd))

			b := strings.builder_make(allocator)
			strings.write_string(&b, "{\"output\":\"Command started in background\",\"exit_code\":0,\"completed\":true,\"session_id\":\"")
			escape_json_string(&b, id_used)
			strings.write_string(&b, "\",\"total_lines\":1,\"truncated\":false,\"content\":[{\"type\":\"text\",\"text\":\"Command started in background\"}]}")
			return strings.to_string(b), false, ""
		}

		out, exit_code, completed, total_lines, truncated := mcp_session_run_command(s, cmd, timeout_ms, allocator)
		defer delete(out, allocator)

		b := strings.builder_make(allocator)
		strings.write_string(&b, "{\"output\":\"")
		escape_json_string(&b, out)
		strings.write_string(&b, "\",\"exit_code\":")
		strings.write_int(&b, exit_code)
		strings.write_string(&b, ",\"completed\":")
		strings.write_string(&b, "true" if completed else "false")
		strings.write_string(&b, ",\"session_id\":\"")
		escape_json_string(&b, id_used)
		strings.write_string(&b, "\",\"total_lines\":")
		strings.write_int(&b, total_lines)
		strings.write_string(&b, ",\"truncated\":")
		strings.write_string(&b, "true" if truncated else "false")
		strings.write_string(&b, ",\"content\":[{\"type\":\"text\",\"text\":\"")
		
		content_str := fmt.tprintf("[exit: %d]\n%s", exit_code, out)
		escape_json_string(&b, content_str)
		
		strings.write_string(&b, "\"}]}")
		return strings.to_string(b), false, ""

	case "terminal_send_input":
		id := _json_get_string(args, "session_id", "auto")
		text := _json_get_string(args, "text", "")

		if len(text) == 0 {
			return "", true, "Missing required parameter 'text'"
		}

		id_used, s, ok := session_manager_get_or_route(sm, id)
		if !ok {
			return "", true, fmt.tprintf("Session not found: '%s'", id)
		}

		n, send_ok := mcp_session_send_input(s, text)
		if !send_ok {
			return "", true, "Failed to write input to terminal PTY"
		}

		b := strings.builder_make(allocator)
		strings.write_string(&b, fmt.tprintf(`{{"bytes_written":%d,"session_id":"%s","content":[{{"type":"text","text":"Wrote %d bytes"}}]}}`, n, id_used, n))
		return strings.to_string(b), false, ""

	case "terminal_send_key":
		id := _json_get_string(args, "session_id", "auto")
		key := _json_get_string(args, "key", "")

		if len(key) == 0 {
			return "", true, "Missing required parameter 'key'"
		}

		_, s, ok := session_manager_get_or_route(sm, id)
		if !ok {
			return "", true, fmt.tprintf("Session not found: '%s'", id)
		}

		send_ok := mcp_session_send_key(s, key)
		if !send_ok {
			return "", true, fmt.tprintf("Unknown key or failed to send key: '%s'", key)
		}

		return strings.clone("{\"sent\":true,\"content\":[{\"type\":\"text\",\"text\":\"Key sent\"}]}", allocator), false, ""

	case "terminal_get_screen":
		id := _json_get_string(args, "session_id", "auto")
		scrollback := _json_get_int(args, "scrollback_lines", 0)

		id_used, s, ok := session_manager_get_or_route(sm, id)
		if !ok {
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
		strings.write_string(&b, "\",\"session_id\":\"")
		escape_json_string(&b, id_used)
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
		id := _json_get_string(args, "session_id", "auto")
		rows := _json_get_int(args, "rows", 0)
		cols := _json_get_int(args, "cols", 0)

		if rows <= 0 || cols <= 0 {
			return "", true, "Parameters 'rows' and 'cols' must be positive integers"
		}

		_, s, ok := session_manager_get_or_route(sm, id)
		if !ok {
			return "", true, fmt.tprintf("Session not found: '%s'", id)
		}

		resize_ok := mcp_session_resize(s, rows, cols)
		if !resize_ok {
			return "", true, "Failed to resize terminal"
		}

		return strings.clone("{\"resized\":true,\"content\":[{\"type\":\"text\",\"text\":\"Resized\"}]}", allocator), false, ""

	case "terminal_list_sessions":
		infos := session_manager_list_sessions(sm, context.temp_allocator)
		b := strings.builder_make(allocator)
		strings.write_string(&b, "{\"sessions\":[")
		for info, idx in infos {
			if idx > 0 do strings.write_string(&b, ",")
			strings.write_string(&b, "{\"id\":\"")
			escape_json_string(&b, info.id)
			strings.write_string(&b, "\",\"is_active\":")
			strings.write_string(&b, "true" if info.is_active else "false")
			strings.write_string(&b, ",\"is_busy\":")
			strings.write_string(&b, "true" if info.is_busy else "false")
			strings.write_string(&b, ",\"active_cmd\":\"")
			escape_json_string(&b, info.active_cmd)
			strings.write_string(&b, "\",\"cwd\":\"")
			escape_json_string(&b, info.cwd)
			strings.write_string(&b, "\",\"command_count\":")
			strings.write_int(&b, info.command_count)
			strings.write_string(&b, "}")
		}
		strings.write_string(&b, "],\"content\":[{\"type\":\"text\",\"text\":\"Listed sessions\"}]}")
		return strings.to_string(b), false, ""

	case "terminal_switch_session":
		target_id := _json_get_string(args, "session_id", "")
		if len(target_id) == 0 {
			return "", true, "Missing required parameter 'session_id'"
		}

		switched := session_manager_switch_active(sm, target_id)
		if !switched {
			return "", true, fmt.tprintf("Session not found: '%s'", target_id)
		}

		b := strings.builder_make(allocator)
		strings.write_string(&b, "{\"active_session_id\":\"")
		escape_json_string(&b, target_id)
		strings.write_string(&b, "\",\"content\":[{\"type\":\"text\",\"text\":\"Active session switched to ")
		escape_json_string(&b, target_id)
		strings.write_string(&b, "\"}]}")
		return strings.to_string(b), false, ""

	case "terminal_list_commands":
		target_id := _json_get_string(args, "session_id", "auto")
		id_used, s, ok := session_manager_get_or_route(sm, target_id)
		if !ok {
			return "", true, fmt.tprintf("Session not found: '%s'", target_id)
		}

		b := strings.builder_make(allocator)
		strings.write_string(&b, "{\"session_id\":\"")
		escape_json_string(&b, id_used)
		strings.write_string(&b, "\",\"commands\":[")
		sync.mutex_lock(&s.lock)
		for rec, idx in s.command_history {
			if idx > 0 do strings.write_string(&b, ",")
			strings.write_string(&b, "{\"id\":")
			strings.write_int(&b, rec.id)
			strings.write_string(&b, ",\"command\":\"")
			escape_json_string(&b, rec.command)
			strings.write_string(&b, "\",\"exit_code\":")
			strings.write_int(&b, rec.exit_code)
			strings.write_string(&b, ",\"duration_ms\":")
			strings.write_int(&b, rec.duration_ms)
			strings.write_string(&b, ",\"completed\":")
			strings.write_string(&b, "true" if rec.completed else "false")
			strings.write_string(&b, ",\"total_lines\":")
			strings.write_int(&b, rec.total_lines)
			strings.write_string(&b, ",\"summary\":\"")
			escape_json_string(&b, rec.summary)
			strings.write_string(&b, "\"}")
		}
		sync.mutex_unlock(&s.lock)
		strings.write_string(&b, "],\"content\":[{\"type\":\"text\",\"text\":\"Command history listed\"}]}")
		return strings.to_string(b), false, ""

	case "terminal_get_output":
		target_id := _json_get_string(args, "session_id", "auto")
		id_used, s, ok := session_manager_get_or_route(sm, target_id)
		if !ok {
			return "", true, fmt.tprintf("Session not found: '%s'", target_id)
		}

		cmd_id := _json_get_int(args, "command_id", 0)
		offset := _json_get_int(args, "offset", 0)
		limit := _json_get_int(args, "limit", 200)
		grep_filter := _json_get_string(args, "grep", "")

		output, total_matched, total_lines, get_ok := session_core.session_get_command_output(s, cmd_id, offset, limit, grep_filter, allocator)
		if !get_ok {
			return "", true, "Command record not found"
		}
		defer delete(output, allocator)

		b := strings.builder_make(allocator)
		strings.write_string(&b, "{\"output\":\"")
		escape_json_string(&b, output)
		strings.write_string(&b, "\",\"session_id\":\"")
		escape_json_string(&b, id_used)
		strings.write_string(&b, "\",\"command_id\":")
		strings.write_int(&b, cmd_id)
		strings.write_string(&b, ",\"offset\":")
		strings.write_int(&b, offset)
		strings.write_string(&b, ",\"limit\":")
		strings.write_int(&b, limit)
		strings.write_string(&b, ",\"total_matched\":")
		strings.write_int(&b, total_matched)
		strings.write_string(&b, ",\"total_lines\":")
		strings.write_int(&b, total_lines)
		strings.write_string(&b, ",\"content\":[{\"type\":\"text\",\"text\":\"")
		escape_json_string(&b, output)
		strings.write_string(&b, "\"}]}")
		return strings.to_string(b), false, ""

	case "terminal_run_parallel":
		cmds_val, has_cmds := args["commands"].(json.Array)
		if !has_cmds || len(cmds_val) == 0 {
			return "", true, "Parameter 'commands' must be a non-empty array of strings"
		}

		cwd := _json_get_string(args, "cwd", "")
		if len(cwd) == 0 && len(sm.active_session_id) > 0 {
			if act_s, exists := sm.sessions[sm.active_session_id]; exists {
				cwd = act_s.cwd
			}
		}
		timeout_ms := _json_get_int(args, "timeout_ms", 60000)

		num_cmds := len(cmds_val)
		workers := make([]Parallel_Worker, num_cmds, context.temp_allocator)
		for i in 0 ..< num_cmds {
			cmd_str, is_str := cmds_val[i].(json.String)
			if !is_str {
				return "", true, "All elements in 'commands' must be strings"
			}
			workers[i].worker_index = i
			workers[i].command = string(cmd_str)
			workers[i].cwd = cwd
			workers[i].timeout_ms = timeout_ms
			workers[i].allocator = allocator
			workers[i].thread = thread.create(parallel_worker_proc)
			workers[i].thread.data = &workers[i]
			thread.start(workers[i].thread)
		}

		for i in 0 ..< num_cmds {
			thread.join(workers[i].thread)
			thread.destroy(workers[i].thread)
		}

		b := strings.builder_make(allocator)
		strings.write_string(&b, "{\"results\":[")
		for i in 0 ..< num_cmds {
			w := &workers[i]
			if i > 0 do strings.write_string(&b, ",")
			strings.write_string(&b, "{\"command\":\"")
			escape_json_string(&b, w.command)
			strings.write_string(&b, "\",\"output\":\"")
			escape_json_string(&b, w.output)
			strings.write_string(&b, "\",\"exit_code\":")
			strings.write_int(&b, w.exit_code)
			strings.write_string(&b, ",\"completed\":")
			strings.write_string(&b, "true" if w.completed else "false")
			strings.write_string(&b, ",\"total_lines\":")
			strings.write_int(&b, w.total_lines)
			strings.write_string(&b, ",\"truncated\":")
			strings.write_string(&b, "true" if w.truncated else "false")
			strings.write_string(&b, "}")
			delete(w.output, allocator)
		}
		strings.write_string(&b, "],\"content\":[{\"type\":\"text\",\"text\":\"Parallel execution finished\"}]}")
		return strings.to_string(b), false, ""

	case:
		return "", true, fmt.tprintf("Unknown tool: '%s'", name)
	}
}
