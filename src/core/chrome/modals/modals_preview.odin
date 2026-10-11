package modals

// Pure Declarative UI Geometry Engine - Modals Preview Fixtures.
// Part of core_chrome: Tier 1 Autonomous Core Primitives.
//
// Invariant: ZERO GPU Dependencies.

import "core:strings"
import "../draw_list"

// preview_modal_normal emits a standard command palette dialog (600x350) centered in viewport.
preview_modal_normal :: proc(dl: ^draw_list.Ui_Draw_List, viewport: [4]f32) {
	if dl == nil do return

	dialog_w: f32 = 600.0
	dialog_h: f32 = 350.0
	dialog_x := viewport[0] + (viewport[2] - dialog_w) * 0.5
	dialog_y := viewport[1] + (viewport[3] - dialog_h) * 0.5

	modal := Chrome_Modal{
		title       = "Command Palette",
		query       = "git status",
		match_count = 8,
		rect        = {dialog_x, dialog_y, dialog_w, dialog_h},
		visible     = true,
	}

	modal_emit_draw_list(&modal, dl)
}

// preview_modal_extreme emits modal scenarios: 10,000-character query, 0x0 size modal, and modal larger than viewport.
preview_modal_extreme :: proc(dl: ^draw_list.Ui_Draw_List, viewport: [4]f32) {
	if dl == nil do return

	// 1. Modal with 10,000-character query
	b := strings.builder_make(context.temp_allocator)
	for _ in 0..<1000 {
		strings.write_string(&b, "0123456789")
	}
	extreme_query := strings.to_string(b)

	m_long := Chrome_Modal{
		title       = "Overflow Query Palette",
		query       = extreme_query,
		match_count = 1,
		rect        = {viewport[0] + 50.0, viewport[1] + 50.0, 500.0, 300.0},
		visible     = true,
	}
	modal_emit_draw_list(&m_long, dl)

	// 2. 0x0 size modal
	m_zero := Chrome_Modal{
		title       = "Zero Bounds",
		query       = "",
		match_count = 0,
		rect        = {viewport[0], viewport[1], 0.0, 0.0},
		visible     = true,
	}
	modal_emit_draw_list(&m_zero, dl)

	// 3. Modal larger than viewport
	m_huge := Chrome_Modal{
		title       = "Huge Modal Overrunning Viewport",
		query       = "all",
		match_count = 9999,
		rect        = {viewport[0] - 100.0, viewport[1] - 100.0, viewport[2] + 200.0, viewport[3] + 200.0},
		visible     = true,
	}
	modal_emit_draw_list(&m_huge, dl)
}
