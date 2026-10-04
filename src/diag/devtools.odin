package diag

// DevTools sampling state.
//
// This file owns the single authoritative view of "how is the frame loop
// doing" that both the on-screen panel and the machine-readable log read
// from. Nothing here renders, nothing here parses configuration, and nothing
// here binds a key: consumers call devtools_snapshot and format it.
//
// Cost model, because this is wired into the per-frame path:
//   - devtools_enabled is a single relaxed atomic load, so the disabled path
//     is one branch.
//   - devtools_record_frame only pushes a fixed-size record into a ring.
//   - The expensive part, metrics_sample_cpu, is throttled to one call per
//     DEVTOOLS_SAMPLE_INTERVAL_NS, so it runs ~4x per second at most.
//   - Percentiles are computed on demand in devtools_snapshot, never per
//     frame, and they sort a reused scratch buffer instead of allocating.

import "base:runtime"
import "core:fmt"
import "core:sort"
import "core:strings"
import "core:sync"

import platform "../platform"

// Number of per-frame records kept. At 120Hz this is a little over two
// seconds of history, which is enough to see a spike and then read it back.
DEVTOOLS_RING_CAPACITY :: 256

// DEVTOOLS_SAMPLE_INTERVAL_NS is the ONE refresh cadence of the whole DevTools
// subsystem. There is deliberately no second interval anywhere: the on-screen
// panel (render.devtools_panel_refresh_due), the internal CPU re-sampling in
// devtools_snapshot, and the JSONL telemetry log (devtools_log_write_sample)
// all ask devtools_cadence_due for the same verdict at the same clock reading,
// so they cannot drift apart.
//
// Mach task/host queries are syscalls; at 4Hz they are free, at 120Hz they
// would be a measurable slice of the frame budget.
DEVTOOLS_SAMPLE_INTERVAL_NS :: 250_000_000

// Frame_Sample is one recorded frame. Fields the caller cannot cheaply
// obtain are left at zero rather than computed on the frame path.
Frame_Sample :: struct {
	frame_ns:     u64,
	parse_ns:     u64,
	gpu_ns:       u64,   // 0 means "not available this frame"
	gpu_valid:    bool,
	strategy:     string, // heap; caller-owned, caller deletes
	dirty_cells:  u32,
	upload_bytes: u64,
	pty_bytes:    u64,
	dropped:      bool,
	// presented is true only when the frame actually reached the display this
	// iteration. app_frame runs continuously and skips presentation when there
	// is nothing to draw, so "a sample was recorded" and "a frame was shown"
	// are different facts. Frame rate must be measured from the latter.
	presented: bool,
}

// Devtools_Snapshot is the aggregate view handed to consumers. Every field is
// derived either from the ring or from the throttled CPU sample; the struct
// owns no memory and stays valid until the caller drops it.
Devtools_Snapshot :: struct {
	fps:                 f64,
	drop_pct:            f64,
	frame_p50_ns:        u64,
	frame_p95_ns:        u64,
	frame_p99_ns:        u64,
	cpu_pct:             f32,
	system_cpu_pct:      f32,
	resident_bytes:      u64,
	thread_count:        u32,
	frame_max_ns:        u64,
	gpu_mean_ns:         u64,
	gpu_p95_ns:          u64,
	gpu_valid:           bool,
	present_mean_ns:     u64,
	// present_count counts frames the display actually received, as opposed to
	// sample_count, which counts loop iterations. fps is derived from this.
	present_count:       u64,
	strategy_instance:   u64,
	strategy_compute:    u64,
	strategy_fullscreen: u64,
	dirty_cells:         u64,
	upload_bytes:        u64,
	pty_bytes:           u64,
	parse_p95_ns:        u64,
	sample_count:        u64,
	dropped_count:       u64,
	// metrics_valid reports whether the CPU metrics in this snapshot were
	// actually sampled. Without it a consumer cannot tell "the process used
	// 0% CPU" from "CPU was never sampled", so the JSONL writer emits null
	// for the CPU fields when it is false.
	metrics_valid: bool,
}

// Ring heads. head is the next write slot, count how many are live.
@(private)
_devtools_state: struct {
	enabled: b32,

	frames:     [DEVTOOLS_RING_CAPACITY]Frame_Sample,
	frame_head: u32,
	frame_count: u32,

	gpu:       [DEVTOOLS_RING_CAPACITY]u64,
	gpu_valid: [DEVTOOLS_RING_CAPACITY]bool,
	gpu_head:  u32,
	gpu_count: u32,

	strategy_instance:   u64,
	strategy_compute:    u64,
	strategy_fullscreen: u64,
	dirty_cells:         u64,
	upload_bytes:        u64,
	pty_bytes:           u64,
	dropped_count:       u64,
	present_total_ns:    u64,
	present_count:       u64,
	sample_count:        u64,

	// active mirrors "the window is doing real work this frame", reported by
	// the app. It is part of the cadence rather than a second clock: while it
	// is false the cadence is neither due nor advanced, so the panel stops
	// rebuilding its text and the log writes no line, and the two surfaces
	// therefore always agree about whether the app was working.
	active:         bool,
	cadence_ns:     u64,
	// metrics_sampled_cadence is NOT a clock. It records which cadence
	// timestamp was already handed to metrics_sample_cpu, so two consumers
	// asking for a snapshot inside one tick pay for one sample, not two. The
	// cadence timestamp itself is the only timebase any sampling decision
	// reads.
	metrics_sampled_cadence: u64,
	// Actual counter-sample time; cadence_ns is only a scheduling anchor.
	metrics_sample_ns: u64,
	metrics_frames:          u64,
	// metrics_presents is the presented-frame counterpart of metrics_frames.
	// Frame rate is a property of frames the display actually received, not of
	// loop iterations: app_frame runs continuously and skips presentation
	// entirely when there is nothing dirty, so counting iterations inflates the
	// rate far above the display's refresh rate.
	metrics_presents:        u64,
	metrics_valid:           bool,
	metrics_prev:            Metric_Sample,
	fps:                     f64,
	cpu_pct:        f32,
	system_cpu_pct: f32,
	resident_bytes: u64,
	thread_count:   u32,

	mutex: sync.Mutex,
}

@(private)
_devtools_frame_scratch: [DEVTOOLS_RING_CAPACITY]u64
@(private)
_devtools_parse_scratch: [DEVTOOLS_RING_CAPACITY]u64
@(private)
_devtools_gpu_scratch: [DEVTOOLS_RING_CAPACITY]u64

// devtools_init resets the state and sets the initial enabled flag.
// Precondition: called once during app setup, before the frame loop starts.
devtools_init :: proc(enabled: bool) {
	sync.mutex_lock(&_devtools_state.mutex)
	defer sync.mutex_unlock(&_devtools_state.mutex)
	_devtools_reset_locked()
	sync.atomic_store(&_devtools_state.enabled, b32(enabled))
	// Default to "working"; the app reports the real per-frame value from
	// app_frame before the first present.
	_devtools_state.active = true
}

// devtools_enabled reports whether DevTools is collecting.
// This is the hot-path guard: one relaxed atomic load, no lock.
devtools_enabled :: proc() -> bool {
	return bool(sync.atomic_load(&_devtools_state.enabled))
}

// devtools_set_enabled turns collection on or off without clearing history.
devtools_set_enabled :: proc(on: bool) {
	sync.atomic_store(&_devtools_state.enabled, b32(on))
}

// devtools_toggle flips collection and returns the new state.
// Turning collection on clears the ring first, so the panel never opens onto
// stale spikes recorded minutes ago; turning it off keeps the last numbers
// available for a final log line.
devtools_toggle :: proc() -> bool {
	sync.mutex_lock(&_devtools_state.mutex)
	defer sync.mutex_unlock(&_devtools_state.mutex)
	on := !bool(sync.atomic_load(&_devtools_state.enabled))
	if on {
		_devtools_reset_locked()
	}
	sync.atomic_store(&_devtools_state.enabled, b32(on))
	return on
}

// devtools_record_frame appends one frame to the ring.
// Precondition: may be called from the render thread only; it takes the state
// mutex briefly and never allocates. A nil sample is ignored.
devtools_record_frame :: proc(s: ^Frame_Sample) {
	if s == nil do return
	if !devtools_enabled() do return

	sync.mutex_lock(&_devtools_state.mutex)
	defer sync.mutex_unlock(&_devtools_state.mutex)

	slot := &_devtools_state.frames[_devtools_state.frame_head]
	// The recorded strategy is a borrowed view of the caller's string. All
	// derived data (the class counts below) is computed here, inside the call,
	// so nothing dereferences the pointer after the caller frees it.
	slot^ = s^
	_devtools_state.frame_head = (_devtools_state.frame_head + 1) % u32(DEVTOOLS_RING_CAPACITY)
	if _devtools_state.frame_count < u32(DEVTOOLS_RING_CAPACITY) {
		_devtools_state.frame_count += 1
	}

	_devtools_state.sample_count += 1
	_devtools_state.dirty_cells += u64(s.dirty_cells)
	_devtools_state.upload_bytes += s.upload_bytes
	_devtools_state.pty_bytes += s.pty_bytes

	if s.dropped {
		_devtools_state.dropped_count += 1
	}
	// presented is the display contract, and it is independent of dropped:
	// a frame can be presented and still have taken longer than the budget, and
	// a frame can be skipped without being late at all.
	if s.presented {
		_devtools_state.present_total_ns += s.frame_ns
		_devtools_state.present_count += 1
	}

	if strings.contains(s.strategy, "Instance") {
		_devtools_state.strategy_instance += 1
	} else if strings.contains(s.strategy, "Compute") {
		_devtools_state.strategy_compute += 1
	} else if strings.contains(s.strategy, "Fullscreen") {
		_devtools_state.strategy_fullscreen += 1
	}
}

// devtools_record_gpu appends one GPU timing measurement.
//
// CRITICAL: the caller MUST obtain this measurement from an MTLCommandBuffer
// addCompletedHandler block, and MUST NEVER call waitUntilCompleted() (or any
// other blocking wait) to obtain it. Commit 34b2daa added Metal triple
// buffering precisely so CPU encoding can run ahead of the GPU; a synchronous
// wait here would serialise encoding against execution and delete that
// optimisation, turning a pipelined renderer into a stalling one. Record only
// after the command buffer has actually completed, and copy whatever you read
// out of the command buffer before releasing it.
//
// Precondition: callable from any thread, including a Metal completion
// handler. Only callable once the measurement is real; pass valid=false when
// there is nothing trustworthy to report.
devtools_record_gpu :: proc(gpu_ns: u64, valid: bool) {
	if !valid do return
	if !devtools_enabled() do return

	sync.mutex_lock(&_devtools_state.mutex)
	defer sync.mutex_unlock(&_devtools_state.mutex)

	_devtools_state.gpu[_devtools_state.gpu_head] = gpu_ns
	_devtools_state.gpu_valid[_devtools_state.gpu_head] = true
	_devtools_state.gpu_head = (_devtools_state.gpu_head + 1) % u32(DEVTOOLS_RING_CAPACITY)
	if _devtools_state.gpu_count < u32(DEVTOOLS_RING_CAPACITY) {
		_devtools_state.gpu_count += 1
	}
}

// devtools_set_active reports whether the app is doing real work this frame.
//
// While it is false the shared cadence reports not-due and is never advanced,
// so both consumers fall silent together: the panel serves its cached text
// instead of rebuilding it, and the JSONL writer writes nothing. That is what
// keeps the two surfaces from disagreeing about whether the app was working,
// and it is why the panel does not rebuild (and re-allocate) once per frame
// while the window sits idle.
//
// The app sets this once per frame, before presenting, so the panel decision
// and the log decision are made against the same reading.
devtools_set_active :: proc(on: bool) {
	sync.mutex_lock(&_devtools_state.mutex)
	defer sync.mutex_unlock(&_devtools_state.mutex)
	_devtools_state.active = on
}

// devtools_cadence_due reports whether the DevTools cadence is due at now_ns.
//
// CONTRACT: the cadence holds one anchor, the instant of the most recent
// devtools_cadence_tick, and a query at now_ns is due exactly when
// now_ns - anchor >= DEVTOOLS_SAMPLE_INTERVAL_NS. The interval boundary is
// inclusive: due at anchor + interval, not due at anchor + interval - 1. A
// clock that reads before the anchor is clamped to it rather than reported as
// due, so a consumer holding a slightly older reading never gets a spurious
// tick.
//
// This predicate is the subsystem's single refresh clock. It is deliberately
// NON-mutating: every consumer asks it the same question in the same frame
// and must get the same answer, so the advance lives in devtools_cadence_tick
// and is performed exactly once per tick by the frame loop, after the panel
// and the log have both consulted it.
//
// A caller must measure the contract against the anchor devtools_cadence_tick
// returned, not against a clock reading sampled independently before the tick:
// devtools_cadence_tick reads its own clock, so such a reading is strictly
// older than the anchor and would fail the boundary check by exactly that gap.
//
// now_ns == 0 means "no timestamp supplied". A clock-less caller must not be
// handed permanently stale data, so zero is always due.
devtools_cadence_due :: proc(now_ns: u64) -> bool {
	sync.mutex_lock(&_devtools_state.mutex)
	defer sync.mutex_unlock(&_devtools_state.mutex)
	return _devtools_cadence_due_locked(now_ns)
}

// _devtools_cadence_due_locked is the non-mutating due test. Caller holds the
// state mutex.
@(private)
_devtools_cadence_due_locked :: proc(now_ns: u64) -> bool {
	if !_devtools_state.active {
		return false
	}
	if now_ns == 0 {
		return true
	}
	return now_ns - min(now_ns, _devtools_state.cadence_ns) >= DEVTOOLS_SAMPLE_INTERVAL_NS
}

// devtools_cadence_tick advances the cadence and returns the new anchor, which
// is the instant every later devtools_cadence_due query is measured against:
// due iff now_ns - anchor >= DEVTOOLS_SAMPLE_INTERVAL_NS.
//
// It advances by one full interval, and re-anchors on its own clock reading
// when the previous anchor was more than one interval in the past, so a
// suspended process cannot wake up and burst. It therefore samples the clock
// itself and takes no argument: the returned anchor, not any reading taken
// before the call, is what the contract is defined against.
//
// It is idempotent in effect, not in time: calling it twice in one interval
// produces two anchors, so it must be called at most once per due tick. The
// frame loop does exactly that, after both consumers have read
// devtools_cadence_due for the tick.
devtools_cadence_tick :: proc() -> u64 {
	sync.mutex_lock(&_devtools_state.mutex)
	defer sync.mutex_unlock(&_devtools_state.mutex)
	return _devtools_cadence_advance_locked()
}

// _devtools_cadence_advance_locked moves the anchor forward one interval. A
// tick that arrives more than a whole interval late re-anchors onto the
// current clock instead of replaying every missed tick, so a suspended
// process cannot wake up and burst. Caller holds the state mutex.
@(private)
_devtools_cadence_advance_locked :: proc() -> u64 {
	now_ns := u64(platform.platform_ticks_to_ns(platform.platform_now()))
	next := _devtools_state.cadence_ns + DEVTOOLS_SAMPLE_INTERVAL_NS
	if _devtools_state.cadence_ns == 0 ||
	   now_ns - min(now_ns, next) > DEVTOOLS_SAMPLE_INTERVAL_NS {
		next = now_ns
	}
	_devtools_state.cadence_ns = next
	return next
}

// devtools_snapshot returns the aggregate view, refreshing the CPU metrics
// first when the shared cadence is due.
//
// The returned struct owns no memory. Percentiles are order statistics over
// the ring, not running means: a mean of frame times is dominated by the bulk
// of quiet frames and silently absorbs a 40ms spike, which is the exact
// failure this instrumentation exists to catch. Sorting a copy of the ring and
// indexing the rank keeps the tail visible.
devtools_snapshot :: proc() -> Devtools_Snapshot {
	sync.mutex_lock(&_devtools_state.mutex)
	defer sync.mutex_unlock(&_devtools_state.mutex)

	now_ns := u64(platform.platform_ticks_to_ns(platform.platform_now()))
	if !_devtools_state.metrics_valid ||
	   (_devtools_cadence_due_locked(now_ns) && _devtools_state.metrics_sampled_cadence != _devtools_state.cadence_ns) {
		prev_sample_ns := _devtools_state.metrics_sample_ns
		sample := metrics_sample_cpu()
		if _devtools_state.metrics_valid && prev_sample_ns > 0 && now_ns > prev_sample_ns {
			elapsed := now_ns - prev_sample_ns
			// Presented frames per second: the rate the display actually saw.
			// sample_count would report loop iterations, which run far faster
			// than the display whenever presentation is skipped.
			presented := _devtools_state.present_count - _devtools_state.metrics_presents
			_devtools_state.fps = f64(presented) * 1_000_000_000.0 / f64(elapsed)
			_devtools_state.cpu_pct = metrics_cpu_pct(&_devtools_state.metrics_prev, sample, elapsed)
		}
		_devtools_state.metrics_sample_ns = now_ns
		_devtools_state.metrics_prev = sample
		_devtools_state.metrics_sampled_cadence = _devtools_state.cadence_ns
		_devtools_state.metrics_frames = _devtools_state.sample_count
		_devtools_state.metrics_presents = _devtools_state.present_count
		_devtools_state.metrics_valid = true
		_devtools_state.system_cpu_pct = metrics_system_cpu_pct(sample)
		_devtools_state.resident_bytes = sample.resident_bytes
		_devtools_state.thread_count = sample.thread_count
	}

	snap: Devtools_Snapshot
	snap.metrics_valid = _devtools_state.metrics_valid
	snap.fps = _devtools_state.fps
	snap.cpu_pct = _devtools_state.cpu_pct
	snap.system_cpu_pct = _devtools_state.system_cpu_pct
	snap.resident_bytes = _devtools_state.resident_bytes
	snap.thread_count = _devtools_state.thread_count
	snap.strategy_instance = _devtools_state.strategy_instance
	snap.strategy_compute = _devtools_state.strategy_compute
	snap.strategy_fullscreen = _devtools_state.strategy_fullscreen
	snap.dirty_cells = _devtools_state.dirty_cells
	snap.upload_bytes = _devtools_state.upload_bytes
	snap.pty_bytes = _devtools_state.pty_bytes
	snap.sample_count = _devtools_state.sample_count
	snap.dropped_count = _devtools_state.dropped_count
	snap.present_count = _devtools_state.present_count
	if snap.sample_count > 0 {
		snap.drop_pct = f64(snap.dropped_count) * 100.0 / f64(snap.sample_count)
	}
	if _devtools_state.present_count > 0 {
		snap.present_mean_ns = _devtools_state.present_total_ns / _devtools_state.present_count
	}

	// Order statistics: copy the live portion of the ring into the reused
	// scratch buffer, sort it, then index by rank.
	live := int(_devtools_state.frame_count)
	frame_n := 0
	parse_n := 0
	for i in 0..<live {
		idx := (int(_devtools_state.frame_head) - live + i + int(DEVTOOLS_RING_CAPACITY)) % int(DEVTOOLS_RING_CAPACITY)
		sample := &_devtools_state.frames[idx]
		_devtools_frame_scratch[frame_n] = sample.frame_ns
		frame_n += 1
		if sample.parse_ns > 0 {
			_devtools_parse_scratch[parse_n] = sample.parse_ns
			parse_n += 1
		}
	}
	frames := _devtools_frame_scratch[:frame_n]
	parse := _devtools_parse_scratch[:parse_n]
	if len(frames) > 0 {
		// Sort first, then read the top of the range. Taking frames[n-1]
		// before the sort yields the most recently recorded frame instead of
		// the slowest one, which made p99 exceed the reported maximum.
		sort.sort(sort.slice_interface(&frames))
		snap.frame_max_ns = frames[frame_n - 1]
		snap.frame_p50_ns = _devtools_percentile(frames, 50, 100)
		snap.frame_p95_ns = _devtools_percentile(frames, 95, 100)
		snap.frame_p99_ns = _devtools_percentile(frames, 99, 100)
	}
	if len(parse) > 0 {
		sort.sort(sort.slice_interface(&parse))
		snap.parse_p95_ns = _devtools_percentile(parse, 95, 100)
	}

	gpu_n := 0
	for i in 0..<int(_devtools_state.gpu_count) {
		idx := (int(_devtools_state.gpu_head) - int(_devtools_state.gpu_count) + i + int(DEVTOOLS_RING_CAPACITY)) % int(DEVTOOLS_RING_CAPACITY)
		if _devtools_state.gpu_valid[idx] {
			_devtools_gpu_scratch[gpu_n] = _devtools_state.gpu[idx]
			gpu_n += 1
		}
	}
	gpu := _devtools_gpu_scratch[:gpu_n]
	if len(gpu) > 0 {
		snap.gpu_valid = true
		total: u64 = 0
		for v in gpu {
			total += v
		}
		snap.gpu_mean_ns = total / u64(len(gpu))
		sort.sort(sort.slice_interface(&gpu))
		snap.gpu_p95_ns = _devtools_percentile(gpu, 95, 100)
	}

	return snap
}

// devtools_format_snapshot renders a snapshot as four ASCII-only key/value
// lines for a 34-column panel. Every line stays under 80 bytes for realistic
// values and uses plain ASCII glyphs only: the render atlas pins the UI
// codepoints (commits db1ce00 and 6c9273a), so a new non-ASCII codepoint
// would require an atlas change that is deliberately out of scope here.
//
// Returns a heap string; the caller owns it and must delete it.
devtools_format_snapshot :: proc(snap: ^Devtools_Snapshot) -> string {
	if snap == nil {
		return fmt.aprintf("fps=- drop=- p50=- p95=- p99=-\ncpu=- sys=- rss=- threads=0 gpu=-\npresent=- strat i=0 c=0 f=0 dirty=0 up=0 pty=0\nparse p95=- n=0 dropped=0", allocator = context.allocator)
	}
	return fmt.aprintf(
		"fps=%.1f drop=%.1f%% frame p50=%.2fms p95=%.2fms p99=%.2fms\n" +
		"cpu=%.1f%% sys=%.1f%% rss=%.1fMB threads=%d gpu=%.2f/%.2fms\n" +
		"present=%.2fms strat i=%d c=%d f=%d dirty=%d up=%.1fMB pty=%.1fKB\n" +
		"parse p95=%.2fms n=%d dropped=%d",
		snap.fps,
		snap.drop_pct,
		f64(snap.frame_p50_ns) / 1_000_000.0,
		f64(snap.frame_p95_ns) / 1_000_000.0,
		f64(snap.frame_p99_ns) / 1_000_000.0,
		snap.cpu_pct,
		snap.system_cpu_pct,
		f64(snap.resident_bytes) / (1024.0 * 1024.0),
		snap.thread_count,
		f64(snap.gpu_mean_ns) / 1_000_000.0,
		f64(snap.gpu_p95_ns) / 1_000_000.0,
		f64(snap.present_mean_ns) / 1_000_000.0,
		snap.strategy_instance,
		snap.strategy_compute,
		snap.strategy_fullscreen,
		snap.dirty_cells,
		f64(snap.upload_bytes) / (1024.0 * 1024.0),
		f64(snap.pty_bytes) / 1024.0,
		f64(snap.parse_p95_ns) / 1_000_000.0,
		snap.sample_count,
		snap.dropped_count,
		allocator = context.allocator,
	)
}

// devtools_reset clears the ring and every counter, keeping the enabled flag.
// Call it on resize or when the target frame interval changes: the frame-time
// percentiles of the old geometry would otherwise be compared against the new
// target and read as drops.
devtools_reset :: proc() {
	sync.mutex_lock(&_devtools_state.mutex)
	defer sync.mutex_unlock(&_devtools_state.mutex)
	_devtools_reset_locked()
}

// _devtools_reset_locked clears all sampled state. Caller holds the mutex.
// Stored strategy strings are dropped here without being freed: they belong to
// the callers that passed them in.
@(private)
_devtools_reset_locked :: proc() {
	for i in 0..<int(DEVTOOLS_RING_CAPACITY) {
		_devtools_state.frames[i].strategy = ""
	}
	_devtools_state.frame_head = 0
	_devtools_state.frame_count = 0
	_devtools_state.gpu_head = 0
	_devtools_state.gpu_count = 0
	for i in 0..<int(DEVTOOLS_RING_CAPACITY) {
		_devtools_state.gpu[i] = 0
		_devtools_state.gpu_valid[i] = false
	}
	_devtools_state.strategy_instance = 0
	_devtools_state.strategy_compute = 0
	_devtools_state.strategy_fullscreen = 0
	_devtools_state.dirty_cells = 0
	_devtools_state.upload_bytes = 0
	_devtools_state.pty_bytes = 0
	_devtools_state.dropped_count = 0
	_devtools_state.present_total_ns = 0
	_devtools_state.present_count = 0
	_devtools_state.sample_count = 0
	_devtools_state.cadence_ns = 0
	_devtools_state.metrics_sampled_cadence = 0
	_devtools_state.metrics_sample_ns = 0
	_devtools_state.metrics_frames = 0
	_devtools_state.metrics_presents = 0
	_devtools_state.metrics_valid = false
	_devtools_state.metrics_prev = Metric_Sample{}
	_devtools_state.fps = 0
	_devtools_state.cpu_pct = 0
	_devtools_state.system_cpu_pct = 0
	_devtools_state.resident_bytes = 0
	_devtools_state.thread_count = 0
}

// _devtools_percentile returns the nearest-rank percentile of an already
// sorted slice: rank = ceil(pct/100 * n), 1-based, clamped to [1, n].
// The ratio is passed as integers so no floating point enters the index.
@(private)
_devtools_percentile :: proc(sorted: []u64, numerator, denominator: int) -> u64 {
	n := len(sorted)
	if n == 0 {
		return 0
	}
	rank := (numerator * n + denominator - 1) / denominator
	if rank < 1 {
		rank = 1
	}
	if rank > n {
		rank = n
	}
	return sorted[rank - 1]
}
