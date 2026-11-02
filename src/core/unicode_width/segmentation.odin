package unicode_width

// UAX #29 / UTS #51 extended grapheme cluster joining and cluster cell width.
// Extend is limited to zero-width runes: a rune that occupies a cell never joins
// the previous cluster (no GB9a SpacingMark), otherwise the cursor would drift
// from the application's wcwidth.

KEYCAP :: rune(0x20E3)
VS16 :: rune(0xFE0F)

// can_extend reports whether a rune with props `p` could ever join a previous
// cluster. should_extend returns false for every .Other rune, so callers skip
// reading the previous cluster for plain text (CJK, Latin, box drawing).
can_extend :: #force_inline proc "contextless" (p: Props) -> bool {
	return p.category != .Other
}

// should_extend tests whether rune `next` extends the cluster `cluster`.
should_extend :: proc(cluster: []rune, next: rune) -> bool {
	if len(cluster) == 0 do return false

	last := cluster[len(cluster) - 1]
	next_cat := props(next).category

	// Keycap sequence: ([0-9#*] | VS16) × U+20E3
	if next == KEYCAP && ((last >= '0' && last <= '9') || last == '#' || last == '*' || last == VS16) {
		return true
	}

	switch next_cat {
	case .Extend, .ZWJ: // GB9
		return true
	case .Emoji_Modifier: // only after an Extended_Pictographic
		return _contains_pictographic(cluster)
	case .Extended_Pictographic: // GB11: ZWJ × Extended_Pictographic after an earlier one
		return props(last).category == .ZWJ && _contains_pictographic(cluster[:len(cluster) - 1])
	case .Regional_Indicator: // GB12/GB13: pairs
		ri_count := 0
		for i := len(cluster) - 1; i >= 0 && props(cluster[i]).category == .Regional_Indicator; i -= 1 {
			ri_count += 1
		}
		return ri_count % 2 == 1
	case .Other:
	}
	return false
}

// cluster_width computes the cell width (1 or 2) of a grapheme cluster.
cluster_width :: proc(cluster: []rune) -> int {
	if len(cluster) == 0 do return 1

	ri_count := 0
	has_ep, wants_emoji := false, false
	for r in cluster {
		if r == KEYCAP do return 2
		p := props(r)
		switch p.category {
		case .Regional_Indicator:
			ri_count += 1
		case .Emoji_Modifier:
			wants_emoji = true
		case .Extended_Pictographic:
			// A wide pictograph, or one turned into emoji by VS16 or a skin-tone modifier.
			if p.width == 2 do return 2
			has_ep = true
		case .Other, .Extend, .ZWJ:
		}
		if r == VS16 do wants_emoji = true
	}
	if ri_count >= 2 do return 2
	if has_ep && wants_emoji do return 2
	return width(cluster[0])
}

@(private = "file")
_contains_pictographic :: proc(runes: []rune) -> bool {
	for r in runes do if props(r).category == .Extended_Pictographic do return true
	return false
}
