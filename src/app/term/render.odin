package term

// Term Surface Rendering, Layer Composition & Layout Synchronization
// Part of Tier 3 Application Shell (src/app/term/*).

import contract "../../core/render/contract"
import tabs_feat "../../features/tabs"
import mux_feat "../../features/multiplexer"
import sess_feat "../../features/session"

// app_sync_layout_and_winsize synchronizes the active tab split geometry
// and updates the PTY window size (TIOCSWINSZ) for any mutated terminal panes.
app_sync_layout_and_winsize :: proc(app: ^Term_App) -> (dirty: bool) {
	// Sync active tab split tree with uniform margin == pane gap
	content_area := layout_compute_content_area(&app.layout)
	_, active_tab := tabs_feat.tabs_manager_get_active(&app.tabs_mgr)
	if active_tab != nil && active_tab.split_tree != nil {
		layout_split_tree_with_uniform_gaps(active_tab.split_tree, content_area, app.layout.metrics.pane_gap)
		mux_feat.multiplexer_sync_split_rects(&app.mux, active_tab.split_tree)
	}

	// Winsize PTY synchronization
	for &pane in app.mux.panes {
		if pane.kind == .Terminal && pane.session != nil && pane.rect[2] > 20 && pane.rect[3] > 20 {
			cols := max(10, int((pane.rect[2] - 2.0 * app.layout.metrics.pane_pad_x) / app.layout.metrics.cell_w))
			rows := max(4, int((pane.rect[3] - 2.0 * app.layout.metrics.pane_pad_y) / app.layout.metrics.cell_h))
			if cols != pane.session.term.cols || rows != pane.session.term.rows {
				sess_feat.session_resize(pane.session, u16(cols), u16(rows))
				dirty = true
			}
		}
	}
	return dirty
}

// app_needs_animation reports whether a redraw is required even without new
// input or PTY output (in-flight tab-bar animation, blinking cursor).
app_needs_animation :: proc(app: ^Term_App) -> bool {
	if app.layout.tab_bar_anim_t > 0.0 && app.layout.tab_bar_anim_t < 1.0 do return true

	p := mux_feat.multiplexer_get_focused_pane(&app.mux)
	return p != nil && p.session != nil && p.session.term.parser.cursor.blinking
}

// app_render_frame renders terminal content & chrome layers, composites them
// via the multi-layer composition pipeline, and presents to the swapchain.
app_render_frame :: proc(app: ^Term_App) {
	tex, view, _ := contract.get_surface_texture(app.surface)
	if rawptr(view) == nil do return

	term_layer, chrome_layer := composer_view_acquire_layers(&app.composer, app.layout.screen_w, app.layout.screen_h)

	if term_layer != nil {
		for &pane in app.mux.panes {
			if pane.kind == .Terminal && pane.session != nil && pane.rect[2] > 10 {
				terminal_view_render_pane(&app.term_view, pane.session, pane.rect, pane.is_focused, &app.mouse, app.time_elapsed, term_layer.view, &app.glyph_atlas, &app.emoji_atlas, app.layout.metrics, app.layout.screen_w, app.layout.screen_h)
			}
		}
	}

	if chrome_layer != nil {
		chrome_view_build_and_render(&app.chrome_view, &app.layout, &app.tabs_mgr, &app.mux, &app.cmd_center, &app.cursor, app.time_elapsed, chrome_layer.view)
	}

	composer_view_composite_and_present(&app.composer, app.surface, view)
	contract.release_surface_texture(tex, view)
}
