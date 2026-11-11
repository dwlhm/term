package term

// CLI entrypoint & interactive event loop for `term studio`.

import "core:math"
import "core:os"
import posix "core:sys/posix"
import "core:time"
import ext "../../core/terminal/extension"

@(private = "file")
_orig_studio_termios: posix.termios
@(private = "file")
_studio_raw_active: bool

@(private = "file")
_studio_raw_enter :: proc() -> bool {
	if _studio_raw_active do return true
	if posix.tcgetattr(posix.FD(0), &_orig_studio_termios) != .OK do return false
	raw := _orig_studio_termios
	raw.c_iflag -= {.IGNBRK, .BRKINT, .PARMRK, .ISTRIP, .INLCR, .IGNCR, .ICRNL, .IXON}
	raw.c_oflag -= {.OPOST}
	raw.c_lflag -= {.ECHO, .ECHONL, .ICANON, .ISIG, .IEXTEN}
	raw.c_cflag -= {.PARENB, .CSTOPB}
	raw.c_cflag += {.CS8}
	raw.c_cc[.VMIN] = 0
	raw.c_cc[.VTIME] = 0
	if posix.tcsetattr(posix.FD(0), .TCSAFLUSH, &raw) != .OK do return false
	_studio_raw_active = true
	return true
}

@(private = "file")
_studio_raw_exit :: proc() {
	if _studio_raw_active {
		posix.tcsetattr(posix.FD(0), .TCSAFLUSH, &_orig_studio_termios)
		_studio_raw_active = false
	}
}

@(private = "file")
_studio_open_modal :: proc(s: ^Studio_State, kind: Studio_Modal_Kind) {
	s.modal = kind
	switch kind {
	case .Palette:
		s.palette_query_len = 0
		s.palette_sel = 1
		studio_osc_popup(10, 46, 10, .Center, 0, 0, 100, .Modal, true, "Command Palette (OSC 7502)")
		studio_paint_palette(s)
	case .Inspect:
		studio_osc_popup(11, 52, 11, .Center, 0, 0, 100, .Modal, true, "Workload Properties")
		studio_paint_inspector(s)
	case .Help:
		studio_osc_popup(12, 54, 13, .Center, 0, 0, 100, .Modal, true, "OSC 7502 Architecture Guide")
		studio_paint_help(s)
	case .None:
	}
}

@(private = "file")
_studio_close_modal :: proc(s: ^Studio_State) {
	if s.modal == .None do return
	id := u16(s.modal)
	s.modal = .None
	// Zero background repaint: GPU removes layer, we simply refocus Root
	studio_osc_close(id)
	studio_osc_focus(0)
	s.focused_surface = 0
	studio_paint_root(s)
}

@(private = "file")
_studio_exec_action :: proc(s: ^Studio_State, key: string) -> (should_quit: bool) {
	switch key {
	case "toggle-stream":
		s.stream_paused = !s.stream_paused
		studio_append_log(s, "INFO", "Log stream paused" if s.stream_paused else "Log stream resumed")
		_studio_close_modal(s)
	case "inspect-row":
		_studio_close_modal(s)
		_studio_open_modal(s, .Inspect)
	case "burst-flood":
		_studio_close_modal(s)
		for i in 1 ..= 15 {
			studio_append_log(s, "PERF", "Hardware scroll burst verified (Split #2)")
		}
	case "reset-surfaces":
		_studio_close_modal(s)
		studio_append_log(s, "WARN", "OSC 7502 lifecycle reset emitted")
	case "show-help":
		_studio_close_modal(s)
		_studio_open_modal(s, .Help)
	case "quit-app":
		return true
	}
	return false
}

@(private = "file")
_studio_handle_key :: proc(s: ^Studio_State, key: string) -> (should_quit: bool) {
	if s.modal == .Palette {
		if key == "\x1b" || key == "\x03" {
			_studio_close_modal(s)
		} else if key == "\r" || key == "\n" {
			action_key := s.palette_actions[clamp(s.palette_sel - 1, 0, len(s.palette_actions) - 1)].key
			return _studio_exec_action(s, action_key)
		} else if key == "\x1b[A" || key == "k" {
			s.palette_sel = max(1, s.palette_sel - 1)
			studio_paint_palette(s)
		} else if key == "\x1b[B" || key == "j" {
			s.palette_sel = min(len(s.palette_actions), s.palette_sel + 1)
			studio_paint_palette(s)
		} else if key == "\x7f" || key == "\b" {
			if s.palette_query_len > 0 {
				s.palette_query_len -= 1
				s.palette_sel = 1
				studio_paint_palette(s)
			}
		} else if len(key) == 1 && key[0] >= 32 && key[0] <= 126 {
			if s.palette_query_len < len(s.palette_query_buf) {
				s.palette_query_buf[s.palette_query_len] = key[0]
				s.palette_query_len += 1
				s.palette_sel = 1
				studio_paint_palette(s)
			}
		}
	} else if s.modal == .Inspect || s.modal == .Help {
		if key == "\x1b" || key == "q" || key == "i" || key == "?" || key == "\r" {
			_studio_close_modal(s)
		}
	} else {
		// Root navigation
		switch key {
		case "q", "\x03": return true
		case "j", "\x1b[B":
			s.selected_row = min(len(s.workloads), s.selected_row + 1)
			studio_paint_root(s)
		case "k", "\x1b[A":
			s.selected_row = max(1, s.selected_row - 1)
			studio_paint_root(s)
		case "\t":
			s.focused_surface = (s.focused_surface + 1) % 3
			studio_osc_focus(s.focused_surface)
			studio_paint_root(s)
		case "p", ":":
			_studio_open_modal(s, .Palette)
		case "i", "\r", "\n":
			_studio_open_modal(s, .Inspect)
		case "?":
			_studio_open_modal(s, .Help)
		case "s", " ":
			s.stream_paused = !s.stream_paused
			studio_append_log(s, "INFO", "Live stream paused" if s.stream_paused else "Live stream resumed")
		case "f":
			for _ in 1 ..= 10 do studio_append_log(s, "PERF", "Rapid hardware scroll burst")
		case "1", "2", "3", "4":
			s.active_tab = int(key[0] - '0')
			studio_paint_root(s)
		}
	}
	return false
}

app_cli_studio :: proc(args: []string) -> int {
	is_demo := false
	for a in args {
		if a == "--demo" do is_demo = true
	}

	state: Studio_State
	studio_state_init(&state)

	// Setup terminal
	studio_osc_write("\x1b[?1049h\x1b[?25l")
	studio_osc_reset()
	_ = _studio_raw_enter()

	defer {
		_studio_raw_exit()
		studio_osc_reset()
		studio_osc_write("\x1b[?25h\x1b[?1049l")
	}

	// Layout: Split #1 right 42%, Split #2 down 50%
	studio_osc_split(1, 0, .Right, 42, false)
	studio_osc_split(2, 1, .Down, 50, false)

	studio_paint_root(&state)
	studio_paint_telemetry(&state)
	studio_osc_target(2, "\x1b[H\x1b[2J\x1b[1;32m EVENT STREAM (#2 - HW SCROLL)\x1b[0m\r\n")
	for i in 1 ..= 4 {
		studio_append_log(&state, "INFO", "Surface grid initialized")
	}

	if is_demo {
		for step in 1 ..= 5 {
			state.tick += 1
			state.cpu_history[len(state.cpu_history) - 1] = 35.0 + f64(step * 6)
			studio_paint_root(&state)
			studio_paint_telemetry(&state)
			studio_append_log(&state, "PERF", "Automated demo hardware scroll active")
			time.sleep(60 * time.Millisecond)
		}
		_studio_open_modal(&state, .Palette)
		time.sleep(80 * time.Millisecond)
		_studio_close_modal(&state)
		_studio_open_modal(&state, .Help)
		time.sleep(80 * time.Millisecond)
		_studio_close_modal(&state)
		return 0
	}

	// 25Hz Non-blocking Event Loop
	events := make([dynamic]Studio_Event, context.temp_allocator)
	buf: [1024]u8

	for {
		state.tick += 1
		pfd := posix.pollfd{fd = posix.FD(0), events = {.IN}}
		res := posix.poll(&pfd, 1, 40) // 40ms timeout -> 25Hz

		// Background telemetry ticks
		if state.tick % 5 == 0 {
			for i in 0 ..< len(state.cpu_history) - 1 {
				state.cpu_history[i] = state.cpu_history[i + 1]
			}
			state.cpu_history[len(state.cpu_history) - 1] = 30.0 + math.sin(f64(state.tick) * 0.15) * 20.0
			state.mem_mb = 142.0 + math.cos(f64(state.tick) * 0.1) * 6.0
			studio_paint_telemetry(&state)
			studio_paint_root(&state)
		}
		if !state.stream_paused && state.tick % 8 == 0 {
			studio_append_log(&state, "INFO", "Heartbeat telemetry pulse verified")
		}

		if res > 0 && .IN in pfd.revents {
			n, rerr := os.read(os.stdin, buf[:])
			if rerr == nil && n > 0 {
				clear(&events)
				studio_demux_chunk(string(buf[:n]), &events, context.temp_allocator)
				for ev in events {
					switch ev.kind {
					case .Focus:
						state.focused_surface = ev.id
						studio_paint_root(&state)
					case .Resize:
						studio_paint_root(&state)
						studio_paint_telemetry(&state)
					case .Close:
						if state.modal != .None do _studio_close_modal(&state)
					case .Child_Input, .Raw_Key:
						if _studio_handle_key(&state, ev.data) do return 0
					case .None, .Probe:
					}
				}
			}
		}
		free_all(context.temp_allocator)
	}
	return 0
}
