package main

import posix "core:sys/posix"
import "core:strings"
import "core:time"
import config "../config"
import i18n "../i18n"
import termgrid "../terminal"
import pty "../platform/pty"
import ui "../ui"

MAX_TABS: int : 32

// Tab_Status reflects the finite state machine state of an isolated session.
Tab_Status :: enum u8 {
	Spawning,
	Running,
	Unresponsive,
	Terminating,
	Exited,
	Error_Spawn,
}

// Tab_Session encapsulates the lifecycle, process ID, and isolated backend for one tab.
Tab_Session :: struct {
	id:                    u32,
	status:                Tab_Status,
	title_buf:             [128]u8,
	title_len:             int,
	osc_title_buf:         [128]u8,
	osc_title_len:         int,
	last_cwd_buf:          [128]u8,
	last_cwd_len:          int,
	had_foreground:        bool,
	title_override_buf:    [128]u8,
	title_override_len:    int,
	title_override_active: bool,
	exit_code:             i32,
	exit_signal:           i32,
	has_bell:              bool,
	terminate_t0:          time.Time,
	backend:               Backend,
}

// Session_Manager manages the collection of concurrent tab sessions.
Session_Manager :: struct {
	tabs:       [dynamic]Tab_Session,
	active_idx: int,
	next_id:    u32,
	max_tabs:   int,
}

// _damage_cells counts dirty cells in the live damage state.
_damage_cells :: proc(t: ^termgrid.Terminal) -> int {
	if t == nil do return 0
	n := 0
	for i in 0..<len(t.damage.dirty_rows) {
		dr := &t.damage.dirty_rows[i]
		if dr.full {
			n += t.damage.col_count
		} else {
			for j in 0..<int(dr.span_count) {
				s := dr.spans[j]
				n += max(0, int(s.col_end) - int(s.col_start))
			}
		}
	}
	return n
}

// session_sanitize_title strips control characters (< 32), BiDi overrides, and clamps length to 64 bytes.
session_sanitize_title :: proc(dst: []u8, src: string) -> int {
	if len(dst) == 0 || len(src) == 0 do return 0

	n := 0
	max_len := min(len(dst), 64)

	for r in src {
		if n >= max_len do break

		// Strip control characters (< 32, 127)
		if r < 32 || r == 127 do continue

		// Strip Unicode BiDi override runes
		switch r {
		case 0x202A ..= 0x202E, 0x2066 ..= 0x2069:
			continue
		}

		if r < 128 {
			dst[n] = u8(r)
			n += 1
		} else {
			buf: [4]u8
			b_len := 0
			if r <= 0x7FF {
				buf[0] = u8(0xC0 | (r >> 6))
				buf[1] = u8(0x80 | (r & 0x3F))
				b_len = 2
			} else if r <= 0xFFFF {
				buf[0] = u8(0xE0 | (r >> 12))
				buf[1] = u8(0x80 | ((r >> 6) & 0x3F))
				buf[2] = u8(0x80 | (r & 0x3F))
				b_len = 3
			} else {
				buf[0] = u8(0xF0 | (r >> 18))
				buf[1] = u8(0x80 | ((r >> 12) & 0x3F))
				buf[2] = u8(0x80 | ((r >> 6) & 0x3F))
				buf[3] = u8(0x80 | (r & 0x3F))
				b_len = 4
			}
			if n + b_len <= max_len {
				copy(dst[n:], buf[:b_len])
				n += b_len
			} else {
				break
			}
		}
	}
	return n
}

// session_title_display resolves the user-visible title: an active override wins
// over the OSC-driven title buffer.
session_title_display :: proc(s: ^Tab_Session) -> string {
	if s == nil do return ""
	if s.title_override_active && s.title_override_len > 0 {
		return string(s.title_override_buf[:s.title_override_len])
	}
	if s.title_len > 0 {
		return string(s.title_buf[:s.title_len])
	}
	return i18n.i18n_get().tab_untitled
}

// session_set_title_override installs a user rename, sanitized like an OSC title.
// Returns true when a non-empty override was stored.
session_set_title_override :: proc(s: ^Tab_Session, text: string) -> bool {
	if s == nil do return false
	n := session_sanitize_title(s.title_override_buf[:], text)
	s.title_override_len = n
	s.title_override_active = n > 0
	return n > 0
}

// session_clear_title_override drops the user rename, restoring the OSC title.
session_clear_title_override :: proc(s: ^Tab_Session) -> bool {
	if s == nil do return false
	s.title_override_len = 0
	s.title_override_active = false
	return true
}

// session_manager_init initializes the session manager container.
session_manager_init :: proc(sm: ^Session_Manager, max_tabs: int = MAX_TABS) {
	if sm == nil do return
	sm.tabs = make([dynamic]Tab_Session, 0, max_tabs)
	sm.active_idx = -1
	sm.next_id = 1
	sm.max_tabs = max_tabs if max_tabs > 0 else MAX_TABS
}

// session_destroy dismantles an individual tab session and its PTY/terminal resources.
session_destroy :: proc(s: ^Tab_Session) {
	if s == nil do return
	backend_destroy(&s.backend)
	s.status = .Exited
}

// session_manager_destroy cleans up all active tab sessions and frees internal structures.
session_manager_destroy :: proc(sm: ^Session_Manager) {
	if sm == nil do return
	for i in 0 ..< len(sm.tabs) {
		session_destroy(&sm.tabs[i])
	}
	delete(sm.tabs)
	sm.tabs = nil
	sm.active_idx = -1
}

// session_spawn creates a new isolated terminal backend and forks child process.
session_spawn :: proc(
	sm: ^Session_Manager,
	prog: string,
	argv: []string,
	rows, cols: int,
	cfg: ^config.Config,
	theme: termgrid.Theme,
) -> (idx: int, ok: bool) {
	if sm == nil do return -1, false
	// Max Tab Guard
	if len(sm.tabs) >= sm.max_tabs do return -1, false

	resize(&sm.tabs, len(sm.tabs) + 1)
	new_idx := len(sm.tabs) - 1
	tab := &sm.tabs[new_idx]
	tab.id = sm.next_id
	sm.next_id += 1
	tab.status = .Spawning
	tab.title_len = session_sanitize_title(tab.title_buf[:], i18n.i18n_get().tab_untitled)

	if !backend_init(&tab.backend, rows, cols, prog, argv, cfg, theme) {
		tab.status = .Error_Spawn
		ordered_remove(&sm.tabs, new_idx)
		return -1, false
	}
	tab.status = .Running
	_ = backend_start_thread(&tab.backend)
	_ = session_refresh_title(tab)

	if sm.active_idx < 0 {
		sm.active_idx = new_idx
	}
	return new_idx, true
}

// session_close_tab begins the escalation ladder to terminate the tab child process, or cleans up if exited.
session_close_tab :: proc(sm: ^Session_Manager, idx: int) -> bool {
	if sm == nil || idx < 0 || idx >= len(sm.tabs) do return false
	s := &sm.tabs[idx]

	// Kirim sinyal SIGHUP ke child process group jika proses masih running
	if s.backend.pty.pid > 1 && s.backend.pty.state == .Running {
		posix.kill(posix.pid_t(-s.backend.pty.pid), .SIGHUP)
	}

	threaded_ids: [MAX_TABS]u32
	threaded_count := 0
	for i in 0 ..< len(sm.tabs) {
		if i != idx && backend_is_threaded(&sm.tabs[i].backend) {
			backend_stop_thread(&sm.tabs[i].backend)
			if threaded_count < MAX_TABS {
				threaded_ids[threaded_count] = sm.tabs[i].id
				threaded_count += 1
			}
		}
	}

	session_destroy(s)
	ordered_remove(&sm.tabs, idx)

	for i in 0 ..< len(sm.tabs) {
		for j in 0 ..< threaded_count {
			if sm.tabs[i].id == threaded_ids[j] {
				_ = backend_start_thread(&sm.tabs[i].backend)
				break
			}
		}
	}

	if len(sm.tabs) == 0 {
		sm.active_idx = -1
	} else if idx < sm.active_idx {
		sm.active_idx -= 1
	} else if idx == sm.active_idx {
		sm.active_idx = min(idx, len(sm.tabs) - 1)
	}

	if sm.active_idx >= 0 && sm.active_idx < len(sm.tabs) {
		termgrid.damage_mark_all(&sm.tabs[sm.active_idx].backend.terminal.damage, nil)
		sm.tabs[sm.active_idx].backend.view_generation += 1
	}

	return true
}

// session_reorder_tab moves the tab at from_idx to to_idx by rotating the
// preallocated array in place (no realloc) while preserving the active tab by id.
// Backends that are threaded are stopped for the move and restarted afterward.
session_reorder_tab :: proc(sm: ^Session_Manager, from_idx, to_idx: int) -> bool {
	if sm == nil do return false
	n := len(sm.tabs)
	if from_idx < 0 || from_idx >= n || to_idx < 0 || to_idx >= n do return false
	if from_idx == to_idx do return true

	active_id: u32 = 0
	if sm.active_idx >= 0 && sm.active_idx < n {
		active_id = sm.tabs[sm.active_idx].id
	}

	threaded_ids: [MAX_TABS]u32
	threaded_count := 0
	for i in 0 ..< n {
		if backend_is_threaded(&sm.tabs[i].backend) {
			backend_stop_thread(&sm.tabs[i].backend)
			if threaded_count < MAX_TABS {
				threaded_ids[threaded_count] = sm.tabs[i].id
				threaded_count += 1
			}
		}
	}

	// Tab_Session embeds a large Backend, so the scratch slot is heap-allocated
	// to avoid a multi-megabyte stack temporary while keeping sm.tabs in place.
	moved := new(Tab_Session, context.allocator)
	defer free(moved, context.allocator)
	moved^ = sm.tabs[from_idx]
	if from_idx < to_idx {
		for i in from_idx ..< to_idx {
			sm.tabs[i] = sm.tabs[i + 1]
		}
	} else {
		for i := from_idx; i > to_idx; i -= 1 {
			sm.tabs[i] = sm.tabs[i - 1]
		}
	}
	sm.tabs[to_idx] = moved^

	for i in 0 ..< n {
		for j in 0 ..< threaded_count {
			if sm.tabs[i].id == threaded_ids[j] {
				_ = backend_start_thread(&sm.tabs[i].backend)
				break
			}
		}
	}

	for i in 0 ..< n {
		if sm.tabs[i].id == active_id {
			sm.active_idx = i
			break
		}
	}
	return true
}

// session_close_others closes every tab except keep_idx, returning the number
// closed. Indices are removed in descending order so earlier indices stay valid.
session_close_others :: proc(sm: ^Session_Manager, keep_idx: int) -> int {
	if sm == nil do return 0
	if keep_idx < 0 || keep_idx >= len(sm.tabs) do return 0
	closed := 0
	for i := len(sm.tabs) - 1; i >= 0; i -= 1 {
		if i == keep_idx do continue
		if session_close_tab(sm, i) do closed += 1
	}
	return closed
}

// session_close_to_right closes every tab after idx, returning the number closed.
session_close_to_right :: proc(sm: ^Session_Manager, idx: int) -> int {
	if sm == nil do return 0
	if idx < 0 || idx >= len(sm.tabs) do return 0
	closed := 0
	for i := len(sm.tabs) - 1; i > idx; i -= 1 {
		if session_close_tab(sm, i) do closed += 1
	}
	return closed
}

// session_switch_tab transitions active focus to the designated tab index and schedules damage refresh.
session_switch_tab :: proc(sm: ^Session_Manager, idx: int) -> bool {
	if sm == nil || idx < 0 || idx >= len(sm.tabs) do return false
	if idx == sm.active_idx do return true

	target_rows := 0
	target_cols := 0
	if sm.active_idx >= 0 && sm.active_idx < len(sm.tabs) {
		prev := &sm.tabs[sm.active_idx]
		target_rows = prev.backend.terminal.grid.row_count
		target_cols = prev.backend.terminal.grid.col_count
	}

	sm.active_idx = idx
	s := &sm.tabs[idx]

	if target_rows > 0 && target_cols > 0 && (s.backend.terminal.grid.row_count != target_rows || s.backend.terminal.grid.col_count != target_cols) {
		termgrid.terminal_resize(&s.backend.terminal, target_rows, target_cols)
		pty.pty_set_winsize(&s.backend.pty, target_rows, target_cols)
	}

	termgrid.damage_mark_all(&s.backend.terminal.damage, nil)
	s.backend.view_generation += 1
	return true
}

// session_poll_all performs fair-scheduled drains across tabs and reaps processes without blocking.
session_poll_all :: proc(sm: ^Session_Manager, max_chunk_budget: int = 65536) -> (any_damaged: bool) {
	if sm == nil || len(sm.tabs) == 0 do return false

	idx := 0
	for idx < len(sm.tabs) {
		s := &sm.tabs[idx]
		switch s.status {
		case .Running, .Terminating:
			if s.backend.pty.master >= 0 && !backend_is_threaded(&s.backend) {
				backend_drain_pty(&s.backend)
				if idx == sm.active_idx && _damage_cells(&s.backend.terminal) > 0 {
					any_damaged = true
				}
			}
			if session_refresh_title(s) do any_damaged = true
			if s.backend.terminal.bell_event {
				s.has_bell = true
			}
			if pty.pty_poll_exit(&s.backend.pty) {
				_ = session_close_tab(sm, idx)
				any_damaged = true
				continue
			}
			idx += 1

		case .Exited, .Spawning, .Unresponsive, .Error_Spawn:
			idx += 1
		}
	}

	return any_damaged
}

// OSC 7 accepts an absolute path or a file URI. Decode before sanitizing and
// reject malformed escapes rather than presenting an ambiguous path.
session_decode_cwd :: proc(dst: []u8, src: string) -> int {
	path := src
	uri := strings.has_prefix(path, "file://")
	if uri {
		path = path[len("file://"):]
		slash := strings.index_byte(path, '/')
		if slash < 0 do return 0
		path = path[slash:]
	}
	if len(path) == 0 || path[0] != '/' do return 0
	buf: [4096]u8
	n := 0
	for i := 0; i < len(path); i += 1 {
		b := path[i]
		if uri && b == '%' {
			if i + 2 >= len(path) do return 0
			high, low := session_hex_digit(path[i+1]), session_hex_digit(path[i+2])
			if high < 0 || low < 0 do return 0
			b = u8(high * 16 + low)
			i += 2
		}
		if b < 32 || b == 127 || n >= len(buf) do return 0
		buf[n] = b
		n += 1
	}
	return session_sanitize_title(dst, string(buf[:n]))
}

session_hex_digit :: proc(b: u8) -> int {
	if b >= '0' && b <= '9' do return int(b - '0')
	if b >= 'a' && b <= 'f' do return int(b - 'a') + 10
	if b >= 'A' && b <= 'F' do return int(b - 'A') + 10
	return -1
}

_path_basename :: proc(path: string) -> string {
	p := path
	for len(p) > 1 && p[len(p)-1] == '/' {
		p = p[:len(p)-1]
	}
	if len(p) == 0 do return ""
	if p == "/" do return "/"
	slash := strings.last_index_byte(p, '/')
	if slash >= 0 {
		return p[slash+1:]
	}
	return p
}

session_update_title :: proc(s: ^Tab_Session, fresh_osc: string, cwd, foreground: string, fresh: bool = false) -> bool {
	if s == nil do return false
	previous := s.title_buf
	previous_len := s.title_len
	cwd_changed := len(cwd) > 0 && cwd != string(s.last_cwd_buf[:s.last_cwd_len])
	fg_started := len(foreground) > 0 && !s.had_foreground
	fg_ended := len(foreground) == 0 && s.had_foreground
	if fresh {
		s.osc_title_len = session_sanitize_title(s.osc_title_buf[:], fresh_osc)
	} else if cwd_changed || fg_started || fg_ended {
		s.osc_title_len = 0
	}
	if len(cwd) > 0 do s.last_cwd_len = session_sanitize_title(s.last_cwd_buf[:], cwd)

	candidate := ""

	// Priority 1: User title override (s.title_override_active)
	if s.title_override_active && s.title_override_len > 0 {
		candidate = string(s.title_override_buf[:s.title_override_len])
	}

	// Priority 2: Foreground process name via pty.pty_foreground_name(&s.backend.pty, foreground[:])
	if len(candidate) == 0 {
		fg_name := foreground
		if len(fg_name) == 0 {
			fg_buf: [128]u8
			fn := pty.pty_foreground_name(&s.backend.pty, fg_buf[:])
			if fn > 0 {
				fg_name = string(fg_buf[:fn])
			}
		}
		if len(fg_name) > 0 {
			candidate = fg_name
		}
	}

	// Priority 3: When at shell prompt (no active foreground child), use the shell process name or directory basename from s.backend.cwd
	if len(candidate) == 0 {
		dir := cwd if len(cwd) > 0 else s.backend.cwd
		if len(dir) > 0 {
			base := _path_basename(dir)
			if len(base) > 0 && base != "." {
				candidate = base
			}
		}
		if len(candidate) == 0 && len(s.backend.prog) > 0 {
			shell_base := _path_basename(s.backend.prog)
			if len(shell_base) > 0 && shell_base != "." {
				candidate = shell_base
			}
		}
	}

	// Priority 4: Sanitized OSC title
	if len(candidate) == 0 {
		if s.osc_title_len > 0 {
			candidate = string(s.osc_title_buf[:s.osc_title_len])
		} else if len(fresh_osc) > 0 {
			candidate = fresh_osc
		}
	}

	// Fallback candidates
	if len(candidate) == 0 do candidate = string(s.title_buf[:s.title_len])
	if len(candidate) == 0 do candidate = i18n.i18n_get().tab_untitled

	s.title_len = session_sanitize_title(s.title_buf[:], candidate)
	s.had_foreground = len(foreground) > 0
	return !s.title_override_active && string(previous[:previous_len]) != string(s.title_buf[:s.title_len])
}

session_refresh_title :: proc(s: ^Tab_Session) -> bool {
	if s == nil do return false
	osc: [128]u8
	raw_cwd: [256]u8
	cwd: [128]u8
	foreground: [128]u8
	native_cwd: [4096]u8
	on, cn, fresh := backend_title_metadata(&s.backend, osc[:], raw_cwd[:])
	dn := session_decode_cwd(cwd[:], string(raw_cwd[:cn]))
	if dn == 0 {
		n := pty.pty_working_directory(&s.backend.pty, native_cwd[:])
		dn = session_decode_cwd(cwd[:], string(native_cwd[:n]))
	}
	if dn == 0 do dn = session_sanitize_title(cwd[:], s.backend.cwd)
	fn := pty.pty_foreground_name(&s.backend.pty, foreground[:])
	return session_update_title(s, string(osc[:on]), string(cwd[:dn]), string(foreground[:fn]), fresh)
}
