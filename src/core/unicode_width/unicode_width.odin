package unicode_width

// Terminal cell width and grapheme properties of a codepoint in one O(1) table
// lookup. The tables are generated from `reference/` (run `make gen-unicode`);
// `tests/` proves props() equals the reference for every codepoint.

Grapheme_Category :: enum u8 {
	Other,
	Extend, // zero-width: nonspacing/enclosing marks and invisible format characters
	ZWJ,
	Emoji_Modifier,
	Regional_Indicator,
	Extended_Pictographic,
}

Props :: bit_field u8 {
	width:    u8                | 2, // terminal cells: 0, 1 or 2
	category: Grapheme_Category | 3,
	emoji:    bool              | 1, // default emoji presentation (Emoji_Presentation=Yes)
}

MAX_CODEPOINT :: 0x10FFFF
BLOCK_SHIFT :: 8

// Runes outside the Unicode range behave like a plain narrow character.
OUT_OF_RANGE :: Props{width = 1}

props :: #force_inline proc "contextless" (r: rune) -> Props #no_bounds_check {
	cp := u32(r)
	if cp > MAX_CODEPOINT do return OUT_OF_RANGE
	block := u32(STAGE1[cp >> BLOCK_SHIFT])
	return transmute(Props)STAGE2[block << BLOCK_SHIFT | (cp & (1 << BLOCK_SHIFT - 1))]
}

// width returns the number of terminal cells `r` occupies (0, 1 or 2).
width :: #force_inline proc "contextless" (r: rune) -> int {
	return int(props(r).width)
}

// is_emoji_presentation reports default emoji presentation: a wide pictograph,
// a skin-tone modifier or a regional indicator.
is_emoji_presentation :: #force_inline proc "contextless" (r: rune) -> bool {
	return props(r).emoji
}
