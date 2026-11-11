package term

// Visual rendering procedures for `term studio`.

import "core:fmt"
import "core:strings"
import "core:time"

// Visual Styles (Dark Slate & Muted Modern Palette)
STUDIO_RST    :: "\x1b[0m"
STUDIO_BOLD   :: "\x1b[1m"
STUDIO_DIM    :: "\x1b[2m"
STUDIO_BLUE   :: "\x1b[38;2;125;175;255m"
STUDIO_CYAN   :: "\x1b[38;2;110;200;240m"
STUDIO_GREEN  :: "\x1b[38;2;100;220;140m"
STUDIO_YELLOW :: "\x1b[38;2;245;195;110m"
STUDIO_PURPLE :: "\x1b[38;2;180;150;255m"
STUDIO_RED    :: "\x1b[38;2;250;110;110m"
STUDIO_GRAY   :: "\x1b[38;2;120;130;150m"
STUDIO_BORDER :: "\x1b[38;2;60;70;90m"
STUDIO_BG_SEL :: "\x1b[48;2;30;40;58m"
STUDIO_ACT    :: "\x1b[38;2;100;220;140m● active \x1b[0m"
STUDIO_IDL    :: "\x1b[38;2;140;150;170m○ idle   \x1b[0m"
STUDIO_BLK    :: "\x1b[38;2;250;110;110m✖ fail   \x1b[0m"

@(private = "file")
SPARK_CHARS := [8]string{" ", "▂", "▃", "▄", "▅", "▆", "▇", "█"}

@(private = "file")
_sparkline :: proc(val, max_val: f64) -> string {
	m := max(1.0, max_val)
	idx := clamp(int((val / m) * 7.0), 0, 7)
	return SPARK_CHARS[idx]
}

@(private = "file")
_format_bar :: proc(val, max_val: f64, width := 12) -> string {
	b := strings.builder_make(context.temp_allocator)
	w := max(1, width)
	filled := clamp(int((val / max_val) * f64(w)), 0, w)
	for _ in 0 ..< filled do strings.write_string(&b, "■")
	for _ in filled ..< w do strings.write_string(&b, "·")
	return strings.to_string(b)
}

studio_paint_root :: proc(s: ^Studio_State) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "\x1b[H\x1b[2J")
	_studio_paint_header(s, &b)
	_studio_paint_tabs(s, &b)

	switch s.active_tab {
	case 1: studio_paint_tab_sessions(s, &b)
	case 2: studio_paint_tab_surfaces(s, &b)
	case 3: studio_paint_tab_telemetry(s, &b)
	}

	_studio_paint_footer(s, &b)
	studio_osc_target(0, strings.to_string(b))
}

@(private = "file")
_studio_paint_header :: proc(s: ^Studio_State, b: ^strings.Builder) {
	h, m, sec := time.clock(time.now())
	scope_str := "Global" if s.scope == .Global else fmt.tprintf("Session #%d", s.current_session_id)
	fmt.sbprintf(
		b,
		" %s%s◈ Term Studio%s  %sScope: %s%s  %s%02d:%02d:%02d%s\r\n",
		STUDIO_BOLD, STUDIO_BLUE, STUDIO_RST,
		STUDIO_GRAY, scope_str, STUDIO_RST,
		STUDIO_DIM, h, m, sec, STUDIO_RST,
	)
	fmt.sbprintf(b, "%s ────────────────────────────────────────────────────────────────────────%s\r\n", STUDIO_BORDER, STUDIO_RST)
}

@(private = "file")
_studio_paint_tabs :: proc(s: ^Studio_State, b: ^strings.Builder) {
	tabs := [3]string{"Sessions", "Surfaces", "Telemetry"}
	strings.write_string(b, " ")
	for t, i in tabs {
		idx := i + 1
		if idx == s.active_tab {
			fmt.sbprintf(b, "%s%s[%d %s]%s  ", STUDIO_BOLD, STUDIO_CYAN, idx, t, STUDIO_RST)
		} else {
			fmt.sbprintf(b, "%s %d %s %s  ", STUDIO_GRAY, idx, t, STUDIO_RST)
		}
	}
	strings.write_string(b, "\r\n")
	fmt.sbprintf(b, "%s ────────────────────────────────────────────────────────────────────────%s\r\n", STUDIO_BORDER, STUDIO_RST)
}

@(private = "file")
_studio_paint_footer :: proc(s: ^Studio_State, b: ^strings.Builder) {
	fmt.sbprintf(b, "%s ────────────────────────────────────────────────────────────────────────%s\r\n", STUDIO_BORDER, STUDIO_RST)
	fmt.sbprintf(
		b,
		" %s↑↓%s Select  %sx%s Interrupt  %sr%s Refresh  %sp%s Palette  %si%s Inspect  %sq%s Quit",
		STUDIO_CYAN, STUDIO_RST,
		STUDIO_CYAN, STUDIO_RST,
		STUDIO_CYAN, STUDIO_RST,
		STUDIO_CYAN, STUDIO_RST,
		STUDIO_CYAN, STUDIO_RST,
		STUDIO_CYAN, STUDIO_RST,
	)
}

studio_paint_telemetry :: proc(s: ^Studio_State) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "\x1b[H\x1b[2J")

	cur_cpu := s.cpu_history[len(s.cpu_history) - 1]
	fmt.sbprintf(&b, " %s%s◈ HOST & ENGINE TELEMETRY%s\r\n", STUDIO_CYAN, STUDIO_BOLD, STUDIO_RST)
	fmt.sbprintf(&b, "%s ──────────────────────────────%s\r\n", STUDIO_BORDER, STUDIO_RST)

	bar := _format_bar(cur_cpu, 100.0, 12)
	fmt.sbprintf(&b, " CPU   [%s%s%s] %4.1f%%\r\n", STUDIO_GREEN, bar, STUDIO_RST, cur_cpu)
	strings.write_string(&b, " Trend " + STUDIO_BLUE)
	for v in s.cpu_history do strings.write_string(&b, _sparkline(v, 100.0))
	fmt.sbprintf(&b, "%s\r\n", STUDIO_RST)

	mbar := _format_bar(s.mem_mb, 256.0, 12)
	fmt.sbprintf(&b, " RSS   [%s%s%s] %3.0fMB\r\n", STUDIO_PURPLE, mbar, STUDIO_RST, s.mem_mb)
	fmt.sbprintf(&b, "%s ──────────────────────────────%s\r\n", STUDIO_BORDER, STUDIO_RST)
	hub_stat := (STUDIO_GREEN + "active" + STUDIO_RST) if s.has_ipc_conn else (STUDIO_GRAY + "standalone" + STUDIO_RST)
	fmt.sbprintf(&b, " Session Hub : %s\r\n", hub_stat)
	fmt.sbprintf(&b, " Sessions    : %s%d live%s\r\n", STUDIO_BOLD, s.session_count, STUDIO_RST)
	fmt.sbprintf(&b, " Compositor  : %sMetal GPU%s\r\n", STUDIO_CYAN, STUDIO_RST)

	studio_osc_target(1, strings.to_string(b))
}

studio_paint_tail :: proc(s: ^Studio_State) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "\x1b[H\x1b[2J")

	sel_idx := clamp(s.selected_row - 1, 0, max(0, s.session_count - 1))
	target_name := "output"
	target_id: u32 = 0
	if s.session_count > 0 {
		target_name = s.sessions[sel_idx].process
		target_id = s.sessions[sel_idx].id
	}

	fmt.sbprintf(&b, " %s%s◈ OUTPUT TAIL%s  %s#%d %s%s\r\n", STUDIO_GREEN, STUDIO_BOLD, STUDIO_RST, STUDIO_GRAY, target_id, target_name, STUDIO_RST)
	fmt.sbprintf(&b, "%s ──────────────────────────────────────────────%s\r\n", STUDIO_BORDER, STUDIO_RST)

	if s.tail_len > 0 {
		strings.write_string(&b, string(s.tail_buf[:s.tail_len]))
	} else {
		fmt.sbprintf(&b, " %s(no recent output recorded for this session)%s\r\n", STUDIO_GRAY, STUDIO_RST)
	}

	studio_osc_target(2, strings.to_string(b))
}

studio_paint_palette :: proc(s: ^Studio_State) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "\x1b[H\x1b[2J")

	q := studio_state_query(s)
	fmt.sbprintf(&b, " %s%s> Filter:%s %s\x1b[K\r\n", STUDIO_CYAN, STUDIO_BOLD, STUDIO_RST, q)
	fmt.sbprintf(&b, "%s────────────────────────────────────────────%s\r\n", STUDIO_BORDER, STUDIO_RST)

	count := 0
	for item in s.palette_actions {
		match := len(q) == 0 || strings.contains(strings.to_lower(item.label, context.temp_allocator), strings.to_lower(q, context.temp_allocator))
		if match && count < 6 {
			count += 1
			is_sel := (count == s.palette_sel)
			if is_sel {
				fmt.sbprintf(&b, "%s%s ▸ %-38s%s\r\n", STUDIO_BG_SEL, STUDIO_CYAN, item.label, STUDIO_RST)
			} else {
				fmt.sbprintf(&b, "   %-38s\r\n", item.label)
			}
		}
	}
	if count == 0 do fmt.sbprintf(&b, "%s  (no matching actions)%s\r\n", STUDIO_GRAY, STUDIO_RST)

	fmt.sbprintf(&b, "%s────────────────────────────────────────────%s\r\n", STUDIO_BORDER, STUDIO_RST)
	fmt.sbprintf(&b, "%s Enter: Run   Esc: Dismiss   ↑↓: Select%s", STUDIO_GRAY, STUDIO_RST)
	studio_osc_target(10, strings.to_string(b))
}

studio_paint_inspector :: proc(s: ^Studio_State) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "\x1b[H\x1b[2J")

	if s.session_count == 0 {
		fmt.sbprintf(&b, " %sNo active session to inspect%s\r\n", STUDIO_GRAY, STUDIO_RST)
		studio_osc_target(11, strings.to_string(b))
		return
	}

	r := s.sessions[clamp(s.selected_row - 1, 0, s.session_count - 1)]
	fmt.sbprintf(&b, " %s%s◈ SESSION INSPECTOR (#%d %s)%s\r\n", STUDIO_YELLOW, STUDIO_BOLD, r.id, r.process, STUDIO_RST)
	fmt.sbprintf(&b, "%s──────────────────────────────────────────────────%s\r\n", STUDIO_BORDER, STUDIO_RST)
	fmt.sbprintf(&b, " PID        : %s%d%s\r\n", STUDIO_CYAN, r.pid, STUDIO_RST)
	fmt.sbprintf(&b, " CWD        : %s%s%s\r\n", STUDIO_BLUE, r.cwd, STUDIO_RST)
	fmt.sbprintf(&b, " State      : %s\r\n", STUDIO_ACT if r.state == .Busy else STUDIO_IDL)
	fmt.sbprintf(&b, " Grid       : %s%dx%d%s\r\n", STUDIO_PURPLE, r.cols, r.rows, STUDIO_RST)
	fmt.sbprintf(&b, " Last Exit  : %s%d%s\r\n", STUDIO_GREEN if r.last_cmd_exit == 0 else STUDIO_RED, r.last_cmd_exit, STUDIO_RST)
	fmt.sbprintf(&b, " Quiet Time : %s%ds%s\r\n", STUDIO_YELLOW, r.quiet_s, STUDIO_RST)
	if len(r.status) > 0 do fmt.sbprintf(&b, " Agent      : %s%s%s\r\n", STUDIO_CYAN, r.status, STUDIO_RST)
	fmt.sbprintf(&b, "%s──────────────────────────────────────────────────%s\r\n", STUDIO_BORDER, STUDIO_RST)
	fmt.sbprintf(&b, "%s Press Esc or i to dismiss%s", STUDIO_GRAY, STUDIO_RST)

	studio_osc_target(11, strings.to_string(b))
}

studio_paint_help :: proc(s: ^Studio_State) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "\x1b[H\x1b[2J")

	fmt.sbprintf(&b, " %s%s◈ TERM STUDIO SHORTCUTS%s\r\n", STUDIO_GREEN, STUDIO_BOLD, STUDIO_RST)
	fmt.sbprintf(&b, "%s────────────────────────────────────────────────────%s\r\n", STUDIO_BORDER, STUDIO_RST)
	strings.write_string(&b, "  j / ↓, k / ↑   Select session in table (auto-tails)\r\n")
	strings.write_string(&b, "  x              Send SIGINT (Ctrl+C) to process\r\n")
	strings.write_string(&b, "  r              Refresh session table\r\n")
	strings.write_string(&b, "  o              Toggle Scope: Global ⟷ Local\r\n")
	strings.write_string(&b, "  Tab            Cycle focus across surface splits\r\n")
	strings.write_string(&b, "  p / :          Open Command Palette\r\n")
	strings.write_string(&b, "  i / Enter      Inspect selected session\r\n")
	strings.write_string(&b, "  s / Space      Pause / resume live tail stream\r\n")
	strings.write_string(&b, "  1, 2, 3        Switch tabs (Sessions / Surfaces / Telemetry)\r\n")
	strings.write_string(&b, "  q / Ctrl+C     Clean exit\r\n")
	fmt.sbprintf(&b, "%s────────────────────────────────────────────────────%s\r\n", STUDIO_BORDER, STUDIO_RST)
	fmt.sbprintf(&b, "%s Press Esc or ? to dismiss%s", STUDIO_GRAY, STUDIO_RST)

	studio_osc_target(12, strings.to_string(b))
}
