package bench_test

import "core:testing"
import ".."
import "../../platform"
import "core:math"

// --- Timer Tests ---

@(test)
test_timer_basic :: proc(t: ^testing.T) {
	timer: bench.Timer
	bench.timer_start(&timer)

	// Do some work to ensure measurable time passes
	sum: int = 0
	for i in 0..<10000 {
		sum += i
	}

	bench.timer_stop(&timer)
	delta := bench.timer_delta_ns(&timer)

	testing.expect(t, delta > 0, "Timer delta should be positive")
	testing.expect(t, delta < 1_000_000_000, "Timer delta should be less than 1 second for trivial work")
}

@(test)
test_timer_conversions :: proc(t: ^testing.T) {
	timer: bench.Timer
	bench.timer_start(&timer)

	// Do some work
	sum: int = 0
	for i in 0..<100000 {
		sum += i
	}

	bench.timer_stop(&timer)

	ns := bench.timer_delta_ns(&timer)
	us := bench.timer_delta_us(&timer)
	ms := bench.timer_delta_ms(&timer)

	testing.expect(t, ns > 0, "ns should be positive")
	testing.expect(t, us > 0.0, "us should be positive")
	// Verify conversions are consistent
	expected_us := f64(ns) / 1000.0
	testing.expect(t, math.abs(us - expected_us) < 0.001, "us conversion should match ns/1000")
	expected_ms := f64(ns) / 1_000_000.0
	testing.expect(t, math.abs(ms - expected_ms) < 0.000001, "ms conversion should match ns/1000000")
}

// --- Stats Tests ---

@(test)
test_stats_basic :: proc(t: ^testing.T) {
	sc := bench.stats_init(100)
	defer bench.stats_destroy(&sc)

	// Add known values: 1 through 10
	for i in 1..<11 {
		bench.stats_add_sample(&sc, f64(i))
	}

	result := bench.stats_compute(&sc)

	testing.expect(t, result.count == 10, "Count should be 10")
	testing.expect(t, result.min == 1.0, "Min should be 1.0")
	testing.expect(t, result.max == 10.0, "Max should be 10.0")

	// Mean = (1+2+...+10)/10 = 55/10 = 5.5
	testing.expect(t, math.abs(result.mean - 5.5) < 0.001, "Mean should be 5.5")

	// Median = (5+6)/2 = 5.5
	testing.expect(t, math.abs(result.median - 5.5) < 0.001, "Median should be 5.5")

	// p50 should equal median
	testing.expect(t, math.abs(result.p50 - 5.5) < 0.001, "p50 should be 5.5")

	// p95: index = 0.95 * 9 = 8.55, between sorted[8]=9 and sorted[9]=10
	// result = 9 + 0.55 * (10-9) = 9.55
	testing.expect(t, math.abs(result.p95 - 9.55) < 0.01, "p95 should be ~9.55")

	// p99: index = 0.99 * 9 = 8.91, between sorted[8]=9 and sorted[9]=10
	// result = 9 + 0.91 * (10-9) = 9.91
	testing.expect(t, math.abs(result.p99 - 9.91) < 0.01, "p99 should be ~9.91")

	// p99.9: index = 0.999 * 9 = 8.991
	// result = 9 + 0.991 * (10-9) = 9.991
	testing.expect(t, math.abs(result.p99_9 - 9.991) < 0.01, "p99.9 should be ~9.991")

	// stddev = sqrt(8.25) ≈ 2.8723
	testing.expect(t, math.abs(result.stddev - 2.8723) < 0.01, "Stddev should be ~2.8723")
}

@(test)
test_stats_empty :: proc(t: ^testing.T) {
	sc := bench.stats_init(10)
	defer bench.stats_destroy(&sc)

	result := bench.stats_compute(&sc)
	testing.expect(t, result.count == 0, "Empty stats should have count 0")
	testing.expect(t, result.min == 0.0, "Empty stats min should be 0")
	testing.expect(t, result.max == 0.0, "Empty stats max should be 0")
}

@(test)
test_stats_single :: proc(t: ^testing.T) {
	sc := bench.stats_init(10)
	defer bench.stats_destroy(&sc)

	bench.stats_add_sample(&sc, 42.0)
	result := bench.stats_compute(&sc)

	testing.expect(t, result.count == 1, "Count should be 1")
	testing.expect(t, result.min == 42.0, "Min should be 42.0")
	testing.expect(t, result.max == 42.0, "Max should be 42.0")
	testing.expect(t, result.mean == 42.0, "Mean should be 42.0")
	testing.expect(t, result.median == 42.0, "Median should be 42.0")
	testing.expect(t, result.stddev == 0.0, "Stddev of single value should be 0")
}

// --- Trace Tests ---

@(test)
test_trace_record_replay :: proc(t: ^testing.T) {
	tr := bench.trace_init("test_trace", 100, true)
	defer bench.trace_destroy(&tr)

	// Record some data
	bench.trace_record(&tr, 'H')
	bench.trace_record(&tr, 'i')
	bench.trace_record(&tr, '!')

	// Verify data was recorded
	testing.expect(t, tr.data_count == 3, "Should have 3 data bytes")
	testing.expect(t, tr.data[0] == 'H', "First byte should be H")
	testing.expect(t, tr.data[1] == 'i', "Second byte should be i")
	testing.expect(t, tr.data[2] == '!', "Third byte should be !")
	testing.expect(t, tr.time_count == 3, "Should have 3 timestamps")
	testing.expect(t, tr.timestamps[0] > 0, "First timestamp should be positive")
}

@(test)
test_trace_without_timestamps :: proc(t: ^testing.T) {
	tr := bench.trace_init("no_ts", 50, false)
	defer bench.trace_destroy(&tr)

	bench.trace_record(&tr, 'A')
	bench.trace_record(&tr, 'B')

	testing.expect(t, tr.data_count == 2, "Should have 2 data bytes")
	testing.expect(t, tr.data[0] == 'A', "First byte should be A")
	testing.expect(t, tr.data[1] == 'B', "Second byte should be B")
	testing.expect(t, tr.has_timestamps == false, "Should not have timestamps")
}

@(test)
test_trace_save_load :: proc(t: ^testing.T) {
	tr := bench.trace_init("save_test", 100, true)
	defer bench.trace_destroy(&tr)

	bench.trace_record(&tr, 'X')
	bench.trace_record(&tr, 'Y')
	bench.trace_record(&tr, 'Z')

	// Save to temp file
	path := "/tmp/bench_trace_test.bin"
	ok := bench.trace_save(&tr, path)
	testing.expect(t, ok, "trace_save should succeed")

	// Load and verify
	loaded, load_ok := bench.trace_load(path)
	testing.expect(t, load_ok, "trace_load should succeed")
	defer bench.trace_destroy(&loaded)

	testing.expect(t, loaded.name == "save_test", "Loaded name should match")
	testing.expect(t, loaded.data_count == 3, "Loaded data count should be 3")
	testing.expect(t, loaded.has_timestamps == true, "Loaded has_timestamps should be true")
	testing.expect(t, loaded.data[0] == 'X', "First byte should be X")
	testing.expect(t, loaded.data[1] == 'Y', "Second byte should be Y")
	testing.expect(t, loaded.data[2] == 'Z', "Third byte should be Z")
}

// --- Synthetic API Tests ---

@(test)
test_synthetic_feed_bytes :: proc(t: ^testing.T) {
	ctx := bench.bench_context_init(10)
	defer bench.bench_context_destroy(&ctx)

	data := []u8{'H', 'e', 'l', 'l', 'o'}
	bench.synthetic_feed_bytes(&ctx, data)

	testing.expect(t, ctx.allocation_count > 0, "feed_bytes should increment allocation_count")
}

@(test)
test_synthetic_mutate_cell :: proc(t: ^testing.T) {
	ctx := bench.bench_context_init(10)
	defer bench.bench_context_destroy(&ctx)

	bench.synthetic_mutate_cell(&ctx, 0, 0, 'A', 0xFFFFFF, 0x000000)
	testing.expect(t, ctx.allocation_count == 1, "mutate_cell should increment allocation_count by 1")

	// Out of bounds should not crash
	bench.synthetic_mutate_cell(&ctx, -1, 0, 'B', 0, 0)
	bench.synthetic_mutate_cell(&ctx, 0, 999, 'C', 0, 0)
}

@(test)
test_synthetic_upload_cells :: proc(t: ^testing.T) {
	ctx := bench.bench_context_init(10)
	defer bench.bench_context_destroy(&ctx)

	bench.synthetic_upload_cells(&ctx)

	testing.expect(t, ctx.gpu_stats.bytes_uploaded > 0, "upload should track bytes")
	testing.expect(t, ctx.gpu_stats.draw_calls == 1, "upload should increment draw_calls")
}

@(test)
test_synthetic_render_frame :: proc(t: ^testing.T) {
	ctx := bench.bench_context_init(10)
	defer bench.bench_context_destroy(&ctx)

	bench.synthetic_render_frame(&ctx)

	testing.expect(t, ctx.gpu_stats.draw_calls == 1, "render should increment draw_calls")
	testing.expect(t, ctx.gpu_stats.render_time_ns >= 0, "render time should be non-negative")
}

// --- Platform Timing Tests ---

@(test)
test_platform_now :: proc(t: ^testing.T) {
	t1 := platform.platform_now()
	t2 := platform.platform_now()
	testing.expect(t, t2 >= t1, "platform_now should be monotonically non-decreasing")
}

@(test)
test_platform_ticks_to_ns :: proc(t: ^testing.T) {
	t1 := platform.platform_now()

	// Do some work
	sum: int = 0
	for i in 0..<100000 {
		sum += i
	}

	t2 := platform.platform_now()
	delta_ns := platform.platform_ticks_to_ns(t2 - t1)

	testing.expect(t, delta_ns > 0, "Delta should be positive")
	testing.expect(t, delta_ns < 1_000_000_000, "Delta should be less than 1 second")
}
