package main

import session_core "../../session_core"

CANARY_PREFIX :: session_core.CANARY_PREFIX
CANARY_SUFFIX :: session_core.CANARY_SUFFIX

// Mcp_Session is an alias to the core session implementation.
Mcp_Session :: session_core.Core_Session

// mcp_session_create initializes a new session via session_core defaulting to Fast_Headless mode.
mcp_session_create :: proc(id: string, rows: int = 24, cols: int = 80, shell: string = "", cwd: string = "", mode: session_core.Session_Mode = .Fast_Headless) -> (^Mcp_Session, bool) {
	cfg := session_core.Session_Config{
		rows  = rows,
		cols  = cols,
		shell = shell,
		cwd   = cwd,
		mode  = mode,
	}
	return session_core.session_create(id, cfg)
}

// mcp_session_start_drain_loop launches the background thread reading PTY output.
mcp_session_start_drain_loop :: proc(s: ^Mcp_Session) {
	session_core.session_start_drain_loop(s)
}

// mcp_session_stop halts the drain thread and terminates the child process group.
mcp_session_stop :: proc(s: ^Mcp_Session) {
	session_core.session_stop(s)
}

// mcp_session_destroy dismantles all terminal and parser resources.
mcp_session_destroy :: proc(s: ^Mcp_Session) {
	session_core.session_destroy(s)
}

// mcp_session_extract_screen captures a clean 2D visual viewport snapshot from the virtual grid.
mcp_session_extract_screen :: proc(s: ^Mcp_Session, scrollback_lines: int = 0, allocator := context.allocator) -> string {
	return session_core.session_extract_screen(s, scrollback_lines, allocator)
}

// mcp_session_send_input writes raw bytes directly into the child PTY master.
mcp_session_send_input :: proc(s: ^Mcp_Session, text: string) -> (int, bool) {
	return session_core.session_send_input(s, text)
}

// mcp_session_send_key sends an interactive control keypress sequence.
mcp_session_send_key :: proc(s: ^Mcp_Session, key: string) -> bool {
	return session_core.session_send_key(s, key)
}

// mcp_session_resize updates both the PTY window size and terminal grid dimensions.
mcp_session_resize :: proc(s: ^Mcp_Session, rows, cols: int) -> bool {
	return session_core.session_resize(s, rows, cols)
}

// mcp_session_run_command executes a command synchronously, detecting completion via OSC 133 or canary sentinel.
mcp_session_run_command :: proc(s: ^Mcp_Session, command: string, timeout_ms: int = 30000, allocator := context.allocator) -> (output: string, exit_code: int, completed: bool, total_lines: int, truncated: bool) {
	return session_core.session_run_command(s, command, timeout_ms, allocator)
}

// mcp_session_get_command_output retrieves buffered raw output lines with offset, limit, and grep filtering.
mcp_session_get_command_output :: proc(s: ^Mcp_Session, cmd_id: int, offset: int, limit: int, grep_filter: string, allocator := context.allocator) -> (output: string, total_matched: int, total_lines: int, ok: bool) {
	return session_core.session_get_command_output(s, cmd_id, offset, limit, grep_filter, allocator)
}
