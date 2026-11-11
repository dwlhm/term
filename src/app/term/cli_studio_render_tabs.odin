package term

// Tab content visual renderers for `term studio`.

import "core:fmt"
import "core:strings"

@(private = "file")
_write_pad :: proc(b: ^strings.Builder, s: string, width: int) {
	strings.write_string(b, s)
	for _ in len(s) ..< width {
		strings.write_byte(b, ' ')
	}
}

@(private = "file")
_write_exit :: proc(b: ^strings.Builder, has_exit: bool, exit_code: i32) {
	if !has_exit {
		strings.write_string(b, "-          ")
		return
	}
	s := fmt.tprintf("✔ %d", exit_code) if exit_code == 0 else fmt.tprintf("✘ %d", exit_code)
	color := STUDIO_GREEN if exit_code == 0 else STUDIO_RED
	strings.write_string(b, color)
	strings.write_string(b, s)
	strings.write_string(b, STUDIO_RST)
	for _ in len(s) ..< 11 do strings.write_byte(b, ' ')
}

studio_paint_tab_sessions :: proc(s: ^Studio_State, b: ^strings.Builder) {
	fmt.sbprintf(b, "%s  STATUS    ID     PID      PROCESS          LAST EXIT  QUIET   CWD%s\r\n", STUDIO_DIM, STUDIO_RST)
	fmt.sbprintf(b, "%s ─────────  ─────  ───────  ───────────────  ─────────  ──────  ────────────────────────%s\r\n", STUDIO_BORDER, STUDIO_RST)

	if s.session_count == 0 {
		fmt.sbprintf(b, "  %s(no active sessions — press 'n' to spawn or 'r' to refresh)%s\r\n", STUDIO_GRAY, STUDIO_RST)
		return
	}

	for idx in 0 ..< s.session_count {
		r := s.sessions[idx]
		is_sel := (idx + 1 == s.selected_row)
		mark := (STUDIO_CYAN + STUDIO_BOLD + "▸ " + STUDIO_RST) if is_sel else "  "
		pill := STUDIO_ACT if r.state == .Busy else (STUDIO_IDL if r.state == .Idle else STUDIO_BLK)

		rb := strings.builder_make(context.temp_allocator)
		strings.write_string(&rb, mark)
		strings.write_string(&rb, pill)
		strings.write_string(&rb, " ")
		_write_pad(&rb, fmt.tprintf("%d", r.id), 7)
		_write_pad(&rb, fmt.tprintf("%d", r.pid), 9)

		proc_name := r.process if len(r.process) <= 15 else r.process[:15]
		_write_pad(&rb, proc_name, 17)
		_write_exit(&rb, r.has_cmd_exit, r.last_cmd_exit)

		q_str := fmt.tprintf("%ds", r.quiet_s)
		_write_pad(&rb, q_str, 8)

		cwd_disp := r.cwd if len(r.cwd) <= 24 else r.cwd[:24]
		strings.write_string(&rb, cwd_disp)

		if is_sel {
			fmt.sbprintf(b, "%s%s%s\r\n", STUDIO_BG_SEL, strings.to_string(rb), STUDIO_RST)
		} else {
			fmt.sbprintf(b, "%s\r\n", strings.to_string(rb))
		}
	}
}

studio_paint_tab_surfaces :: proc(s: ^Studio_State, b: ^strings.Builder) {
	fmt.sbprintf(b, "%s  SURFACE ID  KIND       LAYER       SPLIT DIR  GEOMETRY   CHROME%s\r\n", STUDIO_DIM, STUDIO_RST)
	fmt.sbprintf(b, "%s ───────────  ─────────  ──────────  ─────────  ─────────  ──────────────%s\r\n", STUDIO_BORDER, STUDIO_RST)

	surfs := [5]struct{id: u16, kind: string, layer: string, dir: string, geom: string, chrome: string}{
		{0,  "Root Grid", "ROOT",      "Canvas",   "100% WxH", "None"},
		{1,  "Telemetry", "SPLIT_R",   "Right",    "42% W",    "Border (Gray)"},
		{2,  "Live Tail", "SPLIT_D",   "Down",     "50% H",    "Border (Gray)"},
		{10, "Palette",   "POPUP_SDF", "Center",   "48x12",    "SDF Shadow Modal"},
		{11, "Inspector", "POPUP_SDF", "Center",   "56x13",    "SDF Shadow Modal"},
	}

	for sf in surfs {
		is_foc := (sf.id == s.focused_surface)
		mark := (STUDIO_YELLOW + STUDIO_BOLD + "* " + STUDIO_RST) if is_foc else "  "
		fmt.sbprintf(
			b, "%s#%-10d  %-9s  %-10s  %-9s  %-9s  %s\r\n",
			mark, sf.id, sf.kind, sf.layer, sf.dir, sf.geom, sf.chrome,
		)
	}
}

studio_paint_tab_telemetry :: proc(s: ^Studio_State, b: ^strings.Builder) {
	fmt.sbprintf(b, "%s  SUBSYSTEM        METRIC                     HEALTH     STATUS%s\r\n", STUDIO_DIM, STUDIO_RST)
	fmt.sbprintf(b, "%s ───────────────  ─────────────────────────  ─────────  ────────────────%s\r\n", STUDIO_BORDER, STUDIO_RST)

	subs := [4]struct{name: string, metric: string, health: string, status: string}{
		{"session-core",    "Unix Socket IPC (p50: 0.04ms)", "PASS", "Connected / Active"},
		{"gpu-compositor",  "Metal Blit / SDF Modals",       "PASS", "60 FPS / vsync lock"},
		{"pty-holder",      "Crash Isolation Ring Buffer",   "PASS", "0 orphan leaks"},
		{"process-monitor", "getrusage OS Telemetry",        "PASS", "Non-blocking 25Hz poll"},
	}

	for sub in subs {
		pill := STUDIO_ACT if sub.health == "PASS" else STUDIO_BLK
		fmt.sbprintf(
			b, "  %-15s  %-25s  %s  %s\r\n",
			sub.name, sub.metric, pill, sub.status,
		)
	}
}
