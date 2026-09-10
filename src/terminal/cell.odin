package termgrid

// Content_Handle represents a reference to character content (codepoint or grapheme).
// Phase 1: only codepoints (rune). Phase 2: grapheme clusters.
Content_Handle :: u32

// Cell_Flags is a bitfield for cell metadata.
Cell_Flags :: enum u8 {
	None              = 0,
	Wide_Continuation = 1 << 0, // this cell is the right half of a wide char
	Dirty             = 1 << 1, // cell has been modified (for internal tracking)
}

// Semantic_Cell represents a single cell in the terminal grid.
// Size: 8 bytes (target: <= 16 bytes)
Semantic_Cell :: struct {
	content: Content_Handle, // codepoint or grapheme handle
	style:   Style_Id,       // index into style table
	width:   u8,             // character width (1 or 2 for wide chars)
	flags:   Cell_Flags,     // bitfield metadata
}

// CELL_DEFAULT is the default cell (empty, default style, width 1).
CELL_DEFAULT :: Semantic_Cell{
	content = 0,
	style   = 0,
	width   = 1,
	flags   = .None,
}
