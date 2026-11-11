package term

// CLI entrypoint & interactive event loop for `term studio`.

import "core:math"
import "core:os"
import posix "core:sys/posix"
import "core:time"

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
_studio_sample_telemetry :: proc(s: ^Studio_State) {
	for i in 0 ..< len(s.cpu_history) - 1 {
		s.cpu_history[i] = s.cpu_history[i + 1]
	}
	s.cpu_history[len(s.cpu_history) - 1] = 25.0 + math.sin(f64(s.tick) * 0.15) * 15.0

	usage: posix.rusage
	if posix.getrusage(.SELF, &usage) == .OK {
		when ODIN_OS == .Darwin {
			s.mem_mb = f64(usage.ru_maxrss) / (1024.0 * 1024.0)
		} else {
			s.mem_mb = f64(usage.ru_maxrss) / 1024.0
		}
	}
	studio_paint_telemetry(s)
	studio_paint_root(s)
}

app_cli_studio :: proc(args: []string) -> int {
	is_demo := false
	for a in args do if a == "--demo" do is_demo = true

	state: Studio_State
	studio_state_init(&state)
	defer studio_state_destroy(&state)

	_ = studio_session_connect(&state)
	defer studio_session_disconnect(&state)

	studio_osc_write("\x1b[?1049h\x1b[?25l")
	studio_osc_reset()
	_ = _studio_raw_enter()

	defer {
		_studio_raw_exit()
		studio_osc_reset()
		studio_osc_write("\x1b[?25h\x1b[?1049l")
	}

	studio_osc_split(1, 0, .Right, 42, false)
	studio_osc_split(2, 1, .Down, 50, false)

	studio_session_refresh(&state, is_demo)
	studio_session_update_tail(&state, is_demo)
	studio_paint_root(&state)
	studio_paint_telemetry(&state)
	studio_paint_tail(&state)

	if is_demo do return _studio_run_demo(&state)
	return _studio_run_loop(&state)
}

@(private = "file")
_studio_run_demo :: proc(s: ^Studio_State) -> int {
	for step in 1 ..= 4 {
		s.tick += 1
		s.selected_row = (step % max(1, s.session_count)) + 1
		studio_session_update_tail(s, true)
		_studio_sample_telemetry(s)
		studio_paint_tail(s)
		time.sleep(50 * time.Millisecond)
	}
	studio_open_modal(s, .Palette)
	time.sleep(60 * time.Millisecond)
	studio_close_modal(s)
	studio_open_modal(s, .Inspect)
	time.sleep(60 * time.Millisecond)
	studio_close_modal(s)
	return 0
}

@(private = "file")
_studio_run_loop :: proc(s: ^Studio_State) -> int {
	events := make([dynamic]Studio_Event, context.temp_allocator)
	buf: [1024]u8

	for {
		s.tick += 1
		pfd := posix.pollfd{fd = posix.FD(0), events = {.IN}}
		res := posix.poll(&pfd, 1, 40) // 40ms -> 25Hz

		if s.tick % 5 == 0 {
			_studio_sample_telemetry(s)
		}
		if !s.stream_paused && s.tick % 25 == 0 {
			studio_session_refresh(s, false)
			studio_session_update_tail(s, false)
			studio_paint_tail(s)
		}

		if res > 0 && .IN in pfd.revents {
			n, rerr := os.read(os.stdin, buf[:])
			if rerr == nil && n > 0 {
				clear(&events)
				studio_demux_chunk(string(buf[:n]), &events, context.temp_allocator)
				for ev in events {
					if _studio_dispatch_event(s, ev) do return 0
				}
			}
		}
		free_all(context.temp_allocator)
	}
	return 0
}

@(private = "file")
_studio_dispatch_event :: proc(s: ^Studio_State, ev: Studio_Event) -> (should_quit: bool) {
	switch ev.kind {
	case .Focus:
		s.focused_surface = ev.id
		studio_paint_root(s)
	case .Resize:
		studio_paint_root(s)
		studio_paint_telemetry(s)
		studio_paint_tail(s)
	case .Close:
		if s.modal != .None do studio_close_modal(s)
	case .Child_Input, .Raw_Key:
		return studio_handle_key(s, ev.data)
	case .None, .Probe:
	}
	return false
}
