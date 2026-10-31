package terminal_cell

import "core:unicode"

// Unicode character width calculation for terminal cell layout.
// Monospace cell widths: 0 (zero-width / extend), 1 (standard single), 2 (wide).
// Unicode properties come from core:unicode (generated from the UCD); only the
// terminal-specific overrides below are hand-written.

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

	if is_zero_width_extend(r) {
		return 0
	}
	// Every Emoji_Presentation codepoint is EAW=Wide except regional indicators.
	if unicode.normalized_east_asian_width(r) == 2 || unicode.is_regional_indicator(r) {
		return 2
	}
	return 1
}

// is_zero_width_extend reports whether r occupies no cell: nonspacing/enclosing
// marks (combining diacritics, variation selectors) and invisible format characters
// (soft hyphen, ZWSP, ZWNJ, ZWJ, LRM/RLM, word joiner, BOM). Spacing marks (Mc)
// keep width 1, matching glibc wcwidth so application cursors stay aligned.
is_zero_width_extend :: proc(r: rune) -> bool {
	if r < 0x00AD do return false
	switch r {
	case 0x00AD, 0x200B ..= 0x200F, 0x2060 ..= 0x2064, 0xFEFF:
		return true
	}
	return unicode.is_nonspacing_mark(r) || unicode.is_enclosing_mark(r)
}

// is_emoji_codepoint reports whether r has default emoji presentation (Emoji_Presentation=Yes),
// i.e. a wide pictograph or skin-tone modifier. Emoji=Yes symbols that are narrow by default
// (U+23FA ⏺, U+2714 ✔, U+27A1 ➡) stay text unless followed by VS16 (see grapheme_cluster_width).
is_emoji_codepoint :: proc(r: rune) -> bool {
	if unicode.is_regional_indicator(r) do return true
	if !unicode.is_emoji_extended_pictographic(r) && !unicode.is_emoji_modifier(r) do return false
	return unicode.normalized_east_asian_width(r) == 2
}
