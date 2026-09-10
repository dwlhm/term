package termgrid

// Wide and zero-width tables for terminal cell widths.
// Slow path only: the ASCII fast path never calls into this file.

// _WIDE_RANGES lists inclusive [lo, hi] rune ranges occupying 2 cells.
// Sorted ascending. Covers Hangul Jamo, selected emoji-presentation symbols,
// CJK radicals/ideographs, Hangul syllables, CJK compat, fullwidth forms,
// and the wide emoji + supplementary planes. U+2603 (snowman) is narrow.
// Package-level fixed table (never mutated); `:=` because Odin constants
// are not sliceable for the linear scan.
_WIDE_RANGES := [?][2]rune{
	{0x1100, 0x115F},
	{0x231A, 0x231B},
	{0x2329, 0x232A},
	{0x23E9, 0x23EC},
	{0x23F0, 0x23F0},
	{0x23F3, 0x23F3},
	{0x25FD, 0x25FE},
	{0x2614, 0x2615},
	{0x2648, 0x2653},
	{0x267F, 0x267F},
	{0x2693, 0x2693},
	{0x26A1, 0x26A1},
	{0x26AA, 0x26AB},
	{0x26BD, 0x26BE},
	{0x26C4, 0x26C5},
	{0x26CE, 0x26CE},
	{0x26D4, 0x26D4},
	{0x26EA, 0x26EA},
	{0x26F2, 0x26F3},
	{0x26F5, 0x26F5},
	{0x26FA, 0x26FA},
	{0x26FD, 0x26FD},
	{0x2705, 0x2705},
	{0x270A, 0x270B},
	{0x2728, 0x2728},
	{0x274C, 0x274C},
	{0x274E, 0x274E},
	{0x2753, 0x2755},
	{0x2757, 0x2757},
	{0x2795, 0x2797},
	{0x27B0, 0x27B0},
	{0x27BF, 0x27BF},
	{0x2B1B, 0x2B1C},
	{0x2B50, 0x2B50},
	{0x2B55, 0x2B55},
	{0x2E80, 0x4DBF},
	{0x4E00, 0xA4CF},
	{0xAC00, 0xD7A3},
	{0xF900, 0xFAFF},
	{0xFE10, 0xFE19},
	{0xFE30, 0xFE4F},
	{0xFF00, 0xFF60},
	{0xFFE0, 0xFFE6},
	{0x1F300, 0x1F64F},
	{0x1F900, 0x1F9FF},
	{0x20000, 0x2FFFD},
	{0x30000, 0x3FFFD},
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

// wcwidth returns the terminal cell width of r: 0 (extend), 2 (wide), else 1.
// Controls never reach here: the parser routes C0 to execute_c0 and the
// ASCII fast path (c < 0x80) never calls wcwidth.
wcwidth :: proc(r: rune) -> u8 {
	if is_zero_width_extend(r) {
		return 0
	}
	if _in_ranges(r, _WIDE_RANGES[:]) {
		return 2
	}
	return 1
}
