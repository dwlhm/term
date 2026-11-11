package term

// State types, workload models, and actions for `term studio`.

Studio_Workload :: struct {
	id:      string,
	name:    string,
	kind:    string,
	status:  string,
	cpu:     f64,
	mem:     f64,
	splits:  int,
	uptime:  string,
}

Studio_Palette_Action :: struct {
	key:   string,
	label: string,
	desc:  string,
}

Studio_Modal_Kind :: enum u8 {
	None    = 0,
	Palette = 10,
	Inspect = 11,
	Help    = 12,
}

Studio_State :: struct {
	active_tab:         int,
	selected_row:       int,
	log_count:          int,
	stream_paused:      bool,
	focused_surface:    u16,
	modal:              Studio_Modal_Kind,
	palette_query_buf:  [64]u8,
	palette_query_len:  int,
	palette_sel:        int,
	tick:               int,
	cpu_history:        [16]f64,
	mem_mb:             f64,
	workloads:          [7]Studio_Workload,
	palette_actions:    [6]Studio_Palette_Action,
}

studio_state_init :: proc(s: ^Studio_State) {
	s.active_tab = 1
	s.selected_row = 1
	s.log_count = 0
	s.stream_paused = false
	s.focused_surface = 0
	s.modal = .None
	s.palette_query_len = 0
	s.palette_sel = 1
	s.tick = 0
	s.cpu_history = [16]f64{24, 28, 35, 42, 38, 45, 52, 48, 40, 44, 50, 55, 49, 46, 52, 58}
	s.mem_mb = 142.5

	s.workloads = [7]Studio_Workload{
		{"001", "term-core",    "Session Hub",  "ACTIVE",  12.4, 46.2, 3, "04:12"},
		{"002", "gpu-pipeline", "Metal Blit",   "ACTIVE",  28.1, 68.4, 1, "04:12"},
		{"003", "runner-pty",   "PTY Spawn",    "IDLE",     0.2, 18.0, 1, "02:40"},
		{"004", "lsp-adapter",  "Diagnostics",  "ACTIVE",   6.5, 84.1, 2, "01:15"},
		{"005", "byte-ring",    "Ring Buffer",  "IDLE",     0.0,  8.4, 1, "05:01"},
		{"006", "worker-pool",  "Lua Effects",  "ACTIVE",   8.9, 32.7, 2, "00:54"},
		{"007", "bench-stream", "Throughput",   "BLOCKED",  0.0, 12.1, 1, "00:18"},
	}

	s.palette_actions = [6]Studio_Palette_Action{
		{"toggle-stream", "Toggle Live Log Stream",        "Pause or resume real-time event logs"},
		{"inspect-row",   "Inspect Selected Workload",     "Open detailed property inspector dialog"},
		{"burst-flood",   "Simulate High-Throughput Burst","Send 20 log lines to verify hardware scroll"},
		{"reset-surfaces","Reset All Child Surfaces",      "Trigger OSC 7502;0 surface lifecycle reset"},
		{"show-help",     "Show Keyboard & OSC Guide",     "Display full shortcut and architecture cheatsheet"},
		{"quit-app",      "Quit Term Studio",              "Clean teardown and restore terminal"},
	}
}

studio_state_query :: proc(s: ^Studio_State) -> string {
	return string(s.palette_query_buf[:s.palette_query_len])
}
