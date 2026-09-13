package render

// Fallback font chain: ordered probe of up to 4 rasterized fonts for
// codepoints the primary font does not cover. Slow path only: the ASCII
// fast path never calls into this file.
//
// Slot 0 is always the primary font (owned by the Renderer, aliased not
// freed here). Slots 1..3 are heap-loaded fallbacks owned by the chain.

import "base:runtime"
import "vendor:stb/truetype"

// FALLBACK_MAX_FONTS caps the chain; slot 0 is the primary.
FALLBACK_MAX_FONTS :: 4

// Fallback_Chain is an ordered font probe chain (slot 0 = primary).
Fallback_Chain :: struct {
	fonts:      [FALLBACK_MAX_FONTS]Font_Rasterizer,
	count:      int,
	pixel_size: f32,
}

// Fallback_Counters tracks slow-path resolver activity. Plain u64s, no alloc.
Fallback_Counters :: struct {
	probe_miss:    u64, // primary (slot 0) did not cover the codepoint
	fallback_hit:  [FALLBACK_MAX_FONTS]u64, // per-slot cover hits
	fallback_miss: u64, // no slot in the chain covers the codepoint
	tofu_missing:  u64, // neither tofu glyph is covered anywhere
	mark_drop:     u64, // combining mark uncovered, base kept without it
}

// FALLBACK_TOFU_PRIMARY is the visible box used for uncovered codepoints.
FALLBACK_TOFU_PRIMARY :: u32(0x25A1)

// FALLBACK_TOFU_SECONDARY is the replacement character when the box is missing.
FALLBACK_TOFU_SECONDARY :: u32(0xFFFD)

// fallback_chain_init aliases the primary into slot 0 (never freed here) and
// loads up to 3 fallback fonts into slots 1... Missing files reduce the
// count; init never fails for missing fallbacks.
fallback_chain_init :: proc(
	chain: ^Fallback_Chain,
	primary: ^Font_Rasterizer,
	fallback_paths: []string,
	pixel_size: f32,
	allocator: runtime.Allocator,
) -> bool {
	if chain == nil {
		return false
	}
	chain.count = 0
	chain.pixel_size = pixel_size

	// Slot 0 is always reserved for the primary, even when it failed to
	// load: probing skips entries with no font data, and destroy frees
	// slots 1.. only, so the reservation can never leak.
	if primary != nil {
		chain.fonts[0] = primary^
	}
	chain.count = 1

	if fallback_paths != nil {
		for path in fallback_paths {
			if chain.count >= FALLBACK_MAX_FONTS {
				break
			}
			if font_rasterizer_init(&chain.fonts[chain.count], path, pixel_size, nil, allocator) {
				fb := &chain.fonts[chain.count]
				if primary != nil {
					if fb.metrics.cell_width <= 0 {
						fb.metrics.cell_width = primary.metrics.cell_width
					}
					if fb.metrics.cell_height <= 0 {
						fb.metrics.cell_height = primary.metrics.cell_height
					}
				}
				chain.count += 1
			}
		}
	}
	return true
}

// fallback_chain_destroy frees slots 1.. only. Slot 0 aliases the primary
// font owned by the Renderer and must stay alive past the chain.
fallback_chain_destroy :: proc(chain: ^Fallback_Chain) {
	if chain == nil {
		return
	}
	for i in 1..<chain.count {
		font_rasterizer_destroy(&chain.fonts[i])
	}
	chain.count = 0
}

// fallback_resolve probes slots 0..<count in order; the first font whose
// glyph index is non-zero covers the codepoint. Slow-path only.
// Counters (when non-nil): fallback_hit[i] on a hit at slot i, probe_miss
// once when slot 0 does not cover, fallback_miss when no slot covers.
fallback_resolve :: proc(
	chain: ^Fallback_Chain,
	codepoint: u32,
	counters: ^Fallback_Counters,
) -> (font_index: int, covered: bool) {
	if chain == nil {
		return -1, false
	}
	primary_missed := false
	for i in 0..<chain.count {
		f := &chain.fonts[i]
		if f.font_data == nil {
			if i == 0 {
				primary_missed = true
			}
			continue
		}
		if truetype.FindGlyphIndex(&f.info, rune(codepoint)) != 0 {
			if counters != nil {
				counters.fallback_hit[i] += 1
				if primary_missed {
					counters.probe_miss += 1
				}
			}
			return i, true
		}
		if i == 0 {
			primary_missed = true
		}
	}
	if counters != nil {
		if primary_missed {
			counters.probe_miss += 1
		}
		counters.fallback_miss += 1
	}
	return -1, false
}
