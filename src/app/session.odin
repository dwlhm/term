package main

import posix "core:sys/posix"
import "core:strings"
import "core:time"
import config "../config"
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
	id:           u32,
	status:       Tab_Status,
	title_buf:    [128]u8,
	title_len:    int,
	exit_code:    i32,
	exit_signal:  i32,
	has_bell:     bool,
	terminate_t0: time.Time,
	backend:      Backend,
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
	tab.title_len = session_sanitize_title(tab.title_buf[:], "Terminal")

	if !backend_init(&tab.backend, rows, cols, prog, argv, cfg, theme) {
		tab.status = .Error_Spawn
		ordered_remove(&sm.tabs, new_idx)
		return -1, false
	}
	tab.status = .Running

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

	session_destroy(s)
	ordered_remove(&sm.tabs, idx)

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

// session_switch_tab transitions active focus to the designated tab index and schedules damage refresh.
session_switch_tab :: proc(sm: ^Session_Manager, idx: int) -> bool {
	if sm == nil || idx < 0 || idx >= len(sm.tabs) do return false
	if idx == sm.active_idx do return true

	sm.active_idx = idx
	s := &sm.tabs[idx]
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
				if _damage_cells(&s.backend.terminal) > 0 {
					any_damaged = true
				}
			}
			if osc_title := backend_take_title(&s.backend); len(osc_title) > 0 {
				s.title_len = session_sanitize_title(s.title_buf[:], osc_title)
			}
			if s.backend.terminal.bell_event {
				s.has_bell = true
			}
			if pty.pty_poll_exit(&s.backend.pty) {
				session_destroy(s)
				ordered_remove(&sm.tabs, idx)
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
