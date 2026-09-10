package termgrid

// Style_Id is an index into the style table.
Style_Id :: u16

// Style represents the visual attributes of a cell.
// Size: 16 bytes
Style :: struct {
	fg:        u32, // foreground color (ARGB or palette index)
	bg:        u32, // background color
	underline: u32, // underline color
	flags:     u16, // bitfield: bold, italic, underline_style, etc.
}

// STYLE_DEFAULT is the default style (white on black, no decoration).
STYLE_DEFAULT :: Style{
	fg        = 0xFFFFFFFF, // white
	bg        = 0xFF000000, // black
	underline = 0,
	flags     = 0,
}

// Style attribute flag bits stored in Style.flags.
// NOTE: stored only — the glyph shader resolves fg/bg via Style_LUT and
// does not render bold/italic/underline/inverse/strike yet.
STYLE_FLAG_BOLD      :: u16(1 << 0)
STYLE_FLAG_ITALIC    :: u16(1 << 1)
STYLE_FLAG_UNDERLINE :: u16(1 << 2)
STYLE_FLAG_INVERSE   :: u16(1 << 3)
STYLE_FLAG_STRIKE    :: u16(1 << 4)

// STYLE_TABLE_CAPACITY is the maximum number of styles in the table.
STYLE_TABLE_CAPACITY :: 1024

// Style_Table is a deduplication table for styles.
// Capacity: 1024 entries (configurable via STYLE_TABLE_CAPACITY).
Style_Table :: struct {
	entries: [STYLE_TABLE_CAPACITY]Style,
	count:   u16,
}

// style_table_init initializes a style table with the default style at index 0.
style_table_init :: proc(t: ^Style_Table) {
	t.entries[0] = STYLE_DEFAULT
	t.count = 1
}

// _style_eq checks if two styles are equal (all fields match).
_style_eq :: proc(a, b: Style) -> bool {
	return a.fg == b.fg && a.bg == b.bg && a.underline == b.underline && a.flags == b.flags
}

// style_table_insert inserts a style into the table and returns its ID.
// If the style already exists, returns the existing ID (deduplication).
// If the table is full, returns 0 (default style).
style_table_insert :: proc(t: ^Style_Table, s: Style) -> Style_Id {
	// Check for existing style (deduplication)
	for i in 0..<int(t.count) {
		if _style_eq(t.entries[i], s) {
			return Style_Id(i)
		}
	}

	// Table full — return default style
	if int(t.count) >= STYLE_TABLE_CAPACITY {
		return 0
	}

	// Insert new style
	id := t.count
	t.entries[id] = s
	t.count += 1
	return Style_Id(id)
}

// style_table_get retrieves a style by ID.
// If the ID is invalid, returns STYLE_DEFAULT.
style_table_get :: proc(t: ^Style_Table, id: Style_Id) -> Style {
	if int(id) >= int(t.count) {
		return STYLE_DEFAULT
	}
	return t.entries[id]
}
