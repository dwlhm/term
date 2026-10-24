package term

import "core:math"
import "core:testing"
import chrome_dl "../../core/chrome/draw_list"

@test
test_escape_shell_path :: proc(t: ^testing.T) {
	// 1. Empty string
	testing.expect_value(t, escape_shell_path(""), "")

	// 2. Simple clean path
	clean := escape_shell_path("/usr/local/bin/term")
	defer delete(clean)
	testing.expect_value(t, clean, "/usr/local/bin/term ")

	// 3. Path with spaces
	spaced := escape_shell_path("/Users/user/My Documents/file.pdf")
	defer delete(spaced)
	testing.expect_value(t, spaced, "/Users/user/My\\ Documents/file.pdf ")

	// 4. Path with brackets, parentheses, quotes
	complex_path := escape_shell_path("/tmp/test (1) [final] & 'special'.txt")
	defer delete(complex_path)
	testing.expect_value(t, complex_path, "/tmp/test\\ \\(1\\)\\ \\[final\\]\\ \\&\\ \\'special\\'.txt ")
}

@test
test_drop_wake_interpolation :: proc(t: ^testing.T) {
	state: Drop_Effect_State
	drop_effect_init(&state)
	pane_rect := [4]f32{0.0, 0.0, 800.0, 600.0}

	drop_effect_on_drag_begin(&state)
	drop_effect_on_drag_pos(&state, {100.0, 100.0}, 1, pane_rect)
	drop_effect_on_drag_pos(&state, {250.0, 100.0}, 1, pane_rect)

	active_waves := 0
	for w in state.splashes do if w.active do active_waves += 1
	testing.expect(t, active_waves >= 3, "Wakes should be interpolated along drag motion path")
}

@test
test_drop_effect_lifecycle_and_idle :: proc(t: ^testing.T) {
	state: Drop_Effect_State
	drop_effect_init(&state)

	// Initially idle
	testing.expect(t, !drop_effect_is_active(&state), "State should start idle")

	// Start drag with continuous motion
	pane_rect := [4]f32{0.0, 0.0, 600.0, 400.0}
	drop_effect_on_drag_begin(&state)
	for i in 0..<15 {
		drop_effect_on_drag_pos(&state, {200.0 + f32(i) * 10.0, 200.0}, 1, pane_rect)
		drop_effect_update(&state, 0.020)
	}
	testing.expect(t, drop_effect_is_active(&state), "State should be active while dragging")

	// Trigger drop: should spawn impact wave at drop pos and enter smooth exit
	drop_effect_on_drop(&state, {350.0, 200.0}, 1, pane_rect)
	testing.expect(t, !state.is_dragging, "is_dragging should be false after drop")
	testing.expect(t, state.is_exiting, "is_exiting should be true after drop")
	testing.expect(t, state.exit_fade_t == 1.0, "exit_fade_t should start at 1.0")
	testing.expect(t, state.impact_emitted, "Impact wave should be emitted on drop")
	testing.expect(t, drop_effect_is_active(&state), "State should remain active during wave propagation")

	time_before := state.splashes[0].time

	// Midway through exit transition (160ms)
	for _ in 0..<8 {
		drop_effect_update(&state, 0.020)
	}
	testing.expect(t, state.is_exiting, "State should still be exiting midway")
	testing.expect(t, state.exit_fade_t > 0.3 && state.exit_fade_t < 0.7, "exit_fade_t should be midway")
	testing.expect(t, state.splashes[0].time > time_before, "Wavefront must propagate freely, not freeze in place")
	testing.expect(t, drop_effect_is_active(&state), "State should remain active while ripples propagate")

	// Advance beyond entire impact lifetime (2.4s = 120 ticks of 20ms)
	for _ in 0..<130 {
		drop_effect_update(&state, 0.020)
	}
	// One final tick flushes the clean frame and transitions cleanly to idle
	drop_effect_update(&state, 0.020)
	testing.expect(t, !state.is_exiting, "is_exiting should become false after all waves dissipate")
	testing.expect(t, !drop_effect_is_active(&state), "State should return to idle after flush completes")
}

@test
test_drop_effect_impact_spawn :: proc(t: ^testing.T) {
	state: Drop_Effect_State
	drop_effect_init(&state)
	pane_rect := [4]f32{0.0, 0.0, 600.0, 400.0}

	drop_effect_on_drag_begin(&state)
	drop_effect_on_drag_pos(&state, {200.0, 200.0}, 1, pane_rect)
	drop_effect_on_drop(&state, {420.0, 310.0}, 1, pane_rect)

	has_impact := false
	for w in state.splashes {
		if w.active && w.strength >= 1.0 && math.abs(w.x - 420.0) < 0.1 && math.abs(w.y - 310.0) < 0.1 {
			has_impact = true
			break
		}
	}
	testing.expect(t, has_impact, "Drop impact splash must be spawned at drop coordinates with full strength")
}

@test
test_drop_effect_emit_draw_list :: proc(t: ^testing.T) {
	state: Drop_Effect_State
	drop_effect_init(&state)
	pane_rect := [4]f32{0.0, 0.0, 600.0, 400.0}
	drop_effect_on_drag_begin(&state)
	for i in 0..<15 {
		drop_effect_on_drag_pos(&state, {200.0 + f32(i) * 10.0, 200.0}, 1, pane_rect)
		drop_effect_update(&state, 0.020)
	}
	drop_effect_on_drop(&state, {350.0, 200.0}, 1, pane_rect)

	dl: chrome_dl.Ui_Draw_List
	chrome_dl.ui_draw_list_init(&dl)
	defer chrome_dl.ui_draw_list_destroy(&dl)

	drop_effect_emit_draw_list(&state, &dl, 600.0, 400.0, 1.0)
	testing.expect(t, len(dl.commands) >= 2, "Draw list should contain water surface master quad and wave record")
}
