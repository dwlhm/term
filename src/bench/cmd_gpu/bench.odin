package gpu_bench

// Phase 17 measurement bench: FrameTrace -> TracePlayer -> BackendUnderTest.
//
// bench_record_trace captures a deterministic fixed-grid trace from a Renderer
// (shape only: counts plus pseudo-instance bytes derived from the seed; no GPU
// touched). bench_play_trace replays the submit tail of that trace N times
// against a BackendUnderTest and aggregates CPU-submit nanoseconds plus a
// parity hash. bench_compare reduces two runs to a Bench_Verdict.
//
// Isolation: this package never touches the app Renderer, never mutates
// render/wgpu/strategy/vtable state, and owns nothing global. The caller owns
// Bench_Frame_Trace.instance_bytes and must delete it when done.

import "base:runtime"
import gpu "../../render/gpu"
import instance "../../render/instance"
import render "../../render"
import platform "../../platform"

// BENCH_TRACE_COLS / BENCH_TRACE_ROWS are the fixed deterministic grid dims.
BENCH_TRACE_COLS :: 80
BENCH_TRACE_ROWS :: 24

// BENCH_REPLAY_FRAMES is the replay count per bench_play_trace call.
BENCH_REPLAY_FRAMES :: 1000

// BENCH_FULL_SEED selects the max-submit (full-damage) fixture in
// bench_record_trace. Seed 0 selects the zero-count (skipped/empty) trace.
BENCH_FULL_SEED :: max(u64)

// BENCH_ADOPT_MIN_IMPROVEMENT_PCT is the relative mean-submit improvement at
// or above which bench_compare reports Adopt_Sdl3_Gpu. Anything at or below
// it stays Keep_Wgpu (null stands); missing or mismatched data is
// Inconclusive. Mirrors the ≥10% ADOPT threshold of the DecisionGate.
BENCH_ADOPT_MIN_IMPROVEMENT_PCT :: 10.0

// Bench_Frame_Trace is a deterministic, backend-independent capture of one
// grid shape: per-pass instance counts plus opaque instance bytes used only
// for parity hashing on replay.
Bench_Frame_Trace :: struct {
	cols:           i32,
	rows:           i32,
	bg_count:       u32,
	glyph_count:    u32,
	instance_bytes: []u8,
	seed:           u64,
}

// Bench_Metrics aggregates one bench_play_trace run.
Bench_Metrics :: struct {
	frames:              u64,
	cpu_submit_ns_total: u64,
	present_ns_total:    u64,
	bytes_hash:          u64,
}

// Bench_Backend_Under_Test binds a name to a vtable plus its device/queue.
// The backend owns its window/device/queue lifecycle outside this struct;
// bench_play_trace only issues submit-tail calls and releases nothing.
Bench_Backend_Under_Test :: struct {
	name:   string,
	vtable: ^gpu.Gpu_Backend_VTable,
	device: gpu.Gpu_Device,
	queue:  gpu.Gpu_Queue,
}

// Bench_Verdict is the DecisionGate input produced by bench_compare.
Bench_Verdict :: enum int {
	Keep_Wgpu,
	Adopt_Sdl3_Gpu,
	Inconclusive,
}

// Bench_Comparison carries the reference run, a human-readable note, and the
// verdict. present-to-present and variance analysis live outside this struct
// (callers aggregate repeated runs); see bench_register for the gate summary.
Bench_Comparison :: struct {
	wgpu:        Bench_Metrics,
	native_note: string,
	verdict:     Bench_Verdict,
}

// bench_record_trace captures a deterministic fixed-grid trace. A nil Renderer
// or seed 0 yields the zero-count trace (empty-grid variant: the caller
// asserts skip parity for it). BENCH_FULL_SEED yields the max-submit
// (full-damage) fixture; any other seed yields the typical fixture with a
// deterministic glyph fraction. No GPU calls are issued.
bench_record_trace :: proc(r: ^render.Renderer, seed: u64, allocator: runtime.Allocator = context.allocator) -> Bench_Frame_Trace {
	t: Bench_Frame_Trace
	t.seed = seed
	if r == nil || seed == 0 {
		return t
	}
	cols := r.cols
	rows := r.rows
	if cols <= 0 {
		cols = BENCH_TRACE_COLS
	}
	if rows <= 0 {
		rows = BENCH_TRACE_ROWS
	}
	t.cols = cols
	t.rows = rows
	cell_count := u64(cols) * u64(rows)
	t.bg_count = u32(cell_count)
	if seed == BENCH_FULL_SEED {
		t.glyph_count = u32(cell_count)
	} else {
		rng := seed
		frac := _bench_next_rand(&rng) % 100
		t.glyph_count = u32(cell_count * frac / 100)
	}
	byte_count := (u64(t.bg_count) + u64(t.glyph_count)) * u64(instance.INSTANCE_STRIDE)
	if byte_count == 0 {
		return t
	}
	t.instance_bytes = make([]u8, byte_count, allocator)
	rng := seed | 1
	for i in 0..<len(t.instance_bytes) {
		t.instance_bytes[i] = u8(_bench_next_rand(&rng) >> 33)
	}
	return t
}

// bench_play_trace replays a trace's submit tail BENCH_REPLAY_FRAMES times
// against b and returns aggregate metrics. Surface Lost has no surface in
// scope here, so any backend that cannot submit (nil backend/vtable/device/
// queue) yields the discard: frames=0. A zero-count trace yields a
// zero-submit run (hash only, no vtable calls). present_ns_total stays 0:
// present-to-present requires a surface-backed run and is measured outside.
bench_play_trace :: proc(t: ^Bench_Frame_Trace, b: ^Bench_Backend_Under_Test) -> Bench_Metrics {
	m: Bench_Metrics
	if t == nil || b == nil || b.vtable == nil {
		return m
	}
	if rawptr(b.device) == nil || rawptr(b.queue) == nil {
		return m
	}
	m.frames = BENCH_REPLAY_FRAMES
	m.bytes_hash = bench_hash_frame(t.instance_bytes)
	if len(t.instance_bytes) == 0 {
		return m
	}
	total: u64 = 0
	for _ in 0..<BENCH_REPLAY_FRAMES {
		total += _bench_submit_once(b)
	}
	m.cpu_submit_ns_total = total
	return m
}

// bench_hash_frame hashes frame bytes with FNV-1a (64-bit). Empty input
// hashes to the offset basis.
bench_hash_frame :: proc(bytes: []u8) -> u64 {
	FNV_OFFSET :: 14695981039346656037
	FNV_PRIME :: 1099511628211
	h: u64 = FNV_OFFSET
	for v in bytes {
		h ~= u64(v)
		h *= FNV_PRIME
	}
	return h
}

// bench_compare reduces a reference run (a, wgpu) and a candidate run (b) to
// a verdict. Inconclusive when either run is a discard, the frame counts
// differ, the parity hashes differ, or neither run measured submit time
// (timer resolution below effect: raise N). Otherwise the relative mean
// delta gates Keep_Wgpu vs Adopt_Sdl3_Gpu at BENCH_ADOPT_MIN_IMPROVEMENT_PCT.
bench_compare :: proc(a: Bench_Metrics, b: Bench_Metrics) -> Bench_Comparison {
	c: Bench_Comparison
	c.wgpu = a
	if a.frames == 0 || b.frames == 0 {
		c.native_note = "inconclusive: discard run (frames=0); only clean runs gate"
		c.verdict = .Inconclusive
		return c
	}
	if a.frames != b.frames {
		c.native_note = "inconclusive: frame-count mismatch; rerun with equal N"
		c.verdict = .Inconclusive
		return c
	}
	if a.bytes_hash != b.bytes_hash {
		c.native_note = "inconclusive: parity hash mismatch; submits diverged"
		c.verdict = .Inconclusive
		return c
	}
	if a.cpu_submit_ns_total == 0 || b.cpu_submit_ns_total == 0 {
		c.native_note = "inconclusive: submit time below timer resolution; raise N"
		c.verdict = .Inconclusive
		return c
	}
	mean_a := f64(a.cpu_submit_ns_total) / f64(a.frames)
	mean_b := f64(b.cpu_submit_ns_total) / f64(b.frames)
	improvement_pct := (mean_a - mean_b) / mean_a * 100.0
	if improvement_pct >= BENCH_ADOPT_MIN_IMPROVEMENT_PCT {
		c.native_note = "candidate faster than wgpu reference beyond threshold"
		c.verdict = .Adopt_Sdl3_Gpu
		return c
	}
	c.native_note = "within noise; KEEP (null stands)"
	c.verdict = .Keep_Wgpu
	return c
}

// _bench_submit_once issues one submit-tail triplet against b and returns its
// CPU nanoseconds. No render pass is encoded: no surface is in scope, so the
// measurement is the device-backed submit floor shared by all backends.
_bench_submit_once :: proc(b: ^Bench_Backend_Under_Test) -> u64 {
	vt := b.vtable
	start := platform.platform_now()
	enc := vt.create_command_encoder(b.device)
	cmd := vt.finish_command_buffer(enc)
	_ = vt.submit(b.queue, cmd)
	end := platform.platform_now()
	delta := platform.platform_ticks_to_ns(end - start)
	if delta < 0 {
		return 0
	}
	return u64(delta)
}

// _bench_next_rand advances a xorshift64 state. Used only to derive
// deterministic trace bytes from the seed.
_bench_next_rand :: proc(state: ^u64) -> u64 {
	x := state^
	x ~= x << 13
	x ~= x >> 7
	x ~= x << 17
	state^ = x
	return x
}
