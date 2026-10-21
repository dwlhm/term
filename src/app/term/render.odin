package term

// Term Surface Rendering, Layer Composition & Layout Synchronization
// Part of Tier 3 Application Shell (src/app/term/*).

import "core:os"
import "core:strings"
import "core:time"
import contract "../../core/render/contract"
import composer "../../core/composer"
import pipeline "../../core/composer/pipeline"
import scheduler "../../core/composer/scheduler"
import frame "../../core/composer/frame"
import chrome_splits "../../core/chrome/splits"
import tabs_feat "../../features/tabs"
import mux_feat "../../features/multiplexer"
import sess_feat "../../features/session"
import telemetry "../../features/telemetry"

// tab_title_mask_path replaces $HOME or /Users/<user> / /home/<user> with ~
tab_title_mask_path :: proc(title: string, allocator := context.temp_allocator) -> string {
	if len(title) == 0 do return "Shell"

	// 1. Exact $HOME match or prefix
	home := os.get_env("HOME", allocator)
	if len(home) > 0 {
		if title == home do return "~"
		if strings.has_prefix(title, home) {
			rest := title[len(home):]
			if len(rest) > 0 && rest[0] == '/' {
				return strings.concatenate({"~", rest}, allocator)
			}
		}
		if idx := strings.index(title, home); idx >= 0 {
			before := title[:idx]
			after := title[idx + len(home):]
			return strings.concatenate({before, "~", after}, allocator)
		}
	}

	// 2. Generic /Users/<user> or /home/<user> heuristic fallback
	user_prefix := "/Users/" when ODIN_OS == .Darwin else "/home/"
	if strings.has_prefix(title, user_prefix) {
		rest := title[len(user_prefix):]
		if slash_idx := strings.index_byte(rest, '/'); slash_idx >= 0 {
			return strings.concatenate({"~", rest[slash_idx:]}, allocator)
		} else {
			return "~"
		}
	}

	return title
}

// app_sync_tab_titles reads dynamic PTY foreground process, CWD, and OSC titles from active pane sessions and updates tabs
app_sync_tab_titles :: proc(app: ^Term_App) -> (dirty: bool) {
	if app == nil do return false

	scratch_title: [512]u8

	for i in 0..<len(app.tabs_mgr.entries) {
		entry := &app.tabs_mgr.entries[i]
		pane_id := entry.active_pane_id
		if pane_id == 0 && entry.split_tree != nil {
			if leaf := chrome_splits.split_tree_first_leaf(entry.split_tree); leaf != nil {
				pane_id = leaf.pane_id
			}
		}

		p := mux_feat.multiplexer_get_pane(&app.mux, pane_id)
		if p == nil do continue

		target_title: string = "Shell"
		if p.kind == .Three_D {
			target_title = "3D Canvas"
		} else if p.kind == .Terminal && p.session != nil {
			raw := sess_feat.session_resolve_title(p.session, scratch_title[:], "Shell")
			target_title = tab_title_mask_path(raw, context.temp_allocator)
		}

		current := string(entry.title_buf[:entry.title_len])
		if current != target_title {
			tabs_feat.tabs_manager_set_title(&app.tabs_mgr, i, target_title)
			dirty = true
		}
	}
	return dirty
}

// app_sync_layout_and_winsize synchronizes the active tab split geometry
// and updates the PTY window size (TIOCSWINSZ) for any mutated terminal panes.
app_sync_layout_and_winsize :: proc(app: ^Term_App) -> (dirty: bool) {
	if app_sync_tab_titles(app) do dirty = true

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
			cw := max(1.0, app.layout.metrics.cell_w)
			ch := max(1.0, app.layout.metrics.cell_h)
			cols := max(10, int((pane.rect[2] - 2.0 * app.layout.metrics.pane_pad_x) / cw))
			rows := max(4, int((pane.rect[3] - 2.0 * app.layout.metrics.pane_pad_y) / ch))
			xpixel := u16(f32(cols) * cw)
			ypixel := u16(f32(rows) * ch)
			if cols != pane.session.term.cols || rows != pane.session.term.rows || pane.session.term.parser.cell_w != int(cw) || pane.session.term.parser.cell_h != int(ch) {
				sess_feat.session_resize(pane.session, u16(cols), u16(rows), xpixel, ypixel)
				dirty = true
			}
			if app.mouse.is_dragging_divider {
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

App_Frame_Context :: struct {
	app: ^Term_App,
}

@(private = "file")
_app_frame_acquire :: proc(user: rawptr) -> (contract.Gpu_Texture, contract.Gpu_TextureView, bool) {
	ctx := (^App_Frame_Context)(user)
	if ctx == nil || ctx.app == nil || ctx.app.surface == nil do return nil, nil, false
	tex, view, _ := contract.get_surface_texture(ctx.app.surface)
	if rawptr(view) == nil do return nil, nil, false
	return tex, view, true
}

@(private = "file")
_app_frame_raster :: proc(user: rawptr, enc: contract.Gpu_CommandEncoder, l: ^composer.Composer_Layer) -> bool {
	ctx := (^App_Frame_Context)(user)
	if ctx == nil || ctx.app == nil || rawptr(enc) == nil || l == nil do return false
	app := ctx.app

	switch l.id {
	case 101:
		first := true
		for &pane in app.mux.panes {
			if pane.kind == .Terminal && pane.session != nil && pane.rect[2] > 10 {
				load_op: contract.Gpu_Load_Op = .Clear if first else .Load
				first = false
				strat, dirty_cells := terminal_view_encode_pane(
					&app.term_view,
					enc,
					pane.session,
					pane.id,
					pane.rect,
					pane.is_focused,
					&app.mouse,
					app.time_elapsed,
					l.view,
					&app.text_atlas,
					app.layout.metrics,
					app.layout.screen_w,
					app.layout.screen_h,
					load_op,
				)
				strat_name: string
				switch strat {
				case .Instance: strat_name = "Instance"
				case .Compute_Tiles: strat_name = "Compute_Tiles"
				case .Fullscreen: strat_name = "Fullscreen"
				}
				telemetry.telemetry_add_pane(&app.diag.tel, dirty_cells, strat_name)
			}
		}
		if first {
			pass := contract.begin_render_pass(enc, l.view, {0.0, 0.0, 0.0, 0.0}, .Clear)
			if rawptr(pass) != nil do contract.end_render_pass(pass)
		}
		return true

	case 201:
		return chrome_view_encode(&app.chrome_view, enc, l.view, .Clear)
	}

	return false
}

@(private = "file")
_app_frame_present :: proc(user: rawptr, tex: contract.Gpu_Texture, view: contract.Gpu_TextureView) -> bool {
	ctx := (^App_Frame_Context)(user)
	if ctx == nil || ctx.app == nil || ctx.app.surface == nil do return false
	contract.present_surface(ctx.app.surface)
	contract.release_surface_texture(tex, view)
	return true
}

// app_render_frame executes production frame_tick: rasters only dirty layers onto
// a single CommandEncoder, composites via Composer_Pipeline, submits, and presents once.
app_render_frame :: proc(app: ^Term_App, term_dirty: bool = true) {
	chrome_dirty := chrome_view_build_draw_list(
		&app.chrome_view,
		&app.layout,
		&app.tabs_mgr,
		&app.mux,
		&app.cmd_center,
		&app.cursor,
		app.time_elapsed,
		app.mouse.hovered_split_node,
		app.mouse.drag_split_node,
	)

	if term_dirty {
		pipeline.composer_pipeline_mark_dirty(&app.composer.pipe, 101)
		scheduler.scheduler_mark_damage(&app.composer.sched, 101)
	}
	if chrome_dirty {
		pipeline.composer_pipeline_mark_dirty(&app.composer.pipe, 201)
		scheduler.scheduler_mark_damage(&app.composer.sched, 201)
	}

	ctx := App_Frame_Context{app = app}
	driver := frame.Frame_Driver{
		user    = &ctx,
		acquire = _app_frame_acquire,
		raster  = _app_frame_raster,
		present = _app_frame_present,
	}

	now_ns := u64(time.duration_nanoseconds(time.since(app.start_time)))
	_ = frame.frame_tick(&app.composer.sched, &app.composer.pipe, nil, &driver, now_ns)
}
