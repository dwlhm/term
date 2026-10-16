package feature_session

import "base:runtime"
import "core:strings"
import pty "../../core/platform/pty"
import terminal "../../core/terminal"
import cell "../../core/terminal/cell"
import damage "../../core/terminal/damage"

Session_Config :: struct {
	shell: string,
	argv:  []string,
	cwd:   string,
	rows:  int,
	cols:  int,
}

Terminal_Session :: struct {
	pty:             ^pty.Pty_Handle,
	term:            terminal.Terminal,
	in_prompt:       bool,
	command_running: bool,
	scroll_offset:   int,
	title_buf:       [256]u8,
	title_len:       int,
	cwd_buf:         [512]u8,
	cwd_len:         int,
	allocator:       runtime.Allocator,
}

_osc_title_handler :: proc(user_data: rawptr, osc_id: int, payload: string, term_ptr: rawptr) -> bool {
	sess := (^Terminal_Session)(user_data)
	if sess == nil do return false

	copy_len := min(len(payload), len(sess.title_buf))
	copy(sess.title_buf[:copy_len], payload[:copy_len])
	sess.title_len = copy_len
	return true
}

_osc_cwd_handler :: proc(user_data: rawptr, osc_id: int, payload: string, term_ptr: rawptr) -> bool {
	sess := (^Terminal_Session)(user_data)
	if sess == nil do return false

	copy_len := min(len(payload), len(sess.cwd_buf))
	copy(sess.cwd_buf[:copy_len], payload[:copy_len])
	sess.cwd_len = copy_len
	return true
}

_osc_133_handler :: proc(user_data: rawptr, osc_id: int, payload: string, term_ptr: rawptr) -> bool {
	sess := (^Terminal_Session)(user_data)
	if sess == nil || len(payload) == 0 do return false

	switch payload[0] {
	case 'A': // Prompt start
		sess.in_prompt = true
		sess.command_running = false
	case 'B': // Prompt end (command line entry start)
		sess.in_prompt = false
		sess.command_running = false
	case 'C': // Command executed / start of output
		sess.in_prompt = false
		sess.command_running = true
	case 'D': // Command finished
		sess.in_prompt = false
		sess.command_running = false
	}
	return true
}

session_create :: proc(config: Session_Config, allocator: runtime.Allocator = context.allocator) -> (sess: ^Terminal_Session, err: pty.Pty_Error) {
	rows := max(1, config.rows if config.rows > 0 else 24)
	cols := max(1, config.cols if config.cols > 0 else 80)

	pty_cfg := pty.Pty_Config{
		shell = config.shell,
		argv  = config.argv,
		cwd   = config.cwd,
		rows  = rows,
		cols  = cols,
	}

	handle, pty_err := pty.pty_spawn(pty_cfg)
	if pty_err != .None {
		return nil, pty_err
	}

	sess = new(Terminal_Session, allocator)
	sess.pty = handle
	sess.allocator = allocator
	sess.in_prompt = false
	sess.command_running = false
	sess.scroll_offset = 0
	sess.title_len = 0
	sess.cwd_len = 0

	terminal.terminal_init(&sess.term, rows, cols, allocator)

	// Register clean OSC extensions (zero side-effect coupling to core_terminal!)
	terminal.terminal_register_osc(&sess.term, 0, _osc_title_handler, rawptr(sess))
	terminal.terminal_register_osc(&sess.term, 2, _osc_title_handler, rawptr(sess))
	terminal.terminal_register_osc(&sess.term, 7, _osc_cwd_handler, rawptr(sess))
	terminal.terminal_register_osc(&sess.term, 133, _osc_133_handler, rawptr(sess))

	return sess, .None
}

session_destroy :: proc(sess: ^Terminal_Session) {
	if sess == nil do return

	if sess.pty != nil {
		pty.pty_close(sess.pty)
		sess.pty = nil
	}

	terminal.terminal_destroy(&sess.term)
	free(sess, sess.allocator)
}

session_drain :: proc(sess: ^Terminal_Session) -> int {
	if sess == nil || sess.pty == nil do return 0

	buf: [4096]u8
	total_drained := 0

	for {
		n := pty.pty_read_available(sess.pty, buf[:])
		if n <= 0 do break
		terminal.terminal_feed_bytes(&sess.term, buf[:n])
		total_drained += n
	}

	return total_drained
}

session_write :: proc(sess: ^Terminal_Session, data: []u8) -> (int, pty.Pty_Error) {
	if sess == nil || sess.pty == nil do return 0, .Closed
	return pty.pty_write(sess.pty, data)
}

session_write_string :: proc(sess: ^Terminal_Session, s: string) -> (int, pty.Pty_Error) {
	return session_write(sess, transmute([]u8)s)
}

session_resize :: proc(sess: ^Terminal_Session, cols, rows: u16) {
	if sess == nil do return
	if sess.pty != nil {
		_ = pty.pty_resize(sess.pty, cols, rows)
	}
	terminal.terminal_resize(&sess.term, int(rows), int(cols))
}

session_is_alive :: proc(sess: ^Terminal_Session) -> (bool, int) {
	if sess == nil || sess.pty == nil do return false, -1
	return pty.pty_is_alive(sess.pty)
}

session_get_cell :: proc(sess: ^Terminal_Session, row, col: int) -> cell.Semantic_Cell {
	if sess == nil do return cell.CELL_DEFAULT
	return terminal.terminal_get_cell(&sess.term, row, col)
}

session_consume_damage :: proc(sess: ^Terminal_Session) -> damage.Damage_Journal {
	if sess == nil do return damage.Damage_Journal{has_damage = false}
	return terminal.terminal_consume_damage(&sess.term)
}

session_get_title :: proc(sess: ^Terminal_Session) -> string {
	if sess == nil || sess.title_len == 0 do return ""
	return string(sess.title_buf[:sess.title_len])
}

session_get_cwd :: proc(sess: ^Terminal_Session) -> string {
	if sess == nil || sess.cwd_len == 0 do return ""
	return string(sess.cwd_buf[:sess.cwd_len])
}

session_is_in_prompt :: proc(sess: ^Terminal_Session) -> bool {
	if sess == nil do return false
	return sess.in_prompt
}
