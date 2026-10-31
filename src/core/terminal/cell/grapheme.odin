package terminal_cell

import "core:unicode"

// UAX #29 / UTS #51 Extended Grapheme Cluster (EGC) segmentation and cell
// width. Ported from legacy/src/terminal/unicode_egc.odin.

Grapheme_Category :: enum u8 {
	Other,
	Extend,
	ZWJ,
	Emoji_Modifier,
	Regional_Indicator,
	Extended_Pictographic,
}

// grapheme_classify classifies a rune into its UAX #29 / UTS #51 category.
// Extend is limited to zero-width runes: a rune that occupies a cell never joins
// the previous cluster (no GB9a SpacingMark), otherwise the cursor would drift
// from the application's wcwidth.
grapheme_classify :: proc(r: rune) -> Grapheme_Category {
	if r == 0x200D do return .ZWJ
	if unicode.is_emoji_modifier(r) do return .Emoji_Modifier
	if unicode.is_regional_indicator(r) do return .Regional_Indicator
	if is_zero_width_extend(r) do return .Extend
	if unicode.is_emoji_extended_pictographic(r) do return .Extended_Pictographic
	return .Other
}

// grapheme_should_extend tests whether rune `next` extends the active cluster.
grapheme_should_extend :: proc(cluster_runes: []rune, next: rune) -> bool {
	if len(cluster_runes) == 0 do return false

	last_rune := cluster_runes[len(cluster_runes) - 1]
	next_cat := grapheme_classify(next)
	last_cat := grapheme_classify(last_rune)

	// Keycap sequence: ([0-9#*] | VS16) × U+20E3
	if next == 0x20E3 {
		if (last_rune >= '0' && last_rune <= '9') || last_rune == '#' || last_rune == '*' || last_rune == 0xFE0F {
			return true
		}
	}

	// GB9: × (Extend | ZWJ)
	if next_cat == .Extend || next_cat == .ZWJ do return true

	// Emoji modifier: extend only if cluster already contains an Extended_Pictographic.
	if next_cat == .Emoji_Modifier {
		for r in cluster_runes {
			if grapheme_classify(r) == .Extended_Pictographic do return true
		}
		return false
	}

	// GB11: ZWJ × Extended_Pictographic when an earlier Extended_Pictographic exists.
	if next_cat == .Extended_Pictographic && last_cat == .ZWJ {
		for r in cluster_runes[:len(cluster_runes) - 1] {
			if grapheme_classify(r) == .Extended_Pictographic do return true
		}
		return false
	}

	// GB12/GB13: Regional Indicator pairs.
	if next_cat == .Regional_Indicator {
		ri_count := 0
		for i := len(cluster_runes) - 1; i >= 0; i -= 1 {
			if grapheme_classify(cluster_runes[i]) == .Regional_Indicator {
				ri_count += 1
			} else {
				break
			}
		}
		return ri_count % 2 == 1
	}

	return false
}

// grapheme_cluster_width computes the display cell width (1 or 2) of a cluster.
grapheme_cluster_width :: proc(cluster_runes: []rune) -> int {
	if len(cluster_runes) == 0 do return 1

	// Keycap (U+20E3) always spans 2 cells.
	for r in cluster_runes {
		if r == 0x20E3 do return 2
	}

	// Regional indicator pairs span 2 cells.
	ri_count := 0
	for r in cluster_runes {
		if grapheme_classify(r) == .Regional_Indicator do ri_count += 1
	}
	if ri_count >= 2 do return 2

	// Emoji presentation spans 2 cells: a wide pictograph, or any pictograph turned
	// into emoji by VS16 or a skin-tone modifier (UTS #51 emoji modifier sequence).
	has_ep := false
	wants_emoji := false
	for r in cluster_runes {
		if r == 0xFE0F || unicode.is_emoji_modifier(r) do wants_emoji = true
		if grapheme_classify(r) == .Extended_Pictographic {
			has_ep = true
			if wcwidth(r) == 2 do return 2
		}
	}
	if has_ep && wants_emoji do return 2

	return wcwidth(cluster_runes[0])
}
