package modals

// Interactive Session Safety Confirmation Dialog (Metal UI Modal Sheet)
// Part of core_chrome: Tier 1 Autonomous Core Primitives.
//
// Invariant: Two-way interactive state transfer between background and killed lists,
// collapsible killed section, and zero GPU dependencies in geometry generation.

import "base:runtime"
import "core:fmt"
import "../draw_list"

Session_Action_Choice :: enum u8 {
	Background,
	Kill,
}

Session_Dialog_Action :: enum u8 {
	None,
	Repaint,
	Cancel,
	Apply,
}

Dialog_Session_Item :: struct {
	session_id:    u32,
	tab_index:     int,
	pane_id:       u32,
	title:         string,
	process_name:  string,
	pid:           int,
	is_active_job: bool,
	status_msg:    string,
	choice:        Session_Action_Choice,
	// Interactive bounding boxes for hit testing
	btn_rect:      [4]f32,
}

Session_Dialog_State :: struct {
	items:           [dynamic]Dialog_Session_Item,
	killed_expanded: bool,
	visible:         bool,
	rect:            [4]f32,
	toggle_rect:     [4]f32,
	cancel_rect:     [4]f32,
	apply_rect:      [4]f32,
	allocator:       runtime.Allocator,
}

session_dialog_init :: proc(dlg: ^Session_Dialog_State, allocator := context.allocator) {
	if dlg == nil do return
	dlg.allocator = allocator
	dlg.items = make([dynamic]Dialog_Session_Item, allocator)
	dlg.killed_expanded = false
	dlg.visible = false
}

session_dialog_destroy :: proc(dlg: ^Session_Dialog_State) {
	if dlg == nil do return
	delete(dlg.items)
	dlg.items = nil
	dlg.visible = false
}

session_dialog_reset :: proc(dlg: ^Session_Dialog_State) {
	if dlg == nil do return
	clear(&dlg.items)
	dlg.killed_expanded = false
	dlg.visible = false
}

session_dialog_emit_draw_list :: proc(
	dlg: ^Session_Dialog_State,
	dl: ^draw_list.Ui_Draw_List,
	screen_w, screen_h: f32,
	scale: f32 = 1.0,
) {
	if dlg == nil || dl == nil || !dlg.visible do return

	s := max(1.0, scale)
	modal_w := min(screen_w - 40.0 * s, 640.0 * s)

	// Calculate required modal height based on active items and expanded state
	bg_count := 0
	kill_count := 0
	for item in dlg.items {
		if item.choice == .Background do bg_count += 1
		else do kill_count += 1
	}

	item_h := 36.0 * s
	total_h := 110.0 * s + f32(bg_count) * item_h
	if kill_count > 0 {
		total_h += 34.0 * s
		if dlg.killed_expanded {
			total_h += f32(kill_count) * item_h
		}
	}
	modal_h := min(screen_h - 40.0 * s, total_h)

	modal_x := (screen_w - modal_w) * 0.5
	modal_y := (screen_h - modal_h) * 0.5
	dlg.rect = {modal_x, modal_y, modal_w, modal_h}

	// 1. Drop shadow & Dialog background
	draw_list.ui_draw_shadow(dl, {modal_x - 10.0 * s, modal_y - 6.0 * s, modal_w + 20.0 * s, modal_h + 20.0 * s}, {0.0, 0.0, 0.0, 0.55}, 16.0 * s)
	draw_list.ui_draw_rounded_rect(dl, dlg.rect, {0.11, 0.12, 0.15, 0.98}, 10.0 * s)
	draw_list.ui_draw_border(dl, dlg.rect, {0.30, 0.35, 0.45, 0.85}, 10.0 * s)

	// 2. Title Header
	header_rect: [4]f32 = {modal_x + 18.0 * s, modal_y + 14.0 * s, modal_w - 36.0 * s, 20.0 * s}
	draw_list.ui_draw_text(dl, header_rect, "Konfirmasi Penutupan Sesi", {0.95, 0.95, 0.98, 1.0})

	cur_y := modal_y + 42.0 * s

	// 3. Section: Background Sessions
	sec_bg_rect: [4]f32 = {modal_x + 18.0 * s, cur_y, modal_w - 36.0 * s, 16.0 * s}
	draw_list.ui_draw_text(dl, sec_bg_rect, "Sesi yang akan TETAP BERJALAN di latar belakang:", {0.55, 0.80, 0.55, 1.0})
	cur_y += 20.0 * s

	for i in 0..<len(dlg.items) {
		item := &dlg.items[i]
		if item.choice != .Background do continue

		row_rect: [4]f32 = {modal_x + 18.0 * s, cur_y, modal_w - 36.0 * s, item_h - 4.0 * s}
		draw_list.ui_draw_rounded_rect(dl, row_rect, {0.15, 0.17, 0.22, 0.90}, 5.0 * s)

		// Label text: "[●] Tab X: process (PID)"
		label := fmt.tprintf("[●] Tab %d: %s (PID %d)", item.tab_index + 1, item.process_name, item.pid)
		draw_list.ui_draw_text(dl, {row_rect[0] + 10.0 * s, row_rect[1] + 7.0 * s, row_rect[2] - 110.0 * s, 16.0 * s}, label, {0.90, 0.92, 0.96, 1.0})

		// [ Kill ] Button
		btn_w: f32 = 64.0 * s
		btn_h: f32 = 24.0 * s
		btn_x := row_rect[0] + row_rect[2] - btn_w - 8.0 * s
		btn_y := row_rect[1] + (row_rect[3] - btn_h) * 0.5
		item.btn_rect = {btn_x, btn_y, btn_w, btn_h}

		draw_list.ui_draw_rounded_rect(dl, item.btn_rect, {0.35, 0.15, 0.18, 0.85}, 4.0 * s)
		draw_list.ui_draw_border(dl, item.btn_rect, {0.70, 0.30, 0.35, 0.90}, 4.0 * s)
		draw_list.ui_draw_text(dl, {btn_x + 14.0 * s, btn_y + 4.0 * s, btn_w, 14.0 * s}, "Kill", {0.95, 0.70, 0.75, 1.0})

		cur_y += item_h
	}

	// 4. Section: Collapsible Killed Sessions
	if kill_count > 0 {
		cur_y += 6.0 * s
		toggle_arrow := "▼ " if dlg.killed_expanded else "▶ "
		toggle_str := fmt.tprintf("%s%d sesi / job akan di-kill (klik untuk melihat)", toggle_arrow, kill_count)
		dlg.toggle_rect = {modal_x + 18.0 * s, cur_y, modal_w - 36.0 * s, 20.0 * s}
		draw_list.ui_draw_text(dl, dlg.toggle_rect, toggle_str, {0.85, 0.55, 0.55, 1.0})
		cur_y += 24.0 * s

		if dlg.killed_expanded {
			for i in 0..<len(dlg.items) {
				item := &dlg.items[i]
				if item.choice != .Kill do continue

				row_rect: [4]f32 = {modal_x + 18.0 * s, cur_y, modal_w - 36.0 * s, item_h - 4.0 * s}
				draw_list.ui_draw_rounded_rect(dl, row_rect, {0.18, 0.14, 0.16, 0.80}, 5.0 * s)

				label := fmt.tprintf("[✕] Tab %d: %s", item.tab_index + 1, item.process_name)
				draw_list.ui_draw_text(dl, {row_rect[0] + 10.0 * s, row_rect[1] + 7.0 * s, row_rect[2] - 180.0 * s, 16.0 * s}, label, {0.75, 0.75, 0.80, 0.85})

				// [ Keep in Background ] Button
				btn_w: f32 = 150.0 * s
				btn_h: f32 = 24.0 * s
				btn_x := row_rect[0] + row_rect[2] - btn_w - 8.0 * s
				btn_y := row_rect[1] + (row_rect[3] - btn_h) * 0.5
				item.btn_rect = {btn_x, btn_y, btn_w, btn_h}

				draw_list.ui_draw_rounded_rect(dl, item.btn_rect, {0.15, 0.28, 0.20, 0.85}, 4.0 * s)
				draw_list.ui_draw_border(dl, item.btn_rect, {0.35, 0.65, 0.45, 0.90}, 4.0 * s)
				draw_list.ui_draw_text(dl, {btn_x + 10.0 * s, btn_y + 4.0 * s, btn_w, 14.0 * s}, "Keep in Background", {0.70, 0.95, 0.75, 1.0})

				cur_y += item_h
			}
		}
	} else {
		dlg.toggle_rect = {}
	}

	// 5. Bottom Buttons (Batal & Terapkan)
	btn_bottom_h := 28.0 * s
	btn_bottom_y := modal_y + modal_h - btn_bottom_h - 14.0 * s

	dlg.cancel_rect = {modal_x + 18.0 * s, btn_bottom_y, 110.0 * s, btn_bottom_h}
	draw_list.ui_draw_rounded_rect(dl, dlg.cancel_rect, {0.20, 0.22, 0.27, 0.90}, 4.0 * s)
	draw_list.ui_draw_border(dl, dlg.cancel_rect, {0.35, 0.38, 0.45, 0.80}, 4.0 * s)
	draw_list.ui_draw_text(dl, {dlg.cancel_rect[0] + 16.0 * s, btn_bottom_y + 6.0 * s, 80.0 * s, 16.0 * s}, "Batal (Esc)", {0.80, 0.82, 0.88, 1.0})

	dlg.apply_rect = {modal_x + modal_w - 180.0 * s - 18.0 * s, btn_bottom_y, 180.0 * s, btn_bottom_h}
	draw_list.ui_draw_rounded_rect(dl, dlg.apply_rect, {0.25, 0.45, 0.80, 0.95}, 4.0 * s)
	draw_list.ui_draw_text(dl, {dlg.apply_rect[0] + 16.0 * s, btn_bottom_y + 6.0 * s, 150.0 * s, 16.0 * s}, "Terapkan & Tutup", {0.98, 0.98, 1.0, 1.0})
}

@(private = "file")
_pt_in_rect :: proc "contextless" (pt: [2]f32, rect: [4]f32) -> bool {
	return pt.x >= rect[0] && pt.x <= rect[0] + rect[2] &&
	       pt.y >= rect[1] && pt.y <= rect[1] + rect[3]
}

session_dialog_handle_click :: proc(dlg: ^Session_Dialog_State, mx, my: f32) -> Session_Dialog_Action {
	if dlg == nil || !dlg.visible do return .None
	pt := [2]f32{mx, my}

	if _pt_in_rect(pt, dlg.cancel_rect) do return .Cancel
	if _pt_in_rect(pt, dlg.apply_rect) do return .Apply

	if dlg.toggle_rect[2] > 0.0 && _pt_in_rect(pt, dlg.toggle_rect) {
		dlg.killed_expanded = !dlg.killed_expanded
		return .Repaint
	}

	for i in 0..<len(dlg.items) {
		item := &dlg.items[i]
		if item.btn_rect[2] > 0.0 && _pt_in_rect(pt, item.btn_rect) {
			if item.choice == .Background {
				item.choice = .Kill
			} else {
				item.choice = .Background
			}
			return .Repaint
		}
	}
	return .None
}
