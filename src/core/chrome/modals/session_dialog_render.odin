package modals

// Declarative UI Geometry Emission for Session Safety Confirmation Dialog.
// Part of core_chrome: Tier 1 Autonomous Core Primitives.
//
// Invariant: Steady-state zero heap allocations. Zero GPU dependencies in geometry generation.
// Dual-section design: Background active section + Clickable disclosure bar for killed section.

import "core:fmt"
import "../draw_list"

session_dialog_emit_draw_list :: proc(
	dlg: ^Session_Dialog_State,
	dl: ^draw_list.Ui_Draw_List,
	screen_w, screen_h: f32,
	scale: f32 = 1.0,
) {
	if dlg == nil || dl == nil || !dlg.visible do return

	s := max(1.0, scale)
	card_h := 40.0 * s
	card_gap := 6.0 * s

	modal_x, modal_y, modal_w, modal_h, bg_count, kill_count := _compute_dialog_geometry(
		dlg, screen_w, screen_h, s, card_h, card_gap,
	)
	dlg.rect = {modal_x, modal_y, modal_w, modal_h}

	// 1. Solid backdrop scrim (no detached shadow, no border)
	draw_list.ui_draw_rect(dl, {0, 0, screen_w, screen_h}, {0.0, 0.0, 0.0, 0.60})

	// 2. Solid modal container (borderless)
	draw_list.ui_draw_rounded_rect(dl, dlg.rect, {0.09, 0.10, 0.13, 1.0}, 10.0 * s)

	// 3. Header
	cur_y := _emit_header(dl, modal_x, modal_y, modal_w, s)

	// 4. Section 1: Background sessions
	cur_y = _emit_background_section(dlg, dl, modal_x, cur_y, modal_w, s, card_h, card_gap, bg_count)

	// 5. Section 2: Clickable disclosure bar & killed items
	cur_y = _emit_clickable_killed_section(dlg, dl, modal_x, cur_y, modal_w, s, card_h, card_gap, kill_count)

	// 6. Action buttons with physical keyboard keycaps
	_emit_footer_buttons(dlg, dl, modal_x, modal_y, modal_w, modal_h, s)
}

@(private = "file")
_compute_dialog_geometry :: proc(
	dlg: ^Session_Dialog_State,
	screen_w, screen_h, s, card_h, card_gap: f32,
) -> (modal_x, modal_y, modal_w, modal_h: f32, bg_count, kill_count: int) {
	modal_w = min(screen_w - 48.0 * s, 560.0 * s)
	for item in dlg.items {
		if item.choice == .Background do bg_count += 1
		else do kill_count += 1
	}

	header_h := 72.0 * s
	sec_bg_h := 24.0 * s + (f32(bg_count) * (card_h + card_gap) if bg_count > 0 else 24.0 * s)
	sec_kill_h := f32(0)
	if kill_count > 0 {
		sec_kill_h = 42.0 * s
		if dlg.killed_expanded {
			sec_kill_h += f32(kill_count) * (card_h + card_gap)
		}
	}
	footer_h := 76.0 * s

	total_h := header_h + sec_bg_h + sec_kill_h + footer_h
	modal_h = min(screen_h - 48.0 * s, total_h)
	modal_x = (screen_w - modal_w) * 0.5
	modal_y = (screen_h - modal_h) * 0.5
	return
}

@(private = "file")
_emit_header :: proc(dl: ^draw_list.Ui_Draw_List, modal_x, modal_y, modal_w, s: f32) -> f32 {
	t_rect := [4]f32{modal_x + 24.0 * s, modal_y + 20.0 * s, modal_w - 48.0 * s, 20.0 * s}
	draw_list.ui_draw_text(dl, t_rect, "Konfirmasi Penutupan Sesi", {0.95, 0.96, 0.98, 1.0})

	s_rect := [4]f32{modal_x + 24.0 * s, modal_y + 44.0 * s, modal_w - 48.0 * s, 14.0 * s}
	draw_list.ui_draw_text(dl, s_rect, "Tentukan aksi sebelum menutup jendela terminal.", {0.52, 0.56, 0.64, 1.0})
	return modal_y + 72.0 * s
}

@(private = "file")
_emit_background_section :: proc(
	dlg: ^Session_Dialog_State,
	dl: ^draw_list.Ui_Draw_List,
	modal_x, start_y, modal_w, s, card_h, card_gap: f32,
	bg_count: int,
) -> f32 {
	cur_y := start_y
	sec_rect := [4]f32{modal_x + 24.0 * s, cur_y, modal_w - 48.0 * s, 15.0 * s}
	draw_list.ui_draw_text(dl, sec_rect, "Sesi yang akan tetap berjalan di latar belakang:", {0.55, 0.82, 0.68, 1.0})
	cur_y += 20.0 * s

	if bg_count == 0 {
		draw_list.ui_draw_text(dl, {modal_x + 24.0 * s, cur_y, modal_w - 48.0 * s, 16.0 * s}, "(Tidak ada proses yang berjalan di latar belakang)", {0.45, 0.48, 0.55, 0.8})
		return cur_y + 24.0 * s
	}

	for i in 0..<len(dlg.items) {
		item := &dlg.items[i]
		if item.choice != .Background do continue

		row := [4]f32{modal_x + 24.0 * s, cur_y, modal_w - 48.0 * s, card_h}
		draw_list.ui_draw_rounded_rect(dl, row, {0.13, 0.15, 0.19, 0.90}, 6.0 * s)

		// 1. [ Hentikan ] button (92x28px hit target, generous text box)
		btn_w, btn_h := 92.0 * s, 28.0 * s
		btn_x := row[0] + row[2] - btn_w - 8.0 * s
		btn_y := row[1] + (row[3] - btn_h) * 0.5
		item.btn_rect = {btn_x, btn_y, btn_w, btn_h}
		draw_list.ui_draw_rounded_rect(dl, item.btn_rect, {0.26, 0.12, 0.15, 1.0}, 5.0 * s)
		draw_list.ui_draw_text(dl, {btn_x + 8.0 * s, btn_y + 7.0 * s, btn_w - 16.0 * s, 14.0 * s}, "Hentikan", {0.95, 0.65, 0.70, 1.0})

		// 2. PID fixed column
		pid_w := 64.0 * s
		pid_x := btn_x - pid_w - 10.0 * s
		pid_str := fmt.tprintf("PID %d", item.pid)
		draw_list.ui_draw_text(dl, {pid_x, row[1] + 12.0 * s, pid_w, 15.0 * s}, pid_str, {0.50, 0.54, 0.62, 1.0})

		// 3. Tab prefix: Tab X ·
		tab_w := 48.0 * s
		tab_str := fmt.tprintf("Tab %d  ·", item.tab_index + 1)
		draw_list.ui_draw_text(dl, {row[0] + 14.0 * s, row[1] + 12.0 * s, tab_w, 15.0 * s}, tab_str, {0.45, 0.65, 0.90, 1.0})

		// 4. Clean process name (memory-safe via temp_allocator)
		name_x := row[0] + 14.0 * s + tab_w + 4.0 * s
		name_w := max(40.0 * s, pid_x - name_x - 8.0 * s)
		max_chars := max(6, int(name_w / (7.2 * s)))

		proc_label := _format_process_name(item, max_chars)
		draw_list.ui_draw_text(dl, {name_x, row[1] + 12.0 * s, name_w, 15.0 * s}, proc_label, {0.92, 0.94, 0.98, 1.0})

		cur_y += card_h + card_gap
	}
	return cur_y
}

@(private = "file")
_emit_clickable_killed_section :: proc(
	dlg: ^Session_Dialog_State,
	dl: ^draw_list.Ui_Draw_List,
	modal_x, start_y, modal_w, s, card_h, card_gap: f32,
	kill_count: int,
) -> f32 {
	if kill_count == 0 {
		dlg.toggle_rect = {}
		return start_y
	}

	cur_y := start_y + 4.0 * s

	// Clickable Disclosure Bar (Clearly interactive card container with chevron & button)
	bar_h := 32.0 * s
	dlg.toggle_rect = {modal_x + 24.0 * s, cur_y, modal_w - 48.0 * s, bar_h}
	draw_list.ui_draw_rounded_rect(dl, dlg.toggle_rect, {0.16, 0.13, 0.15, 0.90}, 6.0 * s)

	pill_w, pill_h := 115.0 * s, 22.0 * s
	pill_x := dlg.toggle_rect[0] + dlg.toggle_rect[2] - pill_w - 6.0 * s
	pill_y := cur_y + (bar_h - pill_h) * 0.5
	draw_list.ui_draw_rounded_rect(dl, {pill_x, pill_y, pill_w, pill_h}, {0.24, 0.18, 0.22, 1.0}, 4.0 * s)
	toggle_action_str := "Sembunyikan" if dlg.killed_expanded else "Tampilkan"
	draw_list.ui_draw_text(dl, {pill_x + 8.0 * s, pill_y + 4.0 * s, pill_w - 16.0 * s, 14.0 * s}, toggle_action_str, {0.95, 0.78, 0.82, 1.0})

	chevron := "v " if dlg.killed_expanded else "> "
	bar_text := fmt.tprintf("%s%d proses akan dihentikan saat jendela ditutup", chevron, kill_count)
	draw_list.ui_draw_text(dl, {dlg.toggle_rect[0] + 12.0 * s, cur_y + 9.0 * s, dlg.toggle_rect[2] - pill_w - 24.0 * s, 14.0 * s}, bar_text, {0.90, 0.60, 0.64, 1.0})

	cur_y += bar_h + 8.0 * s

	if !dlg.killed_expanded do return cur_y

	// Render killed items list under the disclosure bar
	for i in 0..<len(dlg.items) {
		item := &dlg.items[i]
		if item.choice != .Kill do continue

		row := [4]f32{modal_x + 24.0 * s, cur_y, modal_w - 48.0 * s, card_h}
		draw_list.ui_draw_rounded_rect(dl, row, {0.13, 0.11, 0.13, 0.75}, 6.0 * s)

		// 1. [ Urungkan ] button (92x28px hit target, generous text box)
		btn_w, btn_h := 92.0 * s, 28.0 * s
		btn_x := row[0] + row[2] - btn_w - 8.0 * s
		btn_y := row[1] + (row[3] - btn_h) * 0.5
		item.btn_rect = {btn_x, btn_y, btn_w, btn_h}
		draw_list.ui_draw_rounded_rect(dl, item.btn_rect, {0.18, 0.20, 0.26, 1.0}, 5.0 * s)
		draw_list.ui_draw_text(dl, {btn_x + 8.0 * s, btn_y + 7.0 * s, btn_w - 16.0 * s, 14.0 * s}, "Urungkan", {0.72, 0.78, 0.88, 1.0})

		// 2. PID fixed column
		pid_w := 64.0 * s
		pid_x := btn_x - pid_w - 10.0 * s
		pid_str := fmt.tprintf("PID %d", item.pid)
		draw_list.ui_draw_text(dl, {pid_x, row[1] + 12.0 * s, pid_w, 15.0 * s}, pid_str, {0.48, 0.44, 0.50, 1.0})

		// 3. Tab prefix: Tab X ·
		tab_w := 48.0 * s
		tab_str := fmt.tprintf("Tab %d  ·", item.tab_index + 1)
		draw_list.ui_draw_text(dl, {row[0] + 14.0 * s, row[1] + 12.0 * s, tab_w, 15.0 * s}, tab_str, {0.50, 0.54, 0.65, 1.0})

		// 4. Process name with (akan dihentikan)
		name_x := row[0] + 14.0 * s + tab_w + 4.0 * s
		name_w := max(40.0 * s, pid_x - name_x - 8.0 * s)
		max_chars := max(6, int(name_w / (7.2 * s)))

		proc_label := _format_process_name(item, max_chars)
		draw_list.ui_draw_text(dl, {name_x, row[1] + 12.0 * s, name_w, 15.0 * s}, proc_label, {0.75, 0.52, 0.55, 0.95})

		cur_y += card_h + card_gap
	}
	return cur_y
}

@(private = "file")
_format_process_name :: proc(item: ^Dialog_Session_Item, max_chars: int) -> string {
	raw := item.process_name
	if len(raw) == 0 {
		raw = item.title if len(item.title) > 0 else "shell"
	}
	if len(raw) > max_chars {
		return fmt.tprintf("%s…", raw[:max(1, max_chars - 1)])
	}
	return raw
}

@(private = "file")
_emit_footer_buttons :: proc(
	dlg: ^Session_Dialog_State,
	dl: ^draw_list.Ui_Draw_List,
	modal_x, modal_y, modal_w, modal_h, s: f32,
) {
	btn_h := 32.0 * s
	btn_y := modal_y + modal_h - btn_h - 20.0 * s

	// 1. Cancel button with keycap [esc]
	dlg.cancel_rect = {modal_x + 24.0 * s, btn_y, 104.0 * s, btn_h}
	draw_list.ui_draw_rounded_rect(dl, dlg.cancel_rect, {0.16, 0.18, 0.23, 1.0}, 6.0 * s)
	draw_list.ui_draw_text(dl, {dlg.cancel_rect[0] + 14.0 * s, btn_y + 8.0 * s, 42.0 * s, 16.0 * s}, "Batal", {0.85, 0.88, 0.92, 1.0})

	esc_w, esc_h := 34.0 * s, 18.0 * s
	esc_x := dlg.cancel_rect[0] + dlg.cancel_rect[2] - esc_w - 8.0 * s
	esc_y := btn_y + (btn_h - esc_h) * 0.5
	draw_list.ui_draw_rounded_rect(dl, {esc_x, esc_y, esc_w, esc_h}, {0.24, 0.26, 0.32, 1.0}, 3.0 * s)
	draw_list.ui_draw_text(dl, {esc_x + 7.0 * s, esc_y + 3.0 * s, esc_w - 14.0 * s, 12.0 * s}, "esc", {0.70, 0.74, 0.82, 1.0})

	// 2. Apply button with keycap [↵]
	apply_w := 186.0 * s
	dlg.apply_rect = {modal_x + modal_w - apply_w - 24.0 * s, btn_y, apply_w, btn_h}
	draw_list.ui_draw_rounded_rect(dl, dlg.apply_rect, {0.18, 0.42, 0.85, 1.0}, 6.0 * s)
	draw_list.ui_draw_text(dl, {dlg.apply_rect[0] + 14.0 * s, btn_y + 8.0 * s, 126.0 * s, 16.0 * s}, "Terapkan & Tutup", {0.98, 0.98, 1.0, 1.0})

	ret_w, ret_h := 24.0 * s, 18.0 * s
	ret_x := dlg.apply_rect[0] + dlg.apply_rect[2] - ret_w - 8.0 * s
	ret_y := btn_y + (btn_h - ret_h) * 0.5
	draw_list.ui_draw_rounded_rect(dl, {ret_x, ret_y, ret_w, ret_h}, {0.12, 0.30, 0.65, 1.0}, 3.0 * s)
	draw_list.ui_draw_text(dl, {ret_x + 7.0 * s, ret_y + 2.5 * s, ret_w - 14.0 * s, 12.0 * s}, "↵", {0.92, 0.95, 1.0, 1.0})
}
