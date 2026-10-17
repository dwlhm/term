package term

// Command-line options for the Term application shell.

import "core:fmt"

Cli_Options :: struct {
	initial_cmd:    string, // -e: command typed into the initial shell
	telemetry_path: string, // --telemetry: per-frame NDJSON stream
	grid_dump_dir:  string, // --grid-dump: grid snapshots on SIGUSR1 and exit
}

// app_parse_cli_args parses command-line arguments.
// Returns should_continue = false if the application handled -v or -h and should terminate.
app_parse_cli_args :: proc(args: []string) -> (opts: Cli_Options, should_continue: bool) {
	for i := 1; i < len(args); i += 1 {
		arg := args[i]
		has_value := i + 1 < len(args)
		switch {
		case arg == "-v" || arg == "--version":
			fmt.printfln("Term %s (Modern Floating Card Compositor Architecture)", VERSION)
			return {}, false
		case arg == "-h" || arg == "--help":
			fmt.println("Usage: term [options]")
			fmt.println("  -e <cmd>             Execute command in initial shell")
			fmt.println("  --telemetry <file>   Stream per-frame metrics as NDJSON (summary on exit)")
			fmt.println("  --grid-dump <dir>    Write visible grid snapshots on SIGUSR1 and exit")
			fmt.println("  -v, --version        Print version information")
			fmt.println("  -h, --help           Show help")
			return {}, false
		case arg == "-e" && has_value:
			i += 1
			opts.initial_cmd = args[i]
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
