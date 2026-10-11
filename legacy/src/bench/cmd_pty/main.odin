package main

import "core:c"
import "core:fmt"
import "core:time"
import posix "core:sys/posix"
import bench ".."
import termgrid "../../terminal"
import parser "../../parser"
import pty "../../platform/pty"

// PTY_BENCH_BYTES is the exact byte count each iteration must drain.
PTY_BENCH_BYTES :: 1048576

// PTY_BENCH_LINE_LEN is the fixture line width before the newline.
PTY_BENCH_LINE_LEN :: 80

// PTY_BENCH_LINE_SEED repeats 4x to build the 80-char fixture line.
PTY_BENCH_LINE_SEED :: "ABCDEFGHIJ0123456789"

// PTY_BENCH_ITERS is the timed iteration count (each spawns a 1MB child).
PTY_BENCH_ITERS :: 5

// PTY_BENCH_TIMEOUT bounds the drain-to-EOF wait (wall clock).
PTY_BENCH_TIMEOUT :: 5 * time.Second

// PTY_BENCH_DRAIN_CAP is the per-drain read size.
PTY_BENCH_DRAIN_CAP :: 65536

// PTY_BENCH_EXIT_ITERS bounds the wait-exit poll after EOF.
PTY_BENCH_EXIT_ITERS :: 200

// _pty_line holds the 80-char fixture line plus its newline.
_pty_line: [PTY_BENCH_LINE_LEN + 1]u8

// _pty_runs counts _pty_bench_once calls including the warm-up run.
_pty_runs: int

// _pty_bytes accumulates drained bytes across all runs.
_pty_bytes: int

// _pty_loss accumulates shortfall bytes (expected - got, when positive).
_pty_loss: int

main :: proc() {
	seed := PTY_BENCH_LINE_SEED
	for i in 0..<PTY_BENCH_LINE_LEN {
		_pty_line[i] = seed[i % len(seed)]
	}
	_pty_line[PTY_BENCH_LINE_LEN] = '\n'

	b := bench.Benchmark{
		name       = "pty_1mb_stream",
		run        = _pty_bench_once,
		iterations = PTY_BENCH_ITERS,
	}
	benchmarks := []bench.Benchmark{b}
	results := bench.run_benchmarks(benchmarks)
	defer delete(results)

	for &r in results {
		result_str := bench.format_benchmark_result(&r)
		fmt.println(result_str)
		delete(result_str)
		ns_per_byte := r.stats.mean / f64(PTY_BENCH_BYTES)
		want := _pty_runs * PTY_BENCH_BYTES
		fmt.printf("pty stream: %.2f ns/byte total=%v bytes (want %v) runs=%v\n", ns_per_byte, _pty_bytes, want, _pty_runs)
		if _pty_loss == 0 {
			fmt.printf("✓ pty stream: %v bytes drained, zero loss\n", _pty_bytes)
		} else {
			fmt.printf("✗ pty stream: got %v of %v bytes, loss=%v — LOSS\n", _pty_bytes, want, _pty_loss)
		}
		fmt.println("")
	}
}

// _pty_bench_once runs one iteration: spawn the 1MB producer, drain all
// bytes to EOF (bounded 5s), parse every chunk, then wait-exit and close
// (no zombie). A short drain records loss instead of hanging.
_pty_bench_once :: proc(ctx: ^bench.Benchmark_Context) {
	_pty_runs += 1
	cmd := fmt.aprintf("stty -onlcr; yes '%s' | head -c %d", string(_pty_line[:PTY_BENCH_LINE_LEN]), PTY_BENCH_BYTES)
	defer delete(cmd)
	p: pty.Pty
	if !pty.pty_spawn(&p, 24, 80, "/bin/sh", {"-c", cmd}) {
		_pty_loss += PTY_BENCH_BYTES
		return
	}
	defer _pty_cleanup(&p)
	term: termgrid.Terminal
	termgrid.terminal_init(&term, 24, 80)
	defer termgrid.terminal_destroy(&term)
	ps: parser.Parser
	parser.parser_init(&ps)
	buf := make([]u8, PTY_BENCH_DRAIN_CAP)
	defer delete(buf)
	got := 0
	start := time.now()
	for {
		n, eof := pty.pty_drain(&p, buf, PTY_BENCH_DRAIN_CAP)
		if n > 0 {
			parser.parse_chunk(&ps, &term, buf[:n])
			got += n
		}
		if eof {
			break
		}
		if n == 0 {
			time.sleep(time.Millisecond)
		}
		if time.since(start) > PTY_BENCH_TIMEOUT {
			break
		}
	}
	_pty_bytes += got
	if got != PTY_BENCH_BYTES {
		_pty_loss += max(PTY_BENCH_BYTES - got, 0)
	}
}

// _pty_cleanup waits for the child (bounded), kills stragglers, reaps,
// and closes the master: no zombie, no fd leak either way.
_pty_cleanup :: proc(p: ^pty.Pty) {
	exited := false
	for _ in 0..<PTY_BENCH_EXIT_ITERS {
		if pty.pty_poll_exit(p) {
			exited = true
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	if !exited && p.pid > 0 {
		posix.kill(posix.pid_t(p.pid), .SIGKILL)
		status: c.int
		posix.waitpid(posix.pid_t(p.pid), &status, posix.Wait_Flags{})
	}
	pty.pty_close(p)
}
