package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import posix "core:sys/posix"

import cfg "../../config"
import sh "../../session_host"

global_host: sh.Session_Host

sig_handler :: proc "c" (sig: posix.Signal) {
	global_host.running = false
}

main :: proc() {
	cfg_data, _ := cfg.config_load()
	defer cfg.config_destroy(&cfg_data)

	socket_path := ""
	max_ws := cfg_data.max_workspaces
	for i := 1; i < len(os.args); i += 1 {
		arg := os.args[i]
		if arg == "--socket" && i + 1 < len(os.args) {
			socket_path = os.args[i + 1]
			i += 1
		} else if strings.has_prefix(arg, "--socket=") {
			socket_path = arg[len("--socket="):]
		} else if (arg == "--max-workspaces" || arg == "--workspaces") && i + 1 < len(os.args) {
			if parsed, ok := strconv.parse_int(os.args[i + 1]); ok && parsed > 0 {
				max_ws = max(1, min(parsed, 256))
			}
			i += 1
		} else if strings.has_prefix(arg, "--max-workspaces=") {
			if parsed, ok := strconv.parse_int(arg[len("--max-workspaces="):]); ok && parsed > 0 {
				max_ws = max(1, min(parsed, 256))
			}
		}
	}

	posix.signal(.SIGINT, sig_handler)
	posix.signal(.SIGTERM, sig_handler)
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)

	if !sh.host_init(&global_host, socket_path, max_ws) {
		fmt.eprintln("[term-host] Failed to initialize session host")
		os.exit(1)
	}
	defer sh.host_destroy(&global_host)

	fmt.printfln(
		"[term-host] Session host daemon running on %s (PID: %d, max_workspaces: %d)",
		global_host.hybrid_adapter.uds.server.socket_path,
		os.get_pid(),
		len(global_host.workspaces),
	)

	for global_host.running {
		sh.host_step(&global_host, 20)
	}
}
