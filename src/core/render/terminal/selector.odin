package render_terminal

// Terminal Content Pillar - Online Adaptive Strategy Selector.
//
// Evaluates damage metrics to select the optimal terminal render strategy
// (Instance, Compute_Tiles, Fullscreen) in ~35.9 nanoseconds.
//
// Decision Bounds:
//   - Dirty ratio < 3.0%: Instance Quad Batching (minimal vertex/compute overhead).
//   - Dirty ratio 3.0% - 65.0%: Compute Tile Binning (shades 16x16 dirty tiles).
//   - Dirty ratio >= 65.0%: Fullscreen Quad Direct (saturates fragment rasterizer).
//
// Sticky Hysteresis Gate:
//   - A different strategy must remain the static candidate for
//     STRATEGY_STICKY_FRAMES consecutive frames before it is committed.
//   - This damps per-frame oscillation between pipelines (Instance <->
//     Compute_Tiles <-> Fullscreen), the primary source of visible flashing
//     while damage-heavy activity streams in.
//   - Structural carve-outs: scroll operations and 1-cell updates lock strictly
//     to Instance and answer immediately without perturbing the committed choice.
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
STRATEGY_STICKY_FRAMES :: 3
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

	// Sticky hysteresis state. `committed` is the strategy currently in effect;
	// `candidate` is a pending alternative that must hold for `candidate_run`
	// consecutive frames before it replaces `committed`.
	committed:     Render_Strategy,
	candidate:     Render_Strategy,
	candidate_run: int,
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

// strategy_select evaluates the optimal strategy considering availability and a
// sticky hysteresis gate.
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

	// Structural invariants: small localized scroll and single-cell updates are
	// non-negotiable and answer immediately. They deliberately do NOT rewrite
	// `committed`/`candidate` so a lone keystroke cannot reset the selection of
	// the dominant workload surrounding it.
	if inp.scroll && inp.ratio < STRATEGY_FULLSCREEN_MIN_RATIO do return gated
	if inp.full_rows == 0 && inp.span_count == 1 && inp.dirty_cells == 1 {
		return gated
	}

	// Sticky hysteresis gate. A different strategy must remain the static
	// candidate for STRATEGY_STICKY_FRAMES consecutive frames before it is
	// committed. This prevents the damage ratio crossing 3% or 65% from flipping
	// pipelines every frame and producing a visible flash.
	if gated == st.committed {
		st.candidate = gated
		st.candidate_run = 0
		return st.committed
	}
	if gated == st.candidate {
		st.candidate_run += 1
	} else {
		st.candidate = gated
		st.candidate_run = 1
	}
	if st.candidate_run >= STRATEGY_STICKY_FRAMES {
		st.committed = st.candidate
		st.candidate_run = 0
	}
	return st.committed
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
