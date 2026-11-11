package term

// Visual rendering procedures for `term studio`.

import "core:fmt"
import "core:strings"
import "core:time"

// Visual Styles
@(private = "file") STUDIO_RST    :: "\x1b[0m"
@(private = "file") STUDIO_BOLD   :: "\x1b[1m"
@(private = "file") STUDIO_DIM    :: "\x1b[2m"
@(private = "file") STUDIO_BLUE   :: "\x1b[38;2;110;185;255m"
@(private = "file") STUDIO_CYAN   :: "\x1b[38;2;90;220;230m"
@(private = "file") STUDIO_GREEN  :: "\x1b[38;2;120;225;140m"
@(private = "file") STUDIO_YELLOW :: "\x1b[38;2;255;200;100m"
@(private = "file") STUDIO_PURPLE :: "\x1b[38;2;190;140;255m"
@(private = "file") STUDIO_RED    :: "\x1b[38;2;255;110;110m"
@(private = "file") STUDIO_GRAY   :: "\x1b[38;2;130;140;160m"
@(private = "file") STUDIO_BORDER :: "\x1b[38;2;70;80;100m"
@(private = "file") STUDIO_BG_SEL :: "\x1b[48;2;40;60;90m"
@(private = "file") STUDIO_ACT    :: "\x1b[48;2;30;70;45;38;2;120;240;150m ACTIVE \x1b[0m"
@(private = "file") STUDIO_IDL    :: "\x1b[48;2;50;55;70;38;2;170;180;200m  IDLE  \x1b[0m"
@(private = "file") STUDIO_BLK    :: "\x1b[48;2;80;40;35;38;2;255;140;130m BLOCKED\x1b[0m"

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
	for _ in 0 ..< filled do strings.write_string(&b, "█")
	for _ in filled ..< w do strings.write_string(&b, "░")
	return strings.to_string(b)
}

studio_paint_root :: proc(s: ^Studio_State) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "\x1b[H")

	now := time.now()
	h, m, sec := time.clock(now)

	// Header
	fmt.sbprintf(
		&b,
		"%s%s  TERM STUDIO %s— NATIVE OSC 7502 COCKPIT%s\x1b[1;62H%s%02d:%02d:%02d%s\r\n",
		STUDIO_BLUE, STUDIO_BOLD, STUDIO_GRAY, STUDIO_RST, STUDIO_CYAN, h, m, sec, STUDIO_RST,
	)
	fmt.sbprintf(&b, "%s  ────────────────────────────────────────────────────────────────────────%s\r\n", STUDIO_BORDER, STUDIO_RST)

	// Tab Bar
	tabs := [4]string{"Workloads", "Sessions", "Surfaces", "Telemetry"}
	strings.write_string(&b, "  ")
	for t, i in tabs {
		idx := i + 1
		if idx == s.active_tab {
			fmt.sbprintf(&b, "%s%s%s [%d] %s %s ", STUDIO_BG_SEL, STUDIO_BOLD, STUDIO_BLUE, idx, t, STUDIO_RST)
		} else {
			fmt.sbprintf(&b, "%s  %d: %s  %s ", STUDIO_GRAY, idx, t, STUDIO_RST)
		}
	}
	strings.write_string(&b, "\r\n")
	fmt.sbprintf(&b, "%s  ────────────────────────────────────────────────────────────────────────%s\r\n", STUDIO_BORDER, STUDIO_RST)

	// Table Header
	fmt.sbprintf(&b, "%s   STATUS    ID   WORKLOAD       TYPE          CPU%%    MEM     SURF  UPTIME %s\r\n", STUDIO_DIM, STUDIO_RST)
	fmt.sbprintf(&b, "%s  ─────────  ───  ─────────────  ────────────  ──────  ──────  ────  ───────%s\r\n", STUDIO_BORDER, STUDIO_RST)

	// Rows
	for w, idx in s.workloads {
		is_sel := (idx + 1 == s.selected_row)
		mark := (STUDIO_BLUE + STUDIO_BOLD + " ▸ " + STUDIO_RST) if is_sel else "   "
		pill := STUDIO_ACT if w.status == "ACTIVE" else (STUDIO_IDL if w.status == "IDLE" else STUDIO_BLK)
		line := fmt.tprintf(
			"%s%s  %-3s  %-13s  %-12s  %s%.1f%%   %s%.1fMB    %d   %s",
			mark, pill, w.id, w.name, w.kind,
			" " if w.cpu < 10.0 else "", w.cpu,
			" " if w.mem < 100.0 else "", w.mem,
			w.splits, w.uptime,
		)
		if is_sel {
			fmt.sbprintf(&b, "%s%s%s\r\n", STUDIO_BG_SEL, line, STUDIO_RST)
		} else {
			fmt.sbprintf(&b, "%s\r\n", line)
		}
	}

	// Status Footer
	strings.write_string(&b, "\x1b[16;1H")
	fmt.sbprintf(&b, "%s  ────────────────────────────────────────────────────────────────────────%s\r\n", STUDIO_BORDER, STUDIO_RST)
	surf_tag := (STUDIO_BLUE + STUDIO_BOLD + "#0 [ROOT]" + STUDIO_RST) if s.focused_surface == 0 else fmt.tprintf("%s#%d [SPLIT]%s", STUDIO_YELLOW, s.focused_surface, STUDIO_RST)
	fmt.sbprintf(
		&b,
		"  Focus: %s  %s│%s  [j/k] Navigate  [p] Palette  [i] Inspect  [?] Help  [q] Quit",
		surf_tag, STUDIO_BORDER, STUDIO_RST,
	)

	studio_osc_target(0, strings.to_string(b))
}

studio_paint_telemetry :: proc(s: ^Studio_State) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "\x1b[H")

	cur_cpu := s.cpu_history[len(s.cpu_history) - 1]
	fmt.sbprintf(&b, "%s%s HARDWARE TELEMETRY (#1)%s\r\n", STUDIO_CYAN, STUDIO_BOLD, STUDIO_RST)
	fmt.sbprintf(&b, "%s ─────────────────────────────%s\r\n", STUDIO_BORDER, STUDIO_RST)

	// CPU Bar & Trend Sparklines
	bar := _format_bar(cur_cpu, 100.0, 12)
	fmt.sbprintf(&b, " CPU: [%s%s%s] %4.1f%%\r\n", STUDIO_GREEN, bar, STUDIO_RST, cur_cpu)
	strings.write_string(&b, " Trend: " + STUDIO_BLUE)
	for v in s.cpu_history {
		strings.write_string(&b, _sparkline(v, 100.0))
	}
	fmt.sbprintf(&b, "%s\r\n", STUDIO_RST)

	// Memory Bar
	mbar := _format_bar(s.mem_mb, 256.0, 12)
	fmt.sbprintf(&b, " MEM: [%s%s%s] %3.0fMB\r\n", STUDIO_PURPLE, mbar, STUDIO_RST, s.mem_mb)

	fmt.sbprintf(&b, "%s ─────────────────────────────%s\r\n", STUDIO_BORDER, STUDIO_RST)
	fmt.sbprintf(&b, " Active Surfaces : %s3 native%s\r\n", STUDIO_YELLOW, STUDIO_RST)
	fmt.sbprintf(&b, " Compositor Layer: %sPOPUP_SDF%s\r\n", STUDIO_CYAN, STUDIO_RST)
	fmt.sbprintf(&b, " Damage Rate     : %s%d cells/s%s\r\n", STUDIO_GRAY, (s.tick * 7) % 64 + 18, STUDIO_RST)

	studio_osc_target(1, strings.to_string(b))
}

studio_append_log :: proc(s: ^Studio_State, level: string, msg: string) {
	s.log_count += 1
	color := STUDIO_GRAY
	switch level {
	case "INFO": color = STUDIO_BLUE
	case "WARN": color = STUDIO_YELLOW
	case "PASS": color = STUDIO_GREEN
	case "FAIL": color = STUDIO_RED
	case "PERF": color = STUDIO_PURPLE
	}

	h, m, sec := time.clock(time.now())
	line := fmt.tprintf("\x1b[90m[%02d:%02d:%02d]\x1b[0m %s%-4s%s %s\r\n", h, m, sec, color, level, STUDIO_RST, msg)
	studio_osc_target(2, line)
}

studio_paint_palette :: proc(s: ^Studio_State) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "\x1b[H\x1b[2J")

	q := studio_state_query(s)
	fmt.sbprintf(&b, "%s%s > %s%sFilter: %s%s\x1b[K\r\n", STUDIO_CYAN, STUDIO_BOLD, STUDIO_RST, STUDIO_BOLD, q, STUDIO_RST)
	fmt.sbprintf(&b, "%s────────────────────────────────────────────%s\r\n", STUDIO_BORDER, STUDIO_RST)

	count := 0
	for item, i in s.palette_actions {
		match := len(q) == 0 || strings.contains(strings.to_lower(item.label, context.temp_allocator), strings.to_lower(q, context.temp_allocator))
		if match && count < 5 {
			count += 1
			is_sel := (count == s.palette_sel)
			if is_sel {
				fmt.sbprintf(&b, "%s%s%s ▸ %-38s%s\r\n", STUDIO_BG_SEL, STUDIO_BOLD, STUDIO_BLUE, item.label, STUDIO_RST)
			} else {
				fmt.sbprintf(&b, "   %-38s\r\n", item.label)
			}
		}
	}
	if count == 0 {
		fmt.sbprintf(&b, "%s  (no matching actions)%s\r\n", STUDIO_GRAY, STUDIO_RST)
	}

	fmt.sbprintf(&b, "%s────────────────────────────────────────────%s\r\n", STUDIO_BORDER, STUDIO_RST)
	fmt.sbprintf(&b, "%s [Enter] Run   [Esc] Dismiss   [↑/↓] Select%s", STUDIO_GRAY, STUDIO_RST)

	studio_osc_target(10, strings.to_string(b))
}

studio_paint_inspector :: proc(s: ^Studio_State) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "\x1b[H\x1b[2J")

	w := s.workloads[clamp(s.selected_row - 1, 0, len(s.workloads) - 1)]
	fmt.sbprintf(&b, "%s%s WORKLOAD PROPERTIES (#%s: %s)%s\r\n", STUDIO_YELLOW, STUDIO_BOLD, w.id, w.name, STUDIO_RST)
	fmt.sbprintf(&b, "%s──────────────────────────────────────────────────%s\r\n", STUDIO_BORDER, STUDIO_RST)
	fmt.sbprintf(&b, " Subsystem Type  : %s%s%s\r\n", STUDIO_CYAN, w.kind, STUDIO_RST)
	fmt.sbprintf(&b, " Execution State : %s%s%s\r\n", STUDIO_GREEN if w.status == "ACTIVE" else STUDIO_GRAY, w.status, STUDIO_RST)
	fmt.sbprintf(&b, " CPU Utilization : %s%.2f%%%%%s\r\n", STUDIO_BLUE, w.cpu, STUDIO_RST)
	fmt.sbprintf(&b, " Resident Memory : %s%.1f MB (Heap clean)%s\r\n", STUDIO_PURPLE, w.mem, STUDIO_RST)
	fmt.sbprintf(&b, " Bound Surfaces  : %s%d isolated splits%s\r\n", STUDIO_YELLOW, w.splits, STUDIO_RST)
	fmt.sbprintf(&b, " Total Uptime    : %s\r\n", w.uptime)
	fmt.sbprintf(&b, "%s──────────────────────────────────────────────────%s\r\n", STUDIO_BORDER, STUDIO_RST)
	fmt.sbprintf(&b, "%s Rendered via OSC 7502;3 (Zero Background Repaint)%s\r\n", STUDIO_GRAY, STUDIO_RST)
	fmt.sbprintf(&b, "%s Press [Esc] or [i] to close inspector%s", STUDIO_GRAY, STUDIO_RST)

	studio_osc_target(11, strings.to_string(b))
}

studio_paint_help :: proc(s: ^Studio_State) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "\x1b[H\x1b[2J")

	fmt.sbprintf(&b, "%s%s TERM STUDIO — OSC 7502 SHORTCUTS & ARCHITECTURE%s\r\n", STUDIO_GREEN, STUDIO_BOLD, STUDIO_RST)
	fmt.sbprintf(&b, "%s────────────────────────────────────────────────────%s\r\n", STUDIO_BORDER, STUDIO_RST)
	fmt.sbprintf(&b, "%s Keyboard Controls:%s\r\n", STUDIO_BOLD, STUDIO_RST)
	strings.write_string(&b, "  j / ↓, k / ↑   Navigate workload rows\r\n")
	strings.write_string(&b, "  Tab            Cycle focus across surface splits\r\n")
	strings.write_string(&b, "  p / :          Open Command Palette (GPU SDF Modal)\r\n")
	strings.write_string(&b, "  i / Enter      Inspect selected workload details\r\n")
	strings.write_string(&b, "  s / Space      Pause / resume live event stream\r\n")
	strings.write_string(&b, "  f              Send 20-line burst (HW scroll test)\r\n")
	strings.write_string(&b, "  ?              Toggle this architecture guide\r\n")
	strings.write_string(&b, "  q / Ctrl+C     Clean exit and surface reset\r\n")
	fmt.sbprintf(&b, "%s────────────────────────────────────────────────────%s\r\n", STUDIO_BORDER, STUDIO_RST)
	fmt.sbprintf(&b, "%s Press [Esc] or [?] to close this modal%s", STUDIO_GRAY, STUDIO_RST)

	studio_osc_target(12, strings.to_string(b))
}
