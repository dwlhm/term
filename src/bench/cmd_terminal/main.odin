package main

import "core:fmt"
import ".."
import "../../platform"
import tg "../../terminal"

main :: proc() {
	fmt.println("=== Phase 1 Terminal Grid Performance Tests ===")
	fmt.println("")

	// Define benchmarks
	cell_mut_bench := bench.Benchmark{
		name       = "cell_mutation",
		run        = bench_cell_mutation,
		iterations = 1000,
	}

	scroll_bench := bench.Benchmark{
		name       = "scroll_operation",
		run        = bench_scroll,
		iterations = 1000,
	}

	damage_bench := bench.Benchmark{
		name       = "damage_tracking",
		run        = bench_damage_tracking,
		iterations = 1000,
	}

	scroll_o1_bench := bench.Benchmark{
		name       = "scroll_o1_rows_independent",
		run        = bench_scroll_o1_rows_independent,
		iterations = 10,
	}

	scroll_region_bench := bench.Benchmark{
		name       = "scroll_region_partial",
		run        = bench_scroll_region_partial,
		iterations = 10,
	}

	benchmarks := []bench.Benchmark{
		cell_mut_bench,
		scroll_bench,
		damage_bench,
		scroll_o1_bench,
		scroll_region_bench,
	}

	// Run all benchmarks
	results := bench.run_benchmarks(benchmarks)
	defer delete(results)

	// Print results
	for &r in results {
		result_str := bench.format_benchmark_result(&r)
		fmt.println(result_str)
		delete(result_str)

		// Check performance targets
		ns_per_op := r.stats.mean
		switch r.name {
		case "cell_mutation":
			if ns_per_op < 10.0 {
				fmt.printf("✓ Cell mutation: %.2f ns/op (target: <10ns)\n", ns_per_op)
			} else {
				fmt.printf("✗ Cell mutation: %.2f ns/op (target: <10ns) - SLOW\n", ns_per_op)
			}
		case "scroll_operation":
			if ns_per_op < 50.0 {
				fmt.printf("✓ Scroll operation: %.2f ns/op (target: <50ns)\n", ns_per_op)
			} else {
				fmt.printf("✗ Scroll operation: %.2f ns/op (target: <50ns) - SLOW\n", ns_per_op)
			}
		case "damage_tracking":
			// damage_tracking does 1000 put_chars + journal, so divide by 1000
			ns_per_cell := ns_per_op / 1000.0
			if ns_per_cell < 5.0 {
				fmt.printf("✓ Damage tracking: %.2f ns/dirty_cell (target: <5ns)\n", ns_per_cell)
			} else {
				fmt.printf("✗ Damage tracking: %.2f ns/dirty_cell (target: <5ns) - SLOW\n", ns_per_cell)
			}
		}
		fmt.println("")
	}

	fmt.println("=== Performance Tests Complete ===")
}

// Benchmark: Cell mutation (1000 put_char operations)
bench_cell_mutation :: proc(ctx: ^bench.Benchmark_Context) {
	t: tg.Terminal
	tg.terminal_init(&t, 24, 80)
	defer tg.terminal_destroy(&t)

	for i in 0..<1000 {
		tg.terminal_put_char(&t, 'a')
	}
}

// Benchmark: Scroll operation (100 scroll_up operations)
bench_scroll :: proc(ctx: ^bench.Benchmark_Context) {
	t: tg.Terminal
	tg.terminal_init(&t, 24, 80)
	defer tg.terminal_destroy(&t)

	for _ in 0..<100 {
		tg.terminal_scroll_up(&t, 1)
	}
}

// Benchmark: Damage tracking (1000 put_char + take_journal)
bench_damage_tracking :: proc(ctx: ^bench.Benchmark_Context) {
	t: tg.Terminal
	tg.terminal_init(&t, 24, 80)
	defer tg.terminal_destroy(&t)

	for i in 0..<1000 {
		tg.terminal_put_char(&t, 'a')
	}

	journal := tg.terminal_take_damage(&t)
	tg.damage_journal_destroy(&journal)
}

// bench_scroll_single times a single grid_scroll_up(g, 1) in nanoseconds.
bench_scroll_single :: proc(g: ^tg.Grid) -> f64 {
	start := platform.platform_now()
	tg.grid_scroll_up(g, 1)
	end := platform.platform_now()
	return f64(platform.platform_ticks_to_ns(end - start))
}

// Benchmark: O(1) scroll gate — ns/scroll must be flat across row counts.
// Rows 24/48/96/192, cols 80. Asserts max/min < 1.5.
bench_scroll_o1_rows_independent :: proc(ctx: ^bench.Benchmark_Context) {
	sizes := [4]int{24, 48, 96, 192}
	per_size := [4]f64{}
	iters := 2000

	for s, si in sizes {
		g: tg.Grid
		tg.grid_init(&g, s, 80)
		defer tg.grid_destroy(&g)

		// Warm up.
		for _ in 0..<100 {
			tg.grid_scroll_up(&g, 1)
		}

		total: i64 = 0
		start := platform.platform_now()
		for _ in 0..<iters {
			tg.grid_scroll_up(&g, 1)
		}
		end := platform.platform_now()
		total = platform.platform_ticks_to_ns(end - start)
		per_size[si] = f64(total) / f64(iters)

		// Touch helper so bench_scroll_single stays wired to the same path.
		_ = bench_scroll_single(&g)
	}

	fmt.println("--- scroll O(1) gate: ns/scroll per size ---")
	for s, si in sizes {
		fmt.printf("  rows=%v cols=80 ns/scroll=%.2f\n", s, per_size[si])
	}
	min_v, max_v := per_size[0], per_size[0]
	for v in per_size {
		if v < min_v {
			min_v = v
		}
		if v > max_v {
			max_v = v
		}
	}
	ratio := max_v / (min_v + 1e-9)
	if ratio < 1.5 {
		fmt.printf("✓ O(1) scroll gate: max/min=%.3f (target <1.5)\n", ratio)
	} else {
		fmt.printf("✗ O(1) scroll gate: max/min=%.3f (target <1.5) - NOT O(1)\n", ratio)
	}
}

// Benchmark: full-grid vs 10-row region scroll contrast.
bench_scroll_region_partial :: proc(ctx: ^bench.Benchmark_Context) {
	iters := 2000

	g_full: tg.Grid
	tg.grid_init(&g_full, 24, 80)
	defer tg.grid_destroy(&g_full)
	start_full := platform.platform_now()
	for _ in 0..<iters {
		tg.grid_scroll_up(&g_full, 1)
	}
	end_full := platform.platform_now()
	ns_full := f64(platform.platform_ticks_to_ns(end_full - start_full)) / f64(iters)

	g_reg: tg.Grid
	tg.grid_init(&g_reg, 24, 80)
	defer tg.grid_destroy(&g_reg)
	d: tg.Damage
	tg.damage_init(&d, 24, 80)
	defer tg.damage_destroy(&d)
	start_reg := platform.platform_now()
	for _ in 0..<iters {
		tg.scroll_up(&g_reg, &d, 7, 16, 1)
	}
	end_reg := platform.platform_now()
	ns_reg := f64(platform.platform_ticks_to_ns(end_reg - start_reg)) / f64(iters)

	fmt.println("--- scroll region contrast ---")
	fmt.printf("  full-grid scroll: %.2f ns/scroll\n", ns_full)
	fmt.printf("  10-row region scroll: %.2f ns/scroll\n", ns_reg)
}
