package tabs

// Automated Unit Tests for Chrome Tabs Declarative Geometry Engine.
// Verifies tab model lifecycle, active tracking, close button geometry,
// empty state, overflow clamping, rapid churn, and zero memory leaks.

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"
import "../draw_list"

@test
test_tabs_lifecycle_and_active_tracking :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)

	bar_rect: [4]f32 = {0, 0, 800, 36}
	m: Chrome_Tabs_Model
	tabs_model_init(&m, bar_rect, alloc)
	defer tabs_model_destroy(&m)

	testing.expect_value(t, len(m.tabs), 0)
	testing.expect_value(t, m.active_idx, -1)

	// First tab added becomes active
	idx0 := tabs_add(&m, 10, "tab 0")
	testing.expect_value(t, idx0, 0)
	testing.expect_value(t, m.active_idx, 0)
	testing.expect(t, m.tabs[0].active)

	// Second tab added does not steal active index
	idx1 := tabs_add(&m, 20, "tab 1")
	testing.expect_value(t, idx1, 1)
	testing.expect_value(t, m.active_idx, 0)
	testing.expect(t, !m.tabs[1].active)

	// Explicitly switch active tab to 1
	ok := tabs_set_active(&m, 1)
	testing.expect(t, ok)
	testing.expect_value(t, m.active_idx, 1)
	testing.expect(t, !m.tabs[0].active)
	testing.expect(t, m.tabs[1].active)

	// Add third tab
	idx2 := tabs_add(&m, 30, "tab 2")
	testing.expect_value(t, idx2, 2)
	testing.expect_value(t, len(m.tabs), 3)

	// Remove active tab (idx 1): tab 2 should now become active or idx 1 kept
	removed := tabs_remove(&m, 1)
	testing.expect(t, removed)
	testing.expect_value(t, len(m.tabs), 2)
	testing.expect_value(t, m.active_idx, 1)
	testing.expect(t, m.tabs[m.active_idx].active)

	// Remove last tab: active_idx should clamp to new end
	removed = tabs_remove(&m, 1)
	testing.expect(t, removed)
	testing.expect_value(t, len(m.tabs), 1)
	testing.expect_value(t, m.active_idx, 0)
	testing.expect(t, m.tabs[0].active)

	// Remove final tab: active_idx should reset to -1
	removed = tabs_remove(&m, 0)
	testing.expect(t, removed)
	testing.expect_value(t, len(m.tabs), 0)
	testing.expect_value(t, m.active_idx, -1)

	// Invalid remove returns false
	testing.expect(t, !tabs_remove(&m, 0))
	testing.expect(t, !tabs_remove(&m, -1))

	tabs_model_destroy(&m)
	testing.expect_value(t, track.current_memory_allocated, 0)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@test
test_tabs_close_rect_math :: proc(t: ^testing.T) {
	bar_rect: [4]f32 = {100.0, 50.0, 800.0, 40.0}
	m: Chrome_Tabs_Model
	tabs_model_init(&m, bar_rect)
	defer tabs_model_destroy(&m)

	tabs_add(&m, 1, "Tab A")
	tabs_add(&m, 2, "Tab B")

	dl: draw_list.Ui_Draw_List
	draw_list.ui_draw_list_init(&dl)
	defer draw_list.ui_draw_list_destroy(&dl)

	tabs_emit_draw_list(&m, &dl)

	// Total width 800 for 2 tabs -> min(220, 800 / 2) = 220
	tab_w: f32 = 220.0
	tab_h: f32 = 40.0
	close_size: f32 = 14.0

	for i in 0..<2 {
		cur_x := 100.0 + f32(i) * tab_w
		testing.expect_value(t, m.tabs[i].rect[0], cur_x)
		testing.expect_value(t, m.tabs[i].rect[1], 50.0)
		testing.expect_value(t, m.tabs[i].rect[2], tab_w)
		testing.expect_value(t, m.tabs[i].rect[3], tab_h)

		expected_close_x := cur_x + tab_w - close_size - 8.0
		expected_close_y := 50.0 + (tab_h - close_size) * 0.5
		testing.expect_value(t, m.tabs[i].close_rect[0], expected_close_x)
		testing.expect_value(t, m.tabs[i].close_rect[1], expected_close_y)
		testing.expect_value(t, m.tabs[i].close_rect[2], close_size)
		testing.expect_value(t, m.tabs[i].close_rect[3], close_size)

		// Close rect must be completely inside the tab rect
		testing.expect(t, m.tabs[i].close_rect[0] >= m.tabs[i].rect[0])
		testing.expect(t, m.tabs[i].close_rect[0] + close_size <= m.tabs[i].rect[0] + tab_w)
		testing.expect(t, m.tabs[i].close_rect[1] >= m.tabs[i].rect[1])
		testing.expect(t, m.tabs[i].close_rect[1] + close_size <= m.tabs[i].rect[1] + tab_h)
	}
}

@test
test_tabs_empty_state_layout :: proc(t: ^testing.T) {
	bar_rect: [4]f32 = {0.0, 0.0, 1000.0, 32.0}
	m: Chrome_Tabs_Model
	tabs_model_init(&m, bar_rect)
	defer tabs_model_destroy(&m)

	dl: draw_list.Ui_Draw_List
	draw_list.ui_draw_list_init(&dl)
	defer draw_list.ui_draw_list_destroy(&dl)

	tabs_emit_draw_list(&m, &dl)

	// Empty state emits exactly 1 command: the tab bar background
	testing.expect_value(t, len(dl.commands), 1)
	testing.expect_value(t, dl.commands[0].kind, draw_list.Ui_Cmd_Kind.Rect)
	testing.expect_value(t, dl.commands[0].rect, bar_rect)
}

@test
test_tabs_128_overflow_layout :: proc(t: ^testing.T) {
	bar_w: f32 = 1280.0
	bar_rect: [4]f32 = {0.0, 0.0, bar_w, 36.0}
	m: Chrome_Tabs_Model
	tabs_model_init(&m, bar_rect)
	defer tabs_model_destroy(&m)

	count := 128
	for i in 0..<count {
		tabs_add(&m, u32(i + 1), "t")
	}
	testing.expect_value(t, len(m.tabs), count)

	dl: draw_list.Ui_Draw_List
	draw_list.ui_draw_list_init(&dl)
	defer draw_list.ui_draw_list_destroy(&dl)

	tabs_emit_draw_list(&m, &dl)

	// Each tab width is clamped to bar_w / count = 1280 / 128 = 10.0
	expected_w: f32 = bar_w / f32(count)
	for i in 0..<count {
		tab := &m.tabs[i]
		testing.expect_value(t, tab.rect[2], expected_w)
		testing.expect(t, tab.rect[0] + tab.rect[2] <= bar_w + 0.01)
	}
}

@test
test_tabs_rapid_churn_zero_leak :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)

	m: Chrome_Tabs_Model
	tabs_model_init(&m, {0, 0, 1000, 36}, alloc)
	defer tabs_model_destroy(&m)

	// 10,000 add and remove operations
	for i in 0..<10_000 {
		tabs_add(&m, u32(i), "churn")
		if len(m.tabs) > 8 {
			tabs_remove(&m, 0)
		}
	}

	for len(m.tabs) > 0 {
		tabs_remove(&m, 0)
	}
	testing.expect_value(t, len(m.tabs), 0)

	tabs_model_destroy(&m)
	testing.expect_value(t, track.current_memory_allocated, 0)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@test
test_tabs_preview_fixtures :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)

	dl: draw_list.Ui_Draw_List
	draw_list.ui_draw_list_init(&dl, alloc)
	defer draw_list.ui_draw_list_destroy(&dl)

	// Normal preview
	preview_tabs_normal(&dl, {0, 0, 800, 36})
	testing.expect(t, len(dl.commands) > 0)

	draw_list.ui_draw_list_clear(&dl)

	// Extreme preview
	preview_tabs_extreme(&dl, {0, 0, 1200, 36}, 128)
	testing.expect(t, len(dl.commands) > 0)

	draw_list.ui_draw_list_destroy(&dl)
	testing.expect_value(t, track.current_memory_allocated, 0)
}

@test
test_tabs_extreme_title_roundtrip_and_zero_alloc_emit :: proc(t: ^testing.T) {
	TAB_COUNT :: 128
	ITERATIONS :: 1_000

	title := preview_tabs_extreme_title()
	testing.expect_value(t, utf8.rune_count_in_string(title), PREVIEW_TABS_EXTREME_TITLE_RUNES)
	testing.expect(t, strings.contains(title, "\u200d"))
	testing.expect(t, strings.contains(title, "\u0301"))

	// Build tab-N titles once, before any measured loop
	extra_titles := make([]string, TAB_COUNT - 1, context.temp_allocator)
	for i in 0..<len(extra_titles) {
		extra_titles[i] = fmt.tprintf("tab-%d", i + 1)
	}

	m: Chrome_Tabs_Model
	tabs_model_init(&m, {0.0, 0.0, 1200.0, 36.0})
	defer tabs_model_destroy(&m)

	tabs_add(&m, 1, title)
	for s, i in extra_titles {
		tabs_add(&m, u32(i + 2), s)
	}
	testing.expect_value(t, len(m.tabs), TAB_COUNT)

	dl: draw_list.Ui_Draw_List
	draw_list.ui_draw_list_init(&dl)
	defer draw_list.ui_draw_list_destroy(&dl)

	// Warmup grows command capacity to steady state
	tabs_emit_draw_list(&m, &dl)
	draw_list.ui_draw_list_clear(&dl)

	heap_track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&heap_track, context.allocator)
	defer mem.tracking_allocator_destroy(&heap_track)

	temp_track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&temp_track, context.temp_allocator)
	defer mem.tracking_allocator_destroy(&temp_track)

	{
		context.allocator = mem.tracking_allocator(&heap_track)
		context.temp_allocator = mem.tracking_allocator(&temp_track)

		for _ in 0..<ITERATIONS {
			draw_list.ui_draw_list_clear(&dl)
			tabs_emit_draw_list(&m, &dl)
		}
	}

	testing.expect_value(t, heap_track.total_allocation_count, 0)
	testing.expect_value(t, temp_track.total_allocation_count, 0)

	// First Text_Run belongs to tab 0
	found := false
	for cmd in dl.commands {
		if cmd.kind == .Text_Run {
			testing.expect(t, cmd.text == title)
			found = true
			break
		}
	}
	testing.expect(t, found)
}
