package term

import "core:testing"
import term_engine "../../core/terminal"
import mux_feat "../../features/multiplexer"
import sess_feat "../../features/session"
import tabs_feat "../../features/tabs"
import plat_win "../../platform/window"

@test
test_menu_bar_attach_background_session :: proc(t: ^testing.T) {
	app := new(Term_App)
	defer free(app)

	tabs_feat.tabs_manager_init(&app.tabs_mgr, {0, 0, 800, 36})
	defer tabs_feat.tabs_manager_destroy(&app.tabs_mgr)

	mux_feat.multiplexer_init(&app.mux)
	defer mux_feat.multiplexer_destroy(&app.mux)

	sess_feat.session_registry_init(&app.session_reg)
	defer sess_feat.session_registry_destroy(&app.session_reg)

	// Create initial tab + pane
	p_initial := app.mux.next_pane_id
	app.mux.next_pane_id += 1
	tabs_feat.tabs_manager_create_tab(&app.tabs_mgr, "Initial Tab", p_initial)

	// Detach a simulated session into session_reg with id 42
	sess := new(sess_feat.Terminal_Session)
	term_engine.terminal_init(&sess.term, 24, 80)
	copy(sess.title_buf[:14], "Background Job")
	sess.title_len = 14

	ok_detach := sess_feat.session_registry_detach(&app.session_reg, 42, 0, "Background Job", sess)
	testing.expect(t, ok_detach, "Failed to detach session into registry")
	testing.expect_value(t, sess_feat.session_registry_count(&app.session_reg), 1)

	// Verify menu bar items populate with tag 2000 + 42
	items := make([dynamic]plat_win.Platform_Menu_Bar_Item, 0, 8, context.temp_allocator)
	active_cnt := _append_menu_bar_sessions(app, &items)
	testing.expect_value(t, active_cnt, 1)
	testing.expect_value(t, len(items), 1)
	testing.expect_value(t, items[0].tag, 2042)

	// Simulate user clicking the background session menu item (tag 2042)
	app_handle_menu_bar_action(app, 2042)

	// Background session must be popped from registry and attached as a new tab
	testing.expect_value(t, sess_feat.session_registry_count(&app.session_reg), 0)
	testing.expect_value(t, len(app.tabs_mgr.entries), 2)
	testing.expect_value(t, app.tabs_mgr.model.active_idx, 1)

	act_idx, act_entry := tabs_feat.tabs_manager_get_active(&app.tabs_mgr)
	testing.expect_value(t, act_idx, 1)
	testing.expect(t, act_entry != nil, "Active tab entry should not be nil")
	testing.expect_value(t, string(act_entry.title_buf[:act_entry.title_len]), "Background Job")

	// Restored session is now owned by app.mux; clean up terminal engine
	term_engine.terminal_destroy(&sess.term)
	free(sess)
}
