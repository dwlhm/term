package feature_session

// Detached Background Session Registry
// Feature Composition Layer (src/features/session/*).
//
// Invariant: Manages sessions that run detached from visible GUI windows.
// Non-blocking PTY background drain preserves child processes without GPU work.

import "base:runtime"
import "core:strings"

Detached_Session_Entry :: struct {
	id:      u32,
	tab_id:  u32,
	title:   string,
	session: ^Terminal_Session,
}

Session_Registry :: struct {
	entries:   [dynamic]Detached_Session_Entry,
	allocator: runtime.Allocator,
}

session_registry_init :: proc(reg: ^Session_Registry, allocator := context.allocator) {
	if reg == nil do return
	reg.allocator = allocator
	reg.entries = make([dynamic]Detached_Session_Entry, allocator)
}

session_registry_destroy :: proc(reg: ^Session_Registry) {
	if reg == nil do return
	for &entry in reg.entries {
		if entry.session != nil {
			session_destroy(entry.session)
			entry.session = nil
		}
		if len(entry.title) > 0 {
			delete(entry.title, reg.allocator)
			entry.title = ""
		}
	}
	delete(reg.entries)
	reg.entries = nil
}

session_registry_detach :: proc(reg: ^Session_Registry, id, tab_id: u32, title: string, sess: ^Terminal_Session) -> bool {
	if reg == nil || sess == nil do return false
	entry := Detached_Session_Entry{
		id      = id,
		tab_id  = tab_id,
		title   = strings.clone(title, reg.allocator),
		session = sess,
	}
	append(&reg.entries, entry)
	return true
}

session_registry_pop :: proc(reg: ^Session_Registry, id: u32) -> (sess: ^Terminal_Session, found: bool) {
	if reg == nil do return nil, false
	for i in 0..<len(reg.entries) {
		if reg.entries[i].id == id {
			entry := reg.entries[i]
			ordered_remove(&reg.entries, i)
			if len(entry.title) > 0 do delete(entry.title, reg.allocator)
			return entry.session, true
		}
	}
	return nil, false
}

// session_registry_drain_all drains PTY output for all background sessions without invoking GPU render passes.
session_registry_drain_all :: proc(reg: ^Session_Registry) -> (total_drained: int) {
	if reg == nil do return 0
	for &entry in reg.entries {
		if entry.session != nil {
			total_drained += session_drain(entry.session)
		}
	}
	return total_drained
}

session_registry_count :: proc(reg: ^Session_Registry) -> int {
	if reg == nil do return 0
	return len(reg.entries)
}
