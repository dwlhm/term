package render

// Phase 16 adaptive strategy selector: static damage-ratio bands from the
// measured crossover tables plus an online moving-average of CPU submit ns
// (platform_now proxy; no GPU timestamps in the vtable).
//
// estimate is a pure read-only pre-compile scan of the live damage journal.
// select_static maps Strategy_Inputs to a candidate (scroll and the 1-cell
// carve-out lock to Instance and are never flipped by history). select gates
// the static candidate on sibling availability, then applies the online
// override only while warm (4+ samples on both sides of the comparison).
// record is the sole mutator of Strategy_State and only fires on a completed
// frame with ns > 0, so skips and failed frames never poison the averages.

import termgrid "../terminal"

// STRATEGY_HISTORY_N is the per-strategy submit-ns ring depth (no alloc).
STRATEGY_HISTORY_N :: 16

// STRATEGY_WARMUP_FRAMES is the sample count before the online override may
// flip the static order.
STRATEGY_WARMUP_FRAMES :: 4

// STRATEGY_INSTANCE_MAX_RATIO: below this dirty fraction Instance wins
// (tile amplification makes the siblings wasteful on tiny damage).
STRATEGY_INSTANCE_MAX_RATIO :: 0.03

// STRATEGY_FULLSCREEN_MIN_RATIO: at or above this dirty fraction Fullscreen
// wins (the full-grid upload beats per-cell bookkeeping near flood).
STRATEGY_FULLSCREEN_MIN_RATIO :: 0.65

// Strategy_Inputs is the selector's view of one frame's damage extent.
Strategy_Inputs :: struct {
	dirty_cells: int,
	total_cells: int,
	ratio:       f32,
	full_rows:   int,
	span_count:  int,
	scroll:      bool,
}

// Strategy_Cost is one strategy's submit-ns ring plus its running sum.
Strategy_Cost :: struct {
	samples: [STRATEGY_HISTORY_N]u64,
	idx:     int,
	count:   int,
	sum:     u64,
}

// Strategy_State holds the per-strategy cost rings, the manual pin, and the
// last executed strategy. Index costs by int(strategy). The zero value is
// unpinned, cold, and last == Instance.
Strategy_State :: struct {
	costs:   [3]Strategy_Cost,
	pinned:  bool,
	pin:     Render_Strategy,
	last:    Render_Strategy,
	last_ns: u64,
}

// strategy_estimate_inputs scans the live damage journal read-only and
// returns the selector inputs. It never takes, clears, or allocates: full
// rows contribute cols cells each, spans contribute max(0, end - start),
// scroll is set when any scroll op is present, and ratio is dirty / total
// (0 when total <= 0). Rows are clamped to the journal length.
strategy_estimate_inputs :: proc(damage: ^termgrid.Damage, rows: i32, cols: i32) -> Strategy_Inputs {
	inp: Strategy_Inputs
	n := len(damage.dirty_rows)
	want := int(rows)
	if want < 0 {
		want = 0
	}
	if want < n {
		n = want
	}
	c := int(cols)
	if c < 0 {
		c = 0
	}
	inp.total_cells = n * c
	for i in 0..<n {
		dr := &damage.dirty_rows[i]
		if dr.full {
			inp.dirty_cells += c
			inp.full_rows += 1
		} else {
			sc := int(dr.span_count)
			if sc > len(dr.spans) {
				sc = len(dr.spans)
			}
			for k in 0..<sc {
				w := int(dr.spans[k].col_end) - int(dr.spans[k].col_start)
				if w > 0 {
					inp.dirty_cells += w
				}
				inp.span_count += 1
			}
		}
	}
	inp.scroll = len(damage.scroll_ops) > 0
	if inp.total_cells > 0 {
		inp.ratio = f32(inp.dirty_cells) / f32(inp.total_cells)
	}
	return inp
}

// strategy_select_static maps inputs to a candidate with no history and no
// availability input: scroll locks to Instance (rebase loses), degenerate
// geometry locks to Instance, the 1-cell single-span carve-out locks to
// Instance (tile amplification), then the ratio bands decide.
strategy_select_static :: proc(inp: Strategy_Inputs) -> Render_Strategy {
	if inp.scroll {
		return .Instance
	}
	if inp.total_cells <= 0 {
		return .Instance
	}
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

// strategy_avg returns the ring's mean submit ns and whether it is warm
// (count >= STRATEGY_WARMUP_FRAMES). Cold rings report avg 0.
strategy_avg :: proc(cost: ^Strategy_Cost) -> (avg: u64, warm: bool) {
	if cost.count <= 0 {
		return 0, false
	}
	return cost.sum / u64(cost.count), cost.count >= STRATEGY_WARMUP_FRAMES
}

// strategy_select returns the frame's strategy. A manual pin wins over
// scroll, ratio, and history; an unavailable pinned sibling falls back to
// Instance without latching availability. Otherwise the static candidate is
// availability-gated (Compute needs compute_avail; Fullscreen needs
// fullscreen_avail and falls back to Compute else Instance), then the online
// override may invert the static order while warm: mid-band Compute flips to
// Fullscreen when fullscreen is cheaper, large-band Fullscreen pulls back to
// Compute when compute is cheaper, small-band Instance follows Compute when
// compute is cheaper. Scroll and the 1-cell carve-out are never flipped.
strategy_select :: proc(
	inp: Strategy_Inputs,
	st: ^Strategy_State,
	compute_avail: bool,
	fullscreen_avail: bool,
) -> Render_Strategy {
	if st.pinned {
		if st.pin == .Compute_Tiles {
			if compute_avail {
				return .Compute_Tiles
			}
			return .Instance
		}
		if st.pin == .Fullscreen {
			if fullscreen_avail {
				return .Fullscreen
			}
			return .Instance
		}
		return .Instance
	}

	static := strategy_select_static(inp)
	gated: Render_Strategy
	switch static {
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

	// Structural carve-outs: scroll and the 1-cell single span never flip.
	if inp.scroll {
		return gated
	}
	if inp.full_rows == 0 && inp.span_count == 1 && inp.dirty_cells == 1 {
		return gated
	}

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
		if warm_in && warm_ct && compute_avail && avg_ct < avg_in {
			return .Compute_Tiles
		}
	}
	return gated
}

// strategy_record folds one completed frame's submit ns into the executed
// strategy's ring (evict-oldest via the running sum once full, count
// saturates at STRATEGY_HISTORY_N) and stamps last/last_ns. Samples of
// ns == 0 are skipped so failed or untimed frames never poison the average.
strategy_record :: proc(st: ^Strategy_State, s: Render_Strategy, ns: u64) {
	if ns == 0 {
		return
	}
	c := &st.costs[int(s)]
	if c.count < STRATEGY_HISTORY_N {
		c.samples[c.idx] = ns
		c.sum += ns
		c.idx = (c.idx + 1) % STRATEGY_HISTORY_N
		c.count += 1
	} else {
		c.sum -= c.samples[c.idx]
		c.samples[c.idx] = ns
		c.sum += ns
		c.idx = (c.idx + 1) % STRATEGY_HISTORY_N
	}
	st.last = s
	st.last_ns = ns
}

// strategy_reset zeroes the cost rings and the last-executed stamp while
// preserving the manual pin (pin/pinned survive; history does not).
strategy_reset :: proc(st: ^Strategy_State) {
	for i in 0..<len(st.costs) {
		st.costs[i].samples = {}
		st.costs[i].idx = 0
		st.costs[i].count = 0
		st.costs[i].sum = 0
	}
	st.last = .Instance
	st.last_ns = 0
}
