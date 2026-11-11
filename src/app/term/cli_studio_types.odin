package term

// State types, developer models, and actions for `term studio`.

import "core:os"
import "core:strconv"
import proto "../../features/session_proto"
import plat_ipc "../../platform/ipc"

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

Studio_Scope_Kind :: enum u8 {
	Global  = 0,
	Session = 1,
}

Studio_Session :: struct {
	id:            u32,
	pid:           u32,
	state:         proto.Session_State,
	process:       string,
	cwd:           string,
	status:        string,
	process_buf:   [32]u8,
	cwd_buf:       [64]u8,
	status_buf:    [64]u8,
	last_cmd_exit: i32,
	has_cmd_exit:  bool,
	quiet_s:       u32,
	attached:      bool,
	cols:          u16,
	rows:          u16,
}

Studio_State :: struct {
	scope:               Studio_Scope_Kind,
	current_session_id:  u32,
	has_current_session: bool,
	active_tab:          int, // 1: Sessions, 2: Surfaces, 3: Telemetry
	selected_row:        int, // 1-based index in sessions list
	stream_paused:       bool,
	focused_surface:     u16,
	modal:               Studio_Modal_Kind,
	palette_query_buf:   [64]u8,
	palette_query_len:   int,
	palette_sel:         int,
	tick:                int,
	cols:                u16,
	rows:                u16,
	cpu_history:         [16]f64,
	mem_mb:              f64,
	peak_rss_kb:         i64,
	// Session Hub Integration
	ipc_client:          plat_ipc.Client,
	has_ipc_conn:        bool,
	sessions:            [16]Studio_Session,
	session_count:       int,
	tail_buf:            [4096]u8,
	tail_len:            int,
	last_tail_session:   u32,
	palette_actions:     [8]Studio_Palette_Action,
}

studio_state_init :: proc(s: ^Studio_State) {
	s.scope = .Global
	s.active_tab = 1
	s.selected_row = 1
	s.stream_paused = false
	s.focused_surface = 0
	s.modal = .None
	s.palette_query_len = 0
	s.palette_sel = 1
	s.tick = 0
	s.cols = 100
	s.rows = 30
	s.cpu_history = [16]f64{18, 22, 28, 35, 30, 42, 38, 44, 39, 41, 48, 52, 45, 40, 46, 50}
	s.mem_mb = 42.5
	s.session_count = 0
	s.tail_len = 0

	sid_str := os.get_env("TERM_SESSION_ID", context.temp_allocator)
	if len(sid_str) > 0 {
		if sid_val, ok := strconv.parse_u64(sid_str); ok {
			s.current_session_id = u32(sid_val)
			s.has_current_session = true
			s.scope = .Session
		}
	}
	_studio_init_palette_actions(s)
}

@(private = "file")
_studio_init_palette_actions :: proc(s: ^Studio_State) {
	s.palette_actions = [8]Studio_Palette_Action{
		{"sigint-session", "Send SIGINT (Ctrl+C)",         "Interrupt foreground process in selected session"},
		{"kill-session",   "Terminate Session (SIGKILL)",  "Force kill selected session and reclaim PTY"},
		{"new-session",    "Spawn New Session",            "Create new login shell session via session core"},
		{"refresh-list",   "Refresh Session Table",        "Re-query session list from session hub"},
		{"toggle-scope",   "Toggle Scope (Global/Session)","Switch between all sessions and local session"},
		{"toggle-stream",  "Toggle Live Output Tail",      "Pause or resume real-time session tail"},
		{"show-help",      "Show Keyboard Guide",          "Display developer shortcuts cheatsheet"},
		{"quit-app",       "Quit Term Studio",             "Clean teardown and restore terminal"},
	}
}

studio_state_destroy :: proc(s: ^Studio_State) {
	// Zero dynamic allocations: completely stack/value clean
}

studio_state_query :: proc(s: ^Studio_State) -> string {
	return string(s.palette_query_buf[:s.palette_query_len])
}
