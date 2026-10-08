package main

import "core:c"
import "core:os"
import "core:strings"

import ipc "../../session_ipc"

when ODIN_OS == .Darwin {
	foreign import monitor_bridge "system:AppKit.framework"

	@(default_calling_convention = "c")
	foreign monitor_bridge {
		term_monitor_run :: proc(socket_path: cstring) -> c.int ---
	}
}

main :: proc() {
	when ODIN_OS == .Darwin {
		socket_path := ""
		for i := 1; i < len(os.args); i += 1 {
			arg := os.args[i]
			if arg == "--socket" && i + 1 < len(os.args) {
				socket_path = os.args[i + 1]
				i += 1
			} else if strings.has_prefix(arg, "--socket=") {
				socket_path = arg[len("--socket="):]
			}
		}

		if len(socket_path) == 0 {
			if def_path, ok := ipc.resolve_default_socket_path(context.temp_allocator); ok {
				socket_path = def_path
			}
		}

		c_path := strings.clone_to_cstring(socket_path, context.temp_allocator)
		term_monitor_run(c_path)
	} else {
		os.exit(1)
	}
}
