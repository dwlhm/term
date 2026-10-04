package ui_test

import "core:testing"

import render "../../render"
import config "../../config"

// devtools_panel_rect is pure geometry over a Renderer: it reads the cell size,
// the surface size and the padding, and returns a rect. A Renderer needs no
// window, no GPU and no enabled collector, so constructing one is enough to
// exercise every anchor over a range of surface sizes.
//
// The invariant under test is that the card is always inside the surface: a
// negative origin or extent would stage an off-screen quad, and a rect that
// ran past the right or bottom edge would draw the panel over the window
// frame.

// devtools_panel_renderer builds a renderer with the given geometry.
//
// The renderer is a single package-level value rather than a local or a fresh
// allocation: it is large enough that a stack copy is a real risk and that a
// per-case heap allocation shows up as a leak report, and the tests are
// single threaded, so one instance reconfigured between cases is both safe and
// free.
@(private)
devtools_panel_r: render.Renderer

devtools_panel_renderer :: proc(surface_w, surface_h: u32, cell_w, cell_h: f32, pad: f32) -> ^render.Renderer {
	r := &devtools_panel_r
	r.cell_width = cell_w
	r.cell_height = cell_h
	r.pad_x = pad
	r.pad_y = pad
	r.surface_w = surface_w
	r.surface_h = surface_h
	return r
}

@test
test_devtools_panel_rect_stays_inside_surface :: proc(t: ^testing.T) {
	anchors := [4]config.Devtools_Anchor{.Top_Right, .Top_Left, .Bottom_Right, .Bottom_Left}
	sizes := [][2]u32{{320, 240}, {640, 480}, {1280, 800}, {3840, 2160}, {80, 24}}
	offsets := [3]f32{0.0, 32.0, 64.0}
	column_counts := [3]int{0, 40, 200}

	for size in sizes {
		for anchor in anchors {
			for offset in offsets {
				for columns in column_counts {
					r := devtools_panel_renderer(size[0], size[1], 8.0, 16.0, 6.0)
					rect := render.devtools_panel_rect(r, offset, anchor, columns)

					// A surface too small to hold a card yields the empty rect
					// by design; anything else must be a real card fully inside.
					if rect.w == 0 && rect.h == 0 {
						continue
					}
					testing.expect(t, rect.w > 0)
					testing.expect(t, rect.h > 0)
					testing.expect(t, rect.x >= 0)
					testing.expect(t, rect.y >= 0)
					testing.expect(t, rect.x + rect.w <= f32(size[0]) + 0.001)
					testing.expect(t, rect.y + rect.h <= f32(size[1]) + 0.001)
				}
			}
		}
	}
}

@test
test_devtools_panel_rect_anchor_places_card :: proc(t: ^testing.T) {
	surface_w: u32 = 800
	surface_h: u32 = 600
	margin: f32 = 6.0
	offset: f32 = 32.0
	r := devtools_panel_renderer(surface_w, surface_h, 8.0, 16.0, margin)

	top_right := render.devtools_panel_rect(r, offset, .Top_Right)
	top_left := render.devtools_panel_rect(r, offset, .Top_Left)
	bottom_right := render.devtools_panel_rect(r, offset, .Bottom_Right)
	bottom_left := render.devtools_panel_rect(r, offset, .Bottom_Left)

	// The tab bar offset applies to the top anchors only; the bottom anchors
	// sit at the opposite edge of the same surface, so they are unaffected.
	testing.expect_value(t, top_right.y, offset)
	testing.expect_value(t, top_left.y, offset)
	testing.expect_value(t, bottom_right.y + bottom_right.h, f32(surface_h) - margin)
	testing.expect_value(t, bottom_left.y + bottom_left.h, f32(surface_h) - margin)

	// Right anchors hug the right margin, left anchors the left margin.
	testing.expect_value(t, top_right.x + top_right.w, f32(surface_w) - margin)
	testing.expect_value(t, bottom_right.x + bottom_right.w, f32(surface_w) - margin)
	testing.expect_value(t, top_left.x, margin)
	testing.expect_value(t, bottom_left.x, margin)
}

@test
test_devtools_panel_rect_column_fallback :: proc(t: ^testing.T) {
	surface_w: u32 = 2000
	r := devtools_panel_renderer(surface_w, 600, 8.0, 16.0, 6.0)

	// A configured width caps the panel; the render package's own constant is
	// the fallback whenever the configured value is not positive.
	fallback := render.devtools_panel_rect(r, 0.0, .Top_Right, 0)
	negative := render.devtools_panel_rect(r, 0.0, .Top_Right, -5)
	narrow := render.devtools_panel_rect(r, 0.0, .Top_Right, 20)

	testing.expect_value(t, narrow.w, 20.0 * 8.0)
	testing.expect(t, narrow.w < fallback.w)
	testing.expect_value(t, negative.w, fallback.w)
	testing.expect_value(t, fallback.w, f32(render.DEVTOOLS_PANEL_COLUMNS) * 8.0)

	// A width wider than the surface is clamped to the available width rather
	// than overflowing the edge.
	huge := render.devtools_panel_rect(r, 0.0, .Top_Right, 10000)
	testing.expect(t, huge.w > 0)
	testing.expect(t, huge.x + huge.w <= f32(surface_w))
}

@test
test_devtools_panel_rect_degenerate_geometry :: proc(t: ^testing.T) {
	surface_h: u32 = 200
	// Zero cells, zero surface and a nil renderer all degrade to the empty
	// rect: no negative or non-positive extent is reachable.
	no_cells := devtools_panel_renderer(800, 600, 0.0, 16.0, 6.0)
	empty := render.devtools_panel_rect(no_cells, 0.0, .Bottom_Left)
	testing.expect_value(t, empty.w, 0.0)
	testing.expect_value(t, empty.h, 0.0)

	no_surface := devtools_panel_renderer(0, 0, 8.0, 16.0, 6.0)
	empty_surface := render.devtools_panel_rect(no_surface, 0.0, .Bottom_Right)
	testing.expect_value(t, empty_surface.w, 0.0)
	testing.expect_value(t, empty_surface.h, 0.0)

	nil_renderer := render.devtools_panel_rect(nil, 0.0, .Top_Left)
	testing.expect_value(t, nil_renderer.x, 0.0)
	testing.expect_value(t, nil_renderer.w, 0.0)

	// An offset larger than the surface cannot push the card past the bottom.
	r := devtools_panel_renderer(400, surface_h, 8.0, 16.0, 6.0)
	overflow := render.devtools_panel_rect(r, 10_000.0, .Top_Right)
	testing.expect(t, overflow.y + overflow.h <= f32(surface_h))
}
