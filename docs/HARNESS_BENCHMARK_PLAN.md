# Harness & Benchmark Plan — V2.2

Status: LOCKED (revision requires a new version number and a changelog entry).
Scope: `src/core/chrome`, `src/core/composer`, `src/cmd/harness_composer`,
`src/cmd/harness_render_chrome`, `src/cmd/harness_render_terminal`.

Claim tags used in this document and in every harness output:
- `[MEASURED]` — produced by a test or harness run on a recorded commit.
- `[HYPOTHESIS]` — plausible, not yet measured; must name the test that would decide it.
- `[UNKNOWN]` — not measured and no test planned yet.

---

## 0. Changelog

### V2.2 (this version)
1. Idle/blink moved to a **virtual clock**: exact counts, no ±1 tolerance, CPU-only.
2. Atlas upload p99 threshold marked **PROVISIONAL**; locking procedure defined (§5.3). Tail metrics use the per-run p99 as the CI sample unit.
3. Local-calibration normalization (`≤ 1.15× local baseline`) **removed** (circular). Replaced by a committed baseline file from the reference machine (§5.4).
4. Invariance, idle/blink, capacity rejection and lifecycle net-zero moved from `make test-gpu` to `make test` via a counting mock `contract.*` vtable. Only BGRA8 readback tests need a GPU.
5. Neg-6 reworded: it detects **buffer aliasing** in the comparator (comparing a buffer with itself), not anti-aliasing.
6. Reference machine identified from real checks (§1). Refresh-rate-dependent claims made conditional on the runtime-read refresh rate.
7. Pass taxonomy split into raster pass vs composite pass (§3.2).

### V2.1
- Lifecycle claim changed to net-zero; steady-state zero-alloc kept as a separate claim.
- `make test` / `make test-gpu` split.
- Student-t over individual frames rejected (frames are correlated); per-run mean is the sample unit; slope CI from regression standard error.
- Restored metric definitions table, `Scen_Scale_Full_Regression`, idle-0 case, Strategy A target, atlas p99, CPU-only marking of extreme animation.
- Pinned PRNG, same-process truth comparison, logical-field capacity hash, exact blink toggle rate.

---

## 1. Reference Machine

| Field | Value | Source |
|---|---|---|
| Model | MacBook Air, `Mac14,2` | `system_profiler SPHardwareDataType` [MEASURED] |
| Chip | Apple M2, CPU 8 cores (4P + 4E), GPU 8 cores | `system_profiler` [MEASURED] |
| Cooling | Fanless | Model spec — thermal throttling is expected under sustained load |
| Built-in display | 2560 × 1664 Retina | `system_profiler SPDisplaysDataType` [MEASURED] |
| Refresh rate | 60 Hz per Apple spec | [UNKNOWN] at runtime until the harness reads it (§4.1) |
| Toolchain | Odin `dev-2026-08:8412dc37a` | `odin version` [MEASURED] |

Consequences:
- Statistical verdicts (PASS/FAIL/INCONCLUSIVE) are issued **only** on this machine. Other machines produce report-only comparisons against the committed baseline file.
- Any FIFO jank number is interpreted against the refresh rate read at runtime. A 120 Hz criterion is not applicable on a 60 Hz panel.
- Every run records thermal state at start and end. A run whose thermal state is not `nominal` at either point is **INVALID** and is re-run, never averaged in.

---

## 2. Test Targets

| Target | Hardware | Gates CI | Contents |
|---|---|---|---|
| `make test` | CPU only | Yes | `core/chrome/*` tests; `core/composer` tests incl. `frame/tests` (mock vtable + virtual clock); scheduler, transition, render contract tests |
| `make test-gpu` | GPU required | Yes, on GPU runners | BGRA8 readback: truth fuzzer, Neg-1..6, ink-overhang audit |
| `make bench` | Reference machine | No (report + tri-state verdict) | Statistical metrics (§5) |

Rule: a test goes to `make test-gpu` only if it needs pixel readback from a real device. Everything that can be counted through the mock `contract.*` vtable runs in `make test`.

---

## 3. Metric Definitions

### 3.1 Metrics table

| Metric | Exact definition (what is measured) | Excluded | Unit |
|---|---|---|---|
| CPU Time per Frame | Wall-clock CPU time from command-encoder creation to return of `contract.submit` within one `frame_tick` | GPU execution, vsync wait, surface acquire wait, present | µs |
| GPU Submission Count | Number of `contract.submit` calls observed by the counting hook | Driver-internal submissions | calls |
| Raster Pass Count | `begin_render_pass` calls whose color view is a layer backing view | Composite passes, compute passes | passes |
| Composite Pass Count | `begin_render_pass` calls whose color view is the frame target view | Raster passes | passes |
| Presented Count | Successful `present` returns | Frames skipped while the surface is occluded/hidden | frames |
| CPU-only FPS | `1 / CPU Time per Frame` | Not a display frame rate; not bounded by vsync | FPS |
| FIFO Present Latency | Time from frame commit to the presentable buffer being ready, FIFO present mode only | Offscreen/headless and Immediate mode | ms |
| Steady-State Allocations | Odin-side allocation count (heap + temp allocator, via tracking allocator) over the measured frame loop after warmup | One-time init/warmup; driver/C/Metal allocations | count (target 0) |
| Lifecycle Net-Zero | Outstanding Odin bytes and live allocation entries after N acquire→resize→release cycles, compared to the pre-loop baseline | Transient allocations during the loop (allowed if fully released) | bytes, entries (target: equal to baseline) |
| Pixel Mismatch Count | BGRA8 pixels that differ bitwise between partial render and full render of the same state | Cross-machine differences (comparison is same device, same process) | pixels (target 0) |

### 3.2 Pass taxonomy and invariants

| State | Raster passes | Composite passes | Submits |
|---|---|---|---|
| All layers clean and static | 0 | 0 | 0 |
| Clean layer moving (transition) | 0 | 1 per ticked frame | 1 per ticked frame |
| K dirty layers | K | 1 | 1 |

`composer_pipeline_should_render` means "raster work exists this frame". It is **not** a composite/present gate [MEASURED: `test_clean_moving_layer_composites_without_raster`].

---

## 4. Run Discipline (`make bench`)

### 4.1 Environment header (printed from real checks, never hardcoded)
Power source; Low Power Mode; thermal state (start and end of each run); QoS class; swapchain resolution and format; refresh rate read at runtime; present mode; surface state (visible/occluded); commit hash plus dirty flag; Odin version; wgpu-native version; macOS version; PRNG seed.

### 4.2 Procedure
1. Uncaptured-error callback installed. Any error during a scenario marks it **INVALID**.
2. Warmup interleaved across all scenarios before measurement.
3. Scenario order shuffled per run with Fisher–Yates using the pinned PRNG (§6.1). The seed is logged.
4. At least 5 runs. At least 30 measured frames per (run, scenario) for mean metrics; 600–1000 frames for jank.
5. For presenting scenarios, `Presented Count ≠ frames` marks the scenario **INVALID**.
6. INVALID scenarios and runs are reported, never deleted and never averaged in. Thresholds are never moved after seeing data. No cause is inferred from a single run.

---

## 5. Statistics and Thresholds

### 5.1 Sample units
- **Mean metrics**: sample unit = mean of one run. 5 runs → df = 4, t(0.975, 4) = 2.776. 95% CI = mean ± 2.776 · s / √5.
- **Tail metrics (p99)**: sample unit = the p99 of one run (5 values), same t-interval.
- Individual frames are never used as independent samples (they are autocorrelated).
- Per-run spread (min/max of run means) and bimodality check are reported alongside every CI. Within-run distribution is reported as min / p50 / p95 / p99 / max.

### 5.2 Layer-count regression (`Scen_Scale_Full_Regression`)
- K ∈ {0, 1, 2, 4, 6, 8, 12, 16}. Observation = mean CPU Time per Frame of one (run, K) cell.
- **0→1 jump**: per-run paired difference L(1) − L(0); 5 differences; t-interval with df = 4.
- **1→N slope**: OLS over K ∈ {1, 2, 4, 6, 8, 12, 16} using all (run, K) cells (n = 35). CI from the regression standard error of the slope, df = n − 2 = 33. Not clamped.
- **R²** of the 1→N fit and per-K residuals are reported, so non-linearity (e.g. a jump at K = 12→16) is visible. The 5 per-run slopes are reported as a cross-check only; they do not drive the verdict.

### 5.3 Thresholds (reference machine §1)

Tri-state rule, fixed before running: CI upper < threshold → **PASS**; CI lower > threshold → **FAIL**; otherwise **INCONCLUSIVE**.

| Metric | Threshold | Status | Scenario |
|---|---|---|---|
| Normal 1-pane CPU Time per Frame | ≤ 80.0 µs | LOCKED | 1 layer, 1920×1080 target |
| 1→N marginal slope | ≤ 15.0 µs/layer | LOCKED | §5.2 |
| 0→1 base jump | ≤ 60.0 µs | LOCKED | §5.2 |
| Terminal Strategy A (Instance) CPU Time per Frame | < 80.0 µs | LOCKED | 120×40 grid, 1 dirty row |
| Atlas upload latency, p99 | < 150.0 µs | **PROVISIONAL** | Dynamic sub-slot upload |
| Jank rate | ≤ 2 per 1000 frames | REPORT-ONLY | FIFO; interval > 1.5 × runtime refresh period |
| `Scen_Extreme_Animation` | throughput only | REPORT-ONLY, **CPU-only (no present)** | 16 layers in transition |

Locking procedure for PROVISIONAL thresholds: one calibration run (5 runs) on the reference machine; the locked value is written into this document together with the calibration commit hash **before** any further run is inspected. Until then the metric is reported without a verdict.

### 5.4 Baseline file
- Path: `bench/baselines/mac14_2-m2.json`, committed.
- Contents: commit hash, Odin version, wgpu-native version, macOS version, date, environment header, and per metric: definition id, unit, the 5 per-run values, mean, CI low, CI high.
- Other machines: report-only comparison against this file.
- Reference machine regression check: flagged **REGRESSION** only when the new CI lower bound is above the baseline CI upper bound. Overlapping CIs → no claim.

---

## 6. Correctness (`make test-gpu`)

### 6.1 Pinned PRNG
xoshiro256** seeded through SplitMix64, implemented in-repo. No runtime or OS RNG. `--replay-seed=<S> --replay-mutation=<M>` reproduces a failure identically across OS and compiler versions.

### 6.2 Truth mode
Partial render vs full render of the same state, same device, same process. No golden images and no cross-machine comparison. Nearest sampling, no MSAA, integer pixel coordinates. Comparator is byte-exact on BGRA8. Damage comes from the production damage journal (`contract.Damage_Rect`). Real font atlas.

### 6.3 Fuzzer
- Corpus: 20 seeds × 500 edits. Gate: 0 mismatching pixels.
- Mutation classes: plain ASCII edit; attribute-only change (style/color, same codepoint); wide CJK at the last column; combining and ZWJ clusters; descenders (`g y p q j _`); italic overhang next to box drawing; cursor and selection overlay; scroll.
- Generator self-audit: every mutation class must occur at least once per seed; a seed with a missing class fails the run.
- On failure: log `[FAIL] Seed: S, Mutation: M, Kind: K, Cell: (r, c), First Mismatch Pixel: (x, y)` and dump `artifacts/fuzz_fail_seedS_mM_partial.png`, `_full.png`, `_diff.png` (magenta).

### 6.4 Negative tests (each MUST be detected)
| Id | Injected defect | Must be caught by |
|---|---|---|
| Neg-1 | ±1 column dilation disabled | horizontal overhang mutations |
| Neg-2 | Space background emission disabled on partial render | glyph-erase mutations |
| Neg-3 | Background and glyph pass order reversed | any overlapping edit |
| Neg-4 | Vertical damage reduced by 1 row | descender mutations |
| Neg-5 | Damage skipped for attribute-only changes | attribute-only mutations |
| Neg-6 | 1-byte change injected into the ground-truth copy | comparator self-audit: detects buffer aliasing (comparing a buffer with itself) |

Gate: 6/6 detected by the fixed corpus. For each Neg-N the first (seed, mutation) that detects it is recorded in the run output.

### 6.5 Ink-overhang audit
ASCII 32–126 and Box Drawing U+2500–U+257F rendered in isolation; any ink outside the cell plus the dilation margin fails.

---

## 7. Deterministic CPU Gates (`make test`)

| Gate | Expected | Status |
|---|---|---|
| Idle, no damage, virtual clock 10 s | exactly 0 submits, 0 raster, 0 composite | [MEASURED] `test_idle_zero_submits` (82033ba) |
| Blink, interval 500 ms (2 toggles/s), window (t0, t0+10 s], steps 1 ms and 7 ms | exactly 20 submits, 20 raster, 20 composite | [MEASURED] `test_blink_exactly_20_in_10s` (82033ba) |
| Blink deadline rule | next = previous deadline + interval (drift-free) | [MEASURED] same test |
| Clean layer moving, 200 ms transition, 1 ms ticks | 201 composite, 201 submits, 0 raster | [MEASURED] `test_clean_moving_layer_composites_without_raster` (82033ba) |
| One-shot deadline | exactly 1 frame, deadline consumed | [MEASURED] `test_one_shot_deadline_consumed` (82033ba) |
| Capacity: 17th layer | `ok = false`; FNV-1a 64 hash of logical fields unchanged; no texture created | [MEASURED] `test_capacity_rejection_logical_hash` (82033ba) |
| Lifecycle 10,000 × acquire→resize→release | Odin bytes and entries equal baseline; textures created = destroyed | [MEASURED] `test_lifecycle_net_zero_10k` (82033ba) |
| Steady state 1,000 ticks | 0 Odin allocations | [MEASURED] `test_steady_state_zero_alloc` (82033ba) |
| `core/chrome` hit test with NaN/±Inf points | `.None` | [MEASURED] `test_hit_test_non_finite_points` (c0523f9) |
| Divider drawn = divider hittable (ratios 0.01, 0.99, NaN) | agree | [MEASURED] `test_hit_test_divider_matches_emitted_divider` (c0523f9) |
| Tab emit with 1024-rune ZWJ/combining title, 128 tabs, 1,000 frames | 0 allocations | [MEASURED] `test_tabs_extreme_title_roundtrip_and_zero_alloc_emit` (c0523f9) |
| Modal emit, 1,000 frames | 0 allocations | [MEASURED] `test_modal_emit_zero_alloc` (c0523f9) |

Logical capacity hash fields: per slot `id, slot_index, kind, width, height, in_use, is_dirty, version, dest_rect, scissor_rect, opacity, corner_radius`; plus `layer_order[0..<layer_count]` and `layer_count`. Raw memory is never hashed.

---

## 8. Scenarios per Harness

### 8.1 `harness_composer` (pure composer)
- Normal: 1 pane at 1920×1080; 2×2 panes.
- `Scen_Scale_Full_Regression` (§5.2).
- Extreme: 16-layer overdraw at 3840×2160 checkerboard (reports CPU-side cost only; GPU fill cost [UNKNOWN] in V2.2); pathological scissors (0×0, negative origin, beyond target); `Scen_Extreme_Animation` (CPU-only, no present).

### 8.2 `harness_render_chrome` (refactor of `harness_render_composer`)
- Consumes `preview_*` fixtures from `core/chrome`.
- Normal: 2–6 tabs, 1 px divider. Extreme: 1000 SDF elements, radius > half size, divider drag.
- Migrates its frame loop to `frame/frame_tick`.

### 8.3 `harness_render_terminal`
- No VT parser, no PTY: `Synthetic_Cell` 2D grid + `contract.Damage_Rect`.
- Grids: 80×24, 120×40, 160×50, 500×200.
- Truth fuzzer (§6.3), Neg-1..6 (§6.4), ink-overhang audit (§6.5), 5000-glyph atlas pressure.
- Dirty sweep 0.1%, 1%, 5%, 25%, 100%; strategy selector checked deterministically at 2.9% / 3.0% / 64.9% / 65.0%.

---

## 9. Known Findings

| Finding | Tag | Handling |
|---|---|---|
| `scheduler_frame_done` does not clear an expired deadline; `scheduler_needs_frame` then stays true every tick | [MEASURED] `test_scheduler_deadline_not_cleared_by_frame_done` | `frame_tick` consumes the expired one-shot deadline. `harness_render_composer` loop still uses the old path until Step 3 |
| `should_render` is not a present gate | [MEASURED] | Documented on the proc |
| Runtime refresh rate of the reference display | [UNKNOWN] | Read by the environment header (§4.1) |
| GPU execution time | [UNKNOWN] | Out of scope for V2.2 verdicts |

---

## 10. Execution Order and Status

| Step | Content | Status |
|---|---|---|
| 1 | `core/chrome` previews + headless tests | DONE (6fba6e4, c0523f9) |
| 2a | `core/composer/frame` + CPU deterministic gates (§7) | DONE (82033ba) |
| 2b | `harness_composer` bench: env header, run discipline, regression, baseline file, extreme scenarios | TODO |
| 3 | `harness_render_chrome` | TODO |
| 4 | `harness_render_terminal` | TODO |
| 5 | Makefile: `test-gpu`, `bench`, harness targets | TODO (`make test` split done in 82033ba) |

After each step the report states what was verified, what was not, and which numbers must not be trusted.
