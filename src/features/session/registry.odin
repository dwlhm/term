package feature_session

// Background Session Registry: the viewer's mirror of the core's sessions that
// no pane of this viewer shows. The core owns them (they keep running with no
// viewer at all); entries are refreshed from its rows (EVENT / SESSIONS) and
// dropped when the core removes the session or this viewer attaches it.

import "base:runtime"
import ipc "../../platform/ipc"

Detached_Session_State :: enum u8 {
	Idle,   // shell at prompt, nothing running
	Busy,   // a CLI/TUI runs in the foreground
	Exited, // the program has exited
}

Detached_Session_Entry :: struct {
	id:        u32,
	state:     Detached_Session_State,
	attention: bool, // set on Busy→Idle or any→Exited; cleared by clear_attention
	pid:       u32,
	elapsed_s: u32,
	title:     Registry_Text,
	process:   Registry_Text,
	cwd:       Registry_Text,
	status:    Registry_Text,
}

Registry_Text :: struct {
	buf: [256]u8,
	len: int,
}

Session_Registry :: struct {
	entries:   [dynamic]Detached_Session_Entry,
	allocator: runtime.Allocator,
}

registry_text :: proc(t: ^Registry_Text) -> string { return string(t.buf[:t.len]) }

@(private = "file")
_set_text :: proc(t: ^Registry_Text, s: string) { t.len = copy(t.buf[:], s) }

session_registry_init :: proc(reg: ^Session_Registry, allocator := context.allocator) {
	if reg == nil do return
	reg.allocator = allocator
	reg.entries = make([dynamic]Detached_Session_Entry, allocator)
}

session_registry_destroy :: proc(reg: ^Session_Registry) {
	if reg == nil do return
	delete(reg.entries)
	reg.entries = nil
}

// session_registry_apply_row mirrors one core row. shown_here = a pane of this
// viewer shows it (not a background session). Returns true if anything changed.
session_registry_apply_row :: proc(reg: ^Session_Registry, row: ipc.Session_Row, shown_here: bool) -> bool {
	if reg == nil do return false
	if shown_here do return session_registry_remove(reg, row.id)
	state: Detached_Session_State
	switch row.state {
	case .Idle:   state = .Idle
	case .Busy:   state = .Busy
	case .Exited: state = .Exited
	}
	e := session_registry_find(reg, row.id)
	if e == nil {
		append(&reg.entries, Detached_Session_Entry{id = row.id, state = state})
		e = &reg.entries[len(reg.entries) - 1]
	} else if e.state != state && (state == .Exited || (e.state == .Busy && state == .Idle)) {
		e.attention = true
	}
	e.state, e.pid, e.elapsed_s = state, row.pid, row.elapsed_s
	_set_text(&e.title, row.title)
	_set_text(&e.process, row.process)
	_set_text(&e.cwd, row.cwd)
	_set_text(&e.status, row.status)
	return true
}

// session_registry_remove drops id's entry; true if it existed.
session_registry_remove :: proc(reg: ^Session_Registry, id: u32) -> bool {
	if reg == nil do return false
	for i in 0..<len(reg.entries) {
		if reg.entries[i].id == id {
			ordered_remove(&reg.entries, i)
			return true
		}
	}
	return false
}

// session_registry_find returns a pointer into entries (invalidated by any
// apply/remove) or nil.
session_registry_find :: proc(reg: ^Session_Registry, id: u32) -> ^Detached_Session_Entry {
	if reg == nil do return nil
	for &e in reg.entries do if e.id == id do return &e
	return nil
}

session_registry_attention_count :: proc(reg: ^Session_Registry) -> int {
	if reg == nil do return 0
	count := 0
	for entry in reg.entries do if entry.attention do count += 1
	return count
}

// session_registry_clear_attention resets attention on all entries; returns
// true if any flag was set.
session_registry_clear_attention :: proc(reg: ^Session_Registry) -> bool {
	if reg == nil do return false
	had_attention := session_registry_attention_count(reg) > 0
	for &entry in reg.entries do entry.attention = false
	return had_attention
}

session_registry_count :: proc(reg: ^Session_Registry) -> int {
	return len(reg.entries) if reg != nil else 0
}
