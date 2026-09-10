package main

import "core:fmt"
import "../bench"

main :: proc() {
	fmt.println("=== Phase 0 Benchmark Harness ===")
	fmt.println("")

	// Define synthetic benchmarks
	feed_bench := bench.Benchmark{
		name = "synthetic_feed_bytes",
		run = feed_bench_run,
		iterations = 1000,
	}

	mutate_bench := bench.Benchmark{
		name = "synthetic_mutate_cell",
		run = mutate_bench_run,
		iterations = 1000,
	}

	upload_bench := bench.Benchmark{
		name = "synthetic_upload_cells",
		run = upload_bench_run,
		iterations = 100,
	}

	render_bench := bench.Benchmark{
		name = "synthetic_render_frame",
		run = render_bench_run,
		iterations = 100,
	}

	benchmarks := []bench.Benchmark{
		feed_bench,
		mutate_bench,
		upload_bench,
		render_bench,
	}

	// Run all benchmarks
	results := bench.run_benchmarks(benchmarks)
	defer delete(results)

	// Print results
	for &r in results {
		result_str := bench.format_benchmark_result(&r)
		fmt.println(result_str)
		delete(result_str)
	}

	fmt.println("=== Benchmark Complete ===")
}

// Benchmark runner procedures

feed_bench_run :: proc(ctx: ^bench.Benchmark_Context) {
	// Simulate feeding a typical terminal escape sequence
	data := []u8{
		0x1b, '[', '2', 'J', // Clear screen
		0x1b, '[', 'H',      // Cursor home
		'H', 'e', 'l', 'l', 'o', ',', ' ', 'W', 'o', 'r', 'l', 'd', '!',
		0x1b, '[', '3', '1', 'm', // Red foreground
		'B', 'o', 'l', 'd',
		0x1b, '[', '0', 'm', // Reset
	}
	bench.synthetic_feed_bytes(ctx, data)
}

mutate_bench_run :: proc(ctx: ^bench.Benchmark_Context) {
	// Mutate a few cells in the grid
	bench.synthetic_mutate_cell(ctx, 0, 0, 'H', 0xFFFFFF, 0x000000)
	bench.synthetic_mutate_cell(ctx, 0, 1, 'i', 0xFFFFFF, 0x000000)
	bench.synthetic_mutate_cell(ctx, 1, 0, '!', 0xFF0000, 0x000000)
}

upload_bench_run :: proc(ctx: ^bench.Benchmark_Context) {
	// Upload the entire grid
	bench.synthetic_upload_cells(ctx)
}

render_bench_run :: proc(ctx: ^bench.Benchmark_Context) {
	// Render a frame
	bench.synthetic_render_frame(ctx)
}
