package main

import "core:fmt"
import "core:strings"
import "core:sync"

import session_core "../../session_core"

// Global session counter for unique session ID generation
@(private="file")
_session_counter: int

// Session_Manager coordinates multi-session PTY lifecycles with isolation and concurrency safety.
Session_Manager :: struct {
	sessions: map[string]^Mcp_Session,
	lock:     sync.Mutex,
}

// session_manager_init initializes the session map and synchronization primitive.
session_manager_init :: proc(sm: ^Session_Manager) {
	if sm == nil {
		return
	}
	sm.sessions = make(map[string]^Mcp_Session)
}

// session_manager_create allocates and spawns a new isolated PTY terminal session.
session_manager_create :: proc(sm: ^Session_Manager, rows: int = 0, cols: int = 0, shell: string = "", cwd: string = "", mode: session_core.Session_Mode = .Fast_Headless) -> (string, ^Mcp_Session, bool) {
	if sm == nil {
		return "", nil, false
	}
	sync.mutex_lock(&sm.lock)
	defer sync.mutex_unlock(&sm.lock)

	count := sync.atomic_add(&_session_counter, 1)
	id := fmt.aprintf("session_%04x", count)

	s, ok := mcp_session_create(id, rows, cols, shell, cwd, mode)
	if !ok {
		delete(id)
		return "", nil, false
	}

	sm.sessions[id] = s
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
}
