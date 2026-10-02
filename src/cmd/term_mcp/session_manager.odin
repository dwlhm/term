package main

import "core:fmt"
import "core:strings"
import "core:sync"

import session_core "../../session_core"

// Global session counter for unique session ID generation
@(private="file")
_session_counter: int

// Session_Status_Info describes the current runtime state of a session.
Session_Status_Info :: struct {
	id:            string,
	is_active:     bool,
	is_busy:       bool,
	active_cmd:    string,
	cwd:           string,
	command_count: int,
}

// Session_Manager coordinates multi-session PTY lifecycles with isolation and concurrency safety.
Session_Manager :: struct {
	sessions:          map[string]^Mcp_Session,
	active_session_id: string,
	max_sessions:      int,
	lock:              sync.Mutex,
}

// session_manager_init initializes the session map and synchronization primitive.
session_manager_init :: proc(sm: ^Session_Manager) {
	if sm == nil {
		return
	}
	sm.sessions = make(map[string]^Mcp_Session)
	sm.active_session_id = ""
	sm.max_sessions = 8
}

// session_manager_create allocates and spawns a new isolated PTY terminal session.
session_manager_create :: proc(sm: ^Session_Manager, rows: int = 0, cols: int = 0, shell: string = "", cwd: string = "", mode: session_core.Session_Mode = .Fast_Headless) -> (string, ^Mcp_Session, bool) {
	if sm == nil {
		return "", nil, false
	}
	sync.mutex_lock(&sm.lock)
	defer sync.mutex_unlock(&sm.lock)

	max_cap := sm.max_sessions if sm.max_sessions > 0 else 8
	if len(sm.sessions) >= max_cap {
		return "", nil, false
	}

	count := sync.atomic_add(&_session_counter, 1)
	id := fmt.aprintf("session_%04x", count)

	s, ok := mcp_session_create(id, rows, cols, shell, cwd, mode)
	if !ok {
		delete(id)
		return "", nil, false
	}

	sm.sessions[id] = s
	if len(sm.active_session_id) == 0 {
		sm.active_session_id = strings.clone(id)
	}
	return id, s, true
}

// session_manager_get looks up an active session by its unique identifier.
session_manager_get :: proc(sm: ^Session_Manager, id: string) -> (^Mcp_Session, bool) {
	if sm == nil || len(id) == 0 {
		return nil, false
	}
	sync.mutex_lock(&sm.lock)
	defer sync.mutex_unlock(&sm.lock)

	s, found := sm.sessions[id]
	return s, found
}

// session_manager_route_auto routes to an idle active session or auto-creates an auxiliary session.
session_manager_route_auto :: proc(sm: ^Session_Manager) -> (id: string, s: ^Mcp_Session, ok: bool) {
	if sm == nil {
		return "", nil, false
	}
	sync.mutex_lock(&sm.lock)
	defer sync.mutex_unlock(&sm.lock)

	// 1. If len(sm.sessions) == 0: auto-create "default", set as active_session_id, return it.
	if len(sm.sessions) == 0 {
		def_id := strings.clone("default")
		def_s, create_ok := mcp_session_create(def_id)
		if !create_ok {
			delete(def_id)
			return "", nil, false
		}
		sm.sessions[def_id] = def_s
		if len(sm.active_session_id) > 0 do delete(sm.active_session_id)
		sm.active_session_id = strings.clone(def_id)
		return sm.active_session_id, def_s, true
	}

	// 2. If active_session_id in sm.sessions:
	// If !sm.sessions[active_session_id].is_busy: return active_session_id, session.
	if len(sm.active_session_id) > 0 {
		if act_s, exists := sm.sessions[sm.active_session_id]; exists {
			if !act_s.is_busy {
				return sm.active_session_id, act_s, true
			}
		}
	}

	// 3. If active is busy: search other sessions in sm.sessions for an idle one (!s.is_busy).
	// If found, set as active_session_id and return.
	for sid, sess in sm.sessions {
		if !sess.is_busy {
			if len(sm.active_session_id) > 0 do delete(sm.active_session_id)
			sm.active_session_id = strings.clone(sid)
			return sm.active_session_id, sess, true
		}
	}

	// 4. If all are busy and len(sm.sessions) < sm.max_sessions:
	// Parent cwd is current active session's cwd.
	// Auto-create new session (e.g. session_%04x), set cwd = parent_cwd, set as active_session_id, and return.
	max_cap := sm.max_sessions if sm.max_sessions > 0 else 8
	if len(sm.sessions) < max_cap {
		parent_cwd := ""
		if len(sm.active_session_id) > 0 {
			if act_s, exists := sm.sessions[sm.active_session_id]; exists {
				parent_cwd = act_s.cwd
			}
		}

		count := sync.atomic_add(&_session_counter, 1)
		new_id := fmt.aprintf("session_%04x", count)
		new_s, create_ok := mcp_session_create(new_id, cwd = parent_cwd)
		if !create_ok {
			delete(new_id)
			return "", nil, false
		}

		sm.sessions[new_id] = new_s
		if len(sm.active_session_id) > 0 do delete(sm.active_session_id)
		sm.active_session_id = strings.clone(new_id)
		return sm.active_session_id, new_s, true
	}

	// 5. If pool full and all busy: return active session.
	if len(sm.active_session_id) > 0 {
		if act_s, exists := sm.sessions[sm.active_session_id]; exists {
			return sm.active_session_id, act_s, true
		}
	}

	return "", nil, false
}

// session_manager_get_or_route resolves target_id or falls back to smart auto routing.
session_manager_get_or_route :: proc(sm: ^Session_Manager, target_id: string) -> (id_used: string, s: ^Mcp_Session, ok: bool) {
	if sm == nil {
		return "", nil, false
	}

	if len(target_id) == 0 || target_id == "auto" {
		return session_manager_route_auto(sm)
	}

	sync.mutex_lock(&sm.lock)
	defer sync.mutex_unlock(&sm.lock)

	if target_s, exists := sm.sessions[target_id]; exists {
		return target_id, target_s, true
	}

	max_cap := sm.max_sessions if sm.max_sessions > 0 else 8
	if len(sm.sessions) < max_cap {
		parent_cwd := ""
		if len(sm.active_session_id) > 0 {
			if act_s, exists := sm.sessions[sm.active_session_id]; exists {
				parent_cwd = act_s.cwd
			}
		}

		id_clone := strings.clone(target_id)
		new_s, create_ok := mcp_session_create(id_clone, cwd = parent_cwd)
		if !create_ok {
			delete(id_clone)
			return "", nil, false
		}

		sm.sessions[id_clone] = new_s
		if len(sm.active_session_id) > 0 do delete(sm.active_session_id)
		sm.active_session_id = strings.clone(id_clone)
		return id_clone, new_s, true
	}

	return "", nil, false
}

// session_manager_list_sessions returns status information for all managed sessions.
session_manager_list_sessions :: proc(sm: ^Session_Manager, allocator := context.allocator) -> []Session_Status_Info {
	if sm == nil do return nil
	sync.mutex_lock(&sm.lock)
	defer sync.mutex_unlock(&sm.lock)

	res := make([]Session_Status_Info, len(sm.sessions), allocator)
	idx := 0
	for id, s in sm.sessions {
		info: Session_Status_Info
		info.id = strings.clone(id, allocator)
		info.is_active = (id == sm.active_session_id)
		info.is_busy = s.is_busy
		info.active_cmd = strings.clone(s.active_cmd, allocator) if len(s.active_cmd) > 0 else ""
		info.cwd = strings.clone(s.cwd, allocator) if len(s.cwd) > 0 else ""
		info.command_count = len(s.command_history)
		res[idx] = info
		idx += 1
	}
	return res
}

// session_manager_switch_active explicitly designates the active session.
session_manager_switch_active :: proc(sm: ^Session_Manager, id: string) -> bool {
	if sm == nil || len(id) == 0 do return false
	sync.mutex_lock(&sm.lock)
	defer sync.mutex_unlock(&sm.lock)

	if id in sm.sessions {
		if sm.active_session_id != id {
			if len(sm.active_session_id) > 0 do delete(sm.active_session_id)
			sm.active_session_id = strings.clone(id)
		}
		return true
	}
	return false
}

// session_manager_close closes an active session, reaps its child processes, and cleans up resources.
session_manager_close :: proc(sm: ^Session_Manager, id: string) -> bool {
	if sm == nil || len(id) == 0 {
		return false
	}
	sync.mutex_lock(&sm.lock)
	defer sync.mutex_unlock(&sm.lock)

	s, found := sm.sessions[id]
	if !found {
		return false
	}

	for stored_id in sm.sessions {
		if stored_id == id {
			delete_key(&sm.sessions, stored_id)
			delete(stored_id)
			break
		}
	}
	if sm.active_session_id == id {
		delete(sm.active_session_id)
		sm.active_session_id = ""
		for remaining_id in sm.sessions {
			sm.active_session_id = strings.clone(remaining_id)
			break
		}
	}
	mcp_session_destroy(s)
	free(s)
	return true
}

// session_manager_destroy_all shuts down all active sessions, killing child processes cleanly.
session_manager_destroy_all :: proc(sm: ^Session_Manager) {
	if sm == nil {
		return
	}
	sync.mutex_lock(&sm.lock)
	defer sync.mutex_unlock(&sm.lock)

	for id, s in sm.sessions {
		mcp_session_destroy(s)
		free(s)
		delete(id)
	}
	clear(&sm.sessions)
	delete(sm.sessions)
	sm.sessions = nil
	if len(sm.active_session_id) > 0 {
		delete(sm.active_session_id)
		sm.active_session_id = ""
	}
}
