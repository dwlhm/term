package app_test

import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

import app "../"
import input "../../platform/input"
import posix "core:sys/posix"
import termgrid "../../terminal"

import pty "../../platform/pty"
import probe "../../bench/probe"

@(test)
test_profile_failure_reasons_are_actionable :: proc(t: ^testing.T) {
	testing.expect(t, app.profile_failure_reason_name(.Window_Size_Timeout) == "window_size_timeout", "window resize timeout is classified")
	testing.expect(t, app.profile_failure_reason_name(.Grid_Size_Timeout) == "grid_size_timeout", "grid convergence timeout is classified")
	testing.expect(t, app.profile_failure_reason_name(.Grid_Change_Missing) == "grid_change_missing", "missing grid change is classified")
}

@(test)
test_profile_scenario_deadline_and_command_events :: proc(t: ^testing.T) {
	scenario := app.Profile_Scenario{}
	testing.expect(t, app.profile_scenario_init(&scenario, 41, 100), "scenario initializes")
	testing.expect(t, app.profile_scenario_next(&scenario, 100) == .Prepare, "echo preparation precedes command submission")
	scenario.echo_prepared = true
	testing.expect(t, app.profile_scenario_next(&scenario, 100) == .Submit_Command, "command submits once echo is prepared")
	prep_evs: [16]input.Input_Event
	m := app.profile_scenario_prepare_events(prep_evs[:])
	testing.expect(t, m >= 11, "echo preparation emits at least ten printable events plus Enter")
	testing.expect(t, prep_evs[0].kind == .Printable && prep_evs[0].rune == 's', "echo preparation leads with stty")
	testing.expect(t, prep_evs[m-1].kind == .Enter, "echo preparation is terminated with Enter")
	events: [256]input.Input_Event
	n := app.profile_scenario_command_events(&scenario, events[:])
	testing.expect(t, n > 1, "scenario emits ordinary key events")
	testing.expect(t, n >= 3 && events[0].kind == .Printable && events[0].rune == 'l' && events[1].kind == .Printable && events[1].rune == 's', "command leads with ls")
	command: [192]u8
	command_len := 0
	for i in 0..<n-1 {
		if events[i].kind == .Printable && events[i].rune != '\'' {
			command[command_len] = u8(events[i].rune)
			command_len += 1
		}
	}
	command_text := string(command[:command_len])
	testing.expect(t, strings.has_prefix(command_text, "ls"), "command starts with ls")
	testing.expect(t, strings.contains(command_text, "PROFILE_DONE_%s"), "command carries the printf format placeholder")
	testing.expect(t, strings.contains(command_text, "41"), "command carries the scenario id digits")
	testing.expect(t, !strings.contains(command_text, "PROFILE_DONE_41"), "command id stays non-contiguous with the done marker")
	testing.expect(t, !strings.contains(command_text, "seq"), "command omits seq when scrollback is disabled")
	testing.expect(t, events[n-1].kind == .Enter, "command is terminated with Enter")

	scenario.scrollback_lines = 2000
	seq_events: [256]input.Input_Event
	sn := app.profile_scenario_command_events(&scenario, seq_events[:])
	seq_command: [192]u8
	seq_command_len := 0
	for i in 0..<sn-1 {
		if seq_events[i].kind == .Printable && seq_events[i].rune != '\'' {
			seq_command[seq_command_len] = u8(seq_events[i].rune)
			seq_command_len += 1
		}
	}
	seq_text := string(seq_command[:seq_command_len])
	testing.expect(t, strings.contains(seq_text, "seq 1 2000"), "command emits seq for configured scrollback depth")
	testing.expect(t, strings.contains(seq_text, "PROFILE_DONE_%s"), "command still carries the printf marker with seq")
	testing.expect(t, seq_events[sn-1].kind == .Enter, "seq command is terminated with Enter")

	testing.expect(t, app.profile_scenario_next(&scenario, scenario.phase_deadline_ns) == .Fail, "deadline fails rather than inferring a phase")
	testing.expect(t, scenario.phase == .Failed, "deadline marks scenario invalid")
}

@(test)
test_profile_scenario_ladder_targets :: proc(t: ^testing.T) {
	initial_w, initial_h := i32(680), i32(480)
	percents := app.PROFILE_LADDER_PERCENTS
	width_expect := [6][2]i32{{340, 480}, {476, 480}, {272, 480}, {612, 480}, {204, 480}, {680, 480}}
	height_expect := [6][2]i32{{680, 240}, {680, 336}, {680, 192}, {680, 432}, {680, 144}, {680, 480}}
	for step in 0..<6 {
		w, h, ok := app.profile_scenario_ladder_target(initial_w, initial_h, step)
		expected_w := i32(f64(initial_w) * f64(percents[step % 6]) / 100.0 + 0.5)
		testing.expect(t, ok, "width ladder step is valid")
		testing.expect(t, w == width_expect[step][0], "width ladder target matches the acceptance table")
		testing.expect(t, w == expected_w, "width ladder target matches the rounding formula")
		testing.expect(t, h == initial_h, "width ladder keeps the initial height")
	}
	for step in 6..<12 {
		w, h, ok := app.profile_scenario_ladder_target(initial_w, initial_h, step)
		expected_h := i32(f64(initial_h) * f64(percents[step % 6]) / 100.0 + 0.5)
		testing.expect(t, ok, "height ladder step is valid")
		testing.expect(t, h == height_expect[step-6][1], "height ladder target matches the acceptance table")
		testing.expect(t, h == expected_h, "height ladder target matches the rounding formula")
		testing.expect(t, w == initial_w, "height ladder keeps the initial width")
	}
	_, _, ok := app.profile_scenario_ladder_target(initial_w, initial_h, -1)
	testing.expect(t, !ok, "negative step is rejected")
	_, _, ok = app.profile_scenario_ladder_target(initial_w, initial_h, 12)
	testing.expect(t, !ok, "out-of-range step is rejected")
	_, _, ok = app.profile_scenario_ladder_target(0, 480, 0)
	testing.expect(t, !ok, "zero initial width is rejected")
	_, _, ok = app.profile_scenario_ladder_target(680, 0, 0)
	testing.expect(t, !ok, "zero initial height is rejected")
	_, _, ok = app.profile_scenario_ladder_target(-1, 480, 0)
	testing.expect(t, !ok, "negative initial width is rejected")
}

@(test)
test_profile_scenario_drag_target_and_next :: proc(t: ^testing.T) {
	scenario := app.Profile_Scenario{}
	testing.expect(t, app.profile_scenario_init(&scenario, 41, 100), "scenario initializes")
	scenario.drag_enabled = true
	scenario.phase = .Complete
	for step in 0..<app.PROFILE_DRAG_STEPS {
		testing.expect(t, app.profile_scenario_next(&scenario, 200) == .Drag_Resize, "complete drag scenario requests a drag resize")
		w, h, ok := app.profile_scenario_drag_target(1280, 768, step, app.PROFILE_DRAG_STEPS)
		testing.expect(t, ok, "drag target step is valid")
		testing.expect(t, w >= 512 && w <= 1280, "drag width stays within 40%..100% of initial")
		testing.expect(t, h == 768, "drag keeps the initial height")
		scenario.drag_step += 1
	}
	testing.expect(t, app.profile_scenario_next(&scenario, 200) == .Stop, "scenario stops after the drag ladder completes")
	_, _, ok := app.profile_scenario_drag_target(0, 768, 0, 90)
	testing.expect(t, !ok, "zero initial width is rejected")
	_, _, ok = app.profile_scenario_drag_target(1280, 768, 90, 90)
	testing.expect(t, !ok, "out-of-range step is rejected")
}

// _fd_open reports whether the given fd slot is open, so tests can detect
// suite-order hazards where an earlier test closed a stdio fd (the pty
// master then collides with it during spawn).
_fd_open :: proc(fd: int) -> bool {
	return posix.fcntl(posix.FD(fd), .GETFD) != -1 || posix.errno() != .EBADF
}

// _grid_nonblank_count counts cells carrying content so tests can detect
// listing output entering the grid without depending on specific filenames.
_grid_nonblank_count :: proc(t: ^termgrid.Terminal) -> int {
	count := 0
	for row in 0..<t.grid.row_count {
		for col in 0..<t.grid.col_count {
			if termgrid.terminal_get_cell(t, row, col).content != 0 {
				count += 1
			}
		}
	}
	return count
}

@(test)
test_profile_scenario_ls_then_resize_ladder :: proc(t: ^testing.T) {
	a := new(app.App)
	defer free(a)
	_bare_app(a)
	defer _bare_destroy(a)
	defer _s15_renderer_teardown(a)
	// Suite-order guard: an earlier test may leave a stdio fd closed, and
	// posix_openpt would then hand the pty master that slot (the spawn's
	// child closes the master after dup2 and takes its own stdio with it,
	// killing the shell at startup). Re-open closed stdio slots onto
	// /dev/null so the master always lands above fd 2.
	for fd in 0..<3 {
		if !_fd_open(fd) {
			_ = posix.open("/dev/null", {.RDWR})
		}
	}
	if !pty.pty_spawn(&a.pty, APP_TEST_ROWS, APP_TEST_COLS, "/bin/sh", {}) {
		testing.expect(t, false, "profile ladder test shell starts")
		return
	}
	defer _e2e_teardown(&a.pty)

	echo_off := "stty -echo\n"
	testing.expect(t, pty.pty_write(&a.pty, transmute([]u8)echo_off), "shell disables PTY echo before marker command")
	time.sleep(20 * time.Millisecond)
	base_count := _grid_nonblank_count(&a.terminal)
	command := "ls; printf 'PROFILE_DONE_41\\n'\n"
	testing.expect(t, pty.pty_write(&a.pty, transmute([]u8)command), "shell lists directory and emits completion marker through PTY")

	scenario := app.Profile_Scenario{}
	testing.expect(t, app.profile_scenario_init(&scenario, 41, 1), "scenario initializes for marker scan")
	scenario.phase = .Running
	scenario.phase_deadline_ns = 60_000_000_000

	listing_seen := false
	done_seen := false
	for _ in 0..<200 {
		_ = app.app_frame(a)
		if !listing_seen && _grid_nonblank_count(&a.terminal) > base_count {
			listing_seen = true
		}
		if app.profile_scenario_observe_terminal(&scenario, &a.terminal, 2) == .Advance && scenario.phase == .Complete {
			done_seen = true
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	if !listing_seen || !done_seen { _e2e_dump_grid(&a.terminal) }
	testing.expect(t, listing_seen, "ls listing enters the grid before any resize")
	testing.expect(t, done_seen, "done marker completes the scenario with advance")

	initial_w := i32(APP_TEST_COLS * app.APP_CELL_W)
	initial_h := i32(APP_TEST_ROWS * app.APP_CELL_H)
	for step in 0..<12 {
		if app.profile_scenario_next(&scenario, 5) != .Resize {
			testing.expect(t, false, "complete scenario requests a resize until the ladder is exhausted")
			return
		}
		target_w, target_h, ok := app.profile_scenario_ladder_target(initial_w, initial_h, step)
		if !ok {
			testing.expectf(t, false, "ladder step %d must have a valid target", step)
			return
		}
		if !app.app_on_resize(a, target_w, target_h) {
			testing.expectf(t, false, "ladder step %d (%d, %d) must resize", step, target_w, target_h)
			return
		}
		testing.expect(t, app.profile_scenario_step_done(&scenario), "ladder step advances")
		if step == 5 {
			testing.expect(t, a.terminal.grid.col_count == APP_TEST_COLS && a.terminal.grid.row_count == APP_TEST_ROWS, "width ladder returns to the full-width grid")
		}
	}
	testing.expect(t, a.terminal.grid.col_count == APP_TEST_COLS && a.terminal.grid.row_count == APP_TEST_ROWS, "height ladder returns to the initial grid")
	testing.expect(t, _grid_nonblank_count(&a.terminal) > 0, "ls listing survives every reflow")
	testing.expect(t, app.profile_scenario_next(&scenario, 6) == .Stop, "scenario stops after the ladder completes")
	testing.expect(t, scenario.resize_step == 12, "scenario counted all ladder steps")
}

@(test)
test_profile_ring_counts_full_drops :: proc(t: ^testing.T) {
	ring := new(probe.Profile_Ring)
	defer free(ring)
	for i in 0..<(probe.PROFILE_RECORD_CAP + 1) {
		ok := probe.profile_try_record(ring, probe.Profile_Record{})
		if i < probe.PROFILE_RECORD_CAP {
			testing.expect(t, ok, "records fit while bounded ring has capacity")
		} else {
			testing.expect(t, !ok, "full ring drops profiler record")
		}
	}
	dropped := sync.atomic_load(&ring.dropped)
	testing.expect(t, dropped == 1, "one dropped record is counted")
}
