package render

// Phase 18 Step 0: atlas pressure measurement (measure-before-mechanism).
// Render-thread only, no allocation. A nil ^Atlas_Pressure means
// uninstrumented: the _p wrappers behave bit-identically to the legacy
// path. No policy code lives here; Step 2b (generational) lands only if
// the gate fires on realistic traces.

// Atlas_Pressure accumulates dynamic-region activity observed through the
// counted _p wrappers. evict counts claims that overwrote a live tag
// (evicted_tag != 0); wraps counts claims where the FIFO cursor wrapped
// (new cursor < old cursor); re_raster counts harness-correlated
// re-rasters of previously evicted tags (the harness owns the evicted
// history; there is no ghost ring in Step 0).
Atlas_Pressure :: struct {
	dynamic_hit:   u64, // tag lookups that hit a valid slot
	dynamic_miss:  u64, // tag lookups that missed (no atlas mutation)
	dynamic_claim: u64, // FIFO slot claims (sync ensure + drain apply)
	dynamic_evict: u64, // claims that overwrote a live tag
	fifo_wraps:    u64, // claims where the cursor wrapped
	re_raster:     u64, // claims re-rasterizing a previously evicted tag
	ghost_reject:  u64, // Step 0 has no ghost ring: always 0
	last_cursor:   int, // cursor value after the most recent counted claim
}

// Atlas_Trace_Kind names the replay workloads. Canonical definition lives
// here (atlas_policy_decide needs it); the bench package aliases it.
Atlas_Trace_Kind :: enum {
	Shell,
	Vim,
	Htop,
	Cjk_Doc,
	Emoji,
	Scan,
	Storm,
}

// atlas_pressure_note_hit records one dynamic tag lookup hit.
atlas_pressure_note_hit :: proc(p: ^Atlas_Pressure) {
	if p == nil {
		return
	}
	p.dynamic_hit += 1
}

// atlas_pressure_note_claim records one FIFO slot claim. A claim always
// follows a miss on the sync path, but misses are counted at lookup, so
// this proc records claim/evict/wrap only.
atlas_pressure_note_claim :: proc(p: ^Atlas_Pressure, evicted_tag: u64, wrapped: bool) {
	if p == nil {
		return
	}
	p.dynamic_claim += 1
	if evicted_tag != 0 {
		p.dynamic_evict += 1
	}
	if wrapped {
		p.fifo_wraps += 1
	}
}

// atlas_pressure_note_reraster records one claim that re-rasterized a
// previously evicted tag (correlated by the harness, which owns history).
atlas_pressure_note_reraster :: proc(p: ^Atlas_Pressure) {
	if p == nil {
		return
	}
	p.re_raster += 1
}

// atlas_pressure_hit_rate returns hit/(hit+miss), 1.0 when empty.
atlas_pressure_hit_rate :: proc(p: ^Atlas_Pressure) -> f32 {
	if p == nil {
		return 1.0
	}
	total := p.dynamic_hit + p.dynamic_miss
	if total == 0 {
		return 1.0
	}
	return f32(p.dynamic_hit) / f32(total)
}

// atlas_pressure_evict_rate returns evict/claim, 0.0 when no claims.
atlas_pressure_evict_rate :: proc(p: ^Atlas_Pressure) -> f32 {
	if p == nil || p.dynamic_claim == 0 {
		return 0.0
	}
	return f32(p.dynamic_evict) / f32(p.dynamic_claim)
}

// atlas_pressure_reraster_rate returns re_raster/claim, 0.0 when no claims.
atlas_pressure_reraster_rate :: proc(p: ^Atlas_Pressure) -> f32 {
	if p == nil || p.dynamic_claim == 0 {
		return 0.0
	}
	return f32(p.re_raster) / f32(p.dynamic_claim)
}

// atlas_pressure_reset zeroes every counter including last_cursor.
atlas_pressure_reset :: proc(p: ^Atlas_Pressure) {
	if p == nil {
		return
	}
	p^ = Atlas_Pressure{}
}

// PRESSURE_KEEP_FIFO_HIT_FLOOR is the minimum hit rate that keeps FIFO.
PRESSURE_KEEP_FIFO_HIT_FLOOR :: 0.95

// PRESSURE_KEEP_FIFO_RERASTER_CEIL is the maximum re-raster rate that keeps FIFO.
PRESSURE_KEEP_FIFO_RERASTER_CEIL :: 0.01

// PRESSURE_WRAP_BUDGET_PER_FRAME is the sustained wrap budget: single
// bursts are exempt (high hit rate still keeps FIFO); sustained wraps>0
// on steady traces with a depressed hit rate escalates.
PRESSURE_WRAP_BUDGET_PER_FRAME :: 0

// ATLAS_POLICY_DECISION is the Step 0 gate outcome per trace kind.
ATLAS_POLICY_DECISION :: enum {
	Undecided,
	Keep_Fifo,
	Generational,
}

// atlas_policy_decide is pure: no atlas, cache, or GPU access. Scan never
// returns Generational alone (one-pass scans must not promote; FIFO is
// scan-safe by doing nothing). Bursts are exempt via the hit-rate gate:
// wraps alone with a healthy hit rate stay Keep_Fifo. Empty snapshots are
// Undecided.
atlas_policy_decide :: proc(p: ^Atlas_Pressure, trace_kind: Atlas_Trace_Kind) -> ATLAS_POLICY_DECISION {
	if p == nil {
		return .Undecided
	}
	if trace_kind == .Scan {
		return .Keep_Fifo
	}
	total := p.dynamic_hit + p.dynamic_miss
	if total == 0 && p.dynamic_claim == 0 {
		return .Undecided
	}
	if atlas_pressure_hit_rate(p) >= PRESSURE_KEEP_FIFO_HIT_FLOOR &&
	   atlas_pressure_reraster_rate(p) <= PRESSURE_KEEP_FIFO_RERASTER_CEIL {
		return .Keep_Fifo
	}
	return .Generational
}
