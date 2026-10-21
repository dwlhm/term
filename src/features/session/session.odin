package feature_session

import "base:runtime"
import "core:strings"
import "core:strconv"
import cursor "../../core/cursor"
import pty "../../platform/pty"
import terminal "../../core/terminal"
import grid "../../core/terminal/grid"
import extension "../../core/terminal/extension"
import cell "../../core/terminal/cell"
import damage "../../core/terminal/damage"

Osc_52_Clipboard_Sink :: extension.Osc_52_Clipboard_Sink

Session_Config :: struct {
	shell:  string,
	argv:   []string,
	cwd:    string,
	rows:   int,
	cols:   int,
	xpixel: int,
	ypixel: int,
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
	custom_bg:       [4]f32,
	has_custom_bg:   bool,
	pointer_shape_buf: [32]u8,
	pointer_shape_len: int,
	custom_scroll_speed: f32,
	scroll_accum:        f32,
	osc_52_ctx:      extension.Osc_52_Context,
	osc_color_cfg:   extension.Osc_Color_Config,
	allocator:       runtime.Allocator,
}

_session_emit_responder :: proc(term: rawptr, response: []u8) -> bool {
	return terminal.terminal_emit_response(term, response)
}

_session_cursor_provider :: proc(term_ptr: rawptr) -> (int, int) {
	if term_ptr == nil do return 0, 0
	t := (^terminal.Terminal)(term_ptr)
	return t.parser.cursor.row, t.parser.cursor.col
}

_session_cell_size_provider :: proc(term_ptr: rawptr) -> (int, int) {
	if term_ptr == nil do return 0, 0
	t := (^terminal.Terminal)(term_ptr)
	return t.parser.cell_w, t.parser.cell_h
}

_session_grid_size_provider :: proc(term_ptr: rawptr) -> (int, int) {
	if term_ptr == nil do return 0, 0
	t := (^terminal.Terminal)(term_ptr)
	return t.cols, t.rows
}

_session_cursor_advancer :: proc(term_ptr: rawptr, cols, rows: int) {
	if term_ptr == nil do return
	t := (^terminal.Terminal)(term_ptr)
	terminal.terminal_advance_cursor_for_image(t, cols, rows)
}

_session_damage_notifier :: proc(term_ptr: rawptr, start_row, row_count: int) {
	if term_ptr == nil do return
	t := (^terminal.Terminal)(term_ptr)
	for r := start_row; r < start_row + row_count && r < t.rows; r += 1 {
		if r >= 0 do damage.damage_mark_row(&t.damage, r)
	}
}

_osc_title_handler :: proc(user_data: rawptr, osc_id: int, payload: string, term_ptr: rawptr) -> bool {
	sess := (^Terminal_Session)(user_data)
	if sess == nil do return false
	sess.title_len = min(len(payload), len(sess.title_buf))
	copy(sess.title_buf[:sess.title_len], payload[:sess.title_len])
	return true
}

_osc_cwd_handler :: proc(user_data: rawptr, osc_id: int, payload: string, term_ptr: rawptr) -> bool {
	sess := (^Terminal_Session)(user_data)
	if sess == nil do return false
	sess.cwd_len = min(len(payload), len(sess.cwd_buf))
	copy(sess.cwd_buf[:sess.cwd_len], payload[:sess.cwd_len])
	return true
}

_osc_133_handler :: proc(user_data: rawptr, osc_id: int, payload: string, term_ptr: rawptr) -> bool {
	sess := (^Terminal_Session)(user_data)
	if sess == nil || len(payload) == 0 do return false

	switch payload[0] {
	case 'A':
		sess.in_prompt, sess.command_running = true, false
		if t := (^terminal.Terminal)(term_ptr); t != nil {
			if phys := grid.grid_physical_row(&t.grid, t.parser.cursor.row); phys >= 0 && phys < len(t.grid.rows) do t.grid.rows[phys].is_prompt = true
		}
	case 'B', 'D': sess.in_prompt, sess.command_running = false, false
	case 'C':      sess.in_prompt, sess.command_running = false, true
	}
	return true
}

_osc_22_handler :: proc(user_data: rawptr, osc_id: int, payload: string, term_ptr: rawptr) -> bool {
	sess := (^Terminal_Session)(user_data)
	if sess == nil do return false
	sess.pointer_shape_len = min(len(payload), len(sess.pointer_shape_buf))
	copy(sess.pointer_shape_buf[:sess.pointer_shape_len], payload[:sess.pointer_shape_len])
	return true
}

_osc_1337_handler :: proc(user_data: rawptr, osc_id: int, payload: string, term_ptr: rawptr) -> bool {
	sess := (^Terminal_Session)(user_data)
	if sess == nil || len(payload) == 0 do return false

	prefix := "ScrollSpeed="
	if strings.has_prefix(payload, prefix) {
		val_str := payload[len(prefix):]
		val, ok := strconv.parse_f32(val_str)
		if ok && val > 0.0 {
			sess.custom_scroll_speed = val
			return true
		} else if ok && val <= 0.0 {
			sess.custom_scroll_speed = 0.0
			return true
		}
	}
	return false
}

session_create :: proc(config: Session_Config, allocator: runtime.Allocator = context.allocator) -> (sess: ^Terminal_Session, err: pty.Pty_Error) {
	rows := max(1, config.rows if config.rows > 0 else 24)
	cols := max(1, config.cols if config.cols > 0 else 80)
	xp := config.xpixel if config.xpixel > 0 else cols * 10
	yp := config.ypixel if config.ypixel > 0 else rows * 20

	pty_cfg := pty.Pty_Config{
		shell  = config.shell,
		argv   = config.argv,
		cwd    = config.cwd,
		rows   = rows,
		cols   = cols,
		xpixel = xp,
		ypixel = yp,
	}

	handle, pty_err := pty.pty_spawn(pty_cfg)
	if pty_err != .None do return nil, pty_err

	sess = new(Terminal_Session, allocator)
	sess.pty = handle
	sess.allocator = allocator
	sess.scroll_offset = 0

	terminal.terminal_init(&sess.term, rows, cols, allocator)
	if cols > 0 && rows > 0 {
		terminal.terminal_set_cell_size(&sess.term, max(1, xp / cols), max(1, yp / rows))
	}

	for id in ([?]int{0, 2}) do terminal.terminal_register_osc(&sess.term, id, _osc_title_handler, rawptr(sess))
	terminal.terminal_register_osc(&sess.term, 7, _osc_cwd_handler, rawptr(sess))
	terminal.terminal_register_osc(&sess.term, 22, _osc_22_handler, rawptr(sess))
	for id in ([?]int{10, 11, 111}) do terminal.terminal_register_osc(&sess.term, id, extension.osc_color_handler, rawptr(&sess.osc_color_cfg))
	terminal.terminal_register_osc(&sess.term, 52, extension.osc_52_handler, rawptr(&sess.osc_52_ctx))
	terminal.terminal_register_osc(&sess.term, 133, _osc_133_handler, rawptr(sess))
	terminal.terminal_register_osc(&sess.term, 1337, _osc_1337_handler, rawptr(sess))

	sess.osc_color_cfg.responder = _session_emit_responder
	sess.osc_color_cfg.user_data = rawptr(sess)
	sess.osc_color_cfg.on_bg_change = proc(ud: rawptr, r, g, b: f32) { if s := (^Terminal_Session)(ud); s != nil do s.custom_bg, s.has_custom_bg = {r, g, b, 1.0}, true }
	sess.osc_color_cfg.on_bg_reset = proc(ud: rawptr) { if s := (^Terminal_Session)(ud); s != nil do s.has_custom_bg = false }

	kitty_ext := extension.kitty_graphics_extension_make(allocator)
	terminal.terminal_register_extension(&sess.term, kitty_ext)
	for i in 0..<sess.term.extensions.ext_count {
		e := &sess.term.extensions.extensions[i]
		if e.name == "kitty_graphics" && e.user_data != nil {
			kstate := (^extension.Kitty_Extension)(e.user_data)
			kstate.responder = _session_emit_responder
			kstate.cursor_provider = _session_cursor_provider
			kstate.cell_size_provider = _session_cell_size_provider
			kstate.grid_size_provider = _session_grid_size_provider
			kstate.cursor_advancer = _session_cursor_advancer
			kstate.damage_notifier = _session_damage_notifier
			break
		}
	}

	return sess, .None
}

session_destroy :: proc(sess: ^Terminal_Session) {
	if sess == nil do return
	if sess.pty != nil do pty.pty_close(sess.pty)
	terminal.terminal_destroy(&sess.term)
	free(sess, sess.allocator)
}

session_drain :: proc(sess: ^Terminal_Session) -> int {
	if sess == nil || sess.pty == nil do return 0

	buf: [65536]u8
	total_drained := 0

	for {
		n := pty.pty_read_available(sess.pty, buf[:])
		if n <= 0 do break
		terminal.terminal_feed_bytes(&sess.term, buf[:n])
		total_drained += n
	}

	// Flush any pending terminal responses (DSR, CPR, DA, OSC 10/11) back to PTY master
	resp_buf: [256]u8
	for {
		resp_n := terminal.terminal_drain_response(&sess.term, resp_buf[:])
		if resp_n <= 0 do break
		_, _ = pty.pty_write(sess.pty, resp_buf[:resp_n])
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

session_resize :: proc(sess: ^Terminal_Session, cols, rows: u16, xpixel: u16 = 0, ypixel: u16 = 0) {
	if sess == nil do return
	terminal.terminal_resize(&sess.term, int(rows), int(cols))
	if cols > 0 && xpixel > 0 && rows > 0 && ypixel > 0 {
		terminal.terminal_set_cell_size(&sess.term, int(xpixel / cols), int(ypixel / rows))
	}
	if sess.pty != nil {
		_ = pty.pty_resize(sess.pty, cols, rows, xpixel, ypixel)
	}
	sess.scroll_offset = clamp(sess.scroll_offset, 0, sess.term.grid.history_count)
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
	return string(sess.title_buf[:sess.title_len]) if sess != nil && sess.title_len > 0 else ""
}

session_get_cwd :: proc(sess: ^Terminal_Session) -> string {
	return string(sess.cwd_buf[:sess.cwd_len]) if sess != nil && sess.cwd_len > 0 else ""
}

// session_get_cwd_path returns the filesystem directory path from OSC 7,
// stripping file://<hostname> prefix if present.
session_get_cwd_path :: proc(sess: ^Terminal_Session) -> string {
	raw := session_get_cwd(sess)
	if len(raw) == 0 do return ""

	if strings.has_prefix(raw, "file://") {
		rest := raw[len("file://"):]
		if slash_idx := strings.index_byte(rest, '/'); slash_idx >= 0 {
			return rest[slash_idx:]
		}
		return rest
	}
	return raw
}

session_is_in_prompt :: proc(sess: ^Terminal_Session) -> bool {
	if sess == nil do return false
	return sess.in_prompt
}

session_set_clipboard_sink :: proc(sess: ^Terminal_Session, sink: extension.Osc_52_Clipboard_Sink, user_data: rawptr) {
	if sess == nil do return
	sess.osc_52_ctx.sink = sink
	sess.osc_52_ctx.user_data = user_data
}

session_get_pointer_shape :: proc(sess: ^Terminal_Session) -> string {
	if sess == nil || sess.pointer_shape_len == 0 do return ""
	return string(sess.pointer_shape_buf[:sess.pointer_shape_len])
}

session_get_mouse_cursor :: proc(sess: ^Terminal_Session, is_shift_held: bool = false) -> cursor.Mouse_Cursor {
	if sess == nil do return .Default
	osc_shape := session_get_pointer_shape(sess)
	return terminal.terminal_cursor(&sess.term, is_shift_held, osc_shape)
}
