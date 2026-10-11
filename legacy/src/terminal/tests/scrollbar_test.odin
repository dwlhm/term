package termgrid_test

import "core:testing"
import tg "../"

@(test)
test_scrollbar_init :: proc(t: ^testing.T) {
	sb: tg.Scrollbar
	tg.scrollbar_init(&sb)
	testing.expect_value(t, sb.visible, false)
	testing.expect_value(t, sb.is_dragging, false)
	testing.expect_value(t, sb.total_lines, 0)
	testing.expect_value(t, sb.visible_lines, 0)
	testing.expect_value(t, sb.offset, 0)
}

@(test)
test_scrollbar_update_visibility :: proc(t: ^testing.T) {
	sb: tg.Scrollbar
	tg.scrollbar_init(&sb)

	// No scrollback lines: visible should be false
	tg.scrollbar_update(&sb, 24, 24, 0, 800, 600)
	testing.expect_value(t, sb.visible, false)

	// With scrollback lines: visible should be true
	tg.scrollbar_update(&sb, 100, 24, 0, 800, 600)
	testing.expect_value(t, sb.visible, true)
	testing.expect_value(t, sb.track_rect[0], 800 - tg.SCROLLBAR_WIDTH)
	testing.expect_value(t, sb.track_rect[1], f32(0))
	testing.expect_value(t, sb.track_rect[2], tg.SCROLLBAR_WIDTH)
	testing.expect_value(t, sb.track_rect[3], f32(600))
}

@(test)
test_scrollbar_hit_test_and_drag :: proc(t: ^testing.T) {
	sb: tg.Scrollbar
	tg.scrollbar_init(&sb)

	// 100 total lines, 20 visible lines, 80 scrollback lines
	// viewport 1000px height
	tg.scrollbar_update(&sb, 100, 20, 0, 800, 1000)
	testing.expect_value(t, sb.visible, true)

	// Thumb height = 1000 * (20 / 100) = 200px
	testing.expect_value(t, sb.thumb_rect[3], f32(200))
	// When offset = 0 (bottom), thumb is at bottom (y = 800)
	testing.expect_value(t, sb.thumb_rect[1], f32(800))

	// Hit test outside
	hit_thumb, hit_track := tg.scrollbar_hit_test(&sb, 100, 500)
	testing.expect(t, !hit_thumb && !hit_track)

	// Hit test on track (above thumb, y = 500)
	hit_thumb, hit_track = tg.scrollbar_hit_test(&sb, 795, 500)
	testing.expect(t, !hit_thumb && hit_track)

	// Hit test on thumb (y = 850)
	hit_thumb, hit_track = tg.scrollbar_hit_test(&sb, 795, 850)
	testing.expect(t, hit_thumb && hit_track)

	// Simulate drag from y = 850 (offset = 0) up to y = 450 (halfway, available_track = 800)
	sb.is_dragging = true
	sb.drag_start_y = 850
	sb.drag_start_offset = 0
	new_offset := tg.scrollbar_drag(&sb, 450)
	// dy = -400, max_offset = 80. delta = (-400 / 800) * 80 = -40. new_offset = 0 - (-40) = 40
	testing.expect_value(t, new_offset, 40)

	// Drag to top (y = 50)
	new_offset = tg.scrollbar_drag(&sb, 50)
	testing.expect_value(t, new_offset, 80)
}

@(test)
test_terminal_search_standalone :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 4, 16)
	defer tg.terminal_destroy(&term)

	// Write "hello world" on row 0
	row0 := term.grid.rows[0].cells
	text := "hello world"
	for ch, i in text {
		if i < len(row0) {
			row0[i] = tg.Semantic_Cell{content = tg.Content_Handle(ch), width = 1}
		}
	}

	matches: [16]tg.Search_Match
	count := tg.terminal_search(&term, "hello", matches[:])
	testing.expect_value(t, count, 1)
	testing.expect_value(t, matches[0].col_start, 0)
	testing.expect_value(t, matches[0].col_end, 4)

	count = tg.terminal_search(&term, "world", matches[:])
	testing.expect_value(t, count, 1)
	testing.expect_value(t, matches[0].col_start, 6)
	testing.expect_value(t, matches[0].col_end, 10)

	count = tg.terminal_search(&term, "nonexistent", matches[:])
	testing.expect_value(t, count, 0)
}
