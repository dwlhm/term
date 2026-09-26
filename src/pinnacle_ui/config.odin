package pinnacle_ui

import "core:math"

UI_Material :: struct {
	base_color:      [4]f32,
	blur_radius:     f32,
	index_of_refrac: f32,
	border_radius:   [4]f32,
	border_color:    [4]f32,
	border_width:    f32,
}

Power_Preference :: enum {
	LowPower,
	Balanced,
	HighPerformance,
}

Renderer_Config :: struct {
	max_ui_elements:       u32,
	max_materials:         u32,
	max_text_glyphs:       u32,

	power_preference:      Power_Preference,
	enable_culling:        bool,
	compute_workgroup_size: u32,

	msdf_pixel_range:      f32,
	enable_3d_spatial:     bool,
	default_font_path:     string,
	fallback_font_paths:   []string,
	
	theme_materials:       []UI_Material,
}

default_config :: proc() -> Renderer_Config {
	return Renderer_Config{
		max_ui_elements        = 500_000,
		max_materials          = 256,
		max_text_glyphs        = 1_000_000,
		power_preference       = .LowPower,
		enable_culling         = true,
		compute_workgroup_size = 256,
		msdf_pixel_range       = 4.0,
		enable_3d_spatial      = false,
	}
}
