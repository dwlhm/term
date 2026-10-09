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
	// Triple Buffering snapshots and lock-free exchange state
	snapshots:            [SNAPSHOT_SLOT_COUNT]Front_Snapshot,
	middle:               int, // atomic
	write_index:          int, // owned by worker
	reader:               Reader_State, // owned by main thread
	missed_rows:          [SNAPSHOT_SLOT_COUNT]Row_Bitset,
	needs_full_copy:      [SNAPSHOT_SLOT_COUNT]bool,
	publish_seq:          u64,
	focus_requested:      bool,

	parser:               parser.Parser,
	pty:                  pty.Pty,
	lut:                  render.Style_LUT,
	cursor:               render.Cursor_Overlay,
	view:                 termgrid.Terminal_View,
	interaction:          inter.Interaction_State,
	search_invalid_regex: bool,
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
	clipboard_pending_buf: []u8,
	clipboard_pending_mtx: sync.Mutex,

	// Multi-threaded worker thread & synchronization primitives
	thread:               ^thread.Thread,
	thread_running:       b32,
	is_background:        b32,
	pending_events:       u32, // atomic bitmask of Backend_Event
	mailbox:              Notification_Mailbox,
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
	// a lock cannot be used instead because the drain does not hold
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

	// Host-backed session client & pane
	host_client:          ^App_Host_Client,
	host_ws_id:           u64,
	host_pane_id:         u64,
}

_backend_observer_on_damage :: proc(user_data: rawptr, min_row, min_col, max_row, max_col: int) {
	b := (^Backend)(user_data)
	if b == nil do return
	g := &b.terminal.grid
	for r in min_row ..= max_row {
		if r >= 0 && r < g.row_count {
			phys := (g.origin + r) & g.mask
			gen := g.rows[phys].generation
			termgrid.damage_mark_span(&b.terminal.damage, r, min_col, max_col, gen)
			for slot in 0 ..< SNAPSHOT_SLOT_COUNT {
				bitset_set(&b.missed_rows[slot], r)
			}
		}
	}
}

_backend_observer_on_title_change :: proc(user_data: rawptr, title: string) {
	b := (^Backend)(user_data)
	if b == nil do return
	termgrid.terminal_osc_set_title(&b.terminal, transmute([]u8)title)
	backend_post_event(b, .Title_Changed)
}

_backend_observer_on_bell :: proc(user_data: rawptr) {
	b := (^Backend)(user_data)
	if b == nil do return
	b.terminal.bell_event = true
	backend_post_event(b, .Bell)
}

_backend_observer_on_exit :: proc(user_data: rawptr, exit_code: int) {
	b := (^Backend)(user_data)
	if b == nil do return
	b.pty.exit_code = exit_code
	backend_post_event(b, .Child_Exited)
}

_backend_response_cb :: proc(user_data: rawptr, data: []u8) {
	b := (^Backend)(user_data)
	if b != nil {
		backend_write_pty(b, data)
	}
}

_backend_graphics_write :: proc(user_data: rawptr, data: []u8) {
	b := (^Backend)(user_data)
	if b == nil do return
	_ = backend_write_pty(b, data)
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

_backend_clipboard_cb :: proc(user_data: rawptr, data: []u8) {
	b := (^Backend)(user_data)
	if b != nil {
		backend_set_pending_clipboard(b, data)
	}
}

// backend_set_pending_clipboard stores a complete owned copy under the mutex.
backend_set_pending_clipboard :: proc(b: ^Backend, data: []u8) {
	if b == nil do return
	pending := make([]u8, len(data), runtime.heap_allocator())
	copy(pending, data)
	sync.mutex_lock(&b.clipboard_pending_mtx)
	defer sync.mutex_unlock(&b.clipboard_pending_mtx)
	delete(b.clipboard_pending_buf, runtime.heap_allocator())
	b.clipboard_pending_buf = pending
}

// backend_take_pending_clipboard returns independently owned text and clears pending storage.
backend_take_pending_clipboard :: proc(b: ^Backend) -> (string, bool) {
	if b == nil do return "", false
	sync.mutex_lock(&b.clipboard_pending_mtx)
	defer sync.mutex_unlock(&b.clipboard_pending_mtx)
	if len(b.clipboard_pending_buf) == 0 do return "", false
	text := strings.clone(string(b.clipboard_pending_buf), runtime.heap_allocator())
	delete(b.clipboard_pending_buf, runtime.heap_allocator())
	b.clipboard_pending_buf = nil
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

// _resolve_shell_argv returns the startup arguments for the spawned shell.
_resolve_shell_argv :: proc(shell: string) -> []string {
	return pty.shell_resolve_argv(shell, .Interactive)
}

// backend_init initializes terminal, parser, PTY, and style LUT.
backend_init :: proc(
	b: ^Backend,
	init_rows, init_cols: int,
	prog: string,
	argv: []string,
	cfg: ^config.Config,
	theme: termgrid.Theme,
	pixel_w: int = 0,
	pixel_h: int = 0,
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

	for i in 0 ..< SNAPSHOT_SLOT_COUNT {
		front_snapshot_init(&b.snapshots[i], init_rows, init_cols, theme = theme)
		b.needs_full_copy[i] = true
		bitset_clear(&b.missed_rows[i])
	}
	b.middle = 1
	b.write_index = 0
	b.reader.read_index = 2
	b.reader.drawn_seq = 0
	b.reader.force_full_redraw = true
	b.publish_seq = 0
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
		_ = posix.fcntl(b.wake_pipe_r, .SETFD, int(posix.FD_CLOEXEC))
		_ = posix.fcntl(b.wake_pipe_w, .SETFD, int(posix.FD_CLOEXEC))
	} else {
		b.wake_pipe_r = -1
		b.wake_pipe_w = -1
	}

	parser.parser_init(&b.parser)
	b.parser.response_cb = nil
	b.parser.response_context_cb = _backend_response_cb
	b.parser.response_user_data = b
	b.parser.graphics_cb = _backend_graphics_cb
	b.parser.graphics_user_data = b
	b.parser.clipboard_cb = nil
	b.parser.clipboard_context_cb = _backend_clipboard_cb
	b.parser.clipboard_user_data = b
	b.parser.clipboard_read_cb = _backend_clipboard_read_cb
	b.parser.clipboard_read_user_data = b

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

	if !pty.pty_spawn(&b.pty, init_rows, init_cols, spawn_prog, spawn_argv, b.cwd, pixel_w, pixel_h) {
		termgrid.terminal_destroy(&b.terminal)
		for i in 0 ..< SNAPSHOT_SLOT_COUNT {
			front_snapshot_destroy(&b.snapshots[i])
		}
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
	b.view_generation = 0
	b.last_mouse_col = 0
	b.last_mouse_row = 0
	b.sync_output_start_ns = 0

	rows := b.terminal.grid.row_count
	cols := b.terminal.grid.col_count

	for i in 0 ..< SNAPSHOT_SLOT_COUNT {
		front_snapshot_init(&b.snapshots[i], rows, cols, theme = theme)
		b.needs_full_copy[i] = true
		bitset_clear(&b.missed_rows[i])
	}
	b.middle = 1
	b.write_index = 0
	b.reader.read_index = 2
	b.reader.drawn_seq = 0
	b.reader.force_full_redraw = true
	b.publish_seq = 0
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

	b.parser.response_cb = nil
	b.parser.response_context_cb = _backend_response_cb
	b.parser.response_user_data = b
	b.parser.graphics_cb = _backend_graphics_cb
	b.parser.graphics_user_data = b
	b.parser.clipboard_cb = nil
	b.parser.clipboard_context_cb = _backend_clipboard_cb
	b.parser.clipboard_user_data = b
	b.parser.clipboard_read_cb = _backend_clipboard_read_cb
	b.parser.clipboard_read_user_data = b

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

	// Synchronize virtual grid to front snapshots
	_backend_publish_snapshot(b)

	// Mark all damage so renderer immediately displays the session's active screen and scrollback
	termgrid.damage_mark_all(&b.terminal.damage, nil)
	for i in 0 ..< SNAPSHOT_SLOT_COUNT {
		b.needs_full_copy[i] = true
		termgrid.damage_mark_all(&b.snapshots[i].terminal.damage, nil)
	}
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
	session_core.session_bind_parser_callbacks(cs)
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
	sync.mutex_lock(&b.clipboard_pending_mtx)
	delete(b.clipboard_pending_buf, runtime.heap_allocator())
	b.clipboard_pending_buf = nil
	sync.mutex_unlock(&b.clipboard_pending_mtx)
	b.parser.graphics_cb = nil
	b.parser.graphics_user_data = nil
	termgrid.terminal_destroy(&b.terminal)
	for i in 0 ..< SNAPSHOT_SLOT_COUNT {
		front_snapshot_destroy(&b.snapshots[i])
	}
	parser.parser_destroy(&b.parser)
	if b.drain_buf != nil {
		delete(b.drain_buf, runtime.heap_allocator())
		b.drain_buf = nil
	}
	delete(b.cwd)
	b.cwd = ""
	b.observer = {}
	b.session_cfg = {}
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
		// Embedded backends may move with tab storage; refresh their origin.
		b.parser.response_user_data = b
		b.parser.clipboard_user_data = b
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
		return termgrid.terminal_take_title(&b.snapshots[b.reader.read_index].terminal)
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
	t := &b.terminal
	view_ptr := &b.view
	inter_ptr := &b.interaction

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

// backend_get_terminal returns the active front terminal if worker is threaded, or live terminal.
backend_get_terminal :: proc(b: ^Backend) -> ^termgrid.Terminal {
	if b == nil do return nil
	if b.thread != nil {
		_ = backend_refresh_snapshot(b)
		idx := b.reader.read_index
		if idx >= 0 && idx < SNAPSHOT_SLOT_COUNT {
			return &b.snapshots[idx].terminal
		}
	}
	return &b.terminal
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

	t := backend_get_terminal(b)
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

	if b.thread != nil {
		_ = backend_refresh_snapshot(b)
	}

	term_ptr := &b.snapshots[b.reader.read_index].terminal if b.thread != nil else &b.terminal
	view_ptr := &b.snapshots[b.reader.read_index].view if b.thread != nil else &b.view
	cursor_ptr := &b.snapshots[b.reader.read_index].cursor if b.thread != nil else &b.cursor
	interaction_ptr := &b.snapshots[b.reader.read_index].interaction if b.thread != nil else &b.interaction
	focused := b.snapshots[b.reader.read_index].focused if b.thread != nil else b.focused

	if b.thread == nil {
		cur := termgrid.terminal_get_cursor(term_ptr)
		render.cursor_overlay_sync(cursor_ptr, cur.row, cur.col, cur.style)
		_ = render.cursor_overlay_tick(cursor_ptr, now, focused, cur.visible)
	}

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
				backend_write_pty(b, []u8{0x1B, '[', 'I'})
			} else {
				backend_write_pty(b, []u8{0x1B, '[', 'O'})
			}
		}
	}
}

// backend_on_resize updates the terminal grid size and PTY window size.
backend_on_resize :: proc(b: ^Backend, rows, cols: int, pixel_w: int = 0, pixel_h: int = 0) -> bool {
	if b == nil || rows <= 0 || cols <= 0 {
		return false
	}
	pty.pty_set_winsize(&b.pty, rows, cols, pixel_w, pixel_h)
	if b.host_client != nil && b.host_pane_id != 0 {
		_ = host_client_send_resize(b.host_client, b.host_ws_id, b.host_pane_id, rows, cols)
	}
	if rows == b.terminal.grid.row_count && cols == b.terminal.grid.col_count {
		return true
	}
	termgrid.terminal_resize(&b.terminal, rows, cols)
	for slot in 0 ..< SNAPSHOT_SLOT_COUNT {
		b.needs_full_copy[slot] = true
	}
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

backend_init_host_backed :: proc(
	b: ^Backend,
	init_rows, init_cols: int,
	hc: ^App_Host_Client,
	ws_id, pane_id: u64,
	cfg: ^config.Config,
	theme: termgrid.Theme,
) -> bool {
	if b == nil do return false

	b.pty.master = -1
	b.pty.pid = -1
	b.pty.state = .Running
	b.focused = true
	b.should_quit = false
	b.view = termgrid.Terminal_View{}
	inter.interaction_init(&b.interaction)
	b.view_generation = 0
	b.pty_bytes_total = 0
	b.prog = "host"
	b.host_client = hc
	b.host_ws_id = ws_id
	b.host_pane_id = pane_id

	termgrid.terminal_init(&b.terminal, init_rows, init_cols, theme = theme)
	for i in 0 ..< SNAPSHOT_SLOT_COUNT {
		front_snapshot_init(&b.snapshots[i], init_rows, init_cols, theme = theme)
		b.needs_full_copy[i] = true
		bitset_clear(&b.missed_rows[i])
	}
	b.middle = 1
	b.write_index = 0
	b.reader.read_index = 2
	b.reader.drawn_seq = 0
	b.reader.force_full_redraw = true
	b.publish_seq = 0
	b.focus_requested = true
	b.drain_buf = make([]u8, APP_DRAIN_CAP, runtime.heap_allocator())
	b.thread = nil
	b.thread_running = false
	b.wake_pipe_r = -1
	b.wake_pipe_w = -1

	parser.parser_init(&b.parser)
	b.cwd = strings.clone(cfg.working_directory if (cfg != nil && len(cfg.working_directory) > 0) else "~")

	render.style_lut_rebuild(&b.lut, &b.terminal.grid.style_table)
	return true
}

// backend_write_pty writes data to the host client if host-backed, or to the local PTY master.
backend_write_pty :: proc(b: ^Backend, data: []u8) -> bool {
	if b == nil || len(data) == 0 do return false
	if b.host_client != nil && b.host_pane_id != 0 {
		return host_client_send_input(b.host_client, b.host_pane_id, data)
	}
	return pty.pty_write(&b.pty, data)
}

// backend_relaunch closes the dead PTY and spawns a fresh child.
backend_relaunch :: proc(b: ^Backend) -> bool {
	if b == nil {
		return false
	}
	pty.pty_close(&b.pty)
	rows := b.terminal.grid.row_count
	cols := b.terminal.grid.col_count
	if !pty.pty_spawn(&b.pty, rows, cols, b.prog, b.argv, b.cwd, b.pty.pixel_w, b.pty.pixel_h) {
		backend_show_banner_fail(b)
		return false
	}
	termgrid.terminal_erase_display(&b.terminal, .Entire)
	termgrid.terminal_move_cursor(&b.terminal, 0, 0)
	parser.parser_init(&b.parser)
	b.parser.response_cb = nil
	b.parser.response_context_cb = _backend_response_cb
	b.parser.response_user_data = b
	b.parser.graphics_cb = _backend_graphics_cb
	b.parser.graphics_user_data = b
	b.parser.clipboard_cb = nil
	b.parser.clipboard_context_cb = _backend_clipboard_cb
	b.parser.clipboard_user_data = b
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
		snap := &b.snapshots[b.reader.read_index]
		if snap.interaction.selection_active {
			return inter.interaction_extract_selection_text(&snap.terminal, &snap.interaction)
		}
		return termgrid.terminal_view_copy(&snap.terminal, &snap.view)
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
		backend_write_pty(b, []u8{0x1B, '[', '2', '0', '0', '~'})
		ok := backend_write_pty(b, transmute([]u8)sanitized)
		backend_write_pty(b, []u8{0x1B, '[', '2', '0', '1', '~'})
		return ok
	}
	return backend_write_pty(b, transmute([]u8)text)
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
		for slot in 0 ..< SNAPSHOT_SLOT_COUNT {
			bitset_set(&b.missed_rows[slot], r)
		}
	}
	if backend_is_threaded(b) do _backend_swap_buffers(b)
}

// _backend_swap_buffers publishes snapshot, then notifies after publishing.
_backend_swap_buffers :: proc(b: ^Backend) {
	if b == nil {
		return
	}
	_backend_publish_snapshot(b)
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
						_backend_clipboard_cb(b, transmute([]u8)text)
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
				if b.pty.state == .Running && b.view.scrollback_offset > 0 {
					termgrid.terminal_view_set_offset(&b.view, &b.terminal, 0)
					inter.interaction_resume_viewport(&b.interaction)
					b.view_generation += 1
				}
				kitty_flags := termgrid.terminal_kitty_active(&b.terminal).flags
				if b.host_client != nil && b.host_pane_id != 0 {
					buf: [input.INPUT_ENCODE_MAX]u8
					m := input.input_encode(ev.input, buf[:], kitty_flags, b.terminal.app_cursor_keys)
					if m > 0 {
						_ = backend_write_pty(b, buf[:m])
					}
				} else {
					key_evs := [1]input.Input_Event{ev.input}
					_ = input.input_pump_events(&b.pty, key_evs[:], kitty_flags, b.terminal.app_cursor_keys)
				}
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
					_ = backend_write_pty(b, buf[:n])
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
						_backend_clipboard_cb(b, transmute([]u8)text)
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
						_ = backend_write_pty(b, seq[:])
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
			backend_on_resize(b, ev.rows, ev.cols, int(ev.grid_pixel_w), int(ev.grid_pixel_h))
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

	for sync.atomic_load(&b.thread_running) {
		// 1. Drain and execute pending UI events from Frontend
		n_events := ui_event_queue_pop_all(&b.event_queue, events_buf[:])
		for i in 0..<n_events {
			backend_handle_ui_event(b, events_buf[i])
		}

		if b.should_quit {
			break
		}

		is_bg := sync.atomic_load(&b.is_background)

		// 2. Drain PTY & Parse (Exhaustive Batch Drain)
		bytes_read := 0
		if b.pty.state == .Running && b.pty.master >= 0 {
			drain_budget := 512 * 1024
			if is_bg {
				drain_budget = 64 * 1024
			}
			total_drained := 0
			for total_drained < drain_budget {
				n := backend_drain_pty(b)
				if n <= 0 do break
				total_drained += n
				bytes_read += n

				pfd := [1]posix.pollfd{{fd = posix.FD(b.pty.master), events = {.IN}}}
				if posix.poll(&pfd[0], 1, 0) <= 0 {
					break
				}
			}
		}

		if is_bg && bytes_read > 0 {
			time.sleep(8 * time.Millisecond)
		}

		// 3. Child exit poll
		was_exited := b.pty.state == .Exited
		backend_poll_exit(b)
		exit_changed := !was_exited && b.pty.state == .Exited
		if exit_changed {
			backend_post_event(b, .Child_Exited)
		}

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
			if !ui_event_queue_has_resize(&b.event_queue) {
				_backend_publish_snapshot(b)
				if !is_bg && b.notify_data_ready_cb != nil {
					b.notify_data_ready_cb(b.notify_user_data)
				}
			}
		}

		// 6. Wait when idle
		if bytes_read == 0 && n_events == 0 {
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

// Copy title metadata; no borrowed worker data escapes to the session title resolver.
backend_title_metadata :: proc(b: ^Backend, title, cwd: []u8) -> (title_len, cwd_len: int, fresh: bool) {
	if b == nil do return
	t := &b.snapshots[b.reader.read_index].terminal if b.thread != nil else &b.terminal
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
		return b.snapshots[b.reader.read_index].exited
	}
	backend_poll_exit(b)
	return b.pty.state == .Exited
}
