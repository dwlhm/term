package terminal_cell

// Style_Flag represents visual character cell attributes
Style_Flag :: enum u8 {
	Bold      = 0,
	Dim       = 1,
	Italic    = 2,
	Underline = 3,
	Invert    = 4,
	Strike    = 5,
	Blink     = 6,
	Hidden    = 7,
}
Style_Flags :: distinct bit_set[Style_Flag; u8]

// Cell_Flag represents layout and rendering metadata for a cell
Cell_Flag :: enum u8 {
	Wide_Lead         = 0, // Left half of a double-width rune
	Wide_Continuation = 1, // Right half of a double-width rune
	Has_Egc           = 2, // References an Extended Grapheme Cluster in egc pool
	Has_Direct_Color  = 3, // Uses 24-bit TrueColor stored in parallel row extension
	Has_Hyperlink     = 4, // References an active OSC 8 hyperlink ID
}
Cell_Flags :: distinct bit_set[Cell_Flag; u8]

// Semantic_Cell is the canonical 64-bit monospace character cell representation.
// Target size: exactly 8 bytes (fits in a single 64-bit machine word/register).
Semantic_Cell :: struct {
	char:  rune,        // 32-bit Unicode codepoint (or EGC pool index if Has_Egc)
	fg:    u8,          // ANSI/256 palette index (0..255)
	bg:    u8,          // ANSI/256 palette index (0..255)
	style: Style_Flags, // 8-bit style attribute bitset
	flags: Cell_Flags,  // 8-bit layout/metadata bitset
}
#assert(size_of(Semantic_Cell) == 8)

// Direct_Color stores optional 24-bit RGB TrueColor values in parallel row buffers.
Direct_Color :: struct {
	fg:     [3]u8, // R, G, B
	bg:     [3]u8, // R, G, B
	has_fg: bool,
	has_bg: bool,
}

// CELL_DEFAULT represents a blank terminal cell with default attributes.
CELL_DEFAULT :: Semantic_Cell{
	char  = ' ',
	fg    = 7,  // Standard default foreground (White/Light Grey)
	bg    = 0,  // Standard default background (Black)
	style = {},
	flags = {},
}

cell_make :: proc(ch: rune, fg: u8 = 7, bg: u8 = 0, style: Style_Flags = {}, flags: Cell_Flags = {}) -> Semantic_Cell {
	return Semantic_Cell{
		char  = ch if ch != 0 else ' ',
		fg    = fg,
		bg    = bg,
		style = style,
		flags = flags,
	}
}

cell_reset :: proc(c: ^Semantic_Cell) {
	if c == nil do return
	c^ = CELL_DEFAULT
}

cell_is_empty :: proc(c: Semantic_Cell) -> bool {
	return (c.char == ' ' || c.char == 0) && c.bg == 0 && c.style == {} && c.flags == {}
}
