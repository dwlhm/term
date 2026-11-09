package term

// Argument parsing for `term session read` (spec 4.4, RD1–RD24, T1–T27).
// Parses -n, --last, --clean, --elements, --tail, --until, --prompt, --exit,
// --idle, --quiet, -t, and --output.

import "core:fmt"
import "core:strconv"
import "core:strings"

Cli_Read_Options :: struct {
	id:          u32,
	lines:       u32,
	last:        bool,
	clean:       bool,
	elements:    bool,
	as_json:     bool,
	tail:        bool,
	until:       string,
	until_new:   bool,
	has_until:   bool,
	prompt:      bool,
	exit:        bool,
	idle:        bool,
	quiet_sec:   f64,
	has_quiet:   bool,
	timeout_sec: f64,
	err_msg:     string,
}

app_cli_parse_read :: proc(
	args: []string,
) -> (opts: Cli_Read_Options, ok: bool) {
	i := 0
	has_id := false
	for i < len(args) {
		a := args[i]
		if strings.has_prefix(a, "-") {
			if !_parse_read_flag(args, &i, &opts) do return opts, false
		} else {
			if !_parse_read_target(a, &opts, &has_id) do return opts, false
		}
		i += 1
	}

	if !has_id {
		self_id, inside := app_agent_self_id()
		if !inside {
			opts.err_msg = "which session? read <id>"
			return opts, false
		}
		opts.id = self_id
	}
	return opts, _validate_read_opts(&opts)
}

@(private = "file")
_validate_read_opts :: proc(opts: ^Cli_Read_Options) -> bool {
	conds := (1 if opts.has_until else 0) +
	         (1 if opts.prompt else 0) +
	         (1 if opts.exit else 0) +
	         (1 if opts.idle else 0) +
	         (1 if opts.has_quiet else 0)
	if conds > 1 {
		opts.err_msg = "give one condition"
		return false
	}
	if conds > 0 && !opts.tail {
		if opts.has_until do opts.err_msg = "--until needs --tail"
		else if opts.prompt do opts.err_msg = "--prompt needs --tail"
		else if opts.exit do opts.err_msg = "--exit needs --tail"
		else if opts.idle do opts.err_msg = "--idle needs --tail"
		else if opts.has_quiet do opts.err_msg = "--quiet needs --tail"
		return false
	}
	if opts.tail && (opts.last || opts.elements) {
		opts.err_msg = "--tail follows the screen: not with --last/--elements"
		return false
	}
	return true
}

@(private = "file")
_parse_cond_flag :: proc(
	args: []string,
	i: ^int,
	opts: ^Cli_Read_Options,
) -> (bool, bool) {
	a := args[i^]
	switch a {
	case "--until":  return _parse_until(args, i, opts), true
	case "--new":    opts.until_new = true; return true, true
	case "--prompt": opts.prompt = true; return true, true
	case "--exit":   opts.exit = true; return true, true
	case "--idle":   opts.idle = true; return true, true
	case "--quiet":  return _parse_quiet(args, i, opts), true
	}
	return false, false
}

@(private = "file")
_parse_read_flag :: proc(
	args: []string,
	i: ^int,
	opts: ^Cli_Read_Options,
) -> bool {
	a := args[i^]
	if ok, matched := _parse_cond_flag(args, i, opts); matched do return ok
	switch {
	case a == "-n":
		return _parse_lines(args, i, opts)
	case a == "--last":
		opts.last = true
	case a == "--clean":
		opts.clean = true
	case a == "--elements":
		opts.elements = true
	case a == "--tail":
		opts.tail = true
	case a == "-t" || a == "--timeout":
		return _parse_timeout(args, i, opts)
	case a == "--json":
		opts.as_json = true
	case a == "--output":
		return _parse_output_arg(args, i, opts)
	case strings.has_prefix(a, "--output="):
		return _parse_output_val(a[len("--output="):], opts)
	case:
		opts.err_msg = fmt.tprintf("unknown option '%s'", a)
		return false
	}
	return true
}

@(private = "file")
_parse_lines :: proc(args: []string, i: ^int, opts: ^Cli_Read_Options) -> bool {
	i^ += 1
	if i^ >= len(args) {
		opts.err_msg = "-n takes a number of lines"
		return false
	}
	val, ok := strconv.parse_int(args[i^])
	if !ok || val < 0 {
		opts.err_msg = "-n takes a number of lines"
		return false
	}
	opts.lines = u32(val)
	return true
}

@(private = "file")
_parse_until :: proc(
	args: []string,
	i: ^int,
	opts: ^Cli_Read_Options,
) -> bool {
	i^ += 1
	if i^ >= len(args) {
		opts.err_msg = "--until takes a string"
		return false
	}
	opts.has_until = true
	opts.until = args[i^]
	if i^ + 1 < len(args) && args[i^ + 1] == "--new" {
		opts.until_new = true
		i^ += 1
	}
	return true
}

@(private = "file")
_parse_quiet :: proc(
	args: []string,
	i: ^int,
	opts: ^Cli_Read_Options,
) -> bool {
	i^ += 1
	if i^ >= len(args) {
		opts.err_msg = "--quiet takes seconds"
		return false
	}
	val, ok := strconv.parse_f64(args[i^])
	if !ok || val <= 0 {
		opts.err_msg = "--quiet takes seconds"
		return false
	}
	opts.has_quiet = true
	opts.quiet_sec = val
	return true
}

@(private = "file")
_parse_timeout :: proc(
	args: []string,
	i: ^int,
	opts: ^Cli_Read_Options,
) -> bool {
	i^ += 1
	if i^ >= len(args) {
		opts.err_msg = "-t takes seconds"
		return false
	}
	val, ok := strconv.parse_f64(args[i^])
	if !ok || val <= 0 {
		opts.err_msg = "-t takes seconds"
		return false
	}
	opts.timeout_sec = val
	return true
}

@(private = "file")
_parse_output_arg :: proc(
	args: []string,
	i: ^int,
	opts: ^Cli_Read_Options,
) -> bool {
	i^ += 1
	if i^ >= len(args) || (args[i^] != "json" && args[i^] != "text") {
		opts.err_msg = "--output takes text or json"
		return false
	}
	opts.as_json = args[i^] == "json"
	return true
}

@(private = "file")
_parse_output_val :: proc(val: string, opts: ^Cli_Read_Options) -> bool {
	if val != "json" && val != "text" {
		opts.err_msg = "--output takes text or json"
		return false
	}
	opts.as_json = val == "json"
	return true
}
