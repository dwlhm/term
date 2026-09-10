package render_tests

// Phase 18 Step 0 tests: pressure wrap/hit-miss/reraster accounting,
// nil-pressure parity with the pre-18 FIFO path, pin audit mechanics,
// nerd sentinel probing, and the policy gate decision table.

import "core:testing"
import render "../"

// _ap_pair pairs a covered codepoint with its resolving chain slot.
_ap_pair :: struct {
	cp: rune,
	fi: int,
}

// _ap_covered collects n chain-covered codepoints from start upward.
_ap_covered :: proc(chain: ^render.Fallback_Chain, start: rune, n: int) -> []_ap_pair {
	dyn := make([dynamic]_ap_pair, 0, n, context.allocator)
	defer delete(dyn)
	cp := start
	for len(dyn) < n && cp < 0x30000 {
		if fi, cov := render.fallback_resolve(chain, u32(cp), nil); cov {
			append(&dyn, _ap_pair{cp = cp, fi = fi})
		}
		cp += 1
	}
	out := make([]_ap_pair, len(dyn), context.allocator)
	copy(out, dyn[:])
	return out
}

// _ap_chain_atlas builds a primary+fallback chain and a prewarmed atlas.
_ap_chain_atlas :: proc(
	t: ^testing.T,
	prim: ^render.Font_Rasterizer,
	chain: ^render.Fallback_Chain,
	atlas: ^render.Atlas,
) {
	_fb_prim(t, prim)
	_fb_chain(t, chain, prim)
	render.atlas_init(atlas, prim)
	render.atlas_prewarm_chain(atlas, chain)
}

@(test)
test_pressure_wrap_counting :: proc(t: ^testing.T) {
	prim: render.Font_Rasterizer
	chain: render.Fallback_Chain
	atlas: render.Atlas
	_ap_chain_atlas(t, &prim, &chain, &atlas)
	defer render.font_rasterizer_destroy(&prim)
	defer render.fallback_chain_destroy(&chain)
	defer render.atlas_destroy(&atlas)

	cps := _ap_covered(&chain, 0x4E00, render.FALLBACK_SLOT_COUNT + 1)
	defer delete(cps)
	testing.expect_value(t, len(cps), render.FALLBACK_SLOT_COUNT + 1)

	pressure: render.Atlas_Pressure
	for p in cps {
		_, ok := render.atlas_dynamic_claim_p(&atlas, &chain, p.fi, u32(p.cp), nil, &pressure)
		testing.expect(t, ok, "CJK claim must rasterize")
	}
	testing.expect_value(t, pressure.dynamic_claim, u64(render.FALLBACK_SLOT_COUNT + 1))
	testing.expect_value(t, pressure.fifo_wraps, u64(1))
	testing.expect_value(t, pressure.dynamic_evict, u64(1))
	testing.expect_value(t, pressure.last_cursor, atlas.fallback_cursor)
}

@(test)
test_pressure_hit_miss_accounting :: proc(t: ^testing.T) {
	prim: render.Font_Rasterizer
	chain: render.Fallback_Chain
	atlas: render.Atlas
	_ap_chain_atlas(t, &prim, &chain, &atlas)
	defer render.font_rasterizer_destroy(&prim)
	defer render.fallback_chain_destroy(&chain)
	defer render.atlas_destroy(&atlas)

	const_N := 10
	cps := _ap_covered(&chain, 0x4E00, const_N)
	defer delete(cps)
	testing.expect_value(t, len(cps), const_N)

	pressure: render.Atlas_Pressure
	for p in cps {
		_, ok := render.atlas_dynamic_claim_p(&atlas, &chain, p.fi, u32(p.cp), nil, &pressure)
		testing.expect(t, ok, "CJK claim must rasterize")
	}
	for p in cps {
		slot, hit := render.atlas_dynamic_lookup_p(&atlas, p.fi, u32(p.cp), &pressure)
		testing.expect(t, hit, "claimed tag must hit")
		testing.expect(t, slot >= render.FALLBACK_SLOT_BASE, "hit slot must be dynamic")
	}
	testing.expect_value(t, pressure.dynamic_hit, u64(const_N))
	testing.expect_value(t, pressure.dynamic_miss, u64(0))
	testing.expect_value(t, render.atlas_pressure_hit_rate(&pressure), f32(1.0))

	// Absent lookup: miss with no atlas mutation.
	before_cursor := atlas.fallback_cursor
	before_tags := atlas.fallback_tag
	_, hit := render.atlas_dynamic_lookup_p(&atlas, 0, 0x10FFFF, &pressure)
	testing.expect(t, !hit, "uncovered tag must miss")
	testing.expect_value(t, pressure.dynamic_miss, u64(1))
	testing.expect_value(t, atlas.fallback_cursor, before_cursor)
	testing.expect(t, atlas.fallback_tag == before_tags, "miss must not mutate tags")
	testing.expect(t, render.atlas_pressure_hit_rate(&pressure) < 1.0, "one miss must drop the rate")
}

@(test)
test_pressure_reraster_correlation :: proc(t: ^testing.T) {
	prim: render.Font_Rasterizer
	chain: render.Fallback_Chain
	atlas: render.Atlas
	_ap_chain_atlas(t, &prim, &chain, &atlas)
	defer render.font_rasterizer_destroy(&prim)
	defer render.fallback_chain_destroy(&chain)
	defer render.atlas_destroy(&atlas)

	cps := _ap_covered(&chain, 0x4E00, render.FALLBACK_SLOT_COUNT + 1)
	defer delete(cps)
	testing.expect_value(t, len(cps), render.FALLBACK_SLOT_COUNT + 1)

	pressure: render.Atlas_Pressure
	victim := cps[0]
	_, ok := render.atlas_dynamic_claim_p(&atlas, &chain, victim.fi, u32(victim.cp), nil, &pressure)
	testing.expect(t, ok, "victim claim must rasterize")
	for p in cps[1:] {
		_, ok := render.atlas_dynamic_claim_p(&atlas, &chain, p.fi, u32(p.cp), nil, &pressure)
		testing.expect(t, ok, "fill claim must rasterize")
	}

	// Victim evicted: lookup misses.
	_, hit := render.atlas_dynamic_lookup_p(&atlas, victim.fi, u32(victim.cp), nil)
	testing.expect(t, !hit, "victim must be evicted after a full FIFO rotation")

	// Harness correlates the reclaim (victim was observed evicted above).
	_, ok = render.atlas_dynamic_claim_p(&atlas, &chain, victim.fi, u32(victim.cp), nil, &pressure)
	testing.expect(t, ok, "reclaim must rasterize")
	render.atlas_pressure_note_reraster(&pressure)
	testing.expect_value(t, pressure.re_raster, u64(1))
	testing.expect(t, render.atlas_pressure_reraster_rate(&pressure) > 0.0, "reraster rate must be non-zero")

	_, hit = render.atlas_dynamic_lookup_p(&atlas, victim.fi, u32(victim.cp), nil)
	testing.expect(t, hit, "reclaimed victim must hit")
}

@(test)
test_pressure_nil_parity :: proc(t: ^testing.T) {
	prim: render.Font_Rasterizer
	chain: render.Fallback_Chain
	a, b: render.Atlas
	_ap_chain_atlas(t, &prim, &chain, &a)
	render.atlas_init(&b, &prim)
	render.atlas_prewarm_chain(&b, &chain)
	defer render.font_rasterizer_destroy(&prim)
	defer render.fallback_chain_destroy(&chain)
	defer render.atlas_destroy(&a)
	defer render.atlas_destroy(&b)

	pressure: render.Atlas_Pressure
	b.pressure = &pressure

	cps := _ap_covered(&chain, 0x4E00, 300)
	defer delete(cps)
	testing.expect(t, len(cps) == 300, "need 300 covered codepoints for wrap parity")

	ca, cb: render.Shape_Cache
	fa, fb: render.Fallback_Counters
	for p in cps {
		key := render.Cluster_Key{base = p.cp, join_form = .Isolated}
		render.atlas_ensure_glyph(&a, &chain, &ca, key, p.fi, u32(p.cp), nil, &fa)
		render.atlas_ensure_glyph(&b, &chain, &cb, key, p.fi, u32(p.cp), nil, &fb)
	}
	testing.expect_value(t, a.fallback_cursor, b.fallback_cursor)
	testing.expect(t, a.fallback_tag == b.fallback_tag, "instrumented tags must match legacy")
	for i in 0..<render.ATLAS_SLOT_COUNT {
		testing.expect(t, a.slots[i].valid == b.slots[i].valid, "slot validity must match legacy")
	}
	testing.expect(t, pressure.dynamic_claim > 0, "instrumented run must record claims")
}

@(test)
test_pressure_pin_audit :: proc(t: ^testing.T) {
	prim: render.Font_Rasterizer
	chain: render.Fallback_Chain
	atlas: render.Atlas
	_ap_chain_atlas(t, &prim, &chain, &atlas)
	defer render.font_rasterizer_destroy(&prim)
	defer render.fallback_chain_destroy(&chain)
	defer render.atlas_destroy(&atlas)

	// Find a chain-covered pinned codepoint, invalidate it (primary-missing
	// shape), then audit must promote it back to valid.
	set := render.atlas_prewarm_set()
	defer delete(set)
	target := rune(-1)
	for cp in set {
		if _, cov := render.fallback_resolve(&chain, u32(cp), nil); cov {
			target = cp
			break
		}
	}
	testing.expect(t, target >= 0, "chain must cover at least one pinned codepoint")
	idx, ok := render.atlas_pinned_slot_index(u32(target))
	testing.expect(t, ok, "target must be pinned")
	atlas.slots[idx].valid = false

	before_tags := atlas.fallback_tag
	before_cursor := atlas.fallback_cursor
	promoted := render.atlas_pin_audit(&atlas, &chain)
	testing.expect(t, promoted > 0, "audit must promote the invalidated pinned slot")
	testing.expect(t, atlas.slots[idx].valid, "audited slot must be valid")
	testing.expect(t, atlas.fallback_tag == before_tags, "audit must not touch dynamic tags")
	testing.expect_value(t, atlas.fallback_cursor, before_cursor)

	// Nil inputs audit to zero.
	testing.expect_value(t, render.atlas_pin_audit(nil, &chain), 0)
	testing.expect_value(t, render.atlas_pin_audit(&atlas, nil), 0)
}

@(test)
test_pressure_nerd_present :: proc(t: ^testing.T) {
	prim: render.Font_Rasterizer
	chain: render.Fallback_Chain
	_fb_prim(t, &prim)
	defer render.font_rasterizer_destroy(&prim)
	_fb_chain(t, &chain, &prim)
	defer render.fallback_chain_destroy(&chain)

	// Self-consistent with individual sentinel probes (pure read).
	sentinels := [3]u32{0xE0B0, 0xE5FA, 0xF09B}
	any_covered := false
	for s in sentinels {
		if _, cov := render.fallback_resolve(&chain, s, nil); cov {
			any_covered = true
		}
	}
	testing.expect(t, render.atlas_nerd_present(&chain) == any_covered, "nerd_present must match sentinel coverage")
	testing.expect(t, render.atlas_nerd_present(&chain) == render.atlas_nerd_present(&chain), "nerd_present must be deterministic")
	testing.expect(t, !render.atlas_nerd_present(nil), "nil chain has no nerd font")
}

@(test)
test_pressure_decide_table :: proc(t: ^testing.T) {
	// Empty snapshot: undecided.
	empty: render.Atlas_Pressure
	testing.expect(t, render.atlas_policy_decide(&empty, .Shell) == .Undecided, "empty snapshot is undecided")
	testing.expect(t, render.atlas_policy_decide(nil, .Shell) == .Undecided, "nil pressure is undecided")

	// Healthy steady state: keep FIFO.
	healthy := render.Atlas_Pressure{dynamic_hit = 980, dynamic_miss = 20}
	testing.expect(t, render.atlas_policy_decide(&healthy, .Shell) == .Keep_Fifo, "healthy shell keeps FIFO")
	testing.expect(t, render.atlas_policy_decide(&healthy, .Cjk_Doc) == .Keep_Fifo, "healthy CJK keeps FIFO")

	// Burst wraps with a healthy hit rate: exempt, keep FIFO.
	burst := render.Atlas_Pressure{dynamic_hit = 1900, dynamic_miss = 40, dynamic_claim = 60, fifo_wraps = 2}
	testing.expect(t, render.atlas_policy_decide(&burst, .Shell) == .Keep_Fifo, "burst wraps with high hits keep FIFO")

	// Persistent miss storm on a realistic kind: generational.
	storm := render.Atlas_Pressure{dynamic_hit = 10, dynamic_miss = 2000, dynamic_claim = 2000, dynamic_evict = 1900, fifo_wraps = 8}
	testing.expect(t, render.atlas_policy_decide(&storm, .Storm) == .Generational, "hot-set storm justifies generational")
	testing.expect(t, render.atlas_policy_decide(&storm, .Cjk_Doc) == .Generational, "realistic churn can fire the gate")

	// Scan never returns Generational alone, however bad the pressure.
	testing.expect(t, render.atlas_policy_decide(&storm, .Scan) == .Keep_Fifo, "scan never promotes")
}
