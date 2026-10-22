package term

// Command-line options for the Term application shell.

import "core:fmt"
import "core:strconv"

Cli_Options :: struct {
	initial_cmd:      string, // -e: command typed into the initial shell
	telemetry_path:   string, // --telemetry: per-frame NDJSON stream
	grid_dump_dir:    string, // --grid-dump: grid snapshots on SIGUSR1 and exit
	blur_override:    int,    // 0 = no override, 1 = force disable (--no-blur), 2 = force enable (--blur)
	opacity_override: f32,    // -1.0 = no override, >= 0.0 = override (--opacity <val>)
	scroll_speed_override: f32, // -1.0 = no override, > 0.0 = override (--scroll-speed <val>)
	working_dir_override:  string, // -d, --working-directory: initial working directory
}

// app_parse_cli_args parses command-line arguments.
// Returns should_continue = false if the application handled -v or -h and should terminate.
app_parse_cli_args :: proc(args: []string) -> (opts: Cli_Options, should_continue: bool) {
	opts.opacity_override = -1.0
	opts.scroll_speed_override = -1.0
	for i := 1; i < len(args); i += 1 {
		arg := args[i]
		has_value := i + 1 < len(args)
		switch {
		case arg == "-v" || arg == "--version":
			fmt.printfln("Term %s (Modern Floating Card Compositor Architecture)", VERSION)
			return {}, false
		case arg == "-h" || arg == "--help":
			fmt.println("Usage: term [options]")
			fmt.println("  -d, --working-directory <dir> Initial working directory")
			fmt.println("  -e <cmd>             Execute command in initial shell")
			fmt.println("  --blur               Enable macOS native background blur (frosted glass)")
			fmt.println("  --no-blur            Disable background blur (opaque window)")
			fmt.println("  --opacity <0.0-1.0>  Window backdrop opacity (0.0 = pure blur, 1.0 = solid)")
			fmt.println("  --telemetry <file>   Stream per-frame metrics as NDJSON (summary on exit)")
			fmt.println("  --grid-dump <dir>    Write visible grid snapshots on SIGUSR1 and exit")
			fmt.println("  -v, --version        Print version information")
			fmt.println("  -h, --help           Show help")
			return {}, false
		case arg == "-e" && has_value:
			i += 1
			opts.initial_cmd = args[i]
		case (arg == "-d" || arg == "--working-directory") && has_value:
			i += 1
			opts.working_dir_override = args[i]
		case arg == "--blur":
			opts.blur_override = 2
		case arg == "--no-blur":
			opts.blur_override = 1
		case arg == "--opacity" && has_value:
			i += 1
			parsed, ok := strconv.parse_f32(args[i])
			if ok {
				opts.opacity_override = clamp(parsed, 0.0, 1.0)
			}
		case (arg == "-s" || arg == "--scroll-speed") && has_value:
			i += 1
			parsed, ok := strconv.parse_f32(args[i])
			if ok && parsed > 0.0 {
				opts.scroll_speed_override = parsed
			}
		case arg == "--telemetry" && has_value:
			i += 1
			opts.telemetry_path = args[i]
		case arg == "--grid-dump" && has_value:
			i += 1
			opts.grid_dump_dir = args[i]
		}
	}
	return opts, true
}
