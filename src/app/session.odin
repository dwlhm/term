package main

import "base:runtime"
import "core:fmt"
import "core:sync"
import posix "core:sys/posix"
import "core:strings"
import "core:time"
import config "../config"
import i18n "../i18n"
import termgrid "../terminal"
import pty "../platform/pty"
import session_core "../session_core"
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
	tree:                  Pane_Tree,
	backend:               Backend,
}

// Session_Manager manages the collection of concurrent tab sessions.
Session_Manager :: struct {
	tabs:                 [dynamic]Tab_Session,
	active_idx:           int,
	next_id:              u32,
	max_tabs:             int,
	registry:             ^session_core.Session_Registry,
	default_rows:         int,
	default_cols:         int,
	default_pixel_w:      int,
	default_pixel_h:      int,
	default_config:       ^config.Config,
	default_theme:        termgrid.Theme,
	clipboard_user_data:  rawptr,
	clipboard_write_cb:   Clipboard_Write_Proc,
	clipboard_read_cb:    Clipboard_Read_Proc,
	notify_data_ready_cb: proc(user_data: rawptr),
	notify_user_data:     rawptr,
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
	sm.registry = session_core.session_registry_default()
	sm.default_rows = 24
	sm.default_cols = 80
}

// _collect_leaves_slice gathers all leaf nodes in depth-first traversal order into out.
_collect_leaves_slice :: proc(node: ^Pane_Node, out: []^Pane_Node, count: ^int) {
	if node == nil do return
	if node.kind == .Leaf {
		if count^ < len(out) {
			out[count^] = node
			count^ += 1
		}
		return
	}
	_collect_leaves_slice(node.first, out, count)
	_collect_leaves_slice(node.second, out, count)
}

// tab_leaf_panes gathers all leaf nodes of the tab's pane tree into out_leaves.
tab_leaf_panes :: proc(tab: ^Tab_Session, out_leaves: []^Pane_Node) -> int {
	if tab == nil || tab.tree.root == nil do return 0
	count := 0
	_collect_leaves_slice(tab.tree.root, out_leaves, &count)
	return count
}

// tab_active_pane returns the currently focused leaf pane node of the tab.
tab_active_pane :: proc(tab: ^Tab_Session) -> ^Pane_Node {
	if tab == nil do return nil
	if tab.tree.focused_pane_id != 0 {
		if node := pane_tree_find_pane(&tab.tree, tab.tree.focused_pane_id); node != nil {
			return node
		}
	}
	if tab.tree.root != nil {
		return _pane_find_first_leaf(tab.tree.root)
	}
	return nil
}

// tab_active_backend returns the backend associated with the tab's active pane,
// falling back to &tab.backend.
tab_active_backend :: proc(tab: ^Tab_Session) -> ^Backend {
	if tab == nil do return nil
	pane := tab_active_pane(tab)
	if pane != nil && pane.backend != nil {
		return pane.backend
	}
	return &tab.backend
}

// _tab_rebase_tree adjusts internal pointers within tab.tree after Tab_Session memory moves.
_tab_rebase_tree :: proc(tab: ^Tab_Session, old_nodes_base: rawptr, old_backend: ^Backend) {
	if tab == nil || old_nodes_base == nil do return
	new_nodes_base := rawptr(&tab.tree.nodes[0])
	if old_nodes_base == new_nodes_base && old_backend == &tab.backend do return

	delta := int(uintptr(new_nodes_base)) - int(uintptr(old_nodes_base))

	rebase_node_ptr :: proc(ptr: ^Pane_Node, delta: int) -> ^Pane_Node {
		if ptr == nil do return nil
		return (^Pane_Node)(uintptr(int(uintptr(ptr)) + delta))
	}

	if tab.tree.root != nil {
		tab.tree.root = rebase_node_ptr(tab.tree.root, delta)
	}
	if tab.tree.divider_hover != nil {
		tab.tree.divider_hover = rebase_node_ptr(tab.tree.divider_hover, delta)
	}

	for i in 0 ..< MAX_PANE_NODES {
		if !tab.tree.node_in_use[i] do continue
		node := &tab.tree.nodes[i]
		if node.parent != nil do node.parent = rebase_node_ptr(node.parent, delta)
		if node.first != nil do node.first = rebase_node_ptr(node.first, delta)
		if node.second != nil do node.second = rebase_node_ptr(node.second, delta)
		if old_backend != nil && node.backend == old_backend {
			node.backend = &tab.backend
		}
	}
}

// session_destroy dismantles an individual tab session and its PTY/terminal resources.
session_destroy :: proc(s: ^Tab_Session) {
	if s == nil do return
	leaves: [MAX_PANE_NODES]^Pane_Node
	count := tab_leaf_panes(s, leaves[:])
	destroyed_tab_backend := false
	for i in 0 ..< count {
		leaf := leaves[i]
		if leaf.backend != nil {
			if leaf.backend == &s.backend {
				destroyed_tab_backend = true
			}
			backend_destroy(leaf.backend)
			if leaf.backend != &s.backend {
				free(leaf.backend)
			}
			leaf.backend = nil
		}
	}
	pane_tree_destroy(&s.tree)
	if !destroyed_tab_backend && s.backend.pty.master >= 0 {
		backend_destroy(&s.backend)
	}
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
	pixel_w: int = 0,
	pixel_h: int = 0,
) -> (idx: int, ok: bool) {
	if sm == nil do return -1, false
	// Max Tab Guard
	if len(sm.tabs) >= sm.max_tabs do return -1, false

	sm.default_rows = rows
	sm.default_cols = cols
	sm.default_pixel_w = pixel_w
	sm.default_pixel_h = pixel_h
	sm.default_config = cfg
	sm.default_theme = theme

	resize(&sm.tabs, len(sm.tabs) + 1)
	new_idx := len(sm.tabs) - 1
	tab := &sm.tabs[new_idx]
	tab.id = sm.next_id
	sm.next_id += 1
	tab.status = .Spawning
	tab.title_len = session_sanitize_title(tab.title_buf[:], i18n.i18n_get().tab_untitled)

	if !backend_init(&tab.backend, rows, cols, prog, argv, cfg, theme, pixel_w, pixel_h) {
		tab.status = .Error_Spawn
		ordered_remove(&sm.tabs, new_idx)
		return -1, false
	}
	tab.status = .Running
	if sm.notify_data_ready_cb != nil {
		backend_set_notify_data_ready(&tab.backend, sm.notify_user_data, sm.notify_data_ready_cb)
	}
	if sm.clipboard_read_cb != nil || sm.clipboard_write_cb != nil {
		backend_set_clipboard_callbacks(&tab.backend, sm.clipboard_user_data, sm.clipboard_write_cb, sm.clipboard_read_cb)
	}
	if !backend_start_thread(&tab.backend) {
		fmt.eprintln("tab spawn failed: backend worker could not start")
		backend_destroy(&tab.backend)
		ordered_remove(&sm.tabs, new_idx)
		return -1, false
	}
	_ = pane_tree_init(&tab.tree, &tab.backend)
	if tab.tree.root != nil {
		tab.tree.root.rows = rows
		tab.tree.root.cols = cols
	}
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

	// Send SIGHUP to child process group of all running leaf panes
	leaves: [MAX_PANE_NODES]^Pane_Node
	leaf_count := tab_leaf_panes(s, leaves[:])
	for i in 0 ..< leaf_count {
		leaf := leaves[i]
		if leaf.backend != nil && leaf.backend.pty.pid > 1 && leaf.backend.pty.state == .Running {
			posix.kill(posix.pid_t(-leaf.backend.pty.pid), .SIGHUP)
		}
	}
	if leaf_count == 0 && s.backend.pty.pid > 1 && s.backend.pty.state == .Running {
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

	old_nodes: [MAX_TABS]rawptr
	old_backends: [MAX_TABS]^Backend
	for i in (idx + 1) ..< len(sm.tabs) {
		old_nodes[i] = &sm.tabs[i].tree.nodes[0]
		old_backends[i] = &sm.tabs[i].backend
	}

	ordered_remove(&sm.tabs, idx)

	for i in idx ..< len(sm.tabs) {
		_tab_rebase_tree(&sm.tabs[i], old_nodes[i + 1], old_backends[i + 1])
	}

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
		active_b := tab_active_backend(&sm.tabs[sm.active_idx])
		termgrid.damage_mark_all(&active_b.terminal.damage, nil)
		active_b.view_generation += 1
	}

	return true
}

// session_detach_tab detaches the tab at idx without killing child process or sending SIGHUP.
// Grid and child process state are preserved in a Core_Session registered into Session_Registry.
// If all tabs become detached, a fresh default shell tab is spawned so the window stays usable.
session_detach_tab :: proc(sm: ^Session_Manager, idx: int) -> bool {
	if sm == nil || idx < 0 || idx >= len(sm.tabs) do return false
	s := &sm.tabs[idx]

	if s.tree.node_count != 1 || tab_active_backend(s) != &s.backend {
		fmt.eprintln("detach rejected: only an embedded singleton terminal can detach")
		return false
	}

	// 1. Pause other threaded backends safely before mutating sm.tabs array
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

	// 2. Stop thread on tab to be detached and clean up leaf panes
	if backend_is_threaded(&s.backend) {
		backend_stop_thread(&s.backend)
	}
	// Reserve the authoritative registry entry before transferring any ownership.
	reg := sm.registry if sm.registry != nil else session_core.session_registry_default()
	cs := new(session_core.Core_Session)
	cs.id = fmt.aprintf("session_%d", s.id)
	cs.gui_tab_id = s.id
	cs.is_detached = true
	if !session_core.session_registry_register(reg, cs) {
		delete(cs.id)
		free(cs)
		for i in 0 ..< len(sm.tabs) {
			for j in 0 ..< threaded_count {
				if sm.tabs[i].id == threaded_ids[j] do _ = backend_start_thread(&sm.tabs[i].backend)
			}
		}
		_ = backend_start_thread(&s.backend)
		return false
	}
	cs.title_len = copy(cs.title_buf[:], s.title_buf[:s.title_len])
	if s.title_override_active do cs.title_override_len = copy(cs.title_override_buf[:], s.title_override_buf[:s.title_override_len])
	cwd := string(s.last_cwd_buf[:s.last_cwd_len]) if s.last_cwd_len > 0 else s.backend.cwd
	cs.cwd = strings.clone(cwd)
	backend_restore_core_session(&s.backend, cs)
	if !session_core.session_start_drain_loop(cs) {
		_ = session_core.session_registry_unregister(reg, cs.id)
		_ = backend_init_from_core_session(&s.backend, cs, sm.default_config, sm.default_theme)
		backend_set_notify_data_ready(&s.backend, sm.notify_user_data, sm.notify_data_ready_cb)
		backend_set_clipboard_callbacks(&s.backend, sm.clipboard_user_data, sm.clipboard_write_cb, sm.clipboard_read_cb)
		_ = backend_start_thread(&s.backend)
		session_core.session_destroy(cs)
		free(cs)
		for i in 0 ..< len(sm.tabs) {
			for j in 0 ..< threaded_count {
				if sm.tabs[i].id == threaded_ids[j] do _ = backend_start_thread(&sm.tabs[i].backend)
			}
		}
		return false
	}
	pane_tree_destroy(&s.tree)

	// 4. Remove tab from sm.tabs
	old_nodes: [MAX_TABS]rawptr
	old_backends: [MAX_TABS]^Backend
	for i in (idx + 1) ..< len(sm.tabs) {
		old_nodes[i] = &sm.tabs[i].tree.nodes[0]
		old_backends[i] = &sm.tabs[i].backend
	}

	ordered_remove(&sm.tabs, idx)

	for i in idx ..< len(sm.tabs) {
		_tab_rebase_tree(&sm.tabs[i], old_nodes[i + 1], old_backends[i + 1])
	}

	// 5. Restart other paused worker threads
	for i in 0 ..< len(sm.tabs) {
		for j in 0 ..< threaded_count {
			if sm.tabs[i].id == threaded_ids[j] {
				_ = backend_start_thread(&sm.tabs[i].backend)
				break
			}
		}
	}

	// 6. Adjust active index
	if len(sm.tabs) == 0 {
		sm.active_idx = -1
	} else if idx < sm.active_idx {
		sm.active_idx -= 1
	} else if idx == sm.active_idx {
		sm.active_idx = min(idx, len(sm.tabs) - 1)
	}

	// 7. If sm.tabs is empty, spawn fresh default shell tab so window stays usable
	if len(sm.tabs) == 0 {
		shell, _ := _resolve_shell()
		shell_argv := _resolve_shell_argv(shell)
		rows := sm.default_rows > 0 ? sm.default_rows : 24
		cols := sm.default_cols > 0 ? sm.default_cols : 80
		new_idx, spawn_ok := session_spawn(sm, shell, shell_argv, rows, cols, sm.default_config, sm.default_theme, sm.default_pixel_w, sm.default_pixel_h)
		if spawn_ok {
			sm.active_idx = new_idx
			new_b := tab_active_backend(&sm.tabs[new_idx])
			if sm.notify_data_ready_cb != nil {
				backend_set_notify_data_ready(new_b, sm.notify_user_data, sm.notify_data_ready_cb)
			}
			if sm.clipboard_read_cb != nil || sm.clipboard_write_cb != nil {
				backend_set_clipboard_callbacks(new_b, sm.clipboard_user_data, sm.clipboard_write_cb, sm.clipboard_read_cb)
			}
		}
	}

	// 8. Mark damage on active tab
	if sm.active_idx >= 0 && sm.active_idx < len(sm.tabs) {
		active_b := tab_active_backend(&sm.tabs[sm.active_idx])
		termgrid.damage_mark_all(&active_b.terminal.damage, nil)
		active_b.view_generation += 1
	}

	return true
}

// session_attach_tab re-attaches a persistent Core_Session into a new tab in sm.tabs.
// Connects backend, starts worker thread, synchronizes virtual grid to front terminal,
// marks damage for immediate display, and returns the new tab index.
session_attach_tab :: proc(sm: ^Session_Manager, persistent_session: ^session_core.Core_Session) -> (int, bool) {
	if sm == nil || persistent_session == nil {
		return -1, false
	}
	if len(sm.tabs) >= sm.max_tabs {
		return -1, false
	}

	// 1. Stop background drain thread on persistent_session
	session_core.session_stop_drain_loop(persistent_session)

	// Keep the registry owner until the attached backend successfully starts.
	// Unregister from registry if registered
	reg := sm.registry if sm.registry != nil else session_core.session_registry_default()

	// 2. Pause other threaded backends safely before mutating sm.tabs
	threaded_ids: [MAX_TABS]u32
	threaded_count := 0
	for i in 0 ..< len(sm.tabs) {
		if backend_is_threaded(&sm.tabs[i].backend) {
			backend_stop_thread(&sm.tabs[i].backend)
			if threaded_count < MAX_TABS {
				threaded_ids[threaded_count] = sm.tabs[i].id
				threaded_count += 1
			}
		}
	}

	// 3. Allocate new tab slot
	resize(&sm.tabs, len(sm.tabs) + 1)
	new_idx := len(sm.tabs) - 1
	tab := &sm.tabs[new_idx]
	tab.id = persistent_session.gui_tab_id if persistent_session.gui_tab_id > 0 else sm.next_id
	sm.next_id = max(sm.next_id + 1, tab.id + 1)
	tab.status = .Exited if persistent_session.pty_handle.state == .Exited else .Running
	tab.exit_code = i32(persistent_session.pty_handle.exit_code)
	tab.exit_signal = 0
	tab.title_len = copy(tab.title_buf[:], persistent_session.title_buf[:persistent_session.title_len])
	if tab.title_len == 0 do tab.title_len = session_sanitize_title(tab.title_buf[:], i18n.i18n_get().tab_untitled)
	tab.title_override_len = copy(tab.title_override_buf[:], persistent_session.title_override_buf[:persistent_session.title_override_len])
	tab.title_override_active = tab.title_override_len > 0
	tab.last_cwd_len = copy(tab.last_cwd_buf[:], persistent_session.cwd)

	// 4. Initialize backend transferring ownership from persistent_session
	b := &tab.backend
	if !backend_init_from_core_session(b, persistent_session, sm.default_config, sm.default_theme) {
		ordered_remove(&sm.tabs, new_idx)
		_ = session_core.session_start_drain_loop(persistent_session)
		for i in 0 ..< len(sm.tabs) {
			for j in 0 ..< threaded_count {
				if sm.tabs[i].id == threaded_ids[j] {
					_ = backend_start_thread(&sm.tabs[i].backend)
					break
				}
			}
		}
		return -1, false
	}


	_ = pane_tree_init(&tab.tree, &tab.backend)
	if tab.tree.root != nil {
		tab.tree.root.rows = b.terminal.grid.row_count
		tab.tree.root.cols = b.terminal.grid.col_count
	}

	// Wire notification & clipboard callbacks
	if sm.notify_data_ready_cb != nil {
		backend_set_notify_data_ready(b, sm.notify_user_data, sm.notify_data_ready_cb)
	}
	if sm.clipboard_read_cb != nil || sm.clipboard_write_cb != nil {
		backend_set_clipboard_callbacks(b, sm.clipboard_user_data, sm.clipboard_write_cb, sm.clipboard_read_cb)
	}

	// 5. Connect backend and start worker thread
	if !backend_start_thread(b) {
		pane_tree_destroy(&tab.tree)
		backend_restore_core_session(b, persistent_session)
		persistent_session.is_detached = true
		_ = session_core.session_start_drain_loop(persistent_session)
		ordered_remove(&sm.tabs, new_idx)
		for i in 0 ..< len(sm.tabs) {
			for j in 0 ..< threaded_count {
				if sm.tabs[i].id == threaded_ids[j] do _ = backend_start_thread(&sm.tabs[i].backend)
			}
		}
		return -1, false
	}
	_ = session_refresh_title(tab)
	if reg != nil do _ = session_core.session_registry_unregister(reg, persistent_session.id)
	session_core.session_destroy(persistent_session)
	free(persistent_session)

	// 6. Resume other tabs' worker threads
	for i in 0 ..< len(sm.tabs) {
		if i == new_idx do continue
		for j in 0 ..< threaded_count {
			if sm.tabs[i].id == threaded_ids[j] {
				_ = backend_start_thread(&sm.tabs[i].backend)
				break
			}
		}
	}

	if sm.active_idx < 0 {
		sm.active_idx = new_idx
	}

	return new_idx, true
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

	old_nodes: [MAX_TABS]rawptr
	old_backends: [MAX_TABS]^Backend
	for i in 0 ..< n {
		old_nodes[i] = &sm.tabs[i].tree.nodes[0]
		old_backends[i] = &sm.tabs[i].backend
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

	if from_idx < to_idx {
		for i in from_idx ..< to_idx {
			_tab_rebase_tree(&sm.tabs[i], old_nodes[i + 1], old_backends[i + 1])
		}
	} else {
		for i := from_idx; i > to_idx; i -= 1 {
			_tab_rebase_tree(&sm.tabs[i], old_nodes[i - 1], old_backends[i - 1])
		}
	}
	_tab_rebase_tree(&sm.tabs[to_idx], old_nodes[from_idx], old_backends[from_idx])

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

	s := &sm.tabs[idx]
	s.has_bell = false
	leaves: [MAX_PANE_NODES]^Pane_Node
	leaf_count := tab_leaf_panes(s, leaves[:])
	for i in 0 ..< leaf_count {
		if leaves[i] != nil {
			leaves[i].has_bell = false
		}
	}

	if idx == sm.active_idx do return true

	sm.active_idx = idx
	curr_b := tab_active_backend(s)

	if curr_b != nil {
		if !backend_is_threaded(curr_b) {
			termgrid.damage_mark_all(&curr_b.terminal.damage, nil)
		} else {
			sync.mutex_lock(&curr_b.swap_mutex)
			termgrid.damage_mark_all(&curr_b.front_terminal.damage, nil)
			sync.mutex_unlock(&curr_b.swap_mutex)
		}
		curr_b.view_generation += 1
	}
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
			if idx == sm.active_idx {
				s.has_bell = false
			}
			leaves: [MAX_PANE_NODES]^Pane_Node
			leaf_count := tab_leaf_panes(s, leaves[:])
			if leaf_count == 0 {
				if s.backend.pty.master >= 0 && !backend_is_threaded(&s.backend) {
					backend_drain_pty(&s.backend)
					if idx == sm.active_idx && _damage_cells(&s.backend.terminal) > 0 {
						any_damaged = true
					}
				}
				if session_refresh_title(s) do any_damaged = true
				if idx != sm.active_idx && s.backend.terminal.bell_event {
					s.has_bell = true
				}
				if backend_snapshot_exited(&s.backend) {
					_ = session_close_tab(sm, idx)
					any_damaged = true
					continue
				}
				idx += 1
				continue
			}

			tab_closed := false
			for i in 0 ..< leaf_count {
				leaf := leaves[i]
				if leaf != nil && idx == sm.active_idx {
					leaf.has_bell = false
				}
				b := leaf.backend
				if b == nil do continue

				if b.pty.master >= 0 && !backend_is_threaded(b) {
					backend_drain_pty(b)
					if idx == sm.active_idx && _damage_cells(&b.terminal) > 0 {
						any_damaged = true
					}
				}
				if backend_is_threaded(b) do backend_lock_render(b)
				snapshot := &b.front_terminal if backend_is_threaded(b) else &b.terminal
				if idx == sm.active_idx && _damage_cells(snapshot) > 0 do any_damaged = true
				if idx != sm.active_idx && snapshot.bell_event {
					s.has_bell = true
					leaf.has_bell = true
				}
				if backend_is_threaded(b) do backend_unlock_render(b)
				if backend_snapshot_exited(b) {
					if leaf.backend != nil {
						backend_destroy(leaf.backend)
						if leaf.backend != &s.backend {
							free(leaf.backend)
						}
						leaf.backend = nil
					}
					closed_last := pane_tree_close(&s.tree, leaf.id)
					if closed_last {
						_ = session_close_tab(sm, idx)
						any_damaged = true
						tab_closed = true
						break
					} else {
						// Invalidate dispatched dimensions on remaining leaves so _app_layout_ui re-dispatches full dimensions
						leaves_rem: [MAX_PANE_NODES]^Pane_Node
						rem_count := tab_leaf_panes(s, leaves_rem[:])
						for k in 0 ..< rem_count {
							if leaves_rem[k] != nil {
								leaves_rem[k].dispatched_rows = 0
								leaves_rem[k].dispatched_cols = 0
							}
						}
						active_b := tab_active_backend(s)
						if active_b != nil {
							if backend_is_threaded(active_b) do backend_lock_render(active_b)
							current := &active_b.front_terminal if backend_is_threaded(active_b) else &active_b.terminal
							termgrid.damage_mark_all(&current.damage, nil)
							if backend_is_threaded(active_b) do backend_unlock_render(active_b)
						}
						any_damaged = true
						break
					}
				}
			}

			if tab_closed do continue

			if session_refresh_title(s) do any_damaged = true
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

	b := tab_active_backend(s)
	if b == nil do b = &s.backend

	// Priority 2: Foreground process name via pty.pty_foreground_name(&b.pty, foreground[:])
	if len(candidate) == 0 {
		fg_name := foreground
		if len(fg_name) == 0 {
			fg_buf: [128]u8
			fn := pty.pty_foreground_name(&b.pty, fg_buf[:])
			if fn > 0 {
				fg_name = string(fg_buf[:fn])
			}
		}
		if len(fg_name) > 0 {
			candidate = fg_name
		}
	}

	// Priority 3: When at shell prompt (no active foreground child), use the shell process name or directory basename from b.cwd
	if len(candidate) == 0 {
		dir := cwd if len(cwd) > 0 else b.cwd
		if len(dir) > 0 {
			base := _path_basename(dir)
			if len(base) > 0 && base != "." {
				candidate = base
			}
		}
		if len(candidate) == 0 && len(b.prog) > 0 {
			shell_base := _path_basename(b.prog)
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
	b := tab_active_backend(s)
	if b == nil do b = &s.backend
	osc: [128]u8
	raw_cwd: [256]u8
	cwd: [128]u8
	foreground: [128]u8
	native_cwd: [4096]u8
	on, cn, fresh := backend_title_metadata(b, osc[:], raw_cwd[:])
	dn := session_decode_cwd(cwd[:], string(raw_cwd[:cn]))
	if dn == 0 {
		n := pty.pty_working_directory(&b.pty, native_cwd[:])
		dn = session_decode_cwd(cwd[:], string(native_cwd[:n]))
	}
	if dn == 0 do dn = session_sanitize_title(cwd[:], b.cwd)
	fn := pty.pty_foreground_name(&b.pty, foreground[:])
	return session_update_title(s, string(osc[:on]), string(cwd[:dn]), string(foreground[:fn]), fresh)
}
