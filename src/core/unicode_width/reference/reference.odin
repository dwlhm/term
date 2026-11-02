package unicode_width_reference

// The definition of every property in unicode_width, written directly against
// core:unicode (generated from the UCD) plus the terminal-specific overrides.
// Slow by design: only the table generator and the equivalence tests use it.

import "core:unicode"
import uw "../"

props :: proc(r: rune) -> uw.Props {
	return {width = u8(width(r)), category = classify(r), emoji = is_emoji_presentation(r)}
}

// width returns 0 for zero-width / combining marks, 2 for wide characters, and
// 1 for normal monospace cells.
width :: proc(r: rune) -> int {
	if r < 0x80 do return 1
	// Box drawing and block elements are strictly width 1 in the terminal grid.
	if r >= 0x2500 && r <= 0x259F do return 1
	// Braille patterns are width 1.
	if r >= 0x2800 && r <= 0x28FF do return 1
	// Nerd Font symbols, Powerline and the supplementary private use planes are width 1.
	if r >= 0xE000 && r <= 0xF8FF do return 1
	if r >= 0xF0000 && r <= 0x10FFFD do return 1

	if is_zero_width(r) do return 0
	// Every Emoji_Presentation codepoint is EAW=Wide except regional indicators.
	if unicode.normalized_east_asian_width(r) == 2 || unicode.is_regional_indicator(r) do return 2
	return 1
}

// is_zero_width reports whether r occupies no cell: nonspacing/enclosing marks
// (combining diacritics, variation selectors) and invisible format characters
// (soft hyphen, ZWSP, ZWNJ, ZWJ, LRM/RLM, word joiner, BOM). Spacing marks (Mc)
// keep width 1, matching glibc wcwidth so application cursors stay aligned.
is_zero_width :: proc(r: rune) -> bool {
	if r < 0x00AD do return false
	switch r {
	case 0x00AD, 0x200B ..= 0x200F, 0x2060 ..= 0x2064, 0xFEFF:
		return true
	}
	return unicode.is_nonspacing_mark(r) || unicode.is_enclosing_mark(r)
}

// classify returns the UAX #29 / UTS #51 category of r.
classify :: proc(r: rune) -> uw.Grapheme_Category {
	if r == 0x200D do return .ZWJ
	if unicode.is_emoji_modifier(r) do return .Emoji_Modifier
	if unicode.is_regional_indicator(r) do return .Regional_Indicator
	if is_zero_width(r) do return .Extend
	if unicode.is_emoji_extended_pictographic(r) do return .Extended_Pictographic
	return .Other
}

// is_emoji_presentation reports Emoji_Presentation=Yes: a wide pictograph or
// skin-tone modifier, or a regional indicator. Emoji=Yes symbols that are narrow
// by default (U+23FA ⏺, U+2714 ✔, U+27A1 ➡) stay text.
is_emoji_presentation :: proc(r: rune) -> bool {
	if unicode.is_regional_indicator(r) do return true
	if !unicode.is_emoji_extended_pictographic(r) && !unicode.is_emoji_modifier(r) do return false
	return unicode.normalized_east_asian_width(r) == 2
}

// build_tables returns the two-stage lookup tables for every codepoint: stage1
// maps a 256-codepoint block to its index in stage2, which holds each distinct
// block once.
build_tables :: proc(allocator := context.allocator) -> (stage1: []u8, stage2: []u8, ok: bool) {
	BLOCK :: 1 << uw.BLOCK_SHIFT
	block_count := (uw.MAX_CODEPOINT + 1) / BLOCK
	stage1 = make([]u8, block_count, allocator)
	blocks := make([dynamic]u8, 0, 64 * BLOCK, allocator)

	current: [BLOCK]u8
	for b in 0 ..< block_count {
		for i in 0 ..< BLOCK do current[i] = transmute(u8)props(rune(b * BLOCK + i))
		index := _find_block(blocks[:], current[:])
		if index < 0 {
			index = len(blocks) / BLOCK
			if index > int(max(u8)) {
				delete(stage1, allocator)
				delete(blocks)
				return nil, nil, false
			}
			append(&blocks, ..current[:])
		}
		stage1[b] = u8(index)
	}
	return stage1, blocks[:], true
}

@(private = "file")
_find_block :: proc(blocks: []u8, block: []u8) -> int {
	for start := 0; start < len(blocks); start += len(block) {
		if string(blocks[start:][:len(block)]) == string(block) do return start / len(block)
	}
	return -1
}
