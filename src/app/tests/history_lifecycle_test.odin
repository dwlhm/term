package app_test

import "core:testing"
import "core:time"
import app "../"
import config "../../config"
import tg "../../terminal"
import inter "../../interaction"
import pty "../../platform/pty"

@(test)
test_backend_full_history_keeps_paused_cells :: proc(t: ^testing.T) {
	b := new(app.Backend)
	defer free(b)
	cfg := config.config_default()
	defer config.config_destroy(&cfg)
	ok := app.backend_init(b, 3, 8, "/bin/sh", {"-c", "stty -echo; printf READY; read trigger; printf '\r\nX\r\n'; sleep 1"}, &cfg, tg.THEME_CATPPUCCIN_MOCHA)
	testing.expect(t, ok)
	if !ok do return
	defer app.backend_destroy(b)
	ready := false
	for _ in 0 ..< 200 {
		_ = app.backend_drain_pty(b)
		if tg.terminal_get_cell(&b.terminal, 0, 4).content == tg.Content_Handle('Y') { ready = true; break }
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, ready, "child must be ready before history setup")
	if !ready do return
	tg.scrollback_destroy(&b.terminal.scrollback, &b.terminal.grapheme_store)
	tg.scrollback_init(&b.terminal.scrollback, b.terminal.grid.col_count, 8)
	for i in 0 ..< 8 {
		_ = tg.grid_set_cell(&b.terminal.grid, 0, 0, tg.Semantic_Cell{content = tg.Content_Handle('A' + i), width = 1})
		tg.terminal_scroll_up(&b.terminal, 1)
	}
	b.terminal.cursor.row = b.terminal.grid.row_count - 1
	b.terminal.cursor.col = 0
	_ = tg.terminal_view_set_offset(&b.view, &b.terminal, 4)
	inter.interaction_pause_viewport(&b.interaction, b.view.scrollback_offset)
	before := tg.terminal_view_get_cell(&b.terminal, &b.view, 0, 0)
	pushes := b.terminal.scrollback.total_pushed
	testing.expect(t, pty.pty_write(&b.pty, []u8{'\n'}))
	for _ in 0 ..< 200 {
		_ = app.backend_drain_pty(b)
		if b.terminal.scrollback.total_pushed >= pushes + 2 do break
		time.sleep(5 * time.Millisecond)
	}
	testing.expect_value(t, b.terminal.scrollback.total_pushed, pushes + 2)
	testing.expect_value(t, b.view.scrollback_offset, 6)
	testing.expect_value(t, b.interaction.paused_offset, 6)
	testing.expect_value(t, tg.terminal_view_get_cell(&b.terminal, &b.view, 0, 0).content, before.content)
}

@(test)
test_closing_tabs_preserves_surviving_active_identity :: proc(t: ^testing.T) {
	for remove_idx in 0 ..< 3 {
		sm: app.Session_Manager
		app.session_manager_init(&sm, 3)
		for i in 0 ..< 3 {
			resize(&sm.tabs, len(sm.tabs) + 1)
			tab := &sm.tabs[len(sm.tabs) - 1]
			tab.id = u32(i + 1)
			tab.status = .Exited
			tab.backend.pty.master = -1
		}
		sm.active_idx = 1
		testing.expect(t, app.session_close_tab(&sm, remove_idx))
		expected_id := u32(2)
		if remove_idx == 1 { expected_id = 3 }
		testing.expect_value(t, sm.tabs[sm.active_idx].id, expected_id)
		testing.expect(t, app.session_close_tab(&sm, 1))
		testing.expect(t, app.session_close_tab(&sm, 0))
		testing.expect_value(t, sm.active_idx, -1)
		app.session_manager_destroy(&sm)
	}
}

@(test)
test_session_close_tab_on_pty_exited_or_last :: proc(t: ^testing.T) {
	sm: app.Session_Manager
	app.session_manager_init(&sm, 3)
	defer app.session_manager_destroy(&sm)

	resize(&sm.tabs, len(sm.tabs) + 1)
	tab0 := &sm.tabs[len(sm.tabs) - 1]
	tab0.id = 1
	tab0.status = .Running
	tab0.backend.pty.master = -1
	tab0.backend.pty.state = .Exited

	resize(&sm.tabs, len(sm.tabs) + 1)
	tab1 := &sm.tabs[len(sm.tabs) - 1]
	tab1.id = 2
	tab1.status = .Running
	tab1.backend.pty.master = -1
	tab1.backend.pty.state = .Running

	sm.active_idx = 0

	testing.expect(t, app.session_close_tab(&sm, 0))
	testing.expect_value(t, len(sm.tabs), 1)
	testing.expect_value(t, sm.active_idx, 0)
	testing.expect_value(t, sm.tabs[sm.active_idx].id, u32(2))

	sm.tabs[0].backend.pty.state = .Exited
	testing.expect(t, app.session_close_tab(&sm, 0))
	testing.expect_value(t, len(sm.tabs), 0)
	testing.expect_value(t, sm.active_idx, -1)
}

