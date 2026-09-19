package ui

// UI_Style defines the presentation mode for UI elements.
UI_Style :: enum u8 {
	Modern_Flat    = 0,
	Terminal_TUI   = 1,
	Modern_Rounded = 2,
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
	status_success: [4]f32,
	status_danger:  [4]f32,
}

TAB_BAR_HEIGHT: f32 : 32.0
SEARCH_BAR_W:   f32 : 380.0
SEARCH_BAR_H:   f32 : 36.0
TAB_MIN_W:      f32 : 120.0
TAB_MAX_W:      f32 : 220.0

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
		status_success = {166.0 / 255.0, 227.0 / 255.0, 161.0 / 255.0, 1.0}, // #a6e3a1
		status_danger  = {243.0 / 255.0, 139.0 / 255.0, 168.0 / 255.0, 1.0}, // #f38ba8
	}
}
