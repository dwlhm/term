package main

// Backend module for the terminal emulator.
// Encapsulates PTY lifecycle, VT parser, terminal grid state, damage,
// view/selection, cursor overlay tracking, and VT input encoding.
//
// STRICT ARCHITECTURAL INVARIANT:
// This module MUST NOT import vendor:sdl3, vendor:wgpu, or windowing APIs.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import posix "core:sys/posix"


import termgrid "../terminal"
import graphics "../graphics"
import platform_chrome "../platform/chrome"
import parser "../parser"
import render "../render"
import platform "../platform"
import input "../platform/input"
import pty "../platform/pty"
import config "../config"
import inter "../interaction"
import probe "../bench/probe"
import session_core "../session_core"

// UI_EVENT_QUEUE_CAP is the capacity of the thread-safe UI event queue.
UI_EVENT_QUEUE_CAP :: 1024

// UI_Event_Queue is a ring buffer queue protected by a Mutex.
UI_Event_Queue :: struct {
	events: [UI_EVENT_QUEUE_CAP]UI_Event,
	head:   int,
	tail:   int,
	count:  int,
	mutex:  sync.Mutex,
}

// ui_event_queue_push enqueues an event thread-safely with capacity guard.
// .Resize events are coalesced in-place so intermediate steps are dropped
// and only the latest resize geometry is queued for calculation.
ui_event_queue_push :: proc(q: ^UI_Event_Queue, ev: UI_Event) -> bool {
	sync.mutex_lock(&q.mutex)
	defer sync.mutex_unlock(&q.mutex)

	if ev.type == .Resize {
		for i in 0 ..< q.count {
			idx := (q.head + i) % UI_EVENT_QUEUE_CAP
			if q.events[idx].type == .Resize {
				q.events[idx] = ev
				return true
			}
		}
	}

	if q.count >= UI_EVENT_QUEUE_CAP {
		return false
	}
	q.events[q.tail] = ev
	q.tail = (q.tail + 1) % UI_EVENT_QUEUE_CAP
	q.count += 1
	return true
}

// ui_event_queue_has_resize returns true if a .Resize event is currently pending in the queue.
ui_event_queue_has_resize :: proc(q: ^UI_Event_Queue) -> bool {
	sync.mutex_lock(&q.mutex)
	defer sync.mutex_unlock(&q.mutex)
	for i in 0 ..< q.count {
		idx := (q.head + i) % UI_EVENT_QUEUE_CAP
		if q.events[idx].type == .Resize {
			return true
		}
	}
	return false
}

ui_event_queue_pop_all :: proc(q: ^UI_Event_Queue, out: []UI_Event) -> int {
	sync.mutex_lock(&q.mutex)
	defer sync.mutex_unlock(&q.mutex)
	n := min(q.count, len(out))
	for i in 0..<n {
		out[i] = q.events[q.head]
		q.head = (q.head + 1) % UI_EVENT_QUEUE_CAP
	}
	q.count -= n
	return n
}

// Backend encapsulates all terminal logic, PTY, parser, and grid manipulation.
Backend :: struct {
	// Back Buffer (internal to Backend worker thread)
	terminal:             termgrid.Terminal,
	// Front Buffer (swapped snapshot read by Frontend renderer)
	front_terminal:       termgrid.Terminal,
	front_view:           termgrid.Terminal_View,
	front_cursor:         render.Cursor_Overlay,
	front_focused:        bool,
	front_exited:         bool,
	search_invalid_regex: bool,
	front_search_invalid_regex: bool,
	focus_requested:      bool,

	parser:               parser.Parser,
	pty:                  pty.Pty,
	lut:                  render.Style_LUT,
	cursor:               render.Cursor_Overlay,
	view:                 termgrid.Terminal_View,
	interaction:          inter.Interaction_State,
	front_interaction:    inter.Interaction_State,
	config:               config.Config,
	focused:              bool,
	should_quit:          bool,
	prog:                 string,
	argv:                 []string,
	cwd:                  string,
	banner_shown:         bool,
	last_mouse_col:       int,
	last_mouse_row:       int,
	wheel_accumulator_y:  f32,
	view_generation:      u64,
	sync_output_start_ns: u64,
	clipboard_user_data:  rawptr,
	clipboard_write_cb:   Clipboard_Write_Proc,
	clipboard_read_cb:    Clipboard_Read_Proc,
	clipboard_pending_buf: [1024]u8,
	clipboard_pending_len: int,
	clipboard_pending_mtx: sync.Mutex,

	// Multi-threaded worker thread & synchronization primitives
	thread:               ^thread.Thread,
	thread_running:       b32,
	swap_mutex:           sync.Mutex,
	render_locked:        bool,
	event_queue:          UI_Event_Queue,
	drain_buf:            []u8,
	resize_generation:    u64,
	// pty_bytes_total counts every byte backend_drain_pty has consumed since
	// the backend was created, across all drain paths (worker thread,
	// session_poll_all, the legacy headless drain). The frame loop cannot see
	// the drain's return value on the tabbed path because the drain runs on
	// another thread, so the count is published here instead. It is updated
	// with sync.atomic_add on the writer side and read with sync.atomic_load
	// by the renderer, matching the discipline already used for
	// resize_generation: a bare read would race with the worker thread, and
	// the swap mutex cannot be used instead because the drain does not hold
	// it. The counter is monotonic per backend, so a torn read is the only
	// failure a relaxed load can produce and that cannot happen here; the
	// frame loop additionally clamps a negative delta, which is what a reset
	// backend produces.
	pty_bytes_total:      u64,
	notify_data_ready_cb: proc(user_data: rawptr),
	notify_user_data:     rawptr,
	wake_pipe_r:          posix.FD,
	wake_pipe_w:          posix.FD,


	// Session core observer port & mode
	observer:             session_core.Terminal_Observer_Port,
	session_mode:         session_core.Session_Mode,
	session_cfg:          session_core.Session_Config,

	// Scrollback cell-sync generation tracking.
	// Tracks whether front_terminal.scrollback.cells was copied from the back
	// buffer at least once for the current total_pushed / clear_generation pair.
	// Separate from total_pushed on front_terminal because metadata and cell
	// data are synced independently: metadata is always updated, cells only
	// when viewing history AND a newer pushed/clear_gen is seen here.
	front_scrollback_synced_pushed:    u64,
	front_scrollback_synced_clear_gen: u64,
}

// backend_global holds the active Backend pointer for C-style callbacks
// required by the parser.
backend_global: ^Backend

_backend_observer_on_damage :: proc(user_data: rawptr, min_row, min_col, max_row, max_col: int) {
	b := (^Backend)(user_data)
	if b == nil do return
	g := &b.terminal.grid
	for r in min_row ..= max_row {
		if r >= 0 && r < g.row_count {
			phys := (g.origin + r) & g.mask
			gen := g.rows[phys].generation
			termgrid.damage_mark_span(&b.terminal.damage, r, min_col, max_col, gen)
		}
	}
}

_backend_observer_on_title_change :: proc(user_data: rawptr, title: string) {
	b := (^Backend)(user_data)
	if b == nil do return
	termgrid.terminal_osc_set_title(&b.terminal, transmute([]u8)title)
}

_backend_observer_on_bell :: proc(user_data: rawptr) {
	b := (^Backend)(user_data)
	if b == nil do return
	b.terminal.bell_event = true
}

_backend_observer_on_exit :: proc(user_data: rawptr, exit_code: int) {
	b := (^Backend)(user_data)
	if b == nil do return
	b.pty.exit_code = exit_code
}

_backend_response_cb :: proc(data: []u8) {
	b := backend_global
	if b != nil && b.pty.master >= 0 && b.pty.state == .Running {
		pty.pty_write(&b.pty, data)
	}
}

_backend_graphics_write :: proc(user_data: rawptr, data: []u8) {
	b := (^Backend)(user_data)
	if b == nil || b.pty.master < 0 || b.pty.state != .Running do return
	_ = pty.pty_write(&b.pty, data)
}

_backend_graphics_cb :: proc(user_data: rawptr, t: ^termgrid.Terminal, control, payload: []u8) {
	b := (^Backend)(user_data)
	if b == nil || t == nil || t != &b.terminal do return
	sink := graphics.Response_Sink{
		user_data = user_data,
		write = _backend_graphics_write,
	}
	_ = termgrid.terminal_graphics_feed(t, control, payload, sink)
}

_backend_clipboard_cb :: proc(data: []u8) {
	b := backend_global
	if b != nil {
		backend_set_pending_clipboard(b, data)
	}
}

// backend_set_pending_clipboard stores clipboard data into the pending buffer under mutex.
backend_set_pending_clipboard :: proc(b: ^Backend, data: []u8) {
	if b == nil do return
	sync.mutex_lock(&b.clipboard_pending_mtx)
	defer sync.mutex_unlock(&b.clipboard_pending_mtx)
	n := min(len(data), len(b.clipboard_pending_buf))
	copy(b.clipboard_pending_buf[:n], data[:n])
	b.clipboard_pending_len = n
}

// backend_take_pending_clipboard retrieves and clears pending clipboard data under mutex.
backend_take_pending_clipboard :: proc(b: ^Backend) -> (string, bool) {
	if b == nil do return "", false
	sync.mutex_lock(&b.clipboard_pending_mtx)
	defer sync.mutex_unlock(&b.clipboard_pending_mtx)
	if b.clipboard_pending_len == 0 do return "", false
	text := string(b.clipboard_pending_buf[:b.clipboard_pending_len])
	b.clipboard_pending_len = 0
	return text, true
}

_backend_clipboard_read_cb :: proc(user_data: rawptr, out: []u8) -> int {
	b := (^Backend)(user_data)
	if b == nil || b.clipboard_read_cb == nil {
		return 0
	}
	return b.clipboard_read_cb(b.clipboard_user_data, out)
}

// _resolve_shell returns the preferred shell path. On macOS, if the user's
// shell is /bin/zsh or fallback, it checks for modern Zsh in Homebrew
// (/opt/homebrew/bin/zsh or /usr/local/bin/zsh) to avoid Apple's frozen
// Unicode table.
_resolve_shell :: proc() -> (shell: string, allocated: bool) {
	val, found := os.lookup_env_alloc(APP_SHELL_ENV, context.allocator)
	shell_cand := APP_SHELL_FALLBACK
	cand_alloc := false
	if found && len(val) > 0 {
		shell_cand = val
		cand_alloc = true
	} else if found {
		delete(val)
	}

	if shell_cand == "/bin/zsh" || shell_cand == APP_SHELL_FALLBACK {
		if os.exists("/opt/homebrew/bin/zsh") {
			if cand_alloc {
				delete(shell_cand)
			}
			return "/opt/homebrew/bin/zsh", false
		}
		if os.exists("/usr/local/bin/zsh") {
			if cand_alloc {
				delete(shell_cand)
			}
			return "/usr/local/bin/zsh", false
		}
	}

	return shell_cand, cand_alloc
}

_SHELL_ARGV_ZSH := []string{"-l", "-o", "COMBINING_CHARS"}
_SHELL_ARGV_DEFAULT := []string{"-l"}

// _resolve_shell_argv returns the startup arguments for the spawned shell.
_resolve_shell_argv :: proc(shell: string) -> []string {
	if strings.has_suffix(shell, "zsh") {
		return _SHELL_ARGV_ZSH
	}
	return _SHELL_ARGV_DEFAULT
}

// backend_init initializes terminal, parser, PTY, and style LUT.
backend_init :: proc(
	b: ^Backend,
	init_rows, init_cols: int,
	prog: string,
	argv: []string,
	cfg: ^config.Config,
	theme: termgrid.Theme,
) -> bool {
	if b == nil {
		return false
	}
	b.pty.master = -1
	b.pty.pid = -1
	if len(prog) == 0 {
		return false
	}

	b.focused = true
	b.should_quit = false
	b.view = termgrid.Terminal_View{}
	inter.interaction_init(&b.interaction)
	inter.interaction_init(&b.front_interaction)
	b.view_generation = 0
	b.pty_bytes_total = 0
	b.prog = prog
	b.argv = argv
	b.banner_shown = false
	b.last_mouse_col = 0
	b.last_mouse_row = 0
	b.sync_output_start_ns = 0

	termgrid.terminal_init(
		&b.terminal,
		init_rows,
		init_cols,
		theme = theme,
	)

	termgrid.terminal_init(
		&b.front_terminal,
		init_rows,
		init_cols,
		theme = theme,
	)
	b.front_view = termgrid.Terminal_View{}
	b.front_cursor = render.Cursor_Overlay{}
	b.front_focused = true
	b.focus_requested = true
	b.drain_buf = make([]u8, APP_DRAIN_CAP, runtime.heap_allocator())
	b.thread = nil
	b.thread_running = false

	pipe_fds: [2]posix.FD
	if posix.pipe(&pipe_fds) == .OK {
		b.wake_pipe_r = pipe_fds[0]
		b.wake_pipe_w = pipe_fds[1]
		_ = posix.fcntl(b.wake_pipe_r, .SETFL, int(posix.O_NONBLOCK))
		_ = posix.fcntl(b.wake_pipe_w, .SETFL, int(posix.O_NONBLOCK))
	} else {
		b.wake_pipe_r = -1
		b.wake_pipe_w = -1
	}

	parser.parser_init(&b.parser)
	b.parser.response_cb = _backend_response_cb
	b.parser.graphics_cb = _backend_graphics_cb
	b.parser.graphics_user_data = b
	b.parser.clipboard_cb = _backend_clipboard_cb
	b.parser.clipboard_read_cb = _backend_clipboard_read_cb
	b.parser.clipboard_read_user_data = b
	backend_global = b

	spawn_prog := b.prog
	spawn_argv := b.argv
	if cfg != nil && len(cfg.shell) > 0 &&
	   (prog == APP_SHELL_FALLBACK || prog == "/bin/zsh" || prog == "/bin/sh" ||
	    prog == "/opt/homebrew/bin/zsh" || prog == "/usr/local/bin/zsh") {
		spawn_prog = cfg.shell
		spawn_argv = _resolve_shell_argv(spawn_prog)
		b.prog = spawn_prog
		b.argv = spawn_argv
	}

	spawn_cwd := cfg.working_directory if (cfg != nil && len(cfg.working_directory) > 0) else "~"
	b.cwd = strings.clone(spawn_cwd)

	b.session_mode = .Interactive_GUI
	b.observer = session_core.Terminal_Observer_Port{
		user_data       = b,
		on_damage       = _backend_observer_on_damage,
		on_title_change = _backend_observer_on_title_change,
		on_bell         = _backend_observer_on_bell,
		on_exit         = _backend_observer_on_exit,
	}
	b.session_cfg = session_core.Session_Config{
		rows     = init_rows,
		cols     = init_cols,
		shell    = spawn_prog,
		cwd      = b.cwd,
		mode     = .Interactive_GUI,
		observer = b.observer,
	}

	if !pty.pty_spawn(&b.pty, init_rows, init_cols, spawn_prog, spawn_argv, b.cwd) {
		termgrid.terminal_destroy(&b.terminal)
		termgrid.terminal_destroy(&b.front_terminal)
		if b.wake_pipe_r >= 0 {
			posix.close(b.wake_pipe_r)
			b.wake_pipe_r = -1
		}
		if b.wake_pipe_w >= 0 {
			posix.close(b.wake_pipe_w)
			b.wake_pipe_w = -1
		}
		if b.drain_buf != nil {
			delete(b.drain_buf, runtime.heap_allocator())
			b.drain_buf = nil
		}
		delete(b.cwd)
		b.cwd = ""
		fmt.eprintf("backend_init: pty_spawn failed for '%s'\n", spawn_prog)
		return false
	}

	render.style_lut_rebuild(&b.lut, &b.terminal.grid.style_table)
	return true
}

// backend_init_from_core_session initializes backend state transferring ownership
// from an existing Core_Session (used during session attach).
backend_init_from_core_session :: proc(
	b: ^Backend,
	cs: ^session_core.Core_Session,
	cfg: ^config.Config,
	theme: termgrid.Theme,
) -> bool {
	if b == nil || cs == nil {
		return false
	}

	b.pty = cs.pty_handle
	b.terminal = cs.term
	b.parser = cs.vt_parser
	b.session_mode = cs.mode
	b.prog = cs.gui_prog
	b.argv = cs.gui_argv
	cs.pty_handle = pty.Pty{master = -1, pid = -1}
	cs.term = {}
	cs.vt_parser = {}

	b.focused = true
	b.should_quit = false
	b.view = termgrid.Terminal_View{}
	inter.interaction_init(&b.interaction)
	inter.interaction_init(&b.front_interaction)
	b.view_generation = 0
	b.last_mouse_col = 0
	b.last_mouse_row = 0
	b.sync_output_start_ns = 0

	rows := b.terminal.grid.row_count
	cols := b.terminal.grid.col_count

	termgrid.terminal_init(&b.front_terminal, rows, cols, theme = theme)
	b.front_view = termgrid.Terminal_View{}
	b.front_cursor = render.Cursor_Overlay{}
	b.front_focused = true
	b.focus_requested = true
	b.drain_buf = make([]u8, APP_DRAIN_CAP, runtime.heap_allocator())
	b.thread = nil
	b.thread_running = false

	pipe_fds: [2]posix.FD
	if posix.pipe(&pipe_fds) == .OK {
		b.wake_pipe_r = pipe_fds[0]
		b.wake_pipe_w = pipe_fds[1]
		_ = posix.fcntl(b.wake_pipe_r, .SETFL, int(posix.O_NONBLOCK))
		_ = posix.fcntl(b.wake_pipe_w, .SETFL, int(posix.O_NONBLOCK))
	} else {
		b.wake_pipe_r = -1
		b.wake_pipe_w = -1
	}

	b.parser.response_cb = _backend_response_cb
	b.parser.graphics_cb = _backend_graphics_cb
	b.parser.graphics_user_data = b
	b.parser.clipboard_cb = _backend_clipboard_cb
	b.parser.clipboard_read_cb = _backend_clipboard_read_cb
	b.parser.clipboard_read_user_data = b
	backend_global = b

	b.cwd = strings.clone(cs.cwd)

	b.observer = session_core.Terminal_Observer_Port{
		user_data       = b,
		on_damage       = _backend_observer_on_damage,
		on_title_change = _backend_observer_on_title_change,
		on_bell         = _backend_observer_on_bell,
		on_exit         = _backend_observer_on_exit,
	}
	b.session_cfg = session_core.Session_Config{
		rows     = rows,
		cols     = cols,
		mode     = b.session_mode,
		observer = b.observer,
	}

	backend_apply_theme(b, theme)

	// Synchronize virtual grid to front terminal
	_terminal_sync_to_front(b)

	// Mark all damage so renderer immediately displays the session's active screen and scrollback
	termgrid.damage_mark_all(&b.terminal.damage, nil)
	termgrid.damage_mark_all(&b.front_terminal.damage, nil)
	b.view_generation += 1

	return true
}

// backend_restore_core_session rolls an unsuccessful attach back to its core owner.
// The backend worker must be stopped before transferring its PTY and parser.
backend_restore_core_session :: proc(b: ^Backend, cs: ^session_core.Core_Session) {
	if b == nil || cs == nil do return
	backend_stop_thread(b)
	cs.pty_handle = b.pty
	cs.term = b.terminal
	cs.vt_parser = b.parser
	cs.vt_parser.graphics_cb = nil
	cs.vt_parser.graphics_user_data = nil
	cs.mode = b.session_mode
	cs.gui_prog = b.prog
	cs.gui_argv = b.argv
	b.pty = pty.Pty{master = -1, pid = -1}
	b.terminal = {}
	b.parser = {}
	backend_destroy(b)
}

// backend_destroy frees terminal, parser, and closes PTY.
backend_destroy :: proc(b: ^Backend) {
	if b == nil {
		return
	}
	backend_stop_thread(b)
	remaining: [128]UI_Event
	for {
		n := ui_event_queue_pop_all(&b.event_queue, remaining[:])
		if n == 0 do break
		for ev in remaining[:n] {
		if ev.type == .Paste do delete(ev.text)
		if ev.type == .Theme && ev.theme != nil do free(ev.theme)
		}
	}
	if b.wake_pipe_r >= 0 {
		posix.close(b.wake_pipe_r)
		b.wake_pipe_r = -1
	}
	if b.wake_pipe_w >= 0 {
		posix.close(b.wake_pipe_w)
		b.wake_pipe_w = -1
	}
	pty.pty_close(&b.pty)
	b.parser.graphics_cb = nil
	b.parser.graphics_user_data = nil
	termgrid.terminal_destroy(&b.terminal)
	termgrid.terminal_destroy(&b.front_terminal)
	parser.parser_destroy(&b.parser)
	if b.drain_buf != nil {
		delete(b.drain_buf, runtime.heap_allocator())
		b.drain_buf = nil
	}
	delete(b.cwd)
	b.cwd = ""
	b.observer = {}
	b.session_cfg = {}
	if backend_global == b {
		backend_global = nil
	}
}

// backend_set_clipboard_callbacks registers the handlers for OSC 52 clipboard ops.
backend_set_clipboard_callbacks :: proc(
	b: ^Backend,
	user_data: rawptr,
	write_cb: Clipboard_Write_Proc,
	read_cb: Clipboard_Read_Proc,
) {
	if b == nil {
		return
	}
	b.clipboard_user_data = user_data
	b.clipboard_write_cb = write_cb
	b.clipboard_read_cb = read_cb
}

backend_set_notify_data_ready :: proc(b: ^Backend, user_data: rawptr, cb: proc(user_data: rawptr)) {
	if b == nil do return
	b.notify_data_ready_cb = cb
	b.notify_user_data = user_data
}

// backend_drain_pty reads available bytes from the PTY master into a buffer
// and passes them to the VT parser.
backend_drain_pty :: proc(b: ^Backend) -> int {
	if b == nil || b.pty.state != .Running || b.pty.master < 0 {
		return 0
	}
	buf := b.drain_buf
	if len(buf) == 0 {
		return 0
	}
	sb_before := termgrid.scrollback_len(&b.terminal.scrollback)
	pushes_before := b.terminal.scrollback.total_pushed
	clear_before := b.terminal.scrollback.clear_generation
	n, _ := pty.pty_drain(&b.pty, buf, len(buf))
	if n > 0 {
		sync.atomic_add(&b.pty_bytes_total, u64(n))
		backend_global = b
		parser.parse_chunk(&b.parser, &b.terminal, buf[:n])
		if b.observer.on_damage != nil {
			min_r := -1
			max_r := -1
			for r in 0 ..< b.terminal.damage.row_count {
				if r < len(b.terminal.damage.dirty_rows) {
					dr := &b.terminal.damage.dirty_rows[r]
					if dr.full || dr.span_count > 0 {
						if min_r == -1 do min_r = r
						max_r = r
					}
				}
			}
			if min_r != -1 {
				b.observer.on_damage(b.observer.user_data, min_r, 0, max_r, b.terminal.grid.col_count - 1)
			}
		}
		sb_after := termgrid.scrollback_len(&b.terminal.scrollback)
		lines_added := int(b.terminal.scrollback.total_pushed - pushes_before)
		history_cleared := b.terminal.scrollback.clear_generation != clear_before
		if history_cleared {
			// A history clear invalidates positions even if the same read refills it.
			b.view.selection.active = false
			b.interaction.selection_active = false
			b.interaction.search_match_count = 0
			b.interaction.search_match_idx = 0
			_ = termgrid.terminal_view_set_offset(&b.view, &b.terminal, 0)
			b.interaction.paused_offset = 0
			b.view_generation += 1
		}
		if !history_cleared && b.interaction.viewport_flow == .Paused {
			evicted := max(0, sb_before + lines_added - sb_after)
			inter.interaction_on_scrollback_push(&b.interaction, lines_added, evicted)
			if b.view.selection.active && evicted > 0 {
				b.view.selection.anchor.row -= evicted
				b.view.selection.focus.row -= evicted
				if b.view.selection.anchor.row < 0 || b.view.selection.focus.row < 0 {
					b.view.selection.active = false
				}
			}
			_ = termgrid.terminal_view_set_offset(&b.view, &b.terminal, b.view.scrollback_offset + lines_added)
			b.interaction.paused_offset = b.view.scrollback_offset
			b.view_generation += 1
		}
	}
	return n
}

// backend_poll_pty aliases backend_drain_pty.
backend_poll_pty :: backend_drain_pty

// backend_pty_bytes_total returns the cumulative number of PTY bytes this
// backend has drained. It is a monotonic counter, not a rate: callers on the
// frame path subtract their previous observation to obtain a per-frame delta,
// because the drain itself is not observable from there.
//
// Callable from any thread; the read is atomic.
backend_pty_bytes_total :: proc(b: ^Backend) -> u64 {
	if b == nil {
		return 0
	}
	return sync.atomic_load(&b.pty_bytes_total)
}

// backend_take_title retrieves and clears any pending window title requested by OSC 0/1/2.
backend_take_title :: proc(b: ^Backend) -> string {
	if b == nil {
		return ""
	}
	if b.thread != nil {
		return termgrid.terminal_take_title(&b.front_terminal)
	}
	return termgrid.terminal_take_title(&b.terminal)
}

// backend_sync_cursor updates the cursor overlay to match the terminal cursor and ticks blink.
backend_sync_cursor :: proc(
	b: ^Backend,
) -> (cursor_changed, position_changed, style_changed: bool, old_row, old_col: int) {
	if b == nil {
		return false, false, false, 0, 0
	}
	t := &b.front_terminal if b.thread != nil else &b.terminal
	view_ptr := &b.front_view if b.thread != nil else &b.view
	inter_ptr := &b.front_interaction if b.thread != nil else &b.interaction

	cur_row: int
	cur_col: int
	cur_style: u8
	cur_visible: bool

	if inter_ptr.mode == .Visual {
		doc_offset := termgrid.scrollback_len(&t.scrollback) - clamp(view_ptr.scrollback_offset, 0, termgrid.terminal_view_max_offset(t))
		cur_row = inter_ptr.visual_cursor.row - doc_offset
		cur_col = clamp(inter_ptr.visual_cursor.col, 0, max(0, t.grid.col_count - 1))
		cur_style = 2 // Steady block cursor for visual mode
		cur_visible = (cur_row >= 0 && cur_row < t.grid.row_count)
	} else {
		cur := termgrid.terminal_get_cursor(t)
		cur_row = cur.row
		cur_col = cur.col
		cur_style = cur.style
		cur_visible = cur.visible
	}

	style_changed = b.cursor.style != cur_style
	position_changed = b.cursor.row != cur_row || b.cursor.col != cur_col
	old_row = b.cursor.row
	old_col = b.cursor.col
	render.cursor_overlay_sync(&b.cursor, cur_row, cur_col, cur_style)
	now := platform.platform_ticks_to_ns(platform.platform_now())
	cursor_changed = render.cursor_overlay_tick(&b.cursor, now, b.focused, cur_visible)
	return cursor_changed, position_changed, style_changed, old_row, old_col
}

_backend_mark_cursor_dirty_terminal :: proc(t: ^termgrid.Terminal, r, c: int) -> bool {
		g := &t.grid
		if g.row_count <= 0 || g.col_count <= 0 || len(g.rows) == 0 {
			return false
		}
		if r < 0 || r >= g.row_count || c < 0 || c >= g.col_count {
			return false
		}
		phys := (g.origin + r) & g.mask
		if phys < 0 || phys >= len(g.rows) {
			return false
		}
		termgrid.damage_mark_cell(&t.damage, r, c, g.rows[phys].generation)
		return true
	}

// backend_mark_cursor_dirty marks the cursor cell with its live generation in the damage tracker.
backend_mark_cursor_dirty :: proc(b: ^Backend, row, col: int) -> bool {
	if b == nil {
		return false
	}

	t := &b.front_terminal if b.thread != nil else &b.terminal
	marked := _backend_mark_cursor_dirty_terminal(t, row, col)
	return marked
}

// backend_get_render_state constructs a Render_State snapshot for the frontend.
backend_get_render_state :: proc(b: ^Backend) -> Render_State {
	if b == nil {
		return Render_State{}
	}
	now := platform.platform_ticks_to_ns(platform.platform_now())
	now_ns := u64(now)

	term_ptr := &b.front_terminal if b.thread != nil else &b.terminal
	view_ptr := &b.front_view if b.thread != nil else &b.view
	cursor_ptr := &b.front_cursor if b.thread != nil else &b.cursor
	interaction_ptr := &b.front_interaction if b.thread != nil else &b.interaction
	focused := b.front_focused if b.thread != nil else b.focused

	if term_ptr.synchronized_output {
		if b.sync_output_start_ns == 0 {
			b.sync_output_start_ns = now_ns
		}
	} else {
		b.sync_output_start_ns = 0
	}
	return Render_State{
		terminal             = term_ptr,
		view                 = view_ptr,
		cursor               = cursor_ptr,
		interaction          = interaction_ptr,
		focused              = focused,
		synchronized_output  = term_ptr.synchronized_output,
		sync_output_start_ns = b.sync_output_start_ns,
	}
}

// backend_set_focused handles focus transitions and emits VT focus sequences if enabled.
backend_set_focused :: proc(b: ^Backend, new_focused: bool) {
	if b == nil {
		return
	}
	if new_focused != b.focused {
		b.focused = new_focused
		if b.terminal.focus_reporting && b.pty.state == .Running {
			if new_focused {
				pty.pty_write(&b.pty, []u8{0x1B, '[', 'I'})
			} else {
				pty.pty_write(&b.pty, []u8{0x1B, '[', 'O'})
			}
		}
	}
}

// backend_on_resize updates the terminal grid size and PTY window size.
backend_on_resize :: proc(b: ^Backend, rows, cols: int) -> bool {
	if b == nil || rows <= 0 || cols <= 0 {
		return false
	}
	pty.pty_set_winsize(&b.pty, rows, cols)
	if rows == b.terminal.grid.row_count && cols == b.terminal.grid.col_count {
		return true
	}
	termgrid.terminal_resize(&b.terminal, rows, cols)
	return true
}

// backend_poll_exit checks child exit status and presents the exit banner once.
backend_poll_exit :: proc(b: ^Backend) {
	if b == nil {
		return
	}
	was_running := b.pty.state == .Running
	pty.pty_poll_exit(&b.pty)
	if was_running && b.pty.state == .Exited {
		if b.observer.on_exit != nil {
			b.observer.on_exit(b.observer.user_data, b.pty.exit_code)
		}
		backend_show_banner(b)
	}
}

// _backend_write_banner_text draws s on the bottom row and latches banner_shown.
_backend_write_banner_text :: proc(b: ^Backend, s: string) {
	if b == nil {
		return
	}
	rows := b.terminal.grid.row_count
	cols := b.terminal.grid.col_count
	if rows <= 0 || cols <= 0 {
		b.banner_shown = true
		return
	}
	text := s
	if len(text) > cols {
		text = text[:cols]
	}
	termgrid.terminal_move_cursor(&b.terminal, rows - 1, 0)
	termgrid.terminal_put_string(&b.terminal, text)
	b.banner_shown = true
}

// backend_show_banner draws the exit banner with the exit code.
backend_show_banner :: proc(b: ^Backend) {
	if b == nil {
		return
	}
	buf: [160]u8
	s := fmt.bprintf(buf[:], APP_BANNER_EXIT_FMT, b.pty.exit_code)
	_backend_write_banner_text(b, s)
}

// backend_show_banner_fail draws the relaunch failure banner.
backend_show_banner_fail :: proc(b: ^Backend) {
	_backend_write_banner_text(b, APP_BANNER_FAIL)
}

// backend_relaunch closes the dead PTY and spawns a fresh child.
backend_relaunch :: proc(b: ^Backend) -> bool {
	if b == nil {
		return false
	}
	pty.pty_close(&b.pty)
	rows := b.terminal.grid.row_count
	cols := b.terminal.grid.col_count
	if !pty.pty_spawn(&b.pty, rows, cols, b.prog, b.argv, b.cwd) {
		backend_show_banner_fail(b)
		return false
	}
	termgrid.terminal_erase_display(&b.terminal, .Entire)
	termgrid.terminal_move_cursor(&b.terminal, 0, 0)
	parser.parser_init(&b.parser)
	b.parser.response_cb = _backend_response_cb
	b.parser.graphics_cb = _backend_graphics_cb
	b.parser.graphics_user_data = b
	b.parser.clipboard_cb = _backend_clipboard_cb
	b.parser.clipboard_read_cb = _backend_clipboard_read_cb
	b.parser.clipboard_read_user_data = b
	b.banner_shown = false
	return true
}

// backend_copy_selection returns the currently selected grid text.
backend_copy_selection :: proc(b: ^Backend) -> string {
	if b == nil {
		return ""
	}
	if b.thread != nil {
		if b.front_interaction.selection_active {
			return inter.interaction_extract_selection_text(&b.front_terminal, &b.front_interaction)
		}
		return termgrid.terminal_view_copy(&b.front_terminal, &b.front_view)
	}
	if b.interaction.selection_active {
		return inter.interaction_extract_selection_text(&b.terminal, &b.interaction)
	}
	return termgrid.terminal_view_copy(&b.terminal, &b.view)
}

// backend_paste writes text into the PTY master, wrapping with bracketed paste if enabled.
backend_paste :: proc(b: ^Backend, text: string) -> bool {
	if b == nil || b.pty.state == .Exited {
		return false
	}
	if len(text) == 0 {
		return true
	}
	if b.terminal.bracketed_paste {
		sanitized := text
		defer if sanitized != text do delete(sanitized)
		if strings.contains(text, "\x1b[201~") {
			sanitized, _ = strings.replace_all(text, "\x1b[201~", "", context.allocator)
		}
		pty.pty_write(&b.pty, []u8{0x1B, '[', '2', '0', '0', '~'})
		ok := pty.pty_write(&b.pty, transmute([]u8)sanitized)
		pty.pty_write(&b.pty, []u8{0x1B, '[', '2', '0', '1', '~'})
		return ok
	}
	return pty.pty_write(&b.pty, transmute([]u8)text)
}

// backend_accumulate_wheel accumulates fractional wheel delta and extracts whole line steps.
backend_accumulate_wheel :: proc(b: ^Backend, pointer: input.Input_Pointer_Event) -> int {
	if b == nil {
		return backend_pointer_wheel_delta(pointer)
	}

	dy: f32 = 0
	if pointer.wheel_y != 0 {
		dy = pointer.wheel_y
	} else if pointer.wheel_integer_y != 0 {
		dy = f32(pointer.wheel_integer_y)
	}

	if pointer.wheel_flipped {
		dy = -dy
	}

	if dy == 0 {
		return 0
	}

	// Immediate response on direction reversal: drop residual momentum from opposite direction
	if (b.wheel_accumulator_y < 0 && dy > 0) || (b.wheel_accumulator_y > 0 && dy < 0) {
		b.wheel_accumulator_y = 0
	}

	mult := b.config.scroll_multiplier if b.config.scroll_multiplier > 0 else 1.0
	b.wheel_accumulator_y += dy * mult

	lines := int(b.wheel_accumulator_y)
	if lines != 0 {
		b.wheel_accumulator_y -= f32(lines)
	}
	return lines
}

// backend_pointer_wheel_delta converts pointer event wheel ticks to lines (stateless fallback).
backend_pointer_wheel_delta :: proc(pointer: input.Input_Pointer_Event) -> int {
	delta := pointer.wheel_integer_y
	if delta == 0 {
		if pointer.wheel_y >= 0.5 {
			delta = 1
		} else if pointer.wheel_y <= -0.5 {
			delta = -1
		}
	}
	if pointer.wheel_flipped {
		delta = -delta
	}
	return int(delta)
}

// backend_pointer_selection_changed updates the active selection in view.
backend_pointer_selection_changed :: proc(b: ^Backend, point: termgrid.Terminal_Point, anchor: bool) -> bool {
	if b == nil {
		return false
	}
	changed := false
	if anchor {
		changed = !b.view.selection.active ||
			b.view.selection.anchor != point ||
			b.view.selection.focus != point
		b.view.selection.active = true
		b.view.selection.anchor = point
		b.view.selection.focus = point
	} else if b.view.selection.active {
		changed = b.view.selection.focus != point
		b.view.selection.focus = point
	}
	if changed {
		b.view_generation += 1
	}
	return changed
}

// backend_apply_theme applies a reloaded theme to the terminal style tables.
backend_apply_theme :: proc(b: ^Backend, theme: termgrid.Theme) {
	if b == nil {
		return
	}
	b.terminal.grid.style_table.theme = theme
	b.terminal.grid.style_table.entries[0] = termgrid.style_table_default(&b.terminal.grid.style_table)
	b.terminal.alt_grid.style_table.theme = theme
	b.terminal.alt_grid.style_table.entries[0] = termgrid.style_table_default(&b.terminal.alt_grid.style_table)

	render.style_lut_rebuild(&b.lut, &b.terminal.grid.style_table)
	for r in 0..<b.terminal.grid.row_count {
		phys := (b.terminal.grid.origin + r) & b.terminal.grid.mask
		gen := b.terminal.grid.rows[phys].generation
		termgrid.damage_mark_row(&b.terminal.damage, r, gen)
	}
	if backend_is_threaded(b) do _backend_swap_buffers(b)
}

// _terminal_sync_to_front synchronizes back buffer terminal state to front buffer terminal.
_terminal_sync_to_front :: proc(b: ^Backend) {
	if b == nil {
		return
	}
	dst := &b.front_terminal
	src := &b.terminal
	view := &b.view
	if dst == nil || src == nil {
		return
	}
	// 1. Grid resize if dimensions changed
	dims_changed := dst.grid.row_count != src.grid.row_count || dst.grid.col_count != src.grid.col_count
	alt_screen_switched := dst.is_alt_screen != src.is_alt_screen
	origin_changed := dst.grid.origin != src.grid.origin

	if dims_changed {
		termgrid.terminal_resize(dst, src.grid.row_count, src.grid.col_count)
	}

	// 2. Copy active grid cells (Delta-only: copy only damaged rows)
	dst.grid.origin = src.grid.origin
	dst.grid.mask = src.grid.mask
	dst.grid.style_table = src.grid.style_table
	if dst.grid.cells != nil && src.grid.cells != nil {
		if dims_changed || alt_screen_switched || origin_changed {
			copy(dst.grid.cells, src.grid.cells)
			if dst.grid.ext_colors != nil && src.grid.ext_colors != nil {
				copy(dst.grid.ext_colors, src.grid.ext_colors)
			}
			for i in 0..<src.grid.capacity {
				if i < len(dst.grid.rows) && i < len(src.grid.rows) {
					dst.grid.rows[i].generation = src.grid.rows[i].generation
					dst.grid.rows[i].wrapped = src.grid.rows[i].wrapped
					dst.grid.rows[i].is_prompt = src.grid.rows[i].is_prompt
					dst.grid.rows[i].ext.channels = src.grid.rows[i].ext.channels
				}
			}
			for r in 0..<dst.damage.row_count {
				if r < len(dst.damage.dirty_rows) {
					dst.damage.dirty_rows[r].full = true
				}
			}
		} else {
			for r in 0..<src.damage.row_count {
				if r < len(src.damage.dirty_rows) {
					dr := src.damage.dirty_rows[r]
					if dr.full || dr.span_count > 0 {
						src_phys := (src.grid.origin + r) & src.grid.mask
						dst_phys := (dst.grid.origin + r) & dst.grid.mask
						if src_phys < len(src.grid.rows) && dst_phys < len(dst.grid.rows) {
							copy(dst.grid.rows[dst_phys].cells, src.grid.rows[src_phys].cells)
							dst.grid.rows[dst_phys].generation = src.grid.rows[src_phys].generation
							dst.grid.rows[dst_phys].wrapped = src.grid.rows[src_phys].wrapped
							dst.grid.rows[dst_phys].is_prompt = src.grid.rows[src_phys].is_prompt
							dst.grid.rows[dst_phys].ext.channels = src.grid.rows[src_phys].ext.channels
							if len(dst.grid.rows[dst_phys].ext.colors) > 0 && len(src.grid.rows[src_phys].ext.colors) > 0 {
								copy(dst.grid.rows[dst_phys].ext.colors, src.grid.rows[src_phys].ext.colors)
							}
						}
					}
				}
			}
		}
	}

	// 3. Alternate grid synchronization (only if alt screen is active)
	if src.is_alt_screen {
		dst.alt_grid.origin = src.alt_grid.origin
		dst.alt_grid.mask = src.alt_grid.mask
		dst.alt_grid.style_table = src.alt_grid.style_table
		if dst.alt_grid.cells != nil && src.alt_grid.cells != nil {
			copy(dst.alt_grid.cells, src.alt_grid.cells)
			if dst.alt_grid.ext_colors != nil && src.alt_grid.ext_colors != nil {
				copy(dst.alt_grid.ext_colors, src.alt_grid.ext_colors)
			}
		}
		for i in 0..<src.alt_grid.capacity {
			if i < len(dst.alt_grid.rows) && i < len(src.alt_grid.rows) {
				dst.alt_grid.rows[i].generation = src.alt_grid.rows[i].generation
				dst.alt_grid.rows[i].wrapped = src.alt_grid.rows[i].wrapped
				dst.alt_grid.rows[i].is_prompt = src.alt_grid.rows[i].is_prompt
				dst.alt_grid.rows[i].ext.channels = src.alt_grid.rows[i].ext.channels
			}
		}
	}

	dst.is_alt_screen = src.is_alt_screen
	dst.cursor = src.cursor
	dst.saved_cursor = src.saved_cursor
	dst.saved_cursor_valid = src.saved_cursor_valid
	dst.current_style = src.current_style

	// 4. Sync scrollback lazily (0 bytes copied when viewing active screen)
	// Resize if scrollback dimensions changed; reset synced markers so cells
	// are re-copied on the next viewing_history frame.
	if dst.scrollback.max_lines != src.scrollback.max_lines || dst.scrollback.col_count != src.scrollback.col_count {
		termgrid.scrollback_destroy(&dst.scrollback, nil)
		termgrid.scrollback_init(&dst.scrollback, src.scrollback.col_count, src.scrollback.max_lines)
		b.front_scrollback_synced_pushed = 0
		b.front_scrollback_synced_clear_gen = 0
	}

	// Always update metadata so head/count are correct for index calculations.
	dst.scrollback.head = src.scrollback.head
	dst.scrollback.count = src.scrollback.count
	dst.scrollback.total_pushed = src.scrollback.total_pushed
	dst.scrollback.clear_generation = src.scrollback.clear_generation

	// Copy cells only when the user is viewing history AND cells have not yet
	// been copied for this pushed/clear_gen pair. Using dedicated synced markers
	// (not dst.scrollback.total_pushed) avoids the race where metadata is
	// updated every frame but cells are only needed while viewing history.
	viewing_history := view != nil && view.scrollback_offset > 0
	needs_cell_sync := b.front_scrollback_synced_pushed != src.scrollback.total_pushed ||
	                   b.front_scrollback_synced_clear_gen != src.scrollback.clear_generation
	if viewing_history && needs_cell_sync {
		if dst.scrollback.cells != nil && src.scrollback.cells != nil {
			copy(dst.scrollback.cells, src.scrollback.cells)
			if dst.scrollback.ext_colors != nil && src.scrollback.ext_colors != nil {
				copy(dst.scrollback.ext_colors, src.scrollback.ext_colors)
			}
		}
		for i in 0..<src.scrollback.max_lines {
			dst.scrollback.rows[i].wrapped = src.scrollback.rows[i].wrapped
			dst.scrollback.rows[i].ext.channels = src.scrollback.rows[i].ext.channels
		}
		b.front_scrollback_synced_pushed = src.scrollback.total_pushed
		b.front_scrollback_synced_clear_gen = src.scrollback.clear_generation
	}

	// Graphics stores are published as a separate deep snapshot. Store epochs
	// cover image/frame changes while placement epochs cover placement changes.
	graphics_changed := dst.graphics_namespace != src.graphics_namespace
	if dst.graphics == nil || src.graphics == nil {
		graphics_changed = graphics_changed || dst.graphics != src.graphics
	} else {
		graphics_changed = graphics_changed ||
			dst.graphics.epoch != src.graphics.epoch ||
			dst.graphics.placement_epoch != src.graphics.placement_epoch ||
			dst.graphics.upload_count != src.graphics.upload_count
	}
	if dst.graphics_alt == nil || src.graphics_alt == nil {
		graphics_changed = graphics_changed || dst.graphics_alt != src.graphics_alt
	} else {
		graphics_changed = graphics_changed ||
			dst.graphics_alt.epoch != src.graphics_alt.epoch ||
			dst.graphics_alt.placement_epoch != src.graphics_alt.placement_epoch ||
			dst.graphics_alt.upload_count != src.graphics_alt.upload_count
	}
	graphics_allocator := dst.state_allocator if dst.state_allocator_set else runtime.heap_allocator()
	termgrid.terminal_graphics_sync(dst, src, graphics_allocator)
	if graphics_changed {
		termgrid.damage_mark_all(&dst.damage, nil)
	}

	// 5. Transfer damage from src to dst: merge dirty rows and copy scroll ops
	for r in 0..<src.damage.row_count {
		if r < len(dst.damage.dirty_rows) && r < len(src.damage.dirty_rows) {
			s_row := src.damage.dirty_rows[r]
			if s_row.full {
				dst.damage.dirty_rows[r].full = true
				dst.damage.dirty_rows[r].generation = s_row.generation
			} else if s_row.span_count > 0 {
				d_row := &dst.damage.dirty_rows[r]
				if d_row.full {
					// already full dirty
				} else if d_row.span_count == 0 {
					d_row^ = s_row
				} else {
					d_row.full = true
					d_row.generation = s_row.generation
				}
			}
		}
	}
	for op in src.damage.scroll_ops {
		append(&dst.damage.scroll_ops, op)
	}
	termgrid.terminal_clear_damage(src)

	dst.cwd = src.cwd
	dst.cwd_len = clamp(src.cwd_len, 0, len(dst.cwd))

	// 6. Transfer title dirty state and auxiliary flags and states
	if src.title_dirty {
		dst.window_title = src.window_title
		dst.window_title_len = src.window_title_len
		dst.title_dirty = true
		src.title_dirty = false
	}

	dst.scroll_top = src.scroll_top
	dst.scroll_bottom = src.scroll_bottom
	dst.grapheme_store = src.grapheme_store
	dst.render_epoch = src.render_epoch
	dst.in_prompt_zone = src.in_prompt_zone
	dst.has_osc_133 = src.has_osc_133
	dst.bracketed_paste = src.bracketed_paste
	dst.focus_reporting = src.focus_reporting
	dst.app_cursor_keys = src.app_cursor_keys
	dst.mouse_tracking = src.mouse_tracking
	dst.mouse_format = src.mouse_format
	dst.synchronized_output = src.synchronized_output
	dst.kitty_kb = src.kitty_kb
	dst.kitty_kb_alt = src.kitty_kb_alt
	if src.bell_event {
		dst.bell_event = true
		src.bell_event = false
	}
	for src.notification_count > 0 {
		notif, ok := termgrid.terminal_pop_notification(src)
		if ok {
			termgrid.terminal_push_notification(dst, notif.title[:notif.title_len], notif.message[:notif.message_len])
		}
	}

	// Only copy hyperlinks struct (526 KB) if entries count changed
	if src.hyperlinks.count != dst.hyperlinks.count {
		dst.hyperlinks = src.hyperlinks
	}

	dst.charset_g0 = src.charset_g0
	dst.charset_g1 = src.charset_g1
	dst.active_charset_is_g1 = src.active_charset_is_g1
	dst.active_charset_is_dec = src.active_charset_is_dec
}

// _backend_perform_swap_locked only publishes state; caller MUST hold b.swap_mutex.
// Notifications must run after unlocking because they may enter the window event system.
_backend_perform_swap_locked :: proc(b: ^Backend) {
	_terminal_sync_to_front(b)
	b.front_view = b.view
	b.front_cursor = b.cursor
	b.front_focused = b.focused
	b.front_exited = b.pty.state == .Exited
	b.front_search_invalid_regex = b.search_invalid_regex
	b.front_interaction = b.interaction
}

// _backend_swap_buffers publishes under swap_mutex, then notifies after unlocking.
_backend_swap_buffers :: proc(b: ^Backend) {
	if b == nil {
		return
	}
	sync.mutex_lock(&b.swap_mutex)
	_backend_perform_swap_locked(b)
	sync.mutex_unlock(&b.swap_mutex)
	if b.notify_data_ready_cb != nil {
		b.notify_data_ready_cb(b.notify_user_data)
	}
}

// backend_start_thread starts the background worker thread.
backend_start_thread :: proc(b: ^Backend) -> bool {
	if b == nil || b.thread != nil {
		return false
	}
	_backend_swap_buffers(b)
	sync.atomic_store(&b.thread_running, true)
	b.thread = thread.create(backend_worker_proc)
	if b.thread == nil {
		sync.atomic_store(&b.thread_running, false)
		return false
	}
	b.thread.data = b
	thread.start(b.thread)
	return true
}

// backend_stop_thread signals shutdown, joins, and destroys the worker thread.
backend_stop_thread :: proc(b: ^Backend) {
	if b == nil || b.thread == nil {
		return
	}
	sync.atomic_store(&b.thread_running, false)
	if b.wake_pipe_w >= 0 {
		wake_byte: [1]byte = {1}
		_ = posix.write(b.wake_pipe_w, raw_data(wake_byte[:]), 1)
	}
	thread.join(b.thread)
	thread.destroy(b.thread)
	b.thread = nil
}

// backend_is_threaded reports whether the worker thread is running.
backend_is_threaded :: proc(b: ^Backend) -> bool {
	return b != nil && b.thread != nil
}

// backend_lock_render locks the swap mutex for rendering the front buffer.
backend_lock_render :: proc(b: ^Backend) {
	if b != nil {
		sync.mutex_lock(&b.swap_mutex)
		b.render_locked = true
	}
}

// backend_unlock_render releases the swap mutex after rendering.
backend_unlock_render :: proc(b: ^Backend) {
	if b != nil && b.render_locked {
		b.render_locked = false
		sync.mutex_unlock(&b.swap_mutex)
	}
}

// backend_push_event enqueues a UI event to be executed by the backend thread.
backend_push_event :: proc(b: ^Backend, ev: UI_Event) -> bool {
	if b == nil {
		return false
	}
	if ev.type == .Resize {
		sync.atomic_add(&b.resize_generation, 1)
	}
	ok := ui_event_queue_push(&b.event_queue, ev)
	if ok && b.wake_pipe_w >= 0 {
		wake_byte: [1]byte = {1}
		_ = posix.write(b.wake_pipe_w, raw_data(wake_byte[:]), 1)
	}
	return ok
}

// backend_handle_ui_event processes a single UI event inside the backend thread.
backend_handle_ui_event :: proc(b: ^Backend, ev: UI_Event) {
	if b == nil {
		return
	}
	switch ev.type {
	case .Input:
		switch ev.input.event_type {
		case .Key:
			if ev.input.paste_shadow && b.interaction.mode != .Search {
				return
			}
			if b.interaction.mode == .Passthrough {
				if b.interaction.visual_cursor == {} || (ev.input.gui && ev.input.ctrl && (ev.input.rune == 'y' || ev.input.rune == 'Y')) {
					cur := termgrid.terminal_get_cursor(&b.terminal)
					b.interaction.visual_cursor = termgrid.terminal_view_point_from_viewport(&b.terminal, &b.view, termgrid.Terminal_Point{row = cur.row, col = cur.col})
				}
			}
			state_before := b.interaction
			consumed, action := inter.interaction_dispatch_key(&b.interaction, ev.input, b.terminal.is_alt_screen)
			if consumed {
				if b.interaction.search_active {
					q := string(b.interaction.search_query[:b.interaction.search_len])
					b.interaction.search_match_count = inter.interaction_search_scan(
						&b.terminal,
						q,
						b.interaction.search_matches[:],
					)
					if b.interaction.search_match_idx >= b.interaction.search_match_count {
						b.interaction.search_match_idx = 0
					}
				}

				switch action {
				case .Select_All:
					inter.interaction_select_all(&b.terminal, &b.interaction)
				case .Copy:
					copy_state := b.interaction
					copy_state.selection_active = true
					text := inter.interaction_extract_selection_text(&b.terminal, &copy_state)
					if len(text) == 0 && state_before.selection_active {
						text = inter.interaction_extract_selection_text(&b.terminal, &state_before)
					}
					if len(text) > 0 {
						_backend_clipboard_cb(transmute([]u8)text)
						delete(text)
					}
					termgrid.terminal_view_set_offset(&b.view, &b.terminal, 0)
					b.view_generation += 1
				case .Resume_Live:
					termgrid.terminal_view_set_offset(&b.view, &b.terminal, 0)
					b.view_generation += 1
				case .Scroll_To_Match:
					if b.interaction.search_active && b.interaction.search_match_count > 0 {
						match_row := b.interaction.search_matches[b.interaction.search_match_idx].row
						sb_len := termgrid.scrollback_len(&b.terminal.scrollback)
						target_offset := max(0, sb_len - match_row)
						termgrid.terminal_view_set_offset(&b.view, &b.terminal, target_offset)
						b.view_generation += 1
					}
				case .Paste:
					buf: [4096]u8
					n := _backend_clipboard_read_cb(b, buf[:])
					if n > 0 {
						backend_paste(b, string(buf[:n]))
					}
				case .None, .Open_Link:
				}

				b.view.selection.active = b.interaction.selection_active
				b.view.selection.anchor = b.interaction.selection_anchor
				b.view.selection.focus = b.interaction.visual_cursor
				b.view.selection.block = (b.interaction.visual_kind == .Block)
				b.view.visual_mode = (b.interaction.mode == .Visual)
				b.view_generation += 1
				return
			}

			if b.pty.state == .Exited {
				switch app_handle_exited_key(ev.input) {
				case .Relaunch:
					_ = backend_relaunch(b)
	case .Quit:
					b.should_quit = true
				case .None:
				}
			} else {
				kitty_flags := termgrid.terminal_kitty_active(&b.terminal).flags
				key_evs := [1]input.Input_Event{ev.input}
				_ = input.input_pump_events(&b.pty, key_evs[:], kitty_flags, b.terminal.app_cursor_keys)
			}
		case .Pointer:
			p := ev.input.pointer
			if b.terminal.mouse_tracking != .None && !p.shift {
				col := clamp(ev.cols + 1, 1, max(1, b.terminal.grid.col_count))
				row := clamp(ev.rows + 1, 1, max(1, b.terminal.grid.row_count))

				if p.kind == .Motion {
					if b.terminal.mouse_tracking == .Normal {
						return
					}
					if b.terminal.mouse_tracking == .Button_Event && !p.primary_down && p.button == 0 {
						return
					}
					if col == b.last_mouse_col && row == b.last_mouse_row {
						return
					}
				}

				buf: [32]u8
				n := input.mouse_encode_sgr(p, col, row, p.shift, buf[:])
				if n > 0 {
					_ = pty.pty_write(&b.pty, buf[:n])
				}
				b.last_mouse_col = col
				b.last_mouse_row = row
				return
			}

			pt_viewport := termgrid.Terminal_Point{row = ev.rows, col = ev.cols}
			doc_pt := termgrid.terminal_view_point_from_viewport(&b.terminal, &b.view, pt_viewport)
			p_doc := p
			p_doc.x = f32(doc_pt.col * APP_CELL_W)
			p_doc.y = f32(doc_pt.row * APP_CELL_H)
			total_doc_rows := termgrid.scrollback_len(&b.terminal.scrollback) + b.terminal.grid.row_count

			consumed, action := inter.interaction_dispatch_pointer(
				&b.interaction,
				p_doc,
				b.terminal.is_alt_screen,
				total_doc_rows,
				b.terminal.grid.col_count,
				APP_CELL_W,
				APP_CELL_H,
			)

			if consumed {
				if p.kind == .Button_Down && p.button == 1 {
					clicks := p.clicks == 0 ? 1 : p.clicks
					if clicks == 2 {
						start, end := inter.interaction_select_word_bounds(&b.terminal, doc_pt)
						b.interaction.selection_anchor = start
						b.interaction.visual_cursor = end
					} else if clicks >= 3 {
						start, end := inter.interaction_select_line_bounds(&b.terminal, doc_pt)
						b.interaction.selection_anchor = start
						b.interaction.visual_cursor = end
					}
				}

				switch action {
				case .Copy:
					text := inter.interaction_extract_selection_text(&b.terminal, &b.interaction)
					if len(text) > 0 {
						_backend_clipboard_cb(transmute([]u8)text)
						delete(text)
					}
					termgrid.terminal_view_set_offset(&b.view, &b.terminal, 0)
					b.view_generation += 1
				case .Resume_Live:
					termgrid.terminal_view_set_offset(&b.view, &b.terminal, 0)
					b.view_generation += 1
				case .Scroll_To_Match:
					if b.interaction.search_active && b.interaction.search_match_count > 0 {
						match_row := b.interaction.search_matches[b.interaction.search_match_idx].row
						sb_len := termgrid.scrollback_len(&b.terminal.scrollback)
						target_offset := max(0, sb_len - match_row)
						termgrid.terminal_view_set_offset(&b.view, &b.terminal, target_offset)
						b.view_generation += 1
					}
				case .Paste, .None, .Open_Link, .Select_All:
				}

				b.view.selection.active = b.interaction.selection_active
				b.view.selection.anchor = b.interaction.selection_anchor
				b.view.selection.focus = b.interaction.visual_cursor
				b.view.selection.block = (b.interaction.visual_kind == .Block)
				b.view.visual_mode = (b.interaction.mode == .Visual)
				b.view_generation += 1
				return
			}

			switch p.kind {
			case .Wheel:
				if b.terminal.is_alt_screen {
					delta := backend_accumulate_wheel(b, p)
					if delta == 0 {
						return
					}
					alt_lines := b.config.alt_screen_wheel_lines if b.config.alt_screen_wheel_lines > 0 else APP_ALT_SCREEN_WHEEL_LINES
					steps := abs(delta) * alt_lines
					code: u8 = 'A' if delta > 0 else 'B'
					seq: [3]u8
					if b.terminal.app_cursor_keys {
						seq = {0x1B, 'O', code}
					} else {
						seq = {0x1B, '[', code}
					}
					for _ in 0 ..< steps {
						_ = pty.pty_write(&b.pty, seq[:])
					}
					return
				}
				delta := backend_accumulate_wheel(b, p)
				old_offset := b.view.scrollback_offset
				_ = termgrid.terminal_view_scroll(&b.view, &b.terminal, delta)
				if old_offset != b.view.scrollback_offset {
					if b.view.scrollback_offset > 0 && b.interaction.viewport_flow == .Live {
						inter.interaction_pause_viewport(&b.interaction, b.view.scrollback_offset)
					} else if b.view.scrollback_offset == 0 && b.interaction.mode == .Passthrough {
						inter.interaction_resume_viewport(&b.interaction)
					}
					b.view_generation += 1
				}
			case .Button_Down:
				if p.button == 1 {
					pt := termgrid.Terminal_Point{row = ev.rows, col = ev.cols}
					point := termgrid.terminal_view_point_from_viewport(&b.terminal, &b.view, pt)
					_ = backend_pointer_selection_changed(b, point, true)
				}
			case .Motion:
				if b.view.selection.active && p.primary_down {
					pt := termgrid.Terminal_Point{row = ev.rows, col = ev.cols}
					point := termgrid.terminal_view_point_from_viewport(&b.terminal, &b.view, pt)
					_ = backend_pointer_selection_changed(b, point, false)
				}
			case .Button_Up:
				if p.button == 1 && b.view.selection.active {
					pt := termgrid.Terminal_Point{row = ev.rows, col = ev.cols}
					point := termgrid.terminal_view_point_from_viewport(&b.terminal, &b.view, pt)
					_ = backend_pointer_selection_changed(b, point, false)
				}
			}
		case .Local:
		case .Drop:
			if len(ev.input.drop.text) > 0 {
				delete(ev.input.drop.text)
			}
		}
	case .Resize:
		if ev.rows > 0 && ev.cols > 0 {
			// Cancellation guard: if a newer resize is already waiting in queue,
			// drop this stale calculation immediately.
			if ui_event_queue_has_resize(&b.event_queue) {
				return
			}
			started_ns := probe.profile_clock_ns()
			backend_on_resize(b, ev.rows, ev.cols)
			elapsed := probe.profile_elapsed_ns(started_ns)
			probe.profile_record_resize(.Idle, .Resize_Stage, ev.pixel_w, ev.pixel_h, ev.pixel_w, ev.pixel_h, i32(ev.rows), i32(ev.cols), i32(b.terminal.grid.row_count), i32(b.terminal.grid.col_count), elapsed, true)
		}
	case .Focus:
		backend_set_focused(b, ev.focused)
	case .Paste:
		if len(ev.text) > 0 {
			backend_paste(b, ev.text)
			delete(ev.text)
		}
	case .Search:
		if ev.search_action == .Close {
			inter.interaction_exit_to_passthrough(&b.interaction)
			termgrid.terminal_view_set_offset(&b.view, &b.terminal, 0)
		} else {
			if ev.search_action == .Query_Changed {
				inter.interaction_enter_search(&b.interaction)
				query := ev.query
				b.interaction.search_len = copy(b.interaction.search_query[:], query[:clamp(ev.query_len, 0, len(query))])
				search := platform_chrome.Search_Bar_State{query = query, query_len = b.interaction.search_len, case_sensitive = ev.case_sensitive, use_regex = ev.use_regex, whole_word = ev.whole_word}
				b.interaction.search_match_count = platform_chrome.search_bar_execute_scan(&search, &b.terminal, b.interaction.search_matches[:])
				b.search_invalid_regex = search.is_invalid_regex
				b.interaction.search_match_idx = 0
			} else if b.interaction.search_match_count > 0 {
				step := 1 if ev.search_action == .Next_Match else -1
				b.interaction.search_match_idx = (b.interaction.search_match_idx+step+b.interaction.search_match_count)%b.interaction.search_match_count
			}
			if b.interaction.search_match_count > 0 {
				match := b.interaction.search_matches[b.interaction.search_match_idx]
				offset := clamp(termgrid.scrollback_len(&b.terminal.scrollback)-match.row, 0, termgrid.terminal_view_max_offset(&b.terminal))
				termgrid.terminal_view_set_offset(&b.view, &b.terminal, offset)
			}
		}
		b.view_generation += 1
	case .Scroll:
		termgrid.terminal_view_set_offset(&b.view, &b.terminal, ev.rows)
		b.view_generation += 1

	case .Theme:
		if ev.theme != nil {
			backend_apply_theme(b, ev.theme^)
			free(ev.theme)
		}
	case .Quit:
		b.should_quit = true
	}
}

// backend_worker_proc is the main loop of the background backend thread.
backend_worker_proc :: proc(t: ^thread.Thread) {
	context = runtime.default_context()
	b := (^Backend)(t.data)
	if b == nil {
		return
	}

	events_buf: [128]UI_Event
	pending_swap := false

	for sync.atomic_load(&b.thread_running) {
		// 1. Drain and execute pending UI events from Frontend
		n_events := ui_event_queue_pop_all(&b.event_queue, events_buf[:])
		for i in 0..<n_events {
			backend_handle_ui_event(b, events_buf[i])
		}

		if b.should_quit {
			break
		}

		// 2. Drain PTY & Parse (Exhaustive Drain)
		bytes_read := 0
		if b.pty.state == .Running && b.pty.master >= 0 {
			bytes_read = backend_drain_pty(b)
		}

		// 3. Child exit poll
		was_exited := b.pty.state == .Exited
		backend_poll_exit(b)
		exit_changed := !was_exited && b.pty.state == .Exited

		// 4. Cursor sync & damage marking
		cursor_changed, position_changed, style_changed, old_row, old_col := backend_sync_cursor(b)
		if cursor_changed || position_changed {
			_backend_mark_cursor_dirty_terminal(&b.terminal, old_row, old_col)
			cur := termgrid.terminal_get_cursor(&b.terminal)
			_backend_mark_cursor_dirty_terminal(&b.terminal, cur.row, cur.col)
		} else if style_changed {
			cur := termgrid.terminal_get_cursor(&b.terminal)
			_backend_mark_cursor_dirty_terminal(&b.terminal, cur.row, cur.col)
		}

		// 5. Swap back buffer to front buffer if any state changed
		if exit_changed || bytes_read > 0 || n_events > 0 || cursor_changed || position_changed || style_changed {
			pending_swap = true
		}
		
		if pending_swap {
			// If a new resize is queued, skip swapping stale buffers to avoid
			// heavy deep copies while window geometry is actively changing.
			if ui_event_queue_has_resize(&b.event_queue) {
				free_all(context.temp_allocator)
				continue
			}
			if sync.mutex_try_lock(&b.swap_mutex) {
				_backend_perform_swap_locked(b)
				sync.mutex_unlock(&b.swap_mutex)
				pending_swap = false
				if b.notify_data_ready_cb != nil do b.notify_data_ready_cb(b.notify_user_data)
			}
		}

		// 6. Wait when idle
		if bytes_read == 0 && n_events == 0 {
			if pending_swap {
				_backend_swap_buffers(b)
				pending_swap = false
			}

			pfds: [2]posix.pollfd
			pfd_count: int = 0
			if b.pty.state == .Running && b.pty.master >= 0 {
				pfds[pfd_count] = posix.pollfd{fd = posix.FD(b.pty.master), events = {.IN}}
				pfd_count += 1
			}
			wake_idx := -1
			if b.wake_pipe_r >= 0 {
				pfds[pfd_count] = posix.pollfd{fd = b.wake_pipe_r, events = {.IN}}
				wake_idx = pfd_count
				pfd_count += 1
			}

			if pfd_count > 0 {
				r := posix.poll(&pfds[0], posix.nfds_t(pfd_count), -1)
				if r > 0 && wake_idx >= 0 && (pfds[wake_idx].revents & {.IN}) != {} {
					buf: [64]byte
					for {
						n := posix.read(b.wake_pipe_r, raw_data(buf[:]), len(buf))
						if n <= 0 do break
					}
				}
			} else {
				time.sleep(10 * time.Millisecond)
			}
		}

		free_all(context.temp_allocator)
	}
}

// Copy title metadata while holding the snapshot lock; no borrowed worker data
// escapes to the session title resolver.
backend_title_metadata :: proc(b: ^Backend, title, cwd: []u8) -> (title_len, cwd_len: int, fresh: bool) {
	if b == nil do return
	if b.thread != nil do sync.mutex_lock(&b.swap_mutex)
	defer { if b.thread != nil do sync.mutex_unlock(&b.swap_mutex) }
	t := &b.front_terminal if b.thread != nil else &b.terminal
	f := t.title_dirty
	if f {
		title_len = copy(title, t.window_title[:clamp(t.window_title_len, 0, len(t.window_title))])
		t.title_dirty = false
	}
	cwd_len = copy(cwd, t.cwd[:clamp(t.cwd_len, 0, len(t.cwd))])
	return
}

// Workers own child reaping; the UI reads the published lifecycle snapshot.
backend_snapshot_exited :: proc(b: ^Backend) -> bool {
	if b == nil do return false
	if backend_is_threaded(b) {
		backend_lock_render(b)
		defer backend_unlock_render(b)
		return b.front_exited
	}
	backend_poll_exit(b)
	return b.pty.state == .Exited
}
