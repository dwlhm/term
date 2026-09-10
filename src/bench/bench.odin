package bench

import "base:runtime"
import "core:fmt"
import "../platform"

// Benchmark_Context holds the state for a single benchmark run.
// Contains timing, statistics collection, and allocation tracking.
Benchmark_Context :: struct {
	timer:            Timer,
	stats:            Stats_Collector,
	allocation_count: int,
	gpu_stats:        Gpu_Stats,
}

// Benchmark defines a single benchmark to run.
Benchmark :: struct {
	name:       string,
	run:        proc(ctx: ^Benchmark_Context),
	iterations: int,
}

// Benchmark_Result holds the results of a completed benchmark.
Benchmark_Result :: struct {
	name:          string,
	stats:         Stats_Result,
	total_time_ns: i64,
	iterations:    int,
}

// Gpu_Stats tracks GPU-related metrics during synthetic benchmarking.
Gpu_Stats :: struct {
	bytes_uploaded: int,
	draw_calls:     int,
	render_time_ns: i64,
}

// Synthetic grid dimensions for terminal simulation.
SYNTHETIC_GRID_ROWS :: 24
SYNTHETIC_GRID_COLS :: 80
SYNTHETIC_GRID_SIZE :: SYNTHETIC_GRID_ROWS * SYNTHETIC_GRID_COLS

// Synthetic_Cell represents a single cell in the terminal grid.
Synthetic_Cell :: struct {
	char:  rune,
	fg:    u32,
	bg:    u32,
}

// bench_context_init creates and initializes a Benchmark_Context.
// The caller must call bench_context_destroy when done.
bench_context_init :: proc(stats_capacity: int, allocator: runtime.Allocator = context.allocator) -> Benchmark_Context {
	return Benchmark_Context{
		stats = stats_init(stats_capacity, allocator),
	}
}

// bench_context_destroy frees all resources held by the Benchmark_Context.
bench_context_destroy :: proc(ctx: ^Benchmark_Context) {
	stats_destroy(&ctx.stats)
}

// format_duration converts nanoseconds to a human-readable duration string.
// The caller is responsible for freeing the returned string.
format_duration :: proc(ns: i64) -> string {
	return _format_ns(f64(ns))
}

// run_benchmark executes a single benchmark for the specified number of iterations.
// Collects timing statistics and returns the benchmark result.
run_benchmark :: proc(b: ^Benchmark, allocator: runtime.Allocator = context.allocator) -> Benchmark_Result {
	ctx := bench_context_init(b.iterations, allocator)
	defer bench_context_destroy(&ctx)

	// Warm-up run
	b.run(&ctx)

	// Timed iterations
	total_start := platform.platform_now()
	for _ in 0..<b.iterations {
		timer_start(&ctx.timer)
		b.run(&ctx)
		timer_stop(&ctx.timer)
		delta := timer_delta_ns(&ctx.timer)
		stats_add_sample(&ctx.stats, f64(delta))
	}
	total_end := platform.platform_now()
	total_ns := platform.platform_ticks_to_ns(total_end - total_start)

	result_stats := stats_compute(&ctx.stats)

	return Benchmark_Result{
		name          = b.name,
		stats         = result_stats,
		total_time_ns = total_ns,
		iterations    = b.iterations,
	}
}

// run_benchmarks executes multiple benchmarks and returns all results.
// Each benchmark is run independently with its own context.
run_benchmarks :: proc(benchmarks: []Benchmark, allocator: runtime.Allocator = context.allocator) -> []Benchmark_Result {
	results := make([]Benchmark_Result, len(benchmarks), allocator)
	for &b, i in benchmarks {
		results[i] = run_benchmark(&b, allocator)
	}
	return results
}

// format_benchmark_result returns a human-readable string for a benchmark result.
// The caller is responsible for freeing the returned string.
format_benchmark_result :: proc(r: ^Benchmark_Result) -> string {
	stats_str := stats_format(&r.stats)
	defer delete(stats_str)
	return fmt.aprintf(
		"Benchmark: %v\n  Iterations: %v\n  Total time: %v\n  %v\n",
		r.name, r.iterations, format_duration(r.total_time_ns), stats_str,
	)
}

// --- Synthetic API ---
// These functions simulate terminal operations for benchmarking purposes.
// They perform real work (memory operations, computations) to produce measurable timing.

// _synthetic_grid is a shared grid for synthetic benchmarks.
_synthetic_grid: [SYNTHETIC_GRID_SIZE]Synthetic_Cell = {}

// synthetic_feed_bytes simulates feeding bytes through a terminal parser.
// Scans for escape sequences and processes printable characters.
// Updates allocation_count to track work done.
synthetic_feed_bytes :: proc(ctx: ^Benchmark_Context, data: []u8) {
	processed: int = 0
	i: int = 0
	for i < len(data) {
		b := data[i]
		if b == 0x1b { // ESC
			// Skip escape sequence (simplified: skip next 2 bytes)
			i += 3
		} else {
			processed += 1
			i += 1
		}
	}
	ctx.allocation_count += processed
}

// synthetic_mutate_cell simulates mutating a cell in the terminal grid.
// Writes character and style data to the grid at the specified position.
synthetic_mutate_cell :: proc(ctx: ^Benchmark_Context, row, col: int, ch: rune, fg, bg: u32) {
	if row < 0 || row >= SYNTHETIC_GRID_ROWS || col < 0 || col >= SYNTHETIC_GRID_COLS {
		return
	}
	idx := row * SYNTHETIC_GRID_COLS + col
	_synthetic_grid[idx].char = ch
	_synthetic_grid[idx].fg = fg
	_synthetic_grid[idx].bg = bg
	ctx.allocation_count += 1
}

// synthetic_upload_cells simulates uploading cell data to the GPU.
// Performs a memory copy and checksum computation over the grid data.
// Updates gpu_stats with bytes uploaded and draw call count.
synthetic_upload_cells :: proc(ctx: ^Benchmark_Context) {
	// Compute checksum over grid data (simulates GPU upload)
	checksum: u32 = 0
	for cell in _synthetic_grid {
		checksum = checksum * 31 + u32(cell.char) + cell.fg + cell.bg
	}
	bytes := SYNTHETIC_GRID_SIZE * size_of(Synthetic_Cell)
	ctx.gpu_stats.bytes_uploaded += bytes
	ctx.gpu_stats.draw_calls += 1
	ctx.allocation_count += 1
}

// synthetic_render_frame simulates rendering a frame from the terminal grid.
// Iterates over all cells and performs composition work.
// Updates gpu_stats with render time and draw call count.
synthetic_render_frame :: proc(ctx: ^Benchmark_Context) {
	start := platform.platform_now()

	// Simulate frame composition: iterate over all cells
	pixels_rendered: int = 0
	for cell in _synthetic_grid {
		// Simulate per-cell rendering work
		if cell.char != 0 {
			pixels_rendered += 1
		}
	}

	end := platform.platform_now()
	render_ns := platform.platform_ticks_to_ns(end - start)
	ctx.gpu_stats.render_time_ns += render_ns
	ctx.gpu_stats.draw_calls += 1
	ctx.allocation_count += pixels_rendered
}
