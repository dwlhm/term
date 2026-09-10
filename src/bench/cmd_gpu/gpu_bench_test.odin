package gpu_bench

// Phase 17 verification: A/A gate, elision gate, driver gate, noise gate.
//
// Headless-safe: the null backend stands in for WGPU where no surface
// exists; the SDL3 spike runs only when a window can be created and reports
// its driver note either way. Present-to-present and the Metal run stay
// deferred; the DecisionGate record below reflects that.

import "core:fmt"
import "core:testing"
import sdl3 "vendor:sdl3"
import bench_stats ".."
import gpu "../../render/gpu"
import render "../../render"
import win "../../platform/window"

BENCH_TEST_SEED :: 0x12345678

@test
test_hash_gate :: proc(t: ^testing.T) {
	a := bench_hash_frame([]u8{1, 2, 3})
	b := bench_hash_frame([]u8{1, 2, 3})
	c := bench_hash_frame([]u8{1, 2, 4})
	testing.expect(t, a == b, "hash must be deterministic")
	testing.expect(t, a != c, "hash must avalanche on one bit")
	testing.expect(t, bench_hash_frame(nil) == 14695981039346656037, "empty must hash to FNV offset basis")
}

@test
test_null_overhead_finite :: proc(t: ^testing.T) {
	ns := bench_measure_vtable_overhead(BENCH_REPLAY_FRAMES)
	testing.expect(t, ns != max(u64), "elision detected: sink dead or timer stalled")
	fmt.printfln("    null vtable overhead: %v ns/frame", ns)
}

@test
test_compare_aa_and_noise_gates :: proc(t: ^testing.T) {
	ref := Bench_Metrics{frames = BENCH_REPLAY_FRAMES, cpu_submit_ns_total = 42000, present_ns_total = 0, bytes_hash = 99}
	cmp := bench_compare(ref, ref)
	testing.expect(t, cmp.verdict == .Keep_Wgpu, "A/A identical runs must Keep_Wgpu")

	discard := bench_compare(Bench_Metrics{}, ref)
	testing.expect(t, discard.verdict == .Inconclusive, "discard run must be Inconclusive")

	mismatch := bench_compare(ref, Bench_Metrics{frames = BENCH_REPLAY_FRAMES, cpu_submit_ns_total = 42000, present_ns_total = 0, bytes_hash = 100})
	testing.expect(t, mismatch.verdict == .Inconclusive, "hash mismatch must be Inconclusive")

	faster := bench_compare(ref, Bench_Metrics{frames = BENCH_REPLAY_FRAMES, cpu_submit_ns_total = 1000, present_ns_total = 0, bytes_hash = 99})
	testing.expect(t, faster.verdict == .Adopt_Sdl3_Gpu, ">10% faster candidate must Adopt_Sdl3_Gpu")
}

@test
test_record_fixtures :: proc(t: ^testing.T) {
	empty := bench_record_trace(nil, BENCH_TEST_SEED)
	defer delete(empty.instance_bytes)
	testing.expect(t, empty.bg_count == 0 && empty.glyph_count == 0 && len(empty.instance_bytes) == 0, "nil renderer must yield zero-count trace")

	r := render.Renderer{cols = BENCH_TRACE_COLS, rows = BENCH_TRACE_ROWS}
	typical := bench_record_trace(&r, BENCH_TEST_SEED)
	defer delete(typical.instance_bytes)
	testing.expect(t, typical.cols == BENCH_TRACE_COLS && typical.rows == BENCH_TRACE_ROWS, "typical must be fixed 80x24")
	testing.expect(t, len(typical.instance_bytes) > 0, "typical must carry instance bytes")

	full := bench_record_trace(&r, BENCH_FULL_SEED)
	defer delete(full.instance_bytes)
	testing.expect(
		t,
		full.bg_count == u32(BENCH_TRACE_COLS * BENCH_TRACE_ROWS) && full.glyph_count == u32(BENCH_TRACE_COLS * BENCH_TRACE_ROWS),
		"full fixture must be max-submit",
	)

	again := bench_record_trace(&r, BENCH_TEST_SEED)
	defer delete(again.instance_bytes)
	testing.expect(t, bench_hash_frame(typical.instance_bytes) == bench_hash_frame(again.instance_bytes), "same seed must hash identically")
}

@test
test_full_runs_decision_gate :: proc(t: ^testing.T) {
	r := render.Renderer{cols = BENCH_TRACE_COLS, rows = BENCH_TRACE_ROWS}
	null_backend := Bench_Backend_Under_Test{
		name   = "null",
		vtable = bench_null_vtable(),
		device = Bench_Device_Sentinel,
		queue  = Bench_Queue_Sentinel,
	}

	fixtures := [3]Bench_Frame_Trace{
		bench_record_trace(nil, 0),
		bench_record_trace(&r, BENCH_TEST_SEED),
		bench_record_trace(&r, BENCH_FULL_SEED),
	}
	defer for &f in fixtures {
		delete(f.instance_bytes)
	}
	names := [3]string{"empty", "typical", "full"}

	for i in 0..<len(fixtures) {
		sc := bench_stats.stats_init(8)
		for _ in 0..<5 {
			m := bench_play_trace(&fixtures[i], &null_backend)
			testing.expect(t, m.frames == BENCH_REPLAY_FRAMES, "clean run must report full frames")
			testing.expect(t, m.bytes_hash == bench_hash_frame(fixtures[i].instance_bytes), "parity hash must match trace bytes")
			bench_stats.stats_add_sample(&sc, f64(m.cpu_submit_ns_total) / f64(m.frames))
		}
		res := bench_stats.stats_compute(&sc)
		bench_stats.stats_destroy(&sc)
		fmt.printfln(
			"    fixture %s: mean %.1fns p95 %.1fns stddev %.1fns hash %v",
			names[i], res.mean, res.p95, res.stddev, bench_hash_frame(fixtures[i].instance_bytes),
		)
	}

	aa_a := bench_play_trace(&fixtures[1], &null_backend)
	aa_b := bench_play_trace(&fixtures[1], &null_backend)
	cmp := bench_compare(aa_a, aa_b)
	testing.expect(t, cmp.verdict == .Keep_Wgpu, "A/A null-vs-null must Keep_Wgpu")
	fmt.printfln("    A/A typical-vs-typical: verdict %v (%s)", cmp.verdict, cmp.native_note)
	fmt.println("    DecisionGate record: KEEP (present-to-present deferred to Metal run; tile_compute blocked-explicit; no Phase-18 authorization)")
}

@test
test_bench_register_gates :: proc(t: ^testing.T) {
	testing.expect(t, bench_register(), "offline gates must pass")
}

@test
test_spike_driver_gate :: proc(t: ^testing.T) {
	testing.expect(t, sdl3_spike_shader_format(nil) == sdl3.GPU_SHADERFORMAT_INVALID, "nil device must yield invalid shader format")

	w: win.Window
	if !win.window_init(&w, "phase17-spike", 640, 480) {
		fmt.println("    spike skipped: no window (headless); driver gate deferred to Metal run")
		return
	}
	defer win.window_destroy(&w)
	ok, note := sdl3_spike_present(win.window_get_sdl_handle(&w))
	defer delete(note)
	fmt.printfln("    spike: ok=%v note='%s'", ok, note)
	testing.expect(t, len(note) > 0, "driver gate must always log the actual driver name")
}

// Bench_Device_Sentinel / Bench_Queue_Sentinel are non-nil stand-ins for the
// null backend, which ignores both. Real backends must pass real handles.
Bench_Device_Sentinel := gpu.Gpu_Device(rawptr(uintptr(0x17beef11)))
Bench_Queue_Sentinel := gpu.Gpu_Queue(rawptr(uintptr(0x17beef22)))
