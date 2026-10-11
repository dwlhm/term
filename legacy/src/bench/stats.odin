package bench

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:sort"

// Stats_Collector accumulates timing samples for statistical analysis.
// Samples are stored in a dynamically-sized slice with a fixed capacity.
Stats_Collector :: struct {
	samples:  []f64,
	capacity: int,
	count:    int,
}

// Stats_Result holds the computed statistical summary of collected samples.
Stats_Result :: struct {
	min:     f64,
	max:     f64,
	mean:    f64,
	median:  f64,
	p50:     f64,
	p95:     f64,
	p99:     f64,
	p99_9:   f64,
	stddev:  f64,
	count:   int,
}

// stats_init allocates a Stats_Collector with the given capacity.
// The caller must call stats_destroy when done.
stats_init :: proc(capacity: int, allocator: runtime.Allocator = context.allocator) -> Stats_Collector {
	return Stats_Collector{
		samples  = make([]f64, capacity, allocator),
		capacity = capacity,
		count    = 0,
	}
}

// stats_destroy frees the memory used by the Stats_Collector.
stats_destroy :: proc(sc: ^Stats_Collector) {
	if sc.samples != nil {
		delete(sc.samples)
		sc.samples = nil
	}
	sc.count = 0
	sc.capacity = 0
}

// stats_add_sample adds a timing sample to the collector.
// If the collector is full, the sample is silently dropped.
stats_add_sample :: proc(sc: ^Stats_Collector, value: f64) {
	if sc.count < sc.capacity {
		sc.samples[sc.count] = value
		sc.count += 1
	}
}

// _percentile computes the p-th percentile (0.0 to 1.0) from a sorted slice.
// Uses linear interpolation between closest ranks.
_percentile :: proc(sorted: []f64, p: f64) -> f64 {
	n := len(sorted)
	if n == 0 {
		return 0.0
	}
	if n == 1 {
		return sorted[0]
	}
	index := p * f64(n - 1)
	lower := int(math.floor(index))
	upper := int(math.ceil(index))
	if lower == upper {
		return sorted[lower]
	}
	frac := index - f64(lower)
	return sorted[lower] + frac * (sorted[upper] - sorted[lower])
}

// stats_compute calculates statistical measures from the collected samples.
// Returns a Stats_Result with min, max, mean, median, percentiles, and stddev.
stats_compute :: proc(sc: ^Stats_Collector) -> Stats_Result {
	if sc.count == 0 {
		return Stats_Result{}
	}

	// Copy samples for sorting (preserve original order)
	sorted := make([]f64, sc.count)
	copy(sorted, sc.samples[:sc.count])

	// Sort the copy
	it := sort.slice_interface(&sorted)
	sort.sort(it)

	// Compute basic statistics
	min_val := sorted[0]
	max_val := sorted[sc.count - 1]

	sum: f64 = 0.0
	for s in sorted {
		sum += s
	}
	mean_val := sum / f64(sc.count)

	// Compute standard deviation
	sum_sq_diff: f64 = 0.0
	for s in sorted {
		diff := s - mean_val
		sum_sq_diff += diff * diff
	}
	variance := sum_sq_diff / f64(sc.count)
	stddev_val := math.sqrt(variance)

	// Compute percentiles
	median_val := _percentile(sorted, 0.50)
	p50_val    := _percentile(sorted, 0.50)
	p95_val    := _percentile(sorted, 0.95)
	p99_val    := _percentile(sorted, 0.99)
	p99_9_val  := _percentile(sorted, 0.999)

	delete(sorted)

	return Stats_Result{
		min    = min_val,
		max    = max_val,
		mean   = mean_val,
		median = median_val,
		p50    = p50_val,
		p95    = p95_val,
		p99    = p99_val,
		p99_9  = p99_9_val,
		stddev = stddev_val,
		count  = sc.count,
	}
}

// _format_ns formats a nanosecond value as a human-readable duration string.
_format_ns :: proc(ns: f64) -> string {
	if ns < 1000.0 {
		return fmt.aprintf("%.1f ns", ns)
	} else if ns < 1_000_000.0 {
		return fmt.aprintf("%.2f µs", ns / 1000.0)
	} else if ns < 1_000_000_000.0 {
		return fmt.aprintf("%.2f ms", ns / 1_000_000.0)
	}
	return fmt.aprintf("%.2f s", ns / 1_000_000_000.0)
}

// stats_format returns a human-readable string representation of the Stats_Result.
// The caller is responsible for freeing the returned string.
stats_format :: proc(r: ^Stats_Result) -> string {
	return fmt.aprintf(
		"min: %v, max: %v, mean: %v, median: %v\n" +
		"p50: %v, p95: %v, p99: %v, p99.9: %v\n" +
		"stddev: %v, count: %v",
		_format_ns(r.min), _format_ns(r.max), _format_ns(r.mean), _format_ns(r.median),
		_format_ns(r.p50), _format_ns(r.p95), _format_ns(r.p99), _format_ns(r.p99_9),
		_format_ns(r.stddev), r.count,
	)
}
