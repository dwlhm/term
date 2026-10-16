package terminal_cell

// Unicode character width calculation for terminal cell layout.
// Monospace cell widths: 0 (zero-width / extend), 1 (standard single), 2 (wide).

_WIDE_RANGES := [?][2]rune{
	{0x1100, 0x115F},   // Hangul Jamo
	{0x231A, 0x231B},   // WATCH, HOURGLASS (EP)
	{0x2329, 0x232A},   // CJK angle brackets (EAW=Wide)
	{0x23E9, 0x23F3},   // fast-fwd..hourglass-flowing
	{0x23F8, 0x23FA},   // pause/stop/record buttons
	{0x25AA, 0x25AB},   // small black/white square
	{0x25B6, 0x25B6},   // play button
	{0x25C0, 0x25C0},   // reverse button
	{0x25FB, 0x25FE},   // medium squares
	{0x2614, 0x2615},   // umbrella+rain, hot beverage
	{0x2648, 0x2653},   // zodiac signs
	{0x267F, 0x267F},   // wheelchair symbol
	{0x2693, 0x2693},   // anchor
	{0x26A1, 0x26A1},   // high voltage / lightning
	{0x26AA, 0x26AB},   // medium circles
	{0x26BD, 0x26BE},   // soccer ball, baseball
	{0x26C4, 0x26C5},   // snowman-no-snow, sun-cloud
	{0x26CE, 0x26CE},   // ophiuchus
	{0x26D4, 0x26D4},   // no entry
	{0x26EA, 0x26EA},   // church
	{0x26F2, 0x26F3},   // fountain, flag in hole
	{0x26F5, 0x26F5},   // sailboat
	{0x26FA, 0x26FA},   // tent
	{0x26FD, 0x26FD},   // fuel pump
	{0x2702, 0x2702},   // scissors
	{0x2705, 0x2705},   // white heavy check mark
	{0x2708, 0x2708},   // airplane
	{0x270A, 0x270D},   // raised-fist..writing-hand
	{0x270F, 0x270F},   // pencil
	{0x2712, 0x2712},   // black nib
	{0x2714, 0x2714},   // heavy check mark
	{0x2716, 0x2716},   // heavy multiplication X
	{0x271D, 0x271D},   // latin cross
	{0x2721, 0x2721},   // star of david
	{0x2728, 0x2728},   // sparkles
	{0x2733, 0x2734},   // eight-spoked/pointed asterisk
	{0x2744, 0x2744},   // snowflake
	{0x2747, 0x2747},   // sparkle
	{0x274C, 0x274C},   // cross mark
	{0x274E, 0x274E},   // cross mark
	{0x2753, 0x2755},   // question marks
	{0x2757, 0x2757},   // exclamation mark
	{0x2763, 0x2764},   // heart exclamation, red heart
	{0x2795, 0x2797},   // plus, minus, division signs
	{0x27A1, 0x27A1},   // right arrow
	{0x27B0, 0x27B0},   // curly loop
	{0x27BF, 0x27BF},   // double curly loop
	{0x2934, 0x2935},   // curved arrows
	{0x2B05, 0x2B07},   // colored direction arrows
	{0x2B1B, 0x2B1C},   // large black/white square
	{0x2B50, 0x2B50},   // star
	{0x2B55, 0x2B55},   // hollow red circle
	{0x2E80, 0x4DBF},   // CJK radicals, Hangul compat...
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

_in_ranges :: proc(r: rune, table: [][2]rune) -> bool {
	for i in 0..<len(table) {
		if r >= table[i][0] && r <= table[i][1] {
			return true
		}
	}
	return false
}

// wcwidth returns 0 for zero-width / combining marks, 2 for wide characters, and 1 for normal monospace cells.
wcwidth :: proc(r: rune) -> int {
	if r < 0x80 do return 1
	// Box drawing and block elements are strictly width 1 in terminal grid
	if r >= 0x2500 && r <= 0x259F do return 1
	// Braille patterns are width 1
	if r >= 0x2800 && r <= 0x28FF do return 1
	// Nerd font symbols & Powerline are width 1
	if r >= 0xE000 && r <= 0xF8FF do return 1
	if r >= 0xF0000 && r <= 0x10FFFD do return 1

	if _in_ranges(r, _EXTEND_RANGES[:]) {
		return 0
	}
	if _in_ranges(r, _WIDE_RANGES[:]) {
		return 2
	}
	return 1
}

// is_zero_width_extend reports whether r is a zero-width extend character:
// a combining mark, variation selector, or ZWJ (U+200D, via U+200B..U+200F).
is_zero_width_extend :: proc(r: rune) -> bool {
	return _in_ranges(r, _EXTEND_RANGES[:])
}

// _EMOJI_BMP_RANGES lists inclusive [lo, hi] BMP ranges with Emoji_Presentation=Yes.
_EMOJI_BMP_RANGES := [?][2]rune{
	{0x231A, 0x231B}, {0x23E9, 0x23F3}, {0x23F8, 0x23FA}, {0x25AA, 0x25AB},
	{0x25B6, 0x25B6}, {0x25C0, 0x25C0}, {0x25FB, 0x25FE}, {0x2614, 0x2615},
	{0x2648, 0x2653}, {0x267F, 0x267F}, {0x2693, 0x2693}, {0x26A1, 0x26A1},
	{0x26AA, 0x26AB}, {0x26BD, 0x26BE}, {0x26C4, 0x26C5}, {0x26CE, 0x26CE},
	{0x26D4, 0x26D4}, {0x26EA, 0x26EA}, {0x26F2, 0x26F3}, {0x26F5, 0x26F5},
	{0x26FA, 0x26FA}, {0x26FD, 0x26FD}, {0x2702, 0x2702}, {0x2705, 0x2705},
	{0x2708, 0x2708}, {0x270A, 0x270D}, {0x270F, 0x270F}, {0x2712, 0x2712},
	{0x2714, 0x2714}, {0x2716, 0x2716}, {0x271D, 0x271D}, {0x2721, 0x2721},
	{0x2728, 0x2728}, {0x2733, 0x2734}, {0x2744, 0x2744}, {0x2747, 0x2747},
	{0x274C, 0x274C}, {0x274E, 0x274E}, {0x2753, 0x2755}, {0x2757, 0x2757},
	{0x2763, 0x2764}, {0x2795, 0x2797}, {0x27A1, 0x27A1}, {0x27B0, 0x27B0},
	{0x27BF, 0x27BF}, {0x2934, 0x2935}, {0x2B05, 0x2B07}, {0x2B1B, 0x2B1C},
	{0x2B50, 0x2B50}, {0x2B55, 0x2B55},
}

// is_emoji_codepoint reports whether r is a standard emoji-presentation or pictograph codepoint.
is_emoji_codepoint :: proc(r: rune) -> bool {
	if (r >= 0x1F000 && r <= 0x1FAFF) || (r >= 0x1FB00 && r <= 0x1FBFF) {
		return true
	}
	return _in_ranges(r, _EMOJI_BMP_RANGES[:])
}

// is_emoji_vs16_eligible reports whether r becomes an emoji when followed by VS16 (U+FE0F).
is_emoji_vs16_eligible :: proc(r: rune) -> bool {
	if is_emoji_codepoint(r) do return true
	if (r >= 0x2600 && r <= 0x27BF) || (r >= 0x2300 && r <= 0x23FF) do return true
	if (r >= 0x2B00 && r <= 0x2BFF) || (r >= 0x25A0 && r <= 0x25FF) do return true
	if r >= 0x2190 && r <= 0x21FF do return true
	switch r {
	case 0x203C, 0x2049, 0x2122, 0x2139, 0x3030, 0x303D, 0x3297, 0x3299:
		return true
	}
	return false
}
