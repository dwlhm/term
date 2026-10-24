package main

// Term Headless E2E Test Driver: Core Driver Operations (<250 lines)
// Part of Tier 4 Harnesses & Automation (src/cmd/term_driver/*).

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"

import tabs_feat "../../features/tabs"
import mux_feat "../../features/multiplexer"
import inter_feat "../../features/interaction"
import sess_feat "../../features/session"
import chrome_splits "../../core/chrome/splits"
import chrome_dl "../../core/chrome/draw_list"
import core_term "../../core/terminal"
import telemetry "../../features/telemetry"

Driver :: struct {
	tm:             tabs_feat.Tabs_Manager,
	mux:            mux_feat.Multiplexer,
	inter:          inter_feat.Interaction_State,
	dl:             chrome_dl.Ui_Draw_List,
	screen_w:       f32,
	screen_h:       f32,
	chrome_h:       f32,
	initialized:    bool,
	active_pane_id: u32,
	cols:           int,
	rows:           int,
}

driver_init :: proc(d: ^Driver, cols, rows: int, shell: string) -> bool {
	d.screen_w = 1280.0
	d.screen_h = 800.0
	d.chrome_h = 36.0
	d.cols = cols if cols > 0 else 80
	d.rows = rows if rows > 0 else 24

	tabs_feat.tabs_manager_init(&d.tm, {0, 0, d.screen_w, d.chrome_h})
	mux_feat.multiplexer_init(&d.mux)
	inter_feat.interaction_init(&d.inter, cell_w = 9.0, cell_h = 18.0)
	chrome_dl.ui_draw_list_init(&d.dl)

	sh := shell if len(shell) > 0 else os.get_env("SHELL", context.temp_allocator)
	if len(sh) == 0 do sh = "/bin/sh"

	term_cfg := sess_feat.Session_Config{shell = sh, rows = d.rows, cols = d.cols}
	p_term, err := mux_feat.multiplexer_create_terminal_pane(&d.mux, term_cfg)
	if err != .None {
		chrome_dl.ui_draw_list_destroy(&d.dl)
		tabs_feat.tabs_manager_destroy(&d.tm)
		mux_feat.multiplexer_destroy(&d.mux)
		return false
	}

	d.active_pane_id = p_term
	tabs_feat.tabs_manager_create_tab(&d.tm, "Terminal", p_term)

	content_area: [4]f32 = {0.0, d.chrome_h, d.screen_w, d.screen_h - d.chrome_h}
	tabs_feat.tabs_manager_update_layout(&d.tm, content_area)
	mux_feat.multiplexer_sync_split_rects(&d.mux, d.tm.entries[0].split_tree)

	d.initialized = true
	return true
}

driver_destroy :: proc(d: ^Driver) {
	if !d.initialized do return
	chrome_dl.ui_draw_list_destroy(&d.dl)
	tabs_feat.tabs_manager_destroy(&d.tm)
	mux_feat.multiplexer_destroy(&d.mux)
	d.initialized = false
}

driver_send :: proc(d: ^Driver, text: string) -> bool {
	pane := mux_feat.multiplexer_get_pane(&d.mux, d.active_pane_id)
	if pane == nil || pane.session == nil do return false
	_, err := sess_feat.session_write_string(pane.session, text)
	return err == .None
}

driver_drain :: proc(d: ^Driver, timeout_ms: int, wait_text: string) -> (found: bool) {
	to := timeout_ms if timeout_ms > 0 else 500
	start := time.now()
	found = len(wait_text) == 0

	for time.duration_milliseconds(time.since(start)) < f64(to) {
		n := mux_feat.multiplexer_drain_all(&d.mux)
		if len(wait_text) > 0 {
			grid_str := driver_get_grid_text(d, context.temp_allocator)
			if strings.contains(grid_str, wait_text) {
				found = true
				break
			}
		}
		if n == 0 {
			time.sleep(10 * time.Millisecond)
		}
	}
	return found
}

driver_resize :: proc(d: ^Driver, cols, rows: int) -> bool {
	pane := mux_feat.multiplexer_get_pane(&d.mux, d.active_pane_id)
	if pane == nil || pane.session == nil do return false
	d.cols = cols
	d.rows = rows
	sess_feat.session_resize(pane.session, u16(cols), u16(rows))
	return true
}

driver_split :: proc(d: ^Driver, direction: string, ratio: f32) -> (new_id: u32, ok: bool) {
	dir := chrome_splits.Split_Kind.Horizontal if direction == "horizontal" else chrome_splits.Split_Kind.Vertical
	r := clamp(ratio if ratio > 0.0 else 0.5, 0.1, 0.9)

	sh := os.get_env("SHELL", context.temp_allocator)
	if len(sh) == 0 do sh = "/bin/sh"
	term_cfg := sess_feat.Session_Config{shell = sh, rows = d.rows, cols = d.cols}
	p_new, err := mux_feat.multiplexer_create_terminal_pane(&d.mux, term_cfg)
	if err != .None do return 0, false

	_, tab := tabs_feat.tabs_manager_get_active(&d.tm)
	if tab == nil || tab.split_tree == nil do return 0, false
	chrome_splits.split_node_split(tab.split_tree, dir, r, p_new)

	content_area: [4]f32 = {0.0, d.chrome_h, d.screen_w, d.screen_h - d.chrome_h}
	tabs_feat.tabs_manager_update_layout(&d.tm, content_area)
	mux_feat.multiplexer_sync_split_rects(&d.mux, tab.split_tree)

	d.active_pane_id = p_new
	return p_new, true
}

driver_tab_new :: proc(d: ^Driver) -> (tab_id: u32, ok: bool) {
	sh := os.get_env("SHELL", context.temp_allocator)
	if len(sh) == 0 do sh = "/bin/sh"
	term_cfg := sess_feat.Session_Config{shell = sh, rows = d.rows, cols = d.cols}
	p_new, err := mux_feat.multiplexer_create_terminal_pane(&d.mux, term_cfg)
	if err != .None do return 0, false

	tid, _ := tabs_feat.tabs_manager_create_tab(&d.tm, "Shell", p_new)
	content_area: [4]f32 = {0.0, d.chrome_h, d.screen_w, d.screen_h - d.chrome_h}
	tabs_feat.tabs_manager_update_layout(&d.tm, content_area)

	d.active_pane_id = p_new
	return tid, true
}

driver_tab_close :: proc(d: ^Driver, idx: int) -> bool {
	close_idx := idx if idx >= 0 else int(d.tm.model.active_idx)
	tabs_feat.tabs_manager_close_tab(&d.tm, close_idx)
	if len(d.tm.entries) > 0 {
		_, tab := tabs_feat.tabs_manager_get_active(&d.tm)
		if tab != nil do d.active_pane_id = tab.active_pane_id
	}
	return true
}

driver_get_active_term :: proc(d: ^Driver) -> ^core_term.Terminal {
	pane := mux_feat.multiplexer_get_pane(&d.mux, d.active_pane_id)
	if pane == nil || pane.session == nil do return nil
	return &pane.session.term
}

driver_get_grid_text :: proc(d: ^Driver, allocator := context.allocator) -> string {
	t := driver_get_active_term(d)
	if t == nil do return ""
	return telemetry.grid_dump_format(t, allocator)
}
