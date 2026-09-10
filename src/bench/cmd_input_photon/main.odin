package main

import "core:c"
import "core:fmt"
import "core:time"
import posix "core:sys/posix"
import bench ".."
import termgrid "../../terminal"
import parser "../../parser"
import pty "../../platform/pty"
import input "../../platform/input"
import render "../../render"

// PHOTON_ITERS is the timed keystroke count.
PHOTON_ITERS :: 1000

// PHOTON_ROWS/PHOTON_COLS are the headless grid dimensions.
PHOTON_ROWS :: 24
PHOTON_COLS :: 80

// PHOTON_ECHO_ITERS bounds the echo wait: 1000 x 1ms = 1s per keystroke.
PHOTON_ECHO_ITERS :: 1000

// PHOTON_DRAIN_CAP is the per-drain read size.
PHOTON_DRAIN_CAP :: 4096

// PHOTON_DRAIN_EXTRA bounds the post-echo remainder drain (nonblocking).
PHOTON_DRAIN_EXTRA :: 64

// _photon_runs counts _photon_once calls including the warm-up run.
_photon_runs: int

// _photon_skips counts iterations skipped on spawn/write/echo failure.
_photon_skips: int

main :: proc() {
	fmt.println("=== input-to-photon latency (headless, CPU-only) ===")
	fmt.println("boundary: to-submit/compile only — present excluded, headless (no GPU)")
	fmt.println("")
	b := bench.Benchmark{
		name       = "input_to_state",
		run        = _photon_once,
		iterations = PHOTON_ITERS,
	}
	benchmarks := []bench.Benchmark{b}
	results := bench.run_benchmarks(benchmarks)
	defer delete(results)

	for &r in results {
		result_str := bench.format_benchmark_result(&r)
		fmt.println(result_str)
		delete(result_str)
		fmt.printf("input-to-state p50: %.2f ns p99: %.2f ns\n", r.stats.p50, r.stats.p99)
		fmt.printf("runs=%v skips=%v (present excluded, headless CPU-only compile)\n", _photon_runs, _photon_skips)
		fmt.println("")
	}
}

// _photon_once runs one keystroke roundtrip: spawn /bin/cat, then time
// only encode -> write -> echo-wait -> drain -> parse -> compile. Setup
// (spawn + terminal/parser/frame init) is excluded by re-arming ctx.timer
// after it: the harness timer_start on entry is overwritten here, and the
// harness timer_stop after return closes the measured section. Compile is
// CPU-only (nil chain/cache/atlas = pure pack, no GPU). Cleanup runs in
// defer. An echo timeout skips the iteration (counted, reported).
_photon_once :: proc(ctx: ^bench.Benchmark_Context) {
	_photon_runs += 1
	p: pty.Pty
	if !pty.pty_spawn(&p, PHOTON_ROWS, PHOTON_COLS, "/bin/cat", {}) {
		_photon_skips += 1
		return
	}
	defer _photon_cleanup(&p)
	term: termgrid.Terminal
	termgrid.terminal_init(&term, PHOTON_ROWS, PHOTON_COLS)
	defer termgrid.terminal_destroy(&term)
	ps: parser.Parser
	parser.parser_init(&ps)
	frame: render.Compiled_Frame_V2
	render.render_compiler_init_v2(&frame, PHOTON_ROWS, PHOTON_COLS)
	defer render.render_compiler_destroy_v2(&frame)

	// Exclude setup from the timed section (see doc comment).
	bench.timer_start(&ctx.timer)

	enc: [input.INPUT_ENCODE_MAX]u8
	n := input.input_encode(input.Input_Event{kind = .Printable, rune = 'x'}, enc[:])
	if n <= 0 {
		_photon_skips += 1
		return
	}
	if !pty.pty_write(&p, enc[:n]) {
		_photon_skips += 1
		return
	}
	buf := make([]u8, PHOTON_DRAIN_CAP)
	defer delete(buf)
	acc := make([dynamic]u8)
	defer delete(acc)
	seen := false
	for _ in 0..<PHOTON_ECHO_ITERS {
		m, eof := pty.pty_drain(&p, buf, PHOTON_DRAIN_CAP)
		if m > 0 {
			append(&acc, ..buf[:m])
			if _photon_has_byte(acc[:], 'x') {
				seen = true
				break
			}
		}
		if eof {
			break
		}
		if m == 0 {
			time.sleep(time.Millisecond)
		}
	}
	if !seen {
		_photon_skips += 1
		return
	}
	for _ in 0..<PHOTON_DRAIN_EXTRA {
		m, _ := pty.pty_drain(&p, buf, PHOTON_DRAIN_CAP)
		if m <= 0 {
			break
		}
		append(&acc, ..buf[:m])
	}
	parser.parse_chunk(&ps, &term, acc[:])
	render.render_compile_full_v2(&frame, &term)
}

// _photon_has_byte reports whether b holds the echo byte.
_photon_has_byte :: proc(b: []u8, want: u8) -> bool {
	for x in b {
		if x == want {
			return true
		}
	}
	return false
}

// _photon_cleanup kills the cat child, reaps it, and closes the master:
// no zombie, no fd leak. Mirrors the test _teardown.
_photon_cleanup :: proc(p: ^pty.Pty) {
	if p.pid > 0 {
		posix.kill(posix.pid_t(p.pid), .SIGKILL)
		status: c.int
		posix.waitpid(posix.pid_t(p.pid), &status, posix.Wait_Flags{})
		p.pid = -1
	}
	pty.pty_close(p)
}
