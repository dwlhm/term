package termgrid

// Style_Id is an index into the style table.
Style_Id :: u16

// Theme_256_Policy selects how a theme extends its ANSI16 palette.
Theme_256_Policy :: enum u8 {
	Xterm_Cube_Grayscale,
}

// Theme contains terminal colors owned by a style table.
Theme :: struct {
	name:                 string,
	foreground:           u32,
	background:           u32,
	selection_foreground: u32,
	selection_background: u32,
	ansi16:               [16]u32,
	palette_256_policy:   Theme_256_Policy,
}

// Catppuccin Mocha palette tokens from the official palette.
CATPPUCCIN_MOCHA_ROSEWATER :: u32(0xFFF5E0DC)
CATPPUCCIN_MOCHA_PINK      :: u32(0xFFF5C2E7)
CATPPUCCIN_MOCHA_RED       :: u32(0xFFF38BA8)
CATPPUCCIN_MOCHA_YELLOW    :: u32(0xFFF9E2AF)
CATPPUCCIN_MOCHA_GREEN     :: u32(0xFFA6E3A1)
CATPPUCCIN_MOCHA_TEAL      :: u32(0xFF94E2D5)
CATPPUCCIN_MOCHA_BLUE      :: u32(0xFF89B4FA)
CATPPUCCIN_MOCHA_TEXT      :: u32(0xFFCDD6F4)
CATPPUCCIN_MOCHA_SUBTEXT1  :: u32(0xFFBAC2DE)
CATPPUCCIN_MOCHA_SUBTEXT0  :: u32(0xFFA6ADC8)
CATPPUCCIN_MOCHA_SURFACE2  :: u32(0xFF585B70)
CATPPUCCIN_MOCHA_SURFACE1  :: u32(0xFF45475A)
CATPPUCCIN_MOCHA_BASE      :: u32(0xFF1E1E2E)

// THEME_CATPPUCCIN_MOCHA is the construction-time default theme.
THEME_CATPPUCCIN_MOCHA :: Theme{
	name                 = "Catppuccin Mocha",
	foreground           = CATPPUCCIN_MOCHA_TEXT,
	background           = CATPPUCCIN_MOCHA_BASE,
	selection_foreground = CATPPUCCIN_MOCHA_BASE,
	selection_background = CATPPUCCIN_MOCHA_SURFACE2,
	ansi16 = [16]u32{
		CATPPUCCIN_MOCHA_SURFACE1,
		CATPPUCCIN_MOCHA_RED,
		CATPPUCCIN_MOCHA_GREEN,
		CATPPUCCIN_MOCHA_YELLOW,
		CATPPUCCIN_MOCHA_BLUE,
		CATPPUCCIN_MOCHA_PINK,
		CATPPUCCIN_MOCHA_TEAL,
		CATPPUCCIN_MOCHA_SUBTEXT1,
		CATPPUCCIN_MOCHA_SURFACE2,
		CATPPUCCIN_MOCHA_RED,
		CATPPUCCIN_MOCHA_GREEN,
		CATPPUCCIN_MOCHA_YELLOW,
		CATPPUCCIN_MOCHA_BLUE,
		CATPPUCCIN_MOCHA_PINK,
		CATPPUCCIN_MOCHA_TEAL,
		CATPPUCCIN_MOCHA_SUBTEXT0,
	},
	palette_256_policy = .Xterm_Cube_Grayscale,
}

// THEME_ANSI16_COUNT is the size of the ANSI16 palette.
THEME_ANSI16_COUNT :: 16

// THEME_256_COUNT is the size of the indexed terminal palette.
THEME_256_COUNT :: 256

// THEME_256_CUBE_START is the first canonical xterm cube index.
THEME_256_CUBE_START :: THEME_ANSI16_COUNT

// THEME_256_CUBE_END is the exclusive end of the canonical xterm cube.
THEME_256_CUBE_END :: 232

// THEME_256_GRAYSCALE_START is the first canonical xterm grayscale index.
THEME_256_GRAYSCALE_START :: THEME_256_CUBE_END

// THEME_XTERM_CUBE_LEVELS are the canonical 6x6x6 xterm intensities.
THEME_XTERM_CUBE_LEVELS :: [6]u32{0, 95, 135, 175, 215, 255}

// THEME_XTERM_CUBE_AXIS is the number of levels on one cube axis.
THEME_XTERM_CUBE_AXIS :: 6

// THEME_XTERM_CUBE_PLANE is the number of colors in one cube plane.
THEME_XTERM_CUBE_PLANE :: THEME_XTERM_CUBE_AXIS * THEME_XTERM_CUBE_AXIS

// THEME_XTERM_GRAYSCALE_BASE is the first canonical xterm gray intensity.
THEME_XTERM_GRAYSCALE_BASE :: 8

// THEME_XTERM_GRAYSCALE_STEP is the canonical xterm gray increment.
THEME_XTERM_GRAYSCALE_STEP :: 10

// THEME_ARGB_OPAQUE is the alpha mask for opaque terminal colors.
THEME_ARGB_OPAQUE :: u32(0xFF000000)

// Style represents the visual attributes of a cell.
// Size: 16 bytes
Style :: struct {
	fg:        u32, // foreground color (ARGB or palette index)
	bg:        u32, // background color
	underline: u32, // underline color
	flags:     u16, // bitfield: bold, italic, underline_style, etc.
}

// STYLE_DEFAULT is the default style derived from the default theme.
STYLE_DEFAULT :: Style{
	fg        = THEME_CATPPUCCIN_MOCHA.foreground,
	bg        = THEME_CATPPUCCIN_MOCHA.background,
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
STYLE_FLAG_DIM       :: u16(1 << 5)

// STYLE_TABLE_CAPACITY is the maximum number of styles in the table.
STYLE_TABLE_CAPACITY :: 1024

// Style_Table is a deduplication table for styles.
// Capacity: 1024 entries (configurable via STYLE_TABLE_CAPACITY).
Style_Table :: struct {
	entries: [STYLE_TABLE_CAPACITY]Style,
	count:   u16,
	theme:   Theme,
}

// style_table_init initializes a style table with a theme default at index 0.
style_table_init :: proc(t: ^Style_Table, theme: Theme = THEME_CATPPUCCIN_MOCHA) {
	t.theme = theme
	t.entries[0] = style_table_default(t)
	t.count = 1
}

// style_table_default returns the default style for the active theme.
style_table_default :: proc(t: ^Style_Table) -> Style {
	return Style{
		fg        = t.theme.foreground,
		bg        = t.theme.background,
		underline = 0,
		flags     = 0,
	}
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
// If the ID is invalid, returns the active theme default.
style_table_get :: proc(t: ^Style_Table, id: Style_Id) -> Style {
	if int(id) >= int(t.count) {
		return style_table_default(t)
	}
	return t.entries[id]
}

// _theme_cube_level maps a 6x6x6 cube component to its xterm intensity.
_theme_cube_level :: proc(v: int) -> u32 {
	if v < 0 || v >= len(THEME_XTERM_CUBE_LEVELS) {
		return 0
	}
	levels := THEME_XTERM_CUBE_LEVELS
	return levels[v]
}

// theme_palette_256 resolves an indexed color through a theme.
// ANSI16 uses the theme; the cube and grayscale use canonical xterm values.
// Invalid indices return the theme foreground.
theme_palette_256 :: proc(theme: Theme, idx: int) -> u32 {
	if idx < 0 || idx >= THEME_256_COUNT {
		return theme.foreground
	}
	if idx < THEME_ANSI16_COUNT {
		return theme.ansi16[idx]
	}

	switch theme.palette_256_policy {
	case .Xterm_Cube_Grayscale:
		if idx < THEME_256_CUBE_END {
			i := idx - THEME_256_CUBE_START
			r := _theme_cube_level(i / THEME_XTERM_CUBE_PLANE)
			g := _theme_cube_level((i % THEME_XTERM_CUBE_PLANE) / THEME_XTERM_CUBE_AXIS)
			b := _theme_cube_level(i % THEME_XTERM_CUBE_AXIS)
			return THEME_ARGB_OPAQUE | (r << 16) | (g << 8) | b
		}
		g := u32(THEME_XTERM_GRAYSCALE_BASE + THEME_XTERM_GRAYSCALE_STEP * (idx - THEME_256_GRAYSCALE_START))
		return THEME_ARGB_OPAQUE | (g << 16) | (g << 8) | g
	}

	return theme.foreground
}
