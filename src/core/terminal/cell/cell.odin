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
	Has_Underline_Decor = 5, // Uses the underline style/colour in the parallel row extension
}
Cell_Flags :: distinct bit_set[Cell_Flag; u8]

// Underline_Style is the SGR 4:<n> underline shape stored beside a cell.
// `.None` means no underline; every other value implies the Underline flag.
Underline_Style :: enum u8 {
	None   = 0,
	Single = 1,
	Double = 2,
	Curly  = 3,
	Dotted = 4,
	Dashed = 5,
}

// Underline_Color_Mode distinguishes the default pen colour (SGR 59), a
// 256-colour palette index (SGR 58;5;n) and a 24-bit RGB value (SGR 58;2::r:g:b).
Underline_Color_Mode :: enum u8 {
	Default = 0,
	Palette = 1,
	Rgb     = 2,
}

Underline_Color :: struct {
	mode:  Underline_Color_Mode,
	index: u8,
	rgb:   [3]u8,
}

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
	link_id: u16, // OSC 8 hyperlink id (0 = none), stored beside the cell
	underline_style: Underline_Style, // SGR 4:n shape (None unless Has_Underline_Decor)
	underline:       Underline_Color, // SGR 58/59 underline colour
}

// underline_decor_needed reports whether the cell's underline needs the side
// storage: a non-single shape or a non-default colour. Plain `SGR 4` stays in
// the 8-byte cell alone, keeping the ASCII fast path free of side reads.
underline_decor_needed :: proc(style: Underline_Style, color: Underline_Color) -> bool {
	return style > .Single || color.mode != .Default
}

// cell_underline_style resolves the effective underline shape for a cell,
// falling back to Single when only the Underline flag is present.
cell_underline_style :: proc(c: Semantic_Cell, dc: Direct_Color) -> Underline_Style {
	if .Underline not_in c.style do return .None
	if .Has_Underline_Decor in c.flags && dc.underline_style > .None do return dc.underline_style
	return .Single
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
