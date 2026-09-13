package termgrid

// UAX #29 and UTS #51 Extended Grapheme Cluster (EGC) segmentation and cell width.

Grapheme_Break_Category :: enum u8 {
	Other,
	Extend,
	ZWJ,
	SpacingMark,
	Emoji_Modifier,
	Regional_Indicator,
	Extended_Pictographic,
	Prepend,
}

// uax29_classify classifies a rune into its UAX #29 / UTS #51 break category.
uax29_classify :: proc(r: rune) -> Grapheme_Break_Category {
	if r == 0x200D {
		return .ZWJ
	}
	if r >= 0x1F3FB && r <= 0x1F3FF {
		return .Emoji_Modifier
	}
	if r >= 0x1F1E6 && r <= 0x1F1FF {
		return .Regional_Indicator
	}
	if is_zero_width_extend(r) {
		return .Extend
	}
	if is_emoji_codepoint(r) {
		return .Extended_Pictographic
	}
	return .Other
}

// uax29_should_extend tests whether rune 'next' extends the active grapheme cluster 'cluster'.
uax29_should_extend :: proc(cluster: ^Grapheme_Cluster, next: rune) -> bool {
	if cluster == nil || cluster.rune_count == 0 {
		return false
	}
	last_rune := cluster.runes[cluster.rune_count - 1]
	next_cat := uax29_classify(next)
	last_cat := uax29_classify(last_rune)

	// Keycap sequence: ([0-9#*] | 0xFE0F) × 0x20E3
	if next == 0x20E3 {
		if (last_rune >= '0' && last_rune <= '9') || last_rune == '#' || last_rune == '*' || last_rune == 0xFE0F {
			return true
		}
	}

	// Rule GB9: × (Extend | ZWJ)
	if next_cat == .Extend || next_cat == .ZWJ {
		return true
	}

	// Rule GB9a: × SpacingMark
	if next_cat == .SpacingMark {
		return true
	}

	// Rule Emoji Modifier: if next_cat == .Emoji_Modifier: check if cluster contains an .Extended_Pictographic
	if next_cat == .Emoji_Modifier {
		for i in 0..<int(cluster.rune_count) {
			cat := uax29_classify(cluster.runes[i])
			if cat == .Extended_Pictographic {
				return true
			}
		}
		return false
	}

	// Rule GB11 (ZWJ emoji sequence): if next_cat == .Extended_Pictographic && last_cat == .ZWJ:
	// check if cluster contains .Extended_Pictographic before ZWJ -> return true.
	if next_cat == .Extended_Pictographic && last_cat == .ZWJ {
		for i in 0..<int(cluster.rune_count - 1) {
			cat := uax29_classify(cluster.runes[i])
			if cat == .Extended_Pictographic {
				return true
			}
		}
		return false
	}

	// Rule GB12/13 (Regional Indicators): if next_cat == .Regional_Indicator:
	// Count consecutive Regional_Indicator runes at end of cluster.
	// If count % 2 == 1 (odd), return true (completes pair). If even, return false (breaks).
	if next_cat == .Regional_Indicator {
		ri_count := 0
		for i := int(cluster.rune_count) - 1; i >= 0; i -= 1 {
			if uax29_classify(cluster.runes[i]) == .Regional_Indicator {
				ri_count += 1
			} else {
				break
			}
		}
		if ri_count % 2 == 1 {
			return true
		}
		return false
	}

	return false
}

// grapheme_cluster_width computes the display cell width (1 or 2) of a cluster.
grapheme_cluster_width :: proc(cluster: ^Grapheme_Cluster) -> u8 {
	if cluster == nil || cluster.rune_count == 0 {
		return 1
	}

	// Check if contains 0x20E3 (keycap) -> return 2
	for i in 0..<int(cluster.rune_count) {
		if cluster.runes[i] == 0x20E3 {
			return 2
		}
	}

	// Check if contains Regional Indicator pair -> return 2
	ri_count := 0
	for i in 0..<int(cluster.rune_count) {
		if uax29_classify(cluster.runes[i]) == .Regional_Indicator {
			ri_count += 1
		}
	}
	if ri_count >= 2 {
		return 2
	}

	// Check if contains Extended_Pictographic / emoji presentation -> return 2
	has_ep := false
	has_vs16 := false
	for i in 0..<int(cluster.rune_count) {
		r := cluster.runes[i]
		if r == 0xFE0F {
			has_vs16 = true
		}
		if uax29_classify(r) == .Extended_Pictographic {
			has_ep = true
			if wcwidth(r) == 2 {
				return 2
			}
		}
	}
	if has_ep && has_vs16 {
		return 2
	}

	// Else return wcwidth(cluster.runes[0])
	w := wcwidth(cluster.runes[0])
	if w == 0 {
		return 1
	}
	return w
}
