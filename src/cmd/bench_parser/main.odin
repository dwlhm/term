package main

// Parser + grid throughput benchmark: feeds synthetic output streams straight
// into terminal_feed_bytes (no PTY, IPC or GPU) and reports ns per byte and per
// op. Damage is consumed every chunk, the way a frame would.
// Usage: bench_parser [--rows N] [--cols N] [--seconds S] [--only name]

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"

import terminal "../../core/terminal"

CHUNK :: 64 * 1024

Options :: struct {
	rows, cols: int,
	seconds:    f64,
	only:       string,
}

main :: proc() {
	opts, ok := _parse_args(os.args[1:])
	if !ok {
		fmt.eprintln("usage: bench_parser [--rows N] [--cols N] [--seconds S] [--only name]")
		os.exit(2)
	}
	fmt.printfln("grid %dx%d, %.1fs per workload", opts.rows, opts.cols, opts.seconds)
	fmt.printfln("%-12s %10s %10s %12s", "workload", "MB/s", "ns/byte", "ns/op")
	for w in workloads_make(opts.rows, opts.cols) {
		if opts.only != "" && opts.only != w.name do continue
		mbps, ns_byte, ns_op := _run(w, opts)
		// Odin zero-pads width-formatted floats, so pad the rendered strings instead.
		fmt.printfln("%-12s %10s %10s %12s", w.name, fmt.tprintf("%.1f", mbps), fmt.tprintf("%.2f", ns_byte), fmt.tprintf("%.1f/%s", ns_op, w.unit))
	}
}

// _run feeds the workload repeatedly into a fresh terminal for opts.seconds.
_run :: proc(w: Workload, opts: Options) -> (mbps, ns_byte, ns_op: f64) {
	t := new(terminal.Terminal)
	defer free(t)
	terminal.terminal_init(t, opts.rows, opts.cols)
	defer terminal.terminal_destroy(t)

	_feed(t, w.data) // warm-up pass: first-touch page faults and caches
	start := time.tick_now()
	passes := 0
	for time.duration_seconds(time.tick_since(start)) < opts.seconds {
		_feed(t, w.data)
		passes += 1
	}
	ns := f64(time.duration_nanoseconds(time.tick_since(start)))
	bytes := f64(passes * len(w.data))
	return bytes / ns * 1e3, ns / bytes, ns / f64(passes * w.units)
}

_feed :: proc(t: ^terminal.Terminal, data: []u8) {
	for off := 0; off < len(data); off += CHUNK {
		terminal.terminal_feed_bytes(t, data[off:min(off + CHUNK, len(data))])
		_ = terminal.terminal_consume_damage(t)
	}
}

_parse_args :: proc(args: []string) -> (opts: Options, ok: bool) {
	opts = {rows = 50, cols = 200, seconds = 1.0}
	for i := 0; i < len(args); i += 2 {
		if i + 1 >= len(args) do return opts, false
		v := args[i + 1]
		switch args[i] {
		case "--rows":    opts.rows, ok = strconv.parse_int(v)
		case "--cols":    opts.cols, ok = strconv.parse_int(v)
		case "--seconds": opts.seconds, ok = strconv.parse_f64(v)
		case "--only":    opts.only, ok = v, true
		case:             return opts, false
		}
		if !ok do return opts, false
	}
	return opts, opts.rows >= 3 && opts.cols >= 4 && opts.seconds > 0
}
