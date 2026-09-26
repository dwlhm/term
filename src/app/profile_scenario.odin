package main

import "core:math"
import "core:os"
import "core:strconv"
import "core:time"

import termgrid "../terminal"
import input "../platform/input"
import platform "../platform"

Profile_Phase :: enum { Idle, Running, Complete, Failed }
Profile_Scenario :: struct {
	enabled: bool,
	phase: Profile_Phase,
	phase_deadline_ns: u64,
	command_id: u64,
	resize_step: int,
	echo_prepared: bool,
	scrollback_lines: int,
	drag_enabled: bool,
	drag_step: int,
	marker_done: [40]u8,
}
Profile_Action :: enum { None, Prepare, Submit_Command, Resize, Advance, Stop, Fail, Drag_Resize }
Profile_Failure_Reason :: enum { None, Scenario_Failed, Invalid_Target, Window_Set_Failed, Window_Size_Timeout, Grid_Size_Timeout, Grid_Change_Missing, Noop_Mismatch, Telemetry_Export_Failed, Telemetry_Dropped_Records }

profile_failure_reason_name :: proc(reason: Profile_Failure_Reason) -> string {
	switch reason {
	case .None: return "none"
	case .Scenario_Failed: return "scenario_failed"
	case .Invalid_Target: return "invalid_resize_target"
	case .Window_Set_Failed: return "window_set_failed"
	case .Window_Size_Timeout: return "window_size_timeout"
	case .Grid_Size_Timeout: return "grid_size_timeout"
	case .Grid_Change_Missing: return "grid_change_missing"
	case .Noop_Mismatch: return "noop_mismatch"
	case .Telemetry_Export_Failed: return "telemetry_export_failed"
	case .Telemetry_Dropped_Records: return "telemetry_dropped_records"
	}
	return "unknown"
}

PROFILE_PHASE_TIMEOUT_NS :: u64(30_000_000_000)
PROFILE_WINDOW_RESIZE_TIMEOUT_NS :: u64(2_000_000_000)
PROFILE_LADDER_PERCENTS :: [6]i32{50, 70, 40, 90, 30, 100}
PROFILE_LADDER_STEP_COUNT :: 12
PROFILE_DRAG_STEPS :: 90

profile_scenario_init :: proc(s: ^Profile_Scenario, command_id: u64, now_ns: u64) -> bool {
	if s == nil || command_id == 0 do return false
	s^ = {}
	if value, found := os.lookup_env("TERM_PROFILE_SCROLLBACK_LINES", context.temp_allocator); found {
		if parsed, ok := strconv.parse_int(value); ok {
			s.scrollback_lines = clamp(parsed, 0, 100_000)
		}
	}
	if value, found := os.lookup_env("TERM_PROFILE_DRAG", context.temp_allocator); found {
		s.drag_enabled = value == "1"
	}
	s.enabled = true
	s.phase = .Idle
	id := command_id % 100_000_000
	if id == 0 { id = 1 }
	s.command_id = id
	profile_marker_write(s.marker_done[:], "PROFILE_DONE_", id)
	s.phase_deadline_ns = now_ns + PROFILE_PHASE_TIMEOUT_NS
	return true
}

profile_scenario_next :: proc(s: ^Profile_Scenario, now_ns: u64) -> Profile_Action {
	if s == nil || !s.enabled || s.phase == .Failed do return .Stop
	if now_ns >= s.phase_deadline_ns {
		s.phase = .Failed
		return .Fail
	}
	if s.phase == .Idle {
		if !s.echo_prepared do return .Prepare
		return .Submit_Command
	}
	if s.phase == .Complete {
		if s.drag_enabled {
			if s.drag_step < PROFILE_DRAG_STEPS do return .Drag_Resize
			return .Stop
		}
		if s.resize_step < PROFILE_LADDER_STEP_COUNT do return .Resize
		return .Stop
	}
	return .None
}

profile_scenario_observe_terminal :: proc(s: ^Profile_Scenario, terminal: ^termgrid.Terminal, now_ns: u64) -> Profile_Action {
	if s == nil || terminal == nil || !s.enabled || s.phase == .Failed do return .Stop
	if now_ns >= s.phase_deadline_ns {
		s.phase = .Failed
		return .Fail
	}
	if s.phase != .Running do return .None
	marker := s.marker_done[:]
	marker_len := 0
	for marker_len < len(marker) && marker[marker_len] != 0 { marker_len += 1 }
	if marker_len == 0 || terminal.grid.col_count <= 0 do return .None
	for row in 0..<terminal.grid.row_count {
		for start in 0..<terminal.grid.col_count {
			found := true
			check_row, check_col := row, start
			for i in 0..<marker_len {
				if check_col >= terminal.grid.col_count {
					phys := (terminal.grid.origin + check_row) & terminal.grid.mask
					if !terminal.grid.rows[phys].wrapped || check_row+1 >= terminal.grid.row_count {
						found = false
						break
					}
					check_row += 1
					check_col = 0
				}
				if u32(termgrid.terminal_get_cell(terminal, check_row, check_col).content) != u32(marker[i]) {
					found = false
					break
				}
				check_col += 1
			}
			if found {
				s.phase = .Complete
				s.phase_deadline_ns = now_ns + PROFILE_PHASE_TIMEOUT_NS
				return .Advance
			}
		}
	}
	return .None
}

profile_scenario_command_events :: proc(s: ^Profile_Scenario, out: []input.Input_Event) -> int {
	if s == nil || len(out) < 96 do return 0
	command: [192]u8
	command_len := 0
	// The typed line carries the printf format placeholder and appends the
	// id digits after the closing quote, so shell echo of the command can
	// never spell the contiguous PROFILE_DONE_<id> the observe scan looks for.
	for ch in "ls" { command[command_len] = u8(ch); command_len += 1 }
	if s.scrollback_lines > 0 {
		for ch in "; seq 1 " { command[command_len] = u8(ch); command_len += 1 }
		value := s.scrollback_lines
		digits: [20]u8
		digit_count := 0
		for value > 0 && digit_count < len(digits) {
			digits[digit_count] = u8(value % 10) + '0'
			value /= 10
			digit_count += 1
		}
		for i := digit_count-1; i >= 0; i -= 1 {
			command[command_len] = digits[i]
			command_len += 1
		}
	}
	for ch in "; printf 'PROFILE_DONE_%s\\n' " { command[command_len] = u8(ch); command_len += 1 }
	value := s.command_id
	digits: [20]u8
	digit_count := 0
	for value > 0 && digit_count < len(digits) {
		digits[digit_count] = u8(value % 10) + '0'
		value /= 10
		digit_count += 1
	}
	for i := digit_count-1; i >= 0; i -= 1 {
		command[command_len] = digits[i]
		command_len += 1
	}
	if command_len+1 > len(out) do return 0
	for i in 0..<command_len {
		out[i] = input.Input_Event{event_type = .Key, kind = .Printable, rune = rune(command[i])}
	}
	out[command_len] = input.Input_Event{event_type = .Key, kind = .Enter}
	return command_len + 1
}

profile_scenario_prepare_events :: proc(out: []input.Input_Event) -> int {
	prepare := "stty -echo"
	if len(out) < len(prepare) + 1 do return 0
	for i in 0..<len(prepare) {
		out[i] = input.Input_Event{event_type = .Key, kind = .Printable, rune = rune(prepare[i])}
	}
	out[len(prepare)] = input.Input_Event{event_type = .Key, kind = .Enter}
	return len(prepare) + 1
}

profile_scenario_ladder_target :: proc(initial_w, initial_h: i32, step: int) -> (pixel_w, pixel_h: i32, ok: bool) {
	if initial_w <= 0 || initial_h <= 0 || step < 0 || step >= PROFILE_LADDER_STEP_COUNT do return 0, 0, false
	idx := step % 6
	percents := PROFILE_LADDER_PERCENTS
	pct := percents[idx]
	if step < 6 {
		return max(1, i32(f64(initial_w) * f64(pct) / 100.0 + 0.5)), initial_h, true
	}
	return initial_w, max(1, i32(f64(initial_h) * f64(pct) / 100.0 + 0.5)), true
}

profile_scenario_drag_target :: proc(initial_w, initial_h: i32, step, total: int) -> (pixel_w, pixel_h: i32, ok: bool) {
	if initial_w <= 0 || initial_h <= 0 || total <= 0 || step < 0 || step >= total do return 0, 0, false
	phase := 2.0 * math.PI * f64(step) / f64(total)
	frac := 0.7 + 0.3 * math.sin(phase)  // sweeps width 40%..100% of initial
	pixel_w = max(1, i32(f64(initial_w) * frac + 0.5))
	pixel_h = initial_h
	return pixel_w, pixel_h, true
}

profile_scenario_step_done :: proc(s: ^Profile_Scenario) -> bool {
	if s == nil || s.resize_step >= PROFILE_LADDER_STEP_COUNT do return false
	s.resize_step += 1
	return true
}

profile_scenario_shell_ready :: proc(terminal: ^termgrid.Terminal) -> bool {
	if terminal == nil || terminal.grid.rows == nil || terminal.grid.row_count <= 0 || terminal.grid.col_count <= 0 do return false
	for row in 0..<terminal.grid.row_count {
		for col in 0..<terminal.grid.col_count {
			if termgrid.terminal_get_cell(terminal, row, col).content != 0 do return true
		}
	}
	return false
}

profile_resize_is_noop :: proc(requested_w, requested_h, actual_w, actual_h: i32) -> bool {
	return requested_w == actual_w && requested_h == actual_h
}

profile_marker_write :: proc(out: []u8, prefix: string, id: u64) {
	if len(out) == 0 do return
	n := min(len(prefix), len(out)-1)
	copy(out[:n], transmute([]u8)prefix[:n])
	pos := n
	value := id
	digits: [20]u8
	count := 0
	for value > 0 && count < len(digits) {
		digits[count] = u8(value % 10) + '0'
		value /= 10
		count += 1
	}
	for i := count-1; i >= 0 && pos < len(out)-1; i -= 1 {
		out[pos] = digits[i]
		pos += 1
	}
	out[pos] = 0
}
