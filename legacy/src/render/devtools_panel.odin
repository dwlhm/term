package render

import diag "../diag"
import config "../config"

// The DevTools panel is DRAW-ONLY, and that is a structural property, not a
// convention.
//
// It stages a background card and glyphs into the Devtools UI layer and
// returns. It performs no click picking, no pointer routing, no focus
// handling and no key handling, and its rectangle is registered with no input
// router, scroll handler, tab-interaction path or session switcher. Nothing
// beneath the panel can be occluded in the input sense, because no input code
// path consults this file. Do not "helpfully" add interactivity here: a
// display overlay that also swallows input silently changes the behaviour of
// the grid underneath it, which is exactly what this layer is designed to be
// unable to do.

// DEVTOOLS_PANEL_LINES is the number of text rows the panel draws. It is
// exactly the line count of diag.devtools_format_snapshot, so the two cannot
// disagree about the panel height.
DEVTOOLS_PANEL_LINES :: 4

// DEVTOOLS_PANEL_COLUMNS caps the panel width in cells. The formatter keeps
// every line under 80 bytes for realistic values; 64 covers that with margin
// while keeping the panel compact. It is a cap, not a fit: the panel never
// grows with the window and never spans it. It is also the fallback used when
// the configured column count is not positive; see devtools_panel_rect.
DEVTOOLS_PANEL_COLUMNS :: 64

// config.DEVTOOLS_DEFAULT_COLUMNS carries the same literal because config
// cannot import render (render depends on config). Keeping two copies of one
// number is only safe while something prevents them from drifting, so assert
// the coupling here, where the fallback is actually applied: if the config
// default is ever changed without this constant, the build fails instead of
// silently giving the panel two different defaults depending on which layer
// answered the question.
#assert(DEVTOOLS_PANEL_COLUMNS == config.DEVTOOLS_DEFAULT_COLUMNS)

// The DevTools panel draws from the single cadence in diag
// (diag.devtools_cadence_due). It deliberately keeps no timestamp of its own:
// an independent interval here is exactly what made the panel text and the
// sampled metrics drift apart, because the two were driven by different
// timestamps updated at different moments. See DEVTOOLS_SAMPLE_INTERVAL_NS.

// Panel card and text colors. Kept local to the render package, which has no
// theme handle, and matched to the muted chrome palette the overlay layers use.
DEVTOOLS_PANEL_BG: [4]f32 : {0.06, 0.06, 0.09, 0.88}
DEVTOOLS_PANEL_TEXT: [4]f32 : {0.82, 0.85, 0.92, 1.0}

// Rect_f32 is an axis-aligned rectangle in device pixels. The UI chrome
// package has its own logical-unit equivalent; this one exists because
// chrome depends on render and therefore cannot be depended on in turn.
Rect_f32 :: struct {
	x, y, w, h: f32,
}

// devtools_panel_rect computes the panel geometry in device pixels: a card
// pinned to the corner named by anchor, bounded by the surface on both axes.
//
// top_offset is the tab bar strip height in device pixels, and it applies to
// the top anchors only. The tab bar is chrome pinned to the top edge of the
// window; a bottom-anchored panel sits at the other edge of the same surface
// and cannot collide with it, so passing the offset through for those anchors
// would push the panel up for no reason and make the bottom anchors depend on
// unrelated chrome geometry. It is therefore dropped (treated as 0) for
// .Bottom_Right and .Bottom_Left. The renderer owns pixels, so the caller
// supplies the tab bar height already multiplied by the content scale; render
// cannot read the chrome constant because chrome imports render.
//
// columns is the configured panel width in cells. A value that is not positive
// falls back to DEVTOOLS_PANEL_COLUMNS, which keeps a zero-valued config field
// (and every headless caller that never resolved a config) on the historical
// geometry rather than collapsing the panel to nothing.
//
// Every clamp below is absolute rather than relative: a negative origin or a
// non-positive extent is unreachable by construction, not merely unlikely, so
// a degenerate or mis-sized surface degrades to a zero rect instead of
// staging an off-screen quad. The bottom anchors derive y from the surface
// height for the same reason, so no anchor can push the card past an edge.
devtools_panel_rect :: proc(
	r: ^Renderer,
	top_offset: f32 = 0.0,
	anchor: config.Devtools_Anchor = .Top_Right,
	columns: int = 0,
) -> Rect_f32 {
	empty := Rect_f32{}
	if r == nil {
		return empty
	}
	cw := r.cell_width
	ch := r.cell_height
	if !(cw > 0) || !(ch > 0) {
		return empty
	}

	sw := f32(r.surface_w)
	sh := f32(r.surface_h)
	margin := max(r.pad_x, 0.0)
	is_top := anchor == .Top_Right || anchor == .Top_Left
	is_right := anchor == .Top_Right || anchor == .Bottom_Right
	top := clamp(top_offset, 0.0, max(sh, 0.0))
	if !is_top {
		top = 0.0
	}

	avail_w := max(sw - margin, 0.0)
	col_limit := columns if columns > 0 else DEVTOOLS_PANEL_COLUMNS
	cols := min(max(int(avail_w / cw), 0), col_limit)
	w := min(f32(cols) * cw, avail_w)

	avail_h := max(sh - top - margin, 0.0)
	lines := min(max(int(avail_h / ch), 0), DEVTOOLS_PANEL_LINES)
	h := min(f32(lines) * ch, avail_h)

	if !(w > 0) || !(h > 0) {
		return empty
	}

	raw_x := sw - margin - w
	if !is_right {
		raw_x = margin
	}
	x := clamp(raw_x, 0.0, max(sw - w, 0.0))
	raw_y := top
	if !is_top {
		raw_y = sh - margin - h
	}
	y := clamp(raw_y, 0.0, max(sh - h, 0.0))
	return Rect_f32{x = x, y = y, w = w, h = h}
}

// _panel_cache holds the last formatted panel text and when it was built.
//
// This throttle exists so the instrumentation cannot distort the frame timing
// it measures. diag.devtools_format_snapshot heap-allocates a fresh string,
// and the snapshot behind it sorts the whole sample ring; running that per
// frame at 120 fps would spend a meaningful slice of the 8.33 ms budget on
// drawing the very numbers that report the budget being missed. The text is
// therefore rebuilt at 4 Hz (diag.DEVTOOLS_SAMPLE_INTERVAL_NS == 250 ms) and
// repainted from this cache on every frame in between. Do not "optimize" the
// throttle away: caching at the glyph level, or dropping the panel entirely
// between ticks, both trade a small, bounded cost for a much larger one.
//
// Ownership: text is heap memory owned by this module for as long as it is
// cached. Callers borrow it (see devtools_panel_text); devtools_panel_release
// frees the final copy at teardown.
@(private)
_panel_cache: struct {
	text:  string, // "" means empty cache
	valid: bool,
}

// _panel_text_fresh reports whether the cached text may be served without
// rebuilding it.
//
// The staleness question is no longer answered here. It is delegated to the
// one cadence clock in diag, so "the panel needs new text" and "the collector
// needs a new sample" are literally the same predicate evaluated on the same
// state; they cannot disagree even for one tick. now_ns follows the
// devtools_panel_text convention: 0 means "no clock", which is always due.
@(private)
_panel_text_fresh :: proc(now_ns: u64) -> bool {
	if !_panel_cache.valid {
		return false
	}
	return !diag.devtools_cadence_due(now_ns)
}

// devtools_panel_refresh_due reports whether the underlying snapshot is due
// for a re-read, so the caller can avoid the per-frame cost of
// diag.devtools_snapshot (which copies the ring and sorts it up to three
// times). Ask this BEFORE taking a snapshot, and still call
// devtools_panel_draw every frame: the panel keeps painting cached text
// between ticks rather than blanking.
//
// now_ns follows the devtools_panel_text convention: a platform_now-derived
// nanosecond timestamp, or 0 for "no clock", which always reports due.
devtools_panel_refresh_due :: proc(now_ns: u64 = 0) -> bool {
	return !_panel_text_fresh(now_ns)
}

// devtools_panel_text returns the panel text for snap, rebuilding it only when
// the cached copy is stale (see _panel_cache).
//
// OWNERSHIP: the returned string is BORROWED, not owned. It points into this
// module's cache; the caller must NOT delete it, and the pointer is
// invalidated by the next call, so glyph staging must complete before the next
// draw. This module frees the previous string on replacement and the last one
// in devtools_panel_release.
devtools_panel_text :: proc(snap: ^diag.Devtools_Snapshot, now_ns: u64) -> string {
	if _panel_text_fresh(now_ns) {
		return _panel_cache.text
	}

	// Free the superseded copy exactly once, here, before the slot is
	// overwritten. Nothing else in this file owns it.
	if _panel_cache.valid {
		delete(_panel_cache.text)
	}
	_panel_cache.text = diag.devtools_format_snapshot(snap)
	_panel_cache.valid = true
	return _panel_cache.text
}

// devtools_panel_release frees the cached panel text. Call it once at
// teardown. Idempotent, so a double release cannot double free.
devtools_panel_release :: proc() {
	if _panel_cache.valid {
		delete(_panel_cache.text)
	}
	_panel_cache.text = ""
	_panel_cache.valid = false
}

// devtools_panel_draw stages the DevTools panel into the Devtools layer and
// reports whether anything was staged.
//
// snap is the aggregate view from diag.devtools_snapshot; the text comes from
// diag.devtools_format_snapshot, the same formatter any future log writer
// uses, so the on-screen panel and the log cannot drift apart. The caller owns
// the snapshot; this proc never frees or copies it. Callers may pass a snapshot
// that is older than this frame: the text served from the cache is the text
// that snapshot produced, which is exactly the intent of the throttle.
//
// top_offset is the tab bar strip height in device pixels, applied to the top
// anchors only, see devtools_panel_rect. anchor and columns carry the
// resolved configuration; a non-positive columns falls back to
// DEVTOOLS_PANEL_COLUMNS inside the geometry proc.
//
// now_ns is a platform_now-derived nanosecond timestamp used only for the
// refresh throttle (0 means "no clock", which rebuilds every call). It must be
// the same value the caller passed to devtools_panel_refresh_due, so the
// snapshot decision and the text decision are made against one clock reading.
//
// Guard order matters: the diag.devtools_enabled() check is what keeps headless
// test runs, which drive the frontend with no real window and no enabled
// collector, from touching the surface at all.
devtools_panel_draw :: proc(
	r: ^Renderer,
	snap: ^diag.Devtools_Snapshot,
	top_offset: f32 = 0.0,
	now_ns:     u64 = 0,
	anchor:     config.Devtools_Anchor = .Top_Right,
	columns:    int = 0,
) -> bool {
	if r == nil {
		return false
	}
	if snap == nil {
		return false
	}
	if !diag.devtools_enabled() {
		return false
	}

	rect := devtools_panel_rect(r, top_offset, anchor, columns)
	if rect.w <= 0 || rect.h <= 0 {
		return false
	}
	cols := int(rect.w / r.cell_width)
	lines := int(rect.h / r.cell_height)
	if cols <= 0 || lines <= 0 {
		return false
	}

	// Borrowed, not owned: devtools_panel_text caches this string, and the
	// throttle in front of it is what keeps the formatter off the per-frame
	// path. Staging the glyphs below is cheap and deliberately stays
	// per-frame, so the panel repaints smoothly between refresh ticks.
	text := devtools_panel_text(snap, now_ns)

	renderer_ui_begin_layer(r, .Devtools)
	renderer_ui_stage_bg(r, rect.x, rect.y, rect.w, rect.h, DEVTOOLS_PANEL_BG)

	// Split the formatted block on newlines while drawing. The formatter
	// guarantees plain ASCII, which the pinned render atlas covers, so no
	// codepoint here can miss the atlas.
	line := 0
	col := 0
	for cp in text {
		if line >= lines {
			break
		}
		if cp == '\n' {
			line += 1
			col = 0
			continue
		}
		if col >= cols {
			continue
		}
		x := rect.x + f32(col) * r.cell_width
		y := rect.y + f32(line) * r.cell_height
		renderer_ui_stage_glyph(r, x, y, r.cell_width, r.cell_height, cp, DEVTOOLS_PANEL_TEXT)
		col += 1
	}

	return true
}