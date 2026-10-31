package feature_session

// Detached Background Session Registry
// Feature Composition Layer (src/features/session/*).
//
// Invariant: Owns every session that is not bound to a visible pane. Entries
// live until attached (pop) or removed (remove); an exited child keeps its
// entry in state .Exited so the user can still notice and dismiss it.

import "base:runtime"

Detached_Session_State :: enum u8 {
	Idle,   // shell at prompt, nothing running
	Busy,   // foreground job running (session_is_running_job)
	Exited, // child process has exited; PTY is dead
}

Detached_Session_Entry :: struct {
	id:        u32,
	session:   ^Terminal_Session,
	state:     Detached_Session_State, // last value computed by session_registry_poll
	attention: bool,                   // set on Busy→Idle or any→Exited; cleared by clear_attention
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
	}
	delete(reg.entries)
	reg.entries = nil
}

// session_registry_detach takes ownership of sess. Initial state is computed
// immediately (same rules as poll with had_output = true), attention = false.
session_registry_detach :: proc(reg: ^Session_Registry, id: u32, sess: ^Terminal_Session) -> bool {
	if reg == nil || sess == nil do return false
	append(&reg.entries, Detached_Session_Entry{id = id, session = sess})
	return true
}

// session_registry_pop releases ownership of a live entry to the caller.
// Returns found = false for unknown ids AND for .Exited entries (a dead
// session must be dismissed with remove, never attached).
session_registry_pop :: proc(reg: ^Session_Registry, id: u32) -> (sess: ^Terminal_Session, found: bool) {
	if reg == nil do return nil, false
	for i in 0..<len(reg.entries) {
		if reg.entries[i].id == id {
			entry := reg.entries[i]
			ordered_remove(&reg.entries, i)
			return entry.session, true
		}
	}
	return nil, false
}

// session_registry_remove destroys the entry's session (kills the child via
// session_destroy) and removes it. Works for any state. false if id unknown.
session_registry_remove :: proc(reg: ^Session_Registry, id: u32) -> bool {
	unimplemented("T1")
}

// session_registry_find returns a pointer into entries (invalidated by any
// detach/pop/remove) or nil.
session_registry_find :: proc(reg: ^Session_Registry, id: u32) -> ^Detached_Session_Entry {
	unimplemented("T1")
}

// session_registry_poll recomputes every entry's state. Exited is detected
// with session_is_alive (a field read, always checked). Busy/Idle uses
// session_is_running_job, which may issue a syscall, so it is only
// re-evaluated when had_output is true. Sets attention on Busy→Idle and on
// any transition into .Exited. Returns true if any state or attention changed.
session_registry_poll :: proc(reg: ^Session_Registry, had_output: bool) -> (changed: bool) {
	unimplemented("T1")
}

session_registry_attention_count :: proc(reg: ^Session_Registry) -> int {
	unimplemented("T1")
}

// session_registry_clear_attention resets attention on all entries; returns
// true if any flag was set.
session_registry_clear_attention :: proc(reg: ^Session_Registry) -> bool {
	unimplemented("T1")
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
