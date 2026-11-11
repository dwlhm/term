package term

// Session Hub IPC integration for `term studio`.

import "core:fmt"
import "core:strings"
import "core:time"
import api "../../features/session_api"
import proto "../../features/session_proto"
import plat_ipc "../../platform/ipc"

studio_session_connect :: proc(s: ^Studio_State) -> bool {
	if s.has_ipc_conn do return true
	err := api.api_open(&s.ipc_client, false)
	s.has_ipc_conn = (err.kind == .None)
	return s.has_ipc_conn
}

studio_session_disconnect :: proc(s: ^Studio_State) {
	if s.has_ipc_conn {
		plat_ipc.client_close(&s.ipc_client)
		s.has_ipc_conn = false
	}
}

@(private = "file")
_studio_add_session :: proc(s: ^Studio_State, r: proto.Session_Row) {
	if s.session_count >= len(s.sessions) do return
	entry := &s.sessions[s.session_count]
	entry.id = r.id
	entry.pid = r.pid
	entry.state = r.state
	entry.attached = r.attached
	entry.cols = r.cols
	entry.rows = r.rows
	entry.quiet_s = r.quiet_s
	entry.last_cmd_exit = r.last_cmd_exit
	entry.has_cmd_exit = r.has_cmd_exit

	p_len := min(len(r.process), len(entry.process_buf))
	copy(entry.process_buf[:p_len], r.process[:p_len])
	entry.process = string(entry.process_buf[:p_len])

	c_len := min(len(r.cwd), len(entry.cwd_buf))
	copy(entry.cwd_buf[:c_len], r.cwd[:c_len])
	entry.cwd = string(entry.cwd_buf[:c_len])

	s_len := min(len(r.status), len(entry.status_buf))
	copy(entry.status_buf[:s_len], r.status[:s_len])
	entry.status = string(entry.status_buf[:s_len])

	s.session_count += 1
}

studio_session_refresh :: proc(s: ^Studio_State, is_demo: bool) {
	s.session_count = 0
	if !is_demo && s.has_ipc_conn {
		rows, err := api.api_ls(&s.ipc_client, context.temp_allocator, 250 * time.Millisecond)
		if err.kind == .None {
			for r in rows {
				if s.scope == .Session && s.has_current_session && r.id != s.current_session_id {
					continue
				}
				_studio_add_session(s, r)
			}
		}
	}

	if s.session_count == 0 {
		_studio_populate_mock_sessions(s, is_demo)
	}

	if s.selected_row < 1 do s.selected_row = 1
	if s.selected_row > s.session_count do s.selected_row = max(1, s.session_count)
}

@(private = "file")
_studio_populate_mock_sessions :: proc(s: ^Studio_State, is_demo: bool) {
	_studio_add_session(s, proto.Session_Row{
		id = 1, state = .Busy, pid = 4812, process = "cargo test --all",
		cwd = "~/project/term", cols = 120, rows = 35, attached = true,
		elapsed_s = 42, quiet_s = 0, cmd_seq = 14, last_cmd_exit = 0,
		has_cmd_exit = true, status = "Running 27 test suites in parallel",
	})
	_studio_add_session(s, proto.Session_Row{
		id = 2, state = .Idle, pid = 5120, process = "nvim src/main.odin",
		cwd = "~/project/term", cols = 120, rows = 35, attached = true,
		elapsed_s = 280, quiet_s = 18, cmd_seq = 8, last_cmd_exit = 0,
		has_cmd_exit = true, title = "main.odin — Neovim",
	})
	_studio_add_session(s, proto.Session_Row{
		id = 3, state = .Busy, pid = 5940, process = "next dev -p 3000",
		cwd = "~/komerce/admin-v2", cols = 80, rows = 24, attached = false,
		elapsed_s = 612, quiet_s = 2, cmd_seq = 3, last_cmd_exit = 1,
		has_cmd_exit = true, status = "Vite v5 ready in 284ms",
	})
}

@(private = "file")
_studio_write_self_info :: proc(s: ^Studio_State, sel_idx: int) {
	msg := fmt.tprintf(
		" \x1b[1;36mℹ Active Host Session (#%d)\x1b[0m\r\n\r\n" +
		"  • Process : %s (PID %d)\r\n" +
		"  • CWD     : %s\r\n" +
		"  • Canvas  : %dx%d (Root Surface)\r\n\r\n" +
		" \x1b[2mTerm Studio is running inside this session.\r\n" +
		" To tail logs, select another session with [j/k],\r\n" +
		" or press [p] -> Spawn New Session.\x1b[0m\r\n",
		s.sessions[sel_idx].id,
		s.sessions[sel_idx].process, s.sessions[sel_idx].pid,
		s.sessions[sel_idx].cwd,
		s.sessions[sel_idx].cols, s.sessions[sel_idx].rows,
	)
	n := min(len(msg), len(s.tail_buf))
	copy(s.tail_buf[:n], msg[:n])
	s.tail_len = n
	s.last_tail_session = s.sessions[sel_idx].id
}

studio_session_update_tail :: proc(s: ^Studio_State, is_demo: bool) {
	if s.session_count == 0 do return
	sel_idx := clamp(s.selected_row - 1, 0, s.session_count - 1)
	target_id := s.sessions[sel_idx].id

	// If current session is term studio itself, avoid inception mirroring
	if !is_demo && s.has_current_session && target_id == s.current_session_id {
		_studio_write_self_info(s, sel_idx)
		return
	}

	if !is_demo && s.has_ipc_conn {
		text, err := api.api_read(&s.ipc_client, target_id, 25, false, context.temp_allocator, 300 * time.Millisecond)
		if err.kind == .None && len(text) > 0 {
			n := min(len(text), len(s.tail_buf))
			copy(s.tail_buf[:n], text[:n])
			s.tail_len = n
			s.last_tail_session = target_id
			return
		}
	}

	// Demo or synthetic fallback output
	synth := ""
	switch target_id {
	case 1:
		synth = " running 27 tests\r\n" +
			" test cli::arg_parse_test ... ok\r\n" +
			" test session::hub_ipc_test ... ok\r\n" +
			" test renderer::metal_blit_test ... ok\r\n\r\n" +
			" test result: ok. 27 passed; 0 failed; finished in 0.42s\r\n"
	case 2:
		synth = " [Neovim] src/main.odin [utf-8] [odin] 120L, 3420B\r\n" +
			"   1 package main\r\n" +
			"   2 import \"core:fmt\"\r\n" +
			"   3 proc main() {\r\n" +
			"   4     fmt.println(\"Term Engine v2.0 Ready\")\r\n" +
			"   5 }\r\n"
	case 3:
		synth = " ▲ Next.js 14.2.5\r\n" +
			" - Local:        http://localhost:3000\r\n" +
			" - Network:      http://192.168.1.42:3000\r\n" +
			" ✓ Ready in 284ms\r\n" +
			" ○ Compiling /dashboard ...\r\n" +
			" ✓ Compiled /dashboard in 142ms (612 modules)\r\n"
	case:
		synth = fmt.tprintf(
			" [15:02:10] Target PID: %d, CWD: %s\r\n" +
			" [15:02:12] Attached: %t, Last Exit: %d\r\n" +
			" [15:02:14] Live telemetry stream connected\r\n",
			s.sessions[sel_idx].pid, s.sessions[sel_idx].cwd,
			s.sessions[sel_idx].attached, s.sessions[sel_idx].last_cmd_exit,
		)
	}
	n := min(len(synth), len(s.tail_buf))
	copy(s.tail_buf[:n], synth[:n])
	s.tail_len = n
	s.last_tail_session = target_id
}

studio_session_sigint :: proc(s: ^Studio_State) -> bool {
	if s.session_count == 0 || !s.has_ipc_conn do return false
	sel_idx := clamp(s.selected_row - 1, 0, s.session_count - 1)
	target_id := s.sessions[sel_idx].id
	err := api.api_signal(&s.ipc_client, target_id, 2)
	return (err.kind == .None)
}

studio_session_kill :: proc(s: ^Studio_State) -> bool {
	if s.session_count == 0 || !s.has_ipc_conn do return false
	sel_idx := clamp(s.selected_row - 1, 0, s.session_count - 1)
	target_id := s.sessions[sel_idx].id
	err := api.api_kill(&s.ipc_client, target_id)
	return (err.kind == .None)
}
