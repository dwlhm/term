package gpu_bench

// Phase 17 bench register: additive wiring point for the bench harness CLI.
//
// bench_register runs the offline-capable gates (hash determinism, null
// overhead finite, A/A compare) and prints the DecisionGate thresholds. It
// issues no GPU calls, opens no window, and changes no existing signature.

import "core:fmt"

// bench_register wires the Phase 17 measurement bench into the bench harness
// CLI. Returns true when every offline gate passes.
bench_register :: proc() -> bool {
	fmt.println("=== Phase 17 GPU measurement bench ===")
	fmt.println("  artifacts: src/render/shaders/msl_spike/*.msl (reference text; translation BLOCKED-EXPLICIT, see TRANSLATION_STATUS.txt)")

	pass := true

	// Hash gate: determinism + empty-basis + avalanche on one bit.
	h1 := bench_hash_frame([]u8{1, 2, 3})
	h2 := bench_hash_frame([]u8{1, 2, 3})
	h3 := bench_hash_frame([]u8{1, 2, 4})
	h0 := bench_hash_frame(nil)
	if h1 != h2 || h1 == h3 || h0 != 14695981039346656037 {
		fmt.println("  [FAIL] hash gate")
		pass = false
	} else {
		fmt.println("  [ok] hash gate (deterministic FNV-1a)")
	}

	// Elision gate: null overhead must be finite (sink live, timer advanced).
	ns := bench_measure_vtable_overhead(BENCH_REPLAY_FRAMES)
	if ns == max(u64) {
		fmt.println("  [FAIL] elision gate (max(u64); sink dead or timer stalled)")
		pass = false
	} else {
		fmt.printfln("  [ok] null vtable overhead: %v ns/frame (mean over %v frames)", ns, BENCH_REPLAY_FRAMES)
	}

	// A/A gate: identical runs compare Keep_Wgpu with identical hashes.
	ref := Bench_Metrics{frames = BENCH_REPLAY_FRAMES, cpu_submit_ns_total = 42000, present_ns_total = 0, bytes_hash = h1}
	cmp := bench_compare(ref, ref)
	if cmp.verdict != .Keep_Wgpu {
		fmt.println("  [FAIL] A/A gate")
		pass = false
	} else {
		fmt.println("  [ok] A/A gate (identical runs -> Keep_Wgpu)")
	}

	fmt.printfln("  ADOPT threshold: candidate >= %.1f%% p95 present-to-present over 3 runs + identical hashes + compute feasible; else KEEP", BENCH_ADOPT_MIN_IMPROVEMENT_PCT)
	fmt.printfln("  verdict: %v", "REGISTERED" if pass else "GATES FAILING")
	return pass
}
