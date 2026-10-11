package draw_list

// Pure Declarative UI Geometry Engine - Draw List Preview Fixtures.
// Part of core_chrome: Tier 1 Autonomous Core Primitives.
//
// Invariant: ZERO GPU Dependencies.

// preview_draw_list_sample emits a canonical set of all primitives:
// Rect, Rounded_Rect, Border, Text_Run, Shadow, both with and without clipping.
preview_draw_list_sample :: proc(dl: ^Ui_Draw_List) {
	if dl == nil do return

	clip: [4]f32 = {20.0, 20.0, 300.0, 300.0}

	// 1. Rect (unclipped and clipped)
	ui_draw_rect(dl, {30.0, 30.0, 120.0, 60.0}, {0.20, 0.40, 0.80, 1.0})
	ui_draw_rect(dl, {10.0, 10.0, 80.0, 80.0}, {0.80, 0.20, 0.20, 0.8}, clip)

	// 2. Rounded_Rect (unclipped and clipped)
	ui_draw_rounded_rect(dl, {60.0, 100.0, 140.0, 70.0}, {0.25, 0.70, 0.35, 1.0}, 8.0)
	ui_draw_rounded_rect(dl, {15.0, 90.0, 90.0, 90.0}, {0.85, 0.65, 0.15, 0.9}, 12.0, clip)

	// 3. Border (unclipped and clipped)
	ui_draw_border(dl, {50.0, 180.0, 180.0, 50.0}, {0.90, 0.90, 0.90, 1.0}, 6.0)
	ui_draw_border(dl, {10.0, 170.0, 100.0, 70.0}, {0.30, 0.80, 0.90, 1.0}, 4.0, clip)

	// 4. Text_Run (unclipped and clipped)
	ui_draw_text(dl, {70.0, 240.0, 200.0, 20.0}, "Terminal Core Sample", {0.95, 0.95, 0.95, 1.0})
	ui_draw_text(dl, {10.0, 230.0, 150.0, 20.0}, "Clipped Text Overflow Running Out", {0.70, 0.75, 0.80, 1.0}, clip)

	// 5. Shadow (unclipped and clipped)
	ui_draw_shadow(dl, {70.0, 270.0, 160.0, 40.0}, {0.0, 0.0, 0.0, 0.5}, 10.0)
	ui_draw_shadow(dl, {15.0, 260.0, 100.0, 50.0}, {0.0, 0.0, 0.0, 0.3}, 8.0, clip)
}
