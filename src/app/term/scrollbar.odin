package term

// Scrollback scrollbar geometry and drag interaction.
//
// The track hugs the right edge of a pane; the thumb is proportional to the
// visible fraction of the buffer, so a 10 000-line history still gives a usable
// handle. Dragging maps the pointer position back onto the scroll offset.

import mux_feat "../../features/multiplexer"

SCROLLBAR_WIDTH     :: f32(5.0)  // logical points, scaled by the pane scale
SCROLLBAR_MARGIN    :: f32(4.0)
SCROLLBAR_MIN_THUMB :: f32(20.0)
SCROLLBAR_HIT_SLOP  :: f32(6.0)

Scrollbar_Geometry :: struct {
	track_x: f32,
	track_y: f32,
	track_h: f32,
	thumb_y: f32,
	thumb_h: f32,
	valid:   bool,
}

// scrollbar_geometry is pure: it derives the track/thumb rectangles from the
// pane rect and buffer dimensions so drawing and hit testing can never diverge.
scrollbar_geometry :: proc(
	pane_rect: [4]f32,
	rows_visible, history, scroll_offset: int,
	scale: f32 = 1.0,
) -> Scrollbar_Geometry {
	if history <= 0 || rows_visible <= 0 do return {}

	s := max(1.0, scale)
	track_h := max(1.0, pane_rect[3] - 16.0 * s)
	visible := f32(rows_visible)
	total := visible + f32(history)
	thumb_h := max(SCROLLBAR_MIN_THUMB * s, track_h * (visible / total))
	progress := f32(scroll_offset) / f32(history)
	thumb_y := pane_rect[1] + 8.0 * s + (track_h - thumb_h) * (1.0 - clamp(progress, 0.0, 1.0))

	return Scrollbar_Geometry{
		track_x = pane_rect[0] + pane_rect[2] - (SCROLLBAR_WIDTH + SCROLLBAR_MARGIN) * s,
		track_y = pane_rect[1] + 8.0 * s,
		track_h = track_h,
		thumb_y = thumb_y,
		thumb_h = thumb_h,
		valid = true,
	}
}

scrollbar_geometry_for_pane :: proc(pane: ^mux_feat.Pane_Entry, scale: f32 = 1.0) -> Scrollbar_Geometry {
	if pane == nil || pane.session == nil do return {}
	return scrollbar_geometry(
		pane.rect,
		pane.session.term.rows,
		pane.session.term.grid.history_count,
		pane.session.scroll_offset,
		scale,
	)
}

// scrollbar_offset_from_pointer maps a pointer position onto a scroll offset.
scrollbar_offset_from_pointer :: proc(geometry: Scrollbar_Geometry, my, grab_offset: f32, history: int) -> int {
	if history <= 0 || !geometry.valid do return 0
	travel := track_travel(geometry)
	if travel <= 0.0 do return 0
	thumb_top := clamp(my - grab_offset, geometry.track_y, geometry.track_y + travel)
	progress := 1.0 - (thumb_top - geometry.track_y) / travel
	return int(clamp(progress, 0.0, 1.0) * f32(history) + 0.5)
}

// scrollbar_hit_pane returns the pane whose scrollbar track contains the point.
scrollbar_hit_pane :: proc(app: ^Term_App, mx, my: f32) -> ^mux_feat.Pane_Entry {
	if app == nil do return nil
	s := max(1.0, app.layout.metrics.scale)
	slop := SCROLLBAR_HIT_SLOP * s
	for &pane in app.mux.panes {
		geometry := scrollbar_geometry_for_pane(&pane, s)
		if !geometry.valid do continue
		if mx < geometry.track_x - slop || mx > geometry.track_x + SCROLLBAR_WIDTH * s + slop do continue
		if my < geometry.track_y || my > geometry.track_y + geometry.track_h do continue
		return &pane
	}
	return nil
}

// scrollbar_begin_drag starts dragging the thumb, jumping it under the pointer.
scrollbar_begin_drag :: proc(app: ^Term_App, pane: ^mux_feat.Pane_Entry, my: f32) -> bool {
	if app == nil || pane == nil do return false
	geometry := scrollbar_geometry_for_pane(pane, max(1.0, app.layout.metrics.scale))
	if !geometry.valid do return false

	inside_thumb := my >= geometry.thumb_y && my <= geometry.thumb_y + geometry.thumb_h
	app.mouse.scrollbar_pane_id = pane.id
	app.mouse.scrollbar_drag_offset = (my - geometry.thumb_y) if inside_thumb else geometry.thumb_h * 0.5
	if !inside_thumb do scrollbar_update_drag(app, pane, my)
	return true
}

// scrollbar_update_drag maps the pointer position onto the scroll offset.
scrollbar_update_drag :: proc(app: ^Term_App, pane: ^mux_feat.Pane_Entry, my: f32) {
	if app == nil || pane == nil || pane.session == nil do return
	history := pane.session.term.grid.history_count
	if history <= 0 do return

	geometry := scrollbar_geometry_for_pane(pane, max(1.0, app.layout.metrics.scale))
	pane.session.scroll_offset = scrollbar_offset_from_pointer(
		geometry,
		my,
		app.mouse.scrollbar_drag_offset,
		history,
	)
}

track_travel :: proc(geometry: Scrollbar_Geometry) -> f32 {
	return max(0.0, geometry.track_h - geometry.thumb_h)
}

scrollbar_drag_active :: proc(app: ^Term_App) -> bool {
	return app != nil && app.mouse.scrollbar_pane_id != 0
}

scrollbar_end_drag :: proc(app: ^Term_App) {
	if app != nil do app.mouse.scrollbar_pane_id = 0
}
