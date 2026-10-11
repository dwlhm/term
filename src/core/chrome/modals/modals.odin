package modals

// Pure Declarative UI Geometry Engine - Modals & Overlays.
// Part of core_chrome: Tier 1 Autonomous Core Primitives.
//
// Invariant: ZERO GPU Dependencies.
// Defines state and geometry emission for Search Overlay, Command Palette, etc.

import "core:fmt"
import "../draw_list"

// Chrome_Modal holds state and bounds for search dialogs or command palettes.
Chrome_Modal :: struct {
	title:          string,
	query:          string,
	match_count:    int,
	rect:           [4]f32,
	visible:        bool,
	// match_text_buf is the backing storage for the match-count Text_Run.
	// The emitted Text_Run string references it and is valid until the next
	// emit on the same modal, or until the modal is destroyed/moved.
	match_text_buf: [32]u8,
}

// modal_emit_draw_list emits the modal dialog hierarchy into dl.
modal_emit_draw_list :: proc(m: ^Chrome_Modal, dl: ^draw_list.Ui_Draw_List) {
	if m == nil || dl == nil || !m.visible do return

	// Drop shadow
	shadow_rect: [4]f32 = {m.rect[0] - 8.0, m.rect[1] - 4.0, m.rect[2] + 16.0, m.rect[3] + 16.0}
	draw_list.ui_draw_shadow(dl, shadow_rect, {0.0, 0.0, 0.0, 0.45}, 12.0)

	// Background body
	draw_list.ui_draw_rounded_rect(dl, m.rect, {0.14, 0.15, 0.18, 0.98}, 8.0)

	// Outline border
	draw_list.ui_draw_border(dl, m.rect, {0.28, 0.30, 0.34, 1.0}, 8.0)

	// Title
	title_rect: [4]f32 = {m.rect[0] + 16.0, m.rect[1] + 12.0, m.rect[2] - 32.0, 18.0}
	draw_list.ui_draw_text(dl, title_rect, m.title, {0.85, 0.88, 0.92, 1.0})

	// Input box background
	input_rect: [4]f32 = {m.rect[0] + 16.0, m.rect[1] + 36.0, m.rect[2] - 32.0, 28.0}
	draw_list.ui_draw_rounded_rect(dl, input_rect, {0.10, 0.11, 0.13, 1.0}, 4.0)
	draw_list.ui_draw_border(dl, input_rect, {0.35, 0.55, 0.85, 1.0}, 4.0)

	// Input query text
	query_str := m.query if len(m.query) > 0 else "Type a command..."
	query_col: [4]f32 = {0.95, 0.95, 0.95, 1.0} if len(m.query) > 0 else {0.45, 0.48, 0.52, 1.0}
	input_text_rect: [4]f32 = {input_rect[0] + 8.0, input_rect[1] + 6.0, input_rect[2] - 16.0, 16.0}
	draw_list.ui_draw_text(dl, input_text_rect, query_str, query_col)

	// Match count indicator
	if m.match_count > 0 {
		info := fmt.bprintf(m.match_text_buf[:], "%d matches", m.match_count)
		info_rect: [4]f32 = {m.rect[0] + 16.0, m.rect[1] + m.rect[3] - 24.0, m.rect[2] - 32.0, 16.0}
		draw_list.ui_draw_text(dl, info_rect, info, {0.55, 0.60, 0.65, 1.0})
	}
}
