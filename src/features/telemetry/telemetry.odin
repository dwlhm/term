package feature_telemetry

// Opt-in per-frame telemetry stream (NDJSON) for stress testing the real app.
// Invariants: buffers are inline and fixed-size, so recording performs zero heap
// allocations; when inactive every entry point is a single branch.

import "core:fmt"
import "core:os"
import "core:sys/posix"
import "core:time"

HIST_RES_NS :: 10_000 // 10 µs histogram resolution
HIST_BUCKETS :: 10_000 // covers 0..100 ms; last bucket collects overflow
WRITE_BUF_SIZE :: 64 * 1024
LINE_MAX :: 512

Frame_Sample :: struct {
	drain_bytes: int,
	dirty_cells: int,
	panes:       int,
	strategy:    string,
}

Telemetry :: struct {
	active:       bool,
	file:         ^os.File,
	start:        time.Tick,
	pending:      Frame_Sample,
	frames:       u64,
	total_bytes:  u64,
	max_frame_ns: u64,
	peak_rss_kb:  i64,
	hist:         [HIST_BUCKETS]u32,
	buf_len:      int,
	buf:          [WRITE_BUF_SIZE]u8,
}

telemetry_open :: proc(t: ^Telemetry, path: string) -> bool {
	if t == nil || len(path) == 0 do return false
	f, err := os.create(path)
	if err != nil do return false
	t^ = {}
	t.file = f
	t.start = time.tick_now()
	t.active = true
	return true
}

// telemetry_close appends the summary record, flushes and closes the stream.
telemetry_close :: proc(t: ^Telemetry) {
	if t == nil || !t.active do return
	line: [LINE_MAX]u8
	s := fmt.bprintf(
		line[:],
		`{{"summary":true,"duration_s":%.3f,"frames":%d,"total_bytes":%d,"p50_us":%d,"p95_us":%d,"p99_us":%d,"p999_us":%d,"max_us":%d,"peak_rss_kb":%d}}` + "\n",
		time.duration_seconds(time.tick_since(t.start)),
		t.frames,
		t.total_bytes,
		telemetry_percentile_ns(t, 0.50) / 1000,
		telemetry_percentile_ns(t, 0.95) / 1000,
		telemetry_percentile_ns(t, 0.99) / 1000,
		telemetry_percentile_ns(t, 0.999) / 1000,
		t.max_frame_ns / 1000,
		t.peak_rss_kb,
	)
	_append(t, transmute([]u8)s)
	_flush(t)
	_ = os.close(t.file)
	t.file = nil
	t.active = false
}

telemetry_add_drain :: #force_inline proc(t: ^Telemetry, bytes: int) {
	if !t.active do return
	t.pending.drain_bytes += bytes
}

telemetry_add_pane :: #force_inline proc(t: ^Telemetry, dirty_cells: int, strategy: string) {
	if !t.active do return
	t.pending.dirty_cells += dirty_cells
	t.pending.panes += 1
	t.pending.strategy = strategy
}

// telemetry_end_frame emits one NDJSON record for the rendered frame and resets the accumulator.
telemetry_end_frame :: proc(t: ^Telemetry, frame_ns: u64) {
	if !t.active do return
	t.frames += 1
	t.total_bytes += u64(t.pending.drain_bytes)
	t.max_frame_ns = max(t.max_frame_ns, frame_ns)
	t.hist[min(frame_ns / HIST_RES_NS, HIST_BUCKETS - 1)] += 1
	t.peak_rss_kb = _peak_rss_kb()

	line: [LINE_MAX]u8
	s := fmt.bprintf(
		line[:],
		`{{"t_us":%d,"frame_us":%d,"drain_bytes":%d,"dirty_cells":%d,"panes":%d,"strategy":"%s","peak_rss_kb":%d}}` + "\n",
		i64(time.duration_microseconds(time.tick_since(t.start))),
		frame_ns / 1000,
		t.pending.drain_bytes,
		t.pending.dirty_cells,
		t.pending.panes,
		t.pending.strategy,
		t.peak_rss_kb,
	)
	_append(t, transmute([]u8)s)
	t.pending = {}
}

// telemetry_percentile_ns returns the upper bound of the histogram bucket holding percentile p (0..1).
telemetry_percentile_ns :: proc(t: ^Telemetry, p: f64) -> u64 {
	if t == nil || t.frames == 0 do return 0
	target := u64(f64(t.frames) * p + 0.999999)
	seen: u64
	for count, i in t.hist {
		seen += u64(count)
		if seen >= max(target, 1) {
			return t.max_frame_ns if i == HIST_BUCKETS - 1 else min(u64(i + 1) * HIST_RES_NS, t.max_frame_ns)
		}
	}
	return t.max_frame_ns
}

@(private = "file")
_append :: proc(t: ^Telemetry, data: []u8) {
	if t.buf_len + len(data) > WRITE_BUF_SIZE do _flush(t)
	n := copy(t.buf[t.buf_len:], data)
	t.buf_len += n
}

@(private = "file")
_flush :: proc(t: ^Telemetry) {
	if t.buf_len == 0 || t.file == nil do return
	_, _ = os.write(t.file, t.buf[:t.buf_len])
	t.buf_len = 0
}

@(private = "file")
_peak_rss_kb :: proc() -> i64 {
	usage: posix.rusage
	if posix.getrusage(.SELF, &usage) != .OK do return 0
	when ODIN_OS == .Darwin {
		return i64(usage.ru_maxrss) / 1024 // bytes on Darwin
	} else {
		return i64(usage.ru_maxrss) // KiB on Linux
	}
}
