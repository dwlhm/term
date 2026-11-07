package feature_session

import "base:runtime"
import "core:strconv"
import "core:strings"
import "core:time"
import cursor "../../core/cursor"
import ipc "../../platform/ipc"
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

// session_config_size clamps a config's geometry the way the Terminal uses it.
session_config_size :: proc(config: Session_Config) -> ipc.Size_Msg {
	rows := max(1, config.rows if config.rows > 0 else 24)
	cols := max(1, config.cols if config.cols > 0 else 80)
	xp := config.xpixel if config.xpixel > 0 else cols * 10
	yp := config.ypixel if config.ypixel > 0 else rows * 20
	return {cols = u16(cols), rows = u16(rows), xpixel = u16(xp), ypixel = u16(yp)}
}

Terminal_Session :: struct {
	link:            Session_Link,
	inbox:           Session_Inbox,
	info:            Session_Info,
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
	program_status:      extension.Program_Status,
	osc_7501_ctx:        extension.Osc_7501_Context,
	command_start_time:  time.Time,
	osc_52_ctx:          extension.Osc_52_Context,
	osc_color_cfg:       extension.Osc_Color_Config,
	controller:          Session_Controller, // an automation holding it (term auto)
	allocator:       runtime.Allocator,
}

// Session_Controller: the automation that holds a session's input, as the core
// reports it in session rows.
Session_Controller :: struct {
	name_buf: [64]u8,
	name_len: int,
	pass:     bool, // it waits for a person to type (a handoff)
}

session_set_controller :: proc(sess: ^Terminal_Session, name: string, pass: bool) -> (changed: bool) {
	if sess == nil do return false
	c := &sess.controller
	n := min(len(name), len(c.name_buf))
	changed = string(c.name_buf[:c.name_len]) != name[:n] || c.pass != pass
	copy(c.name_buf[:], name[:n])
	c.name_len, c.pass = n, pass
	return
}

session_controller :: proc(sess: ^Terminal_Session) -> (name: string, pass: bool) {
	if sess == nil do return "", false
	return string(sess.controller.name_buf[:sess.controller.name_len]), sess.controller.pass
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

_session_screen_provider :: proc(term_ptr: rawptr) -> extension.Kitty_Screen {
	if term_ptr == nil do return .Primary
	t := (^terminal.Terminal)(term_ptr)
	return .Alternate if terminal.terminal_in_alt_screen(t) else .Primary
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
	case 'A', 'B', 'P':
		sess.in_prompt, sess.command_running = true, false
	case 'D':
		sess.in_prompt, sess.command_running = false, false
	case 'C':
		sess.in_prompt, sess.command_running = false, true
		sess.command_start_time = time.now()
	}
	return true
}

_osc_7501_sink :: proc(user_data: rawptr, status: extension.Program_Status) -> bool {
	sess := (^Terminal_Session)(user_data)
	if sess == nil do return false
	sess.program_status = status
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

// session_create builds the Terminal side of a session. The program runs
// behind link (the caller already asked for it to be spawned).
session_create :: proc(size: ipc.Size_Msg, link: Session_Link, allocator: runtime.Allocator = context.allocator) -> ^Terminal_Session {
	rows, cols := max(1, int(size.rows)), max(1, int(size.cols))
	xp, yp := int(size.xpixel) if size.xpixel > 0 else cols * 10, int(size.ypixel) if size.ypixel > 0 else rows * 20

	sess := new(Terminal_Session, allocator)
	sess.link = link
	sess.inbox.ring.buf = make([]u8, SESSION_INBOX_BYTES, allocator)
	sess.info.alive = true
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

	sess.osc_7501_ctx = extension.Osc_7501_Context{
		sink      = _osc_7501_sink,
		user_data = rawptr(sess),
	}
	terminal.terminal_register_osc(&sess.term, 7501, extension.osc_7501_handler, rawptr(&sess.osc_7501_ctx))

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
			kstate.screen_provider = _session_screen_provider
			break
		}
	}

	return sess
}

session_program_status :: proc(sess: ^Terminal_Session) -> ^extension.Program_Status {
	if sess == nil do return nil
	return &sess.program_status
}

session_is_running_job :: proc(sess: ^Terminal_Session) -> bool {
	if sess == nil do return false

	if sess.program_status.state == .Working || sess.program_status.state == .Blocked {
		return true
	}
	if sess.program_status.state == .Done || sess.program_status.state == .Error {
		return false
	}

	if sess.command_running do return true
	if sess.in_prompt do return false

	fg_name := session_process_name(sess)
	return len(fg_name) > 0 && fg_name != "login" && !session_is_shell_process(fg_name)
}

session_destroy :: proc(sess: ^Terminal_Session) {
	if sess == nil do return
	terminal.terminal_destroy(&sess.term)
	delete(sess.inbox.ring.buf, sess.allocator)
	free(sess, sess.allocator)
}

// session_drain feeds what the link delivered into the Terminal and sends
// the Terminal's replies (queries the core left for the viewer) back.
session_drain :: proc(sess: ^Terminal_Session) -> int {
	if sess == nil do return 0
	buf: [65536]u8
	total_drained := 0
	for {
		n := _inbox_pop(sess, buf[:])
		if n <= 0 do break
		terminal.terminal_feed_bytes(&sess.term, buf[:n])
		total_drained += n
	}
	if total_drained > 0 {
		// ED 3 (a program's `clear`, a history resync) can shrink the history under the view.
		sess.scroll_offset = min(sess.scroll_offset, sess.term.grid.history_count)
		if sess.link.consumed != nil do sess.link.consumed(sess.link.user, total_drained)
	}
	session_flush_responses(sess)
	return total_drained
}

// session_flush_responses sends pending Terminal replies (DSR, DA, OSC 10/11…) to the program.
session_flush_responses :: proc(sess: ^Terminal_Session) {
	resp_buf: [256]u8
	for {
		resp_n := terminal.terminal_drain_response(&sess.term, resp_buf[:])
		if resp_n <= 0 do break
		if sess.link.reply != nil do sess.link.reply(sess.link.user, resp_buf[:resp_n])
	}
}

session_write :: proc(sess: ^Terminal_Session, data: []u8) {
	if sess == nil || sess.link.write == nil || len(data) == 0 do return
	sess.link.write(sess.link.user, data)
}

session_write_string :: proc(sess: ^Terminal_Session, s: string) {
	session_write(sess, transmute([]u8)s)
}

session_resize :: proc(sess: ^Terminal_Session, cols, rows: u16, xpixel: u16 = 0, ypixel: u16 = 0) {
	if sess == nil do return
	terminal.terminal_resize(&sess.term, int(rows), int(cols))
	if cols > 0 && xpixel > 0 && rows > 0 && ypixel > 0 {
		terminal.terminal_set_cell_size(&sess.term, int(xpixel / cols), int(ypixel / rows))
	}
	if sess.link.resize != nil {
		sess.link.resize(sess.link.user, {cols = cols, rows = rows, xpixel = xpixel, ypixel = ypixel})
	}
	sess.scroll_offset = clamp(sess.scroll_offset, 0, sess.term.grid.history_count)
}

session_is_alive :: proc(sess: ^Terminal_Session) -> (bool, int) {
	if sess == nil do return false, -1
	return sess.info.alive, sess.info.exit_code
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
