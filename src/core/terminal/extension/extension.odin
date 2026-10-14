package terminal_extension

// Osc_Handler_Proc is called when a terminal parser encounters a finished OSC sequence.
// Return true if the extension handled the OSC command, false to allow fallthrough.
Osc_Handler_Proc :: #type proc(user_data: rawptr, osc_id: int, payload: string, term: rawptr) -> (handled: bool)

// Csi_Handler_Proc allows custom CSI extension interception (e.g. Kitty keyboard protocol).
Csi_Handler_Proc :: #type proc(user_data: rawptr, cmd: rune, params: []int, term: rawptr) -> (handled: bool)

// Osc_Handler_Registration maps a specific OSC ID (e.g. 52, 7, 8, 133) or -1 (wildcard) to a handler.
Osc_Handler_Registration :: struct {
	osc_id:    int,
	handler:   Osc_Handler_Proc,
	user_data: rawptr,
}

// Terminal_Extension defines a lifecycle-managed modular extension.
Terminal_Extension :: struct {
	name:       string,
	user_data:  rawptr,
	init:       proc(ext: ^Terminal_Extension, term: rawptr),
	handle_osc: proc(ext: ^Terminal_Extension, osc_id: int, payload: string, term: rawptr) -> bool,
	handle_csi: proc(ext: ^Terminal_Extension, cmd: rune, params: []int, term: rawptr) -> bool,
	deinit:     proc(ext: ^Terminal_Extension),
}

MAX_OSC_HANDLERS :: 16
MAX_EXTENSIONS   :: 8

// Terminal_Extension_Registry is an allocation-free registry stored directly inside Terminal.
Terminal_Extension_Registry :: struct {
	handlers:       [MAX_OSC_HANDLERS]Osc_Handler_Registration,
	handler_count:  int,
	extensions:     [MAX_EXTENSIONS]Terminal_Extension,
	ext_count:      int,
}

registry_init :: proc(reg: ^Terminal_Extension_Registry) {
	if reg == nil do return
	reg.handler_count = 0
	reg.ext_count = 0
}

registry_destroy :: proc(reg: ^Terminal_Extension_Registry) {
	if reg == nil do return
	for i in 0..<reg.ext_count {
		if reg.extensions[i].deinit != nil {
			reg.extensions[i].deinit(&reg.extensions[i])
		}
	}
	reg.handler_count = 0
	reg.ext_count = 0
}

// registry_register_osc registers a callback for a specific OSC ID or -1 (catch-all).
registry_register_osc :: proc(reg: ^Terminal_Extension_Registry, osc_id: int, handler: Osc_Handler_Proc, user_data: rawptr = nil) -> bool {
	if reg == nil || handler == nil do return false
	if reg.handler_count >= MAX_OSC_HANDLERS do return false

	reg.handlers[reg.handler_count] = Osc_Handler_Registration{
		osc_id    = osc_id,
		handler   = handler,
		user_data = user_data,
	}
	reg.handler_count += 1
	return true
}

// registry_register_extension registers a full modular extension.
registry_register_extension :: proc(reg: ^Terminal_Extension_Registry, ext: Terminal_Extension, term: rawptr) -> bool {
	if reg == nil do return false
	if reg.ext_count >= MAX_EXTENSIONS do return false

	reg.extensions[reg.ext_count] = ext
	e := &reg.extensions[reg.ext_count]
	reg.ext_count += 1

	if e.init != nil {
		e.init(e, term)
	}
	return true
}

// registry_dispatch_osc notifies all registered extensions and specific OSC handlers.
registry_dispatch_osc :: proc(reg: ^Terminal_Extension_Registry, osc_id: int, payload: string, term: rawptr) -> bool {
	if reg == nil do return false

	// 1. Dispatch to dedicated OSC handler registrations (exact match first)
	for i in 0..<reg.handler_count {
		entry := &reg.handlers[i]
		if entry.osc_id == osc_id {
			if entry.handler(entry.user_data, osc_id, payload, term) {
				return true
			}
		}
	}

	// 2. Dispatch to modular extensions
	for i in 0..<reg.ext_count {
		ext := &reg.extensions[i]
		if ext.handle_osc != nil {
			if ext.handle_osc(ext, osc_id, payload, term) {
				return true
			}
		}
	}

	// 3. Fallback to wildcard handlers (osc_id == -1)
	for i in 0..<reg.handler_count {
		entry := &reg.handlers[i]
		if entry.osc_id == -1 {
			if entry.handler(entry.user_data, osc_id, payload, term) {
				return true
			}
		}
	}

	return false
}

// registry_dispatch_csi notifies registered extensions of unhandled CSI commands.
registry_dispatch_csi :: proc(reg: ^Terminal_Extension_Registry, cmd: rune, params: []int, term: rawptr) -> bool {
	if reg == nil do return false
	for i in 0..<reg.ext_count {
		ext := &reg.extensions[i]
		if ext.handle_csi != nil {
			if ext.handle_csi(ext, cmd, params, term) {
				return true
			}
		}
	}
	return false
}
