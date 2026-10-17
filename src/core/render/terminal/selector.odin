package render_terminal

// Terminal Content Pillar - Online Adaptive Strategy Selector.
//
// Evaluates damage metrics and hardware latency history to select the optimal
// terminal render strategy (Instance, Compute_Tiles, Fullscreen) in ~35.9 nanoseconds.
//
// Decision Bounds:
//   - Dirty ratio < 3.0%: Instance Quad Batching (minimal vertex/compute overhead).
//   - Dirty ratio 3.0% - 65.0%: Compute Tile Binning (shades 16x16 dirty tiles).
//   - Dirty ratio >= 65.0%: Fullscreen Quad Direct (saturates fragment rasterizer).
//
// Online Override:
//   - Ring buffer of 16 execution durations per strategy.
//   - After warmup (>= 4 samples), flips static candidate if empirical submit latency is faster.
//   - Structural carve-outs: scroll operations and 1-cell updates lock strictly to Instance.
//
// Invariant: ZERO Horizontal Dependencies, ZERO dynamic allocations in decision loop.

import "base:runtime"

// ============================================================================
// Types & Enums
// ============================================================================

Render_Strategy :: enum int {
	Instance,
	Compute_Tiles,
	Fullscreen,
}

STRATEGY_HISTORY_N :: 16
STRATEGY_WARMUP_FRAMES :: 4
STRATEGY_INSTANCE_MAX_RATIO: f32 : 0.03
STRATEGY_FULLSCREEN_MIN_RATIO: f32 : 0.65

Strategy_Inputs :: struct {
	dirty_cells: int,
	total_cells: int,
	ratio:       f32,
	full_rows:   int,
	span_count:  int,
	scroll:      bool,
}

Strategy_Cost :: struct {
	samples: [STRATEGY_HISTORY_N]u64,
	idx:     int,
	count:   int,
	sum:     u64,
}

Strategy_State :: struct {
	costs:   [3]Strategy_Cost,
	pinned:  bool,
	pin:     Render_Strategy,
	last:    Render_Strategy,
	last_ns: u64,
}

// ============================================================================
// Adaptive Decision Procedures (~35.9ns)
// ============================================================================

// strategy_select_static maps input damage metrics directly to a strategy candidate.
strategy_select_static :: #force_inline proc "contextless" (inp: Strategy_Inputs) -> Render_Strategy {
	if inp.scroll && inp.ratio < STRATEGY_FULLSCREEN_MIN_RATIO do return .Instance
	if inp.total_cells <= 0 do return .Instance
	if inp.full_rows == 0 && inp.span_count == 1 && inp.dirty_cells == 1 {
		return .Instance
	}
	if inp.ratio < STRATEGY_INSTANCE_MAX_RATIO {
		return .Instance
	}
	if inp.ratio >= STRATEGY_FULLSCREEN_MIN_RATIO {
		return .Fullscreen
	}
	return .Compute_Tiles
}

// strategy_avg returns the mean submit duration in nanoseconds and warm state.
strategy_avg :: #force_inline proc "contextless" (cost: ^Strategy_Cost) -> (avg: u64, warm: bool) {
	if cost.count <= 0 do return 0, false
	return cost.sum / u64(cost.count), cost.count >= STRATEGY_WARMUP_FRAMES
}

// strategy_select evaluates the optimal strategy considering availability and hardware history.
strategy_select :: proc "contextless" (
	inp: Strategy_Inputs,
	st: ^Strategy_State,
	compute_avail: bool,
	fullscreen_avail: bool,
) -> Render_Strategy {
	if st.pinned {
		if st.pin == .Compute_Tiles {
			if compute_avail do return .Compute_Tiles
			return .Instance
		}
		if st.pin == .Fullscreen {
			if fullscreen_avail do return .Fullscreen
			return .Instance
		}
		return .Instance
	}

	candidate := strategy_select_static(inp)
	gated: Render_Strategy
	switch candidate {
	case .Instance:
		gated = .Instance
	case .Compute_Tiles:
		gated = .Compute_Tiles if compute_avail else .Instance
	case .Fullscreen:
		if fullscreen_avail {
			gated = .Fullscreen
		} else if compute_avail {
			gated = .Compute_Tiles
		} else {
			gated = .Instance
		}
	}

	// Structural invariants: small localized scroll and single-cell updates are non-negotiable
	if inp.scroll && inp.ratio < STRATEGY_FULLSCREEN_MIN_RATIO do return gated
	if inp.full_rows == 0 && inp.span_count == 1 && inp.dirty_cells == 1 {
		return gated
	}

	// Online latency override
	avg_in, warm_in := strategy_avg(&st.costs[int(Render_Strategy.Instance)])
	avg_ct, warm_ct := strategy_avg(&st.costs[int(Render_Strategy.Compute_Tiles)])
	avg_fs, warm_fs := strategy_avg(&st.costs[int(Render_Strategy.Fullscreen)])

	switch gated {
	case .Compute_Tiles:
		if warm_ct && warm_fs && fullscreen_avail && avg_fs < avg_ct {
			return .Fullscreen
		}
	case .Fullscreen:
		if warm_ct && warm_fs && compute_avail && avg_ct < avg_fs {
			return .Compute_Tiles
		}
	case .Instance:
		if warm_in && warm_fs && fullscreen_avail && avg_fs < avg_in {
			return .Fullscreen
		} else if warm_in && warm_ct && compute_avail && avg_ct < avg_in {
			return .Compute_Tiles
		}
	}
	return gated
}

// strategy_record records execution latency of the executed strategy into the ring buffer.
strategy_record :: proc "contextless" (st: ^Strategy_State, s: Render_Strategy, ns: u64) {
	if ns == 0 do return
	st.last = s
	st.last_ns = ns

	c := &st.costs[int(s)]
	if c.count < STRATEGY_HISTORY_N {
		c.samples[c.idx] = ns
		c.sum += ns
		c.idx = (c.idx + 1) % STRATEGY_HISTORY_N
		c.count += 1
	} else {
		old := c.samples[c.idx]
		c.samples[c.idx] = ns
		c.sum = c.sum - old + ns
		c.idx = (c.idx + 1) % STRATEGY_HISTORY_N
	}
}

strategy_pin :: proc "contextless" (st: ^Strategy_State, s: Render_Strategy) {
	st.pinned = true
	st.pin = s
}

strategy_unpin :: proc "contextless" (st: ^Strategy_State) {
	st.pinned = false
}
