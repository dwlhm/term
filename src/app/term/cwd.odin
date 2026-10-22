package term

// Term Working Directory & Launcher Detection
// Part of Tier 3 Application Shell (src/app/term/*).

import "core:os"
import "core:strings"
import posix "core:sys/posix"

// app_get_process_cwd queries the current working directory of the process via POSIX getcwd.
app_get_process_cwd :: proc(allocator := context.temp_allocator) -> string {
	buf: [1024]u8
	c_str := posix.getcwd(raw_data(buf[:]), len(buf))
	if c_str != nil {
		return strings.clone(string(c_str), allocator)
	}
	return ""
}

// app_is_launched_from_launcher detects if Term was invoked directly by macOS GUI
// launcher (Spotlight, Raycast, Alfred, Finder, Dock, or `open -a Term`).
// On macOS, LaunchServices sets working directory to "/" and stdin is not a terminal.
app_is_launched_from_launcher :: proc() -> bool {
	cur := app_get_process_cwd()
	if cur == "/" do return true
	when ODIN_OS == .Darwin {
		is_bundle := len(os.args) > 0 && strings.contains(os.args[0], ".app")
		if is_bundle && !posix.isatty(posix.STDIN_FILENO) {
			return true
		}
	}
	return false
}

// app_resolve_initial_cwd evaluates the startup working directory with precedence:
// 1. Explicit CLI override (-d, --working-directory)
// 2. Explicit user config override (config.json "working_directory")
// 3. Launcher detection: if launched from launcher or in "/", default to user $HOME (~)
// 4. Fallback to current working directory (e.g. interactive terminal CLI invocation)
app_resolve_initial_cwd :: proc(cfg: ^App_Config, opts: Cli_Options) -> string {
	// 1. Explicit CLI override
	if len(opts.working_dir_override) > 0 {
		return config_expand_path(opts.working_dir_override)
	}

	// 2. Explicit configuration file override
	if cfg != nil {
		if cfg_cwd := config_resolve_working_directory(cfg); len(cfg_cwd) > 0 {
			return cfg_cwd
		}
	}

	// 3. macOS GUI launcher launch
	if app_is_launched_from_launcher() {
		home := os.get_env("HOME", context.temp_allocator)
		if len(home) > 0 do return home
	}

	// 4. Inherited directory from parent process
	cur := app_get_process_cwd()
	if cur == "/" {
		home := os.get_env("HOME", context.temp_allocator)
		if len(home) > 0 do return home
	}
	return cur
}
