package draw_list

// Automated Unit Tests for Ui_Draw_List Declarative Geometry Engine.
// Verifies command lifecycle, clear-without-capacity-drop, zero steady-state allocation,
// nil safety, and zero memory leaks via Tracking_Allocator.

import "core:mem"
import "core:testing"

@test
test_draw_list_lifecycle_and_primitives :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)

	dl: Ui_Draw_List
	ui_draw_list_init(&dl, alloc)
	defer ui_draw_list_destroy(&dl)

	testing.expect_value(t, len(dl.commands), 0)
	testing.expect_value(t, cap(dl.commands), 0)

	// Append Rect
	ui_draw_rect(&dl, {10, 10, 100, 50}, {1, 0, 0, 1})
	testing.expect_value(t, len(dl.commands), 1)
	testing.expect_value(t, dl.commands[0].kind, Ui_Cmd_Kind.Rect)
	testing.expect_value(t, dl.commands[0].rect, [4]f32{10, 10, 100, 50})
	testing.expect_value(t, dl.commands[0].color, [4]f32{1, 0, 0, 1})

	// Append Rounded_Rect
	ui_draw_rounded_rect(&dl, {20, 20, 80, 40}, {0, 1, 0, 1}, 4.0)
	testing.expect_value(t, len(dl.commands), 2)
	testing.expect_value(t, dl.commands[1].kind, Ui_Cmd_Kind.Rounded_Rect)
	testing.expect_value(t, dl.commands[1].radius, f32(4.0))

	// Append Border
	ui_draw_border(&dl, {30, 30, 60, 30}, {0, 0, 1, 1}, 2.0)
	testing.expect_value(t, len(dl.commands), 3)
	testing.expect_value(t, dl.commands[2].kind, Ui_Cmd_Kind.Border)
	testing.expect_value(t, dl.commands[2].border_color, [4]f32{0, 0, 1, 1})

	// Append Text_Run
	ui_draw_text(&dl, {40, 40, 120, 20}, "hello", {1, 1, 1, 1})
	testing.expect_value(t, len(dl.commands), 4)
	testing.expect_value(t, dl.commands[3].kind, Ui_Cmd_Kind.Text_Run)
	testing.expect_value(t, dl.commands[3].text, "hello")

	// Append Shadow
	ui_draw_shadow(&dl, {50, 50, 100, 50}, {0, 0, 0, 0.5}, 8.0)
	testing.expect_value(t, len(dl.commands), 5)
	testing.expect_value(t, dl.commands[4].kind, Ui_Cmd_Kind.Shadow)
	testing.expect_value(t, dl.commands[4].radius, f32(8.0))

	// Test clear without capacity drop
	cap_before := cap(dl.commands)
	testing.expect(t, cap_before >= 5, "Capacity should accommodate 5 elements")
	ui_draw_list_clear(&dl)
	testing.expect_value(t, len(dl.commands), 0)
	testing.expect_value(t, cap(dl.commands), cap_before)

	// Destroy and verify zero leak
	ui_draw_list_destroy(&dl)
	testing.expect_value(t, len(dl.commands), 0)
	testing.expect(t, dl.commands == nil, "Commands slice should be nil after destroy")
	testing.expect_value(t, track.current_memory_allocated, 0)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@test
test_draw_list_zero_allocation_on_reuse :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)

	dl: Ui_Draw_List
	ui_draw_list_init(&dl, alloc)
	defer ui_draw_list_destroy(&dl)

	// Populate initial capacity
	for i in 0..<16 {
		ui_draw_rect(&dl, {f32(i), 0, 10, 10}, {1, 1, 1, 1})
	}
	testing.expect_value(t, len(dl.commands), 16)
	cap_established := cap(dl.commands)

	// Clear retains capacity
	ui_draw_list_clear(&dl)
	testing.expect_value(t, len(dl.commands), 0)
	testing.expect_value(t, cap(dl.commands), cap_established)

	// Steady-state reuse: adding commands within capacity must perform ZERO new allocations
	total_alloc_before := track.total_memory_allocated
	for i in 0..<16 {
		ui_draw_rect(&dl, {f32(i * 2), 0, 10, 10}, {0.5, 0.5, 0.5, 1})
	}
	testing.expect_value(t, len(dl.commands), 16)
	testing.expect_value(t, track.total_memory_allocated, total_alloc_before)

	ui_draw_list_destroy(&dl)
	testing.expect_value(t, track.current_memory_allocated, 0)
}

@test
test_draw_list_preview_sample_coverage :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)

	dl: Ui_Draw_List
	ui_draw_list_init(&dl, alloc)
	defer ui_draw_list_destroy(&dl)

	preview_draw_list_sample(&dl)
	// 5 primitives * 2 (unclipped and clipped) = 10 commands
	testing.expect_value(t, len(dl.commands), 10)

	has_rect := false
	has_rounded_rect := false
	has_border := false
	has_text := false
	has_shadow := false
	clipped_count := 0

	for cmd in dl.commands {
		switch cmd.kind {
		case .Rect:         has_rect = true
		case .Rounded_Rect: has_rounded_rect = true
		case .Border:       has_border = true
		case .Text_Run:     has_text = true
		case .Shadow:       has_shadow = true
		case .Icon:
		}
		if cmd.clip_rect != {} {
			clipped_count += 1
		}
	}

	testing.expect(t, has_rect, "Must contain Rect command")
	testing.expect(t, has_rounded_rect, "Must contain Rounded_Rect command")
	testing.expect(t, has_border, "Must contain Border command")
	testing.expect(t, has_text, "Must contain Text_Run command")
	testing.expect(t, has_shadow, "Must contain Shadow command")
	testing.expect_value(t, clipped_count, 5)

	ui_draw_list_destroy(&dl)
	testing.expect_value(t, track.current_memory_allocated, 0)
}

@test
test_draw_list_nil_guards :: proc(t: ^testing.T) {
	// None of these procedures should crash when passed nil
	ui_draw_list_init(nil)
	ui_draw_list_destroy(nil)
	ui_draw_list_clear(nil)
	ui_draw_rect(nil, {0, 0, 10, 10}, {1, 1, 1, 1})
	ui_draw_rounded_rect(nil, {0, 0, 10, 10}, {1, 1, 1, 1}, 2.0)
	ui_draw_border(nil, {0, 0, 10, 10}, {1, 1, 1, 1}, 2.0)
	ui_draw_text(nil, {0, 0, 10, 10}, "test", {1, 1, 1, 1})
	ui_draw_shadow(nil, {0, 0, 10, 10}, {0, 0, 0, 1}, 4.0)
	preview_draw_list_sample(nil)
	testing.expect(t, true, "Nil guards succeeded")
}
