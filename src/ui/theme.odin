package ui

// UI_Spacing defines the spacing scale in logical pixels.
UI_Spacing :: struct {
	xs: f32,
	sm: f32,
	md: f32,
	lg: f32,
}

// UI_Radii defines the corner radius scale in logical pixels.
UI_Radii :: struct {
	tab:  f32,
	card: f32,
	pill: f32,
}

// UI_Motion defines interaction transition durations in milliseconds.
UI_Motion :: struct {
	hover_ms:  f32,
	active_ms: f32,
}

// UI_Type defines typography sizes in logical pixels.
UI_Type :: struct {
	title_px: f32,
}

// UI_Theme encapsulates color tokens used for rendering chrome surfaces and badges.
UI_Theme :: struct {
	surface_base:   [4]f32,
	surface_bar:    [4]f32,
	surface_card:   [4]f32,
	surface_hover:  [4]f32,
	surface_active: [4]f32,
	border_subtle:  [4]f32,
	accent_primary: [4]f32,
	text_primary:   [4]f32,
	text_muted:     [4]f32,
	text_faint:     [4]f32,
	status_success: [4]f32,
	status_danger:  [4]f32,
	spacing:        UI_Spacing,
	radii:          UI_Radii,
	motion:         UI_Motion,
	typ:            UI_Type,
}

TAB_BAR_HEIGHT: f32 : 28.0
SEARCH_BAR_W:   f32 : 380.0
SEARCH_BAR_H:   f32 : 36.0
TAB_MIN_W:      f32 : 110.0
TAB_MAX_W:      f32 : 200.0

// theme_catppuccin_mocha returns the standard Catppuccin Mocha design tokens.
theme_catppuccin_mocha :: proc() -> UI_Theme {
	return UI_Theme{
		surface_base   = {30.0 / 255.0, 30.0 / 255.0, 46.0 / 255.0, 1.0},    // #1e1e2e
		surface_bar    = {24.0 / 255.0, 24.0 / 255.0, 37.0 / 255.0, 1.0},    // #181825
		surface_card   = {49.0 / 255.0, 50.0 / 255.0, 68.0 / 255.0, 1.0},    // #313244
		surface_hover  = {69.0 / 255.0, 71.0 / 255.0, 90.0 / 255.0, 1.0},    // #45475a
		surface_active = {88.0 / 255.0, 91.0 / 255.0, 112.0 / 255.0, 1.0},   // #585b70
		border_subtle  = {69.0 / 255.0, 71.0 / 255.0, 90.0 / 255.0, 0.4},    // rgba(69, 71, 90, 0.4)
		accent_primary = {203.0 / 255.0, 166.0 / 255.0, 247.0 / 255.0, 1.0}, // #cba6f7
		text_primary   = {205.0 / 255.0, 214.0 / 255.0, 244.0 / 255.0, 1.0}, // #cdd6f4
		text_muted     = {166.0 / 255.0, 173.0 / 255.0, 200.0 / 255.0, 1.0}, // #a6adc8
		text_faint     = {108.0 / 255.0, 112.0 / 255.0, 134.0 / 255.0, 1.0}, // #6c7086 overlay0
		status_success = {166.0 / 255.0, 227.0 / 255.0, 161.0 / 255.0, 1.0}, // #a6e3a1
		status_danger  = {243.0 / 255.0, 139.0 / 255.0, 168.0 / 255.0, 1.0}, // #f38ba8
		spacing        = {xs = 2.0, sm = 4.0, md = 8.0, lg = 12.0},
		radii          = {tab = 4.0, card = 6.0, pill = 4.0},
		motion         = {hover_ms = 90.0, active_ms = 160.0},
		typ            = {title_px = 12.0},
	}
}
