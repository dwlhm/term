package core_terminal

// Terminal Pane Domain Model.
// Part of Tier 1 Autonomous Core Engine (src/core/terminal/*).
//
// Represents an active terminal viewport/canvas containing a dedicated Terminal
// state machine, geometry bounds, and decoupled I/O sink.
//
// Invariant: ZERO OS/Platform dependencies, ZERO graphics/GPU dependencies.

import "base:runtime"
import cell "cell"
import extension "extension"

Pane_Kind :: enum {
	Terminal,
	Three_D,
}

Pane_IO_Write_Proc :: #type proc(user_data: rawptr, data: []u8) -> (written: int, ok: bool)

Terminal_Pane :: struct {
	id:            u32,
	kind:          Pane_Kind,
	term:          Terminal,
	rect:          [4]f32,
	is_focused:    bool,
	is_zoomed:     bool,
	saved_rect:    [4]f32,
	scroll_offset: int,
	title_buf:     [256]u8,
	title_len:     int,
	cwd_buf:       [512]u8,
	cwd_len:       int,
	custom_bg:     [4]f32,
	has_custom_bg: bool,

	// Decoupled I/O Driver Binding (Zero platform/OS leakage)
	io_write_sink: Pane_IO_Write_Proc,
	io_user_data:  rawptr,
	allocator:     runtime.Allocator,
}

_pane_osc_title_handler :: proc(user_data: rawptr, osc_id: int, payload: string, term_ptr: rawptr) -> bool {
	p := (^Terminal_Pane)(user_data)
	if p == nil do return false

	copy_len := min(len(payload), len(p.title_buf))
	copy(p.title_buf[:copy_len], payload[:copy_len])
	p.title_len = copy_len
	return true
}

_pane_osc_cwd_handler :: proc(user_data: rawptr, osc_id: int, payload: string, term_ptr: rawptr) -> bool {
	p := (^Terminal_Pane)(user_data)
	if p == nil do return false

	copy_len := min(len(payload), len(p.cwd_buf))
	copy(p.cwd_buf[:copy_len], payload[:copy_len])
	p.cwd_len = copy_len
	return true
}

pane_init :: proc(
	p: ^Terminal_Pane,
	id: u32,
	kind: Pane_Kind = .Terminal,
	rows: int = 24,
	cols: int = 80,
	allocator: runtime.Allocator = context.allocator,
) {
	if p == nil do return
	p.id = id
	p.kind = kind
	p.allocator = allocator
	p.is_focused = false
	p.is_zoomed = false
	p.scroll_offset = 0
	p.title_len = 0
	p.cwd_len = 0
	p.has_custom_bg = false

	if kind == .Terminal {
		terminal_init(&p.term, rows, cols, allocator)

		// Register canonical OSC extension hooks
		terminal_register_osc(&p.term, 0, _pane_osc_title_handler, rawptr(p))
		terminal_register_osc(&p.term, 2, _pane_osc_title_handler, rawptr(p))
		terminal_register_osc(&p.term, 7, _pane_osc_cwd_handler, rawptr(p))
	}
}

pane_destroy :: proc(p: ^Terminal_Pane) {
	if p == nil do return
	if p.kind == .Terminal {
		terminal_destroy(&p.term)
	}
	p.id = 0
	p.title_len = 0
	p.cwd_len = 0
	p.io_write_sink = nil
	p.io_user_data = nil
}

pane_set_io_sink :: proc(p: ^Terminal_Pane, sink: Pane_IO_Write_Proc, user_data: rawptr) {
	if p == nil do return
	p.io_write_sink = sink
	p.io_user_data = user_data
}

pane_feed_bytes :: proc(p: ^Terminal_Pane, data: []u8) {
	if p == nil || p.kind != .Terminal do return
	terminal_feed_bytes(&p.term, data)
}

pane_write_input :: proc(p: ^Terminal_Pane, data: []u8) -> (int, bool) {
	if p == nil || p.io_write_sink == nil do return 0, false
	return p.io_write_sink(p.io_user_data, data)
}

pane_write_input_string :: proc(p: ^Terminal_Pane, s: string) -> (int, bool) {
	return pane_write_input(p, transmute([]u8)s)
}

pane_drain_response :: proc(p: ^Terminal_Pane, out: []u8) -> int {
	if p == nil || p.kind != .Terminal do return 0
	return terminal_drain_response(&p.term, out)
}

pane_resize :: proc(p: ^Terminal_Pane, rows, cols: int) {
	if p == nil || p.kind != .Terminal do return
	terminal_resize(&p.term, rows, cols)
}

pane_get_title :: proc(p: ^Terminal_Pane) -> string {
	if p == nil || p.title_len == 0 do return ""
	return string(p.title_buf[:p.title_len])
}

pane_get_cwd :: proc(p: ^Terminal_Pane) -> string {
	if p == nil || p.cwd_len == 0 do return ""
	return string(p.cwd_buf[:p.cwd_len])
}

pane_set_custom_bg :: proc(p: ^Terminal_Pane, color: [4]f32) {
	if p == nil do return
	p.custom_bg = color
	p.has_custom_bg = true
}

pane_clear_custom_bg :: proc(p: ^Terminal_Pane) {
	if p == nil do return
	p.has_custom_bg = false
}
