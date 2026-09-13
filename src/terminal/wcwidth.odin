package termgrid

// Wide and zero-width tables for terminal cell widths.
// Slow path only: the ASCII fast path never calls into this file.

// _WIDE_RANGES lists inclusive [lo, hi] rune ranges occupying 2 cells.
// Sorted ascending. Sources:
//   • East_Asian_Width=Wide from Unicode 15 (Hangul, CJK, fullwidth forms)
//   • Emoji_Presentation=Yes from Unicode 15 (BMP entries only; SMP is
//     covered by the large 0x1F000+ blocks below)
// U+2603 SNOWMAN and similar have Emoji but NOT Emoji_Presentation: they
// default to text/narrow and are excluded. U+FE0F variation selector stays
// in _EXTEND_RANGES (zero-width). Package-level fixed table (never mutated);
// `:=` because Odin constants are not sliceable for the linear scan.
_WIDE_RANGES := [?][2]rune{
	{0x1100, 0x115F},   // Hangul Jamo
	{0x231A, 0x231B},   // WATCH, HOURGLASS (EP)
	{0x2329, 0x232A},   // CJK angle brackets (EAW=Wide)
	{0x23E9, 0x23F3},   // fast-fwd..hourglass-flowing (all EP)
	{0x23F8, 0x23FA},   // pause/stop/record buttons (EP)
	{0x25AA, 0x25AB},   // small black/white square (EP)
	{0x25B6, 0x25B6},   // play button (EP)
	{0x25C0, 0x25C0},   // reverse button (EP)
	{0x25FB, 0x25FE},   // medium squares (EP; expands old 25FD-25FE)
	{0x2614, 0x2615},   // umbrella+rain, hot beverage (EP)
	{0x2648, 0x2653},   // zodiac signs (EP)
	{0x267F, 0x267F},   // wheelchair symbol (EP)
	{0x2693, 0x2693},   // anchor (EP)
	{0x26A1, 0x26A1},   // high voltage / lightning (EP)
	{0x26AA, 0x26AB},   // medium circles (EP)
	{0x26BD, 0x26BE},   // soccer ball, baseball (EP)
	{0x26C4, 0x26C5},   // snowman-no-snow, sun-cloud (EP)
	{0x26CE, 0x26CE},   // ophiuchus (EP)
	{0x26D4, 0x26D4},   // no entry (EP)
	{0x26EA, 0x26EA},   // church (EP)
	{0x26F2, 0x26F3},   // fountain, flag in hole (EP)
	{0x26F5, 0x26F5},   // sailboat (EP)
	{0x26FA, 0x26FA},   // tent (EP)
	{0x26FD, 0x26FD},   // fuel pump (EP)
	{0x2702, 0x2702},   // scissors (EP)
	{0x2705, 0x2705},   // white heavy check mark (EP)
	{0x2708, 0x2708},   // airplane (EP; U+2709 envelope is NOT EP)
	{0x270A, 0x270D},   // raised-fist..writing-hand (all EP; expands old 270A-270B)
	{0x270F, 0x270F},   // pencil (EP)
	{0x2712, 0x2712},   // black nib (EP)
	{0x2714, 0x2714},   // heavy check mark (EP)
	{0x2716, 0x2716},   // heavy multiplication X (EP)
	{0x271D, 0x271D},   // latin cross (EP)
	{0x2721, 0x2721},   // star of david (EP)
	{0x2728, 0x2728},   // sparkles (EP)
	{0x2733, 0x2734},   // eight-spoked/pointed asterisk (EP)
	{0x2744, 0x2744},   // snowflake (EP)
	{0x2747, 0x2747},   // sparkle (EP)
	{0x274C, 0x274C},   // cross mark (EP)
	{0x274E, 0x274E},   // cross mark (EP)
	{0x2753, 0x2755},   // question marks (EP)
	{0x2757, 0x2757},   // exclamation mark (EP)
	{0x2763, 0x2764},   // heart exclamation, red heart (EP)
	{0x2795, 0x2797},   // plus, minus, division signs (EP)
	{0x27A1, 0x27A1},   // right arrow (EP)
	{0x27B0, 0x27B0},   // curly loop (EP)
	{0x27BF, 0x27BF},   // double curly loop (EP)
	{0x2934, 0x2935},   // curved arrows (EP)
	{0x2B05, 0x2B07},   // colored direction arrows (EP)
	{0x2B1B, 0x2B1C},   // large black/white square (EP)
	{0x2B50, 0x2B50},   // star (EP)
	{0x2B55, 0x2B55},   // hollow red circle (EP)
	{0x2E80, 0x4DBF},   // CJK radicals, Kangxi, bopomofo, Hangul compat...
	{0x4E00, 0xA4CF},   // CJK unified ideographs + Yi
	{0xAC00, 0xD7A3},   // Hangul syllables
	{0xF900, 0xFAFF},   // CJK compatibility ideographs
	{0xFE10, 0xFE19},   // Vertical forms
	{0xFE30, 0xFE4F},   // CJK compatibility forms
	{0xFF00, 0xFF60},   // Fullwidth Latin/symbols
	{0xFFE0, 0xFFE6},   // Fullwidth signs
	{0x1F000, 0x1F02F}, // Mahjong tiles
	{0x1F0A0, 0x1F0FF}, // Playing cards
	{0x1F1E6, 0x1F1FF}, // Regional indicator symbols
	{0x1F300, 0x1FAFF}, // Misc symbols & pictographs, emoticons, transport...
	{0x1FB00, 0x1FBFF}, // Symbols for legacy computing
	{0x20000, 0x2FFFD}, // CJK extension B-F
	{0x30000, 0x3FFFD}, // CJK extension G-H
}

// _EXTEND_RANGES lists inclusive [lo, hi] combining-mark ranges (width 0).
// Sorted ascending. Single-codepoint extends (ZWJ, ZWNBSP, ZWSP..RLO,
// soft hyphen) are covered via range entries below. Fixed table, see above.
_EXTEND_RANGES := [?][2]rune{
	{0x00AD, 0x00AD},
	{0x0300, 0x036F},
	{0x1AB0, 0x1AFF},
	{0x1DC0, 0x1DFF},
	{0x200B, 0x200F},
	{0x20D0, 0x20FF},
	{0xFE00, 0xFE0F},
	{0xFEFF, 0xFEFF},
}

// _in_ranges reports whether r falls in any inclusive range of table.
// Linear scan is fine: this file is slow-path only.
_in_ranges :: proc(r: rune, table: [][2]rune) -> bool {
	for i in 0..<len(table) {
		if r >= table[i][0] && r <= table[i][1] {
			return true
		}
	}
	return false
}

// is_zero_width_extend reports whether r is a zero-width extend character:
// a combining mark appended to the base cluster (no cursor advance).
// Includes ZWJ (U+200D, via the U+200B..U+200F range): it extends the base
// cluster, but the following base char still starts a new cell (no ligature).
is_zero_width_extend :: proc(r: rune) -> bool {
	return _in_ranges(r, _EXTEND_RANGES[:])
}

// is_emoji_codepoint reports whether r is a standard emoji presentation or pictograph codepoint.
is_emoji_codepoint :: proc(r: rune) -> bool {
	if (r >= 0x1F000 && r <= 0x1FAFF) || (r >= 0x1FB00 && r <= 0x1FBFF) {
		return true
	}
	if (r >= 0x2600 && r <= 0x27BF) || (r >= 0x2300 && r <= 0x23FF) {
		return true
	}
	if (r >= 0x2B00 && r <= 0x2BFF) || (r >= 0x25A0 && r <= 0x25FF) {
		return true
	}
	if (r >= 0x2190 && r <= 0x21FF) {
		return true
	}
	switch r {
	case 0x203C, 0x2049, 0x2122, 0x2139, 0x3030, 0x303D, 0x3297, 0x3299:
		return true
	}
	return false
}

// is_emoji_presentation is an alias for is_emoji_codepoint.
is_emoji_presentation :: proc(r: rune) -> bool {
	return is_emoji_codepoint(r)
}

// wcwidth returns the terminal cell width of r: 0 (extend), 2 (wide), else 1.
// Controls never reach here: the parser routes C0 to execute_c0 and the
// ASCII fast path (c < 0x80) never calls wcwidth.
// Width is determined by _WIDE_RANGES (East_Asian_Width=Wide + Unicode 15
// Emoji_Presentation BMP entries). Extend check runs first so variation
// selectors (U+FE00..U+FE0F) and ZWJ (U+200D) stay zero-width.
wcwidth :: proc(r: rune) -> u8 {
	if is_zero_width_extend(r) {
		return 0
	}
	if _in_ranges(r, _WIDE_RANGES[:]) {
		return 2
	}
	return 1
}

