package mcp_test

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import posix "core:sys/posix"

import mcp "../"
import session_core "../../../session_core"

@test
test_mcp_protocol_parse :: proc(t: ^testing.T) {
	// Valid request
	raw := `{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}`
	req, raw_val, ok, code, msg := mcp.parse_json_rpc_request(raw)
	defer json.destroy_value(raw_val)

	testing.expect(t, ok, "valid request should parse successfully")
	testing.expect(t, req.jsonrpc == "2.0", "jsonrpc must be 2.0")
	testing.expect(t, req.method == "ping", "method must be ping")
	testing.expect(t, !req.is_notification, "is_notification should be false when id is present")

	// Invalid version
	raw_bad := `{"jsonrpc":"1.0","id":2,"method":"ping"}`
	_, raw_bad_val, ok_bad, _, _ := mcp.parse_json_rpc_request(raw_bad)
	defer json.destroy_value(raw_bad_val)
	testing.expect(t, !ok_bad, "version != 2.0 should fail")

	// Notification (no id)
	raw_notif := `{"jsonrpc":"2.0","method":"notifications/initialized"}`
	req_notif, raw_notif_val, ok_notif, _, _ := mcp.parse_json_rpc_request(raw_notif)
	defer json.destroy_value(raw_notif_val)
	testing.expect(t, ok_notif, "notification should parse")
	testing.expect(t, req_notif.is_notification, "is_notification should be true")
}

@test
test_mcp_initialize_and_tools_list :: proc(t: ^testing.T) {
	// Test TOOLS_LIST_JSON schema validity
	val, err := json.parse_string(mcp.TOOLS_LIST_JSON)
	testing.expect(t, err == .None, "TOOLS_LIST_JSON must be valid JSON")
	defer json.destroy_value(val)

	obj, is_obj := val.(json.Object)
	testing.expect(t, is_obj, "tools list root must be an object")

	tools_arr, has_tools := obj["tools"].(json.Array)
	testing.expect(t, has_tools, "tools must be an array")
	testing.expect(t, len(tools_arr) == 12, "must contain exactly 12 tools")

	expected_tools := []string{
		"terminal_create_session",
		"terminal_close_session",
		"terminal_run_command",
		"terminal_send_input",
		"terminal_send_key",
		"terminal_get_screen",
		"terminal_resize",
		"terminal_list_sessions",
		"terminal_switch_session",
		"terminal_list_commands",
		"terminal_get_output",
		"terminal_run_parallel",
	}

	for expected in expected_tools {
		found := false
		for item in tools_arr {
			tool_obj := item.(json.Object)
			if tool_obj["name"].(json.String) == expected {
				found = true
				if expected == "terminal_create_session" {
					schema := tool_obj["inputSchema"].(json.Object)
					props := schema["properties"].(json.Object)
					_, has_mode := props["mode"]
					testing.expect(t, has_mode, "terminal_create_session must expose 'mode' parameter")
				}
				break
			}
		}
		testing.expect(t, found, expected)
	}

	// Test MCP initialize format string validity
	init_result := fmt.tprintf(
		`{{"protocolVersion":"%s","capabilities":{{"tools":{{}}}},"serverInfo":{{"name":"%s","version":"%s"}}}}`,
		mcp.MCP_PROTOCOL_VERSION,
		mcp.MCP_SERVER_NAME,
		mcp.MCP_SERVER_VERSION,
	)
	init_val, init_err := json.parse_string(init_result)
	testing.expect(t, init_err == .None, "initialize result must be valid JSON")
	defer json.destroy_value(init_val)

	init_obj, init_is_obj := init_val.(json.Object)
	testing.expect(t, init_is_obj, "initialize result must be an object")
	if init_is_obj {
		proto_ver, has_pv := init_obj["protocolVersion"].(json.String)
		testing.expect(t, has_pv && proto_ver == mcp.MCP_PROTOCOL_VERSION, "protocolVersion must match")
	}
}

@test
test_mcp_session_lifecycle :: proc(t: ^testing.T) {
	sm: mcp.Session_Manager
	mcp.session_manager_init(&sm)
	defer mcp.session_manager_destroy_all(&sm)

	// 1. Verify default / Fast_Headless session creation
	id_fast, s_fast, ok_fast := mcp.session_manager_create(&sm, 24, 80, mode = .Fast_Headless)
	testing.expect(t, ok_fast, "fast headless session creation should succeed")
	testing.expect(t, len(id_fast) > 0, "session id should not be empty")
	testing.expect(t, s_fast != nil, "session pointer should not be nil")
	testing.expect(t, s_fast.pty_handle.pid > 0, "pty pid should be valid")
	testing.expect(t, s_fast.mode == .Fast_Headless, "mode must be Fast_Headless")

	pid_fast := s_fast.pty_handle.pid

	// Verify session lookup
	s_lookup, found := mcp.session_manager_get(&sm, id_fast)
	testing.expect(t, found, "lookup should find active session")
	testing.expect(t, s_lookup == s_fast, "lookup must return same pointer")

	// Close fast session
	closed_fast := mcp.session_manager_close(&sm, id_fast)
	testing.expect(t, closed_fast, "closing session should succeed")

	// Verify session is no longer in manager
	_, found_after := mcp.session_manager_get(&sm, id_fast)
	testing.expect(t, !found_after, "session must no longer exist after close")

	// Verify child process was reaped / terminated
	time.sleep(10 * time.Millisecond)
	status: c.int
	r := posix.waitpid(posix.pid_t(pid_fast), &status, posix.Wait_Flags{.NOHANG})
	testing.expect(t, r == -1 || r == posix.pid_t(pid_fast), "child process should be terminated or reaped")

	// 2. Verify Interactive_GUI session creation
	id_gui, s_gui, ok_gui := mcp.session_manager_create(&sm, 24, 80, mode = .Interactive_GUI)
	testing.expect(t, ok_gui, "interactive GUI session creation should succeed")
	testing.expect(t, len(id_gui) > 0, "session id should not be empty")
	testing.expect(t, s_gui != nil, "interactive session pointer should not be nil")
	testing.expect(t, s_gui.pty_handle.pid > 0, "pty pid should be valid")
	testing.expect(t, s_gui.mode == .Interactive_GUI, "mode must be Interactive_GUI")

	// Close interactive session
	closed_gui := mcp.session_manager_close(&sm, id_gui)
	testing.expect(t, closed_gui, "closing interactive session should succeed")
}

@test
test_mcp_run_command_echo :: proc(t: ^testing.T) {
	sm: mcp.Session_Manager
	mcp.session_manager_init(&sm)
	defer mcp.session_manager_destroy_all(&sm)

	id, s, ok := mcp.session_manager_create(&sm, 24, 80)
	testing.expect(t, ok, "session creation should succeed")

	// Run simple command
	output, exit_code, completed, total_lines, truncated := mcp.mcp_session_run_command(s, "echo hello", 10000)
	defer delete(output)
	testing.expect(t, completed, "command should complete")
	testing.expect(t, exit_code == 0, "exit code must be 0")
	testing.expect(t, strings.contains(output, "hello"), "output should contain hello")
	testing.expect(t, !strings.contains(output, "\x1b["), "output must not contain escape codes")
	testing.expect(t, total_lines >= 1, "total_lines should be at least 1")
	testing.expect(t, !truncated, "should not be truncated")

	// Run false to verify non-zero exit code
	false_out, false_code, false_done, _, _ := mcp.mcp_session_run_command(s, "false", 10000)
	defer delete(false_out)
	testing.expect(t, false_done, "false command should complete")
	testing.expect(t, false_code != 0, "false exit code must be non-zero")

	mcp.session_manager_close(&sm, id)
}

@test
test_mcp_screen_extraction :: proc(t: ^testing.T) {
	sm: mcp.Session_Manager
	mcp.session_manager_init(&sm)
	defer mcp.session_manager_destroy_all(&sm)

	id, s, ok := mcp.session_manager_create(&sm, 24, 80)
	testing.expect(t, ok, "session creation should succeed")

	// Run a command that outputs distinct text
	cmd_out, _, completed, _, _ := mcp.mcp_session_run_command(s, "echo 'TERM_MCP_TEST_SCREEN_OK'", 10000)
	defer delete(cmd_out)
	testing.expect(t, completed, "command should complete")

	// Capture screen snapshot
	screen := mcp.mcp_session_extract_screen(s, 0)
	defer delete(screen)
	testing.expect(t, len(screen) > 0, "screen should have content")
	testing.expect(t, strings.contains(screen, "TERM_MCP_TEST_SCREEN_OK"), "screen must show executed output")
	testing.expect(t, !strings.contains(screen, "\x1b["), "screen must not contain raw ANSI codes")

	mcp.session_manager_close(&sm, id)
}

@test
test_mcp_tool_dispatch_e2e :: proc(t: ^testing.T) {
	sm: mcp.Session_Manager
	mcp.session_manager_init(&sm)
	defer mcp.session_manager_destroy_all(&sm)

	// 1. Dispatch terminal_create_session
	create_res, is_err, _ := mcp.tools_dispatch_call(&sm, "terminal_create_session", nil)
	defer delete(create_res)
	testing.expect(t, !is_err, "terminal_create_session should succeed")

	parsed_create, parse_err := json.parse_string(create_res)
	testing.expect(t, parse_err == .None, "result should be valid JSON")
	create_obj := parsed_create.(json.Object)
	session_id_val := create_obj["session_id"].(json.String)
	sess_str := strings.clone(string(session_id_val))
	defer delete(sess_str)
	defer json.destroy_value(parsed_create)

	// 2. Dispatch terminal_run_command
	run_args_json := fmt.tprintf(`{{"session_id":"%s","command":"echo dispatch_ok"}}`, sess_str)
	val_args, parse_args_err := json.parse_string(run_args_json, parse_integers = true)
	testing.expect(t, parse_args_err == .None, "args should parse")
	defer json.destroy_value(val_args)

	run_res, run_err, _ := mcp.tools_dispatch_call(&sm, "terminal_run_command", val_args)
	defer delete(run_res)
	testing.expect(t, !run_err, "terminal_run_command should succeed")

	parsed_run, _ := json.parse_string(run_res, parse_integers = true)
	defer json.destroy_value(parsed_run)
	run_obj, is_run_obj := parsed_run.(json.Object)
	testing.expect(t, is_run_obj, "run_obj should be an object")
	if is_run_obj {
		out_str := run_obj["output"].(json.String)
		testing.expect(t, strings.contains(out_str, "dispatch_ok"), "output must contain dispatch_ok")
		_, has_tot := run_obj["total_lines"]
		testing.expect(t, has_tot, "response must contain total_lines")
		_, has_trunc := run_obj["truncated"]
		testing.expect(t, has_trunc, "response must contain truncated")
	}

	// 3. Dispatch terminal_get_screen
	screen_args_json := fmt.tprintf(`{{"session_id":"%s"}}`, sess_str)
	val_scr, _ := json.parse_string(screen_args_json, parse_integers = true)
	defer json.destroy_value(val_scr)

	scr_res, scr_err, _ := mcp.tools_dispatch_call(&sm, "terminal_get_screen", val_scr)
	defer delete(scr_res)
	testing.expect(t, !scr_err, "terminal_get_screen should succeed")

	parsed_scr, _ := json.parse_string(scr_res, parse_integers = true)
	defer json.destroy_value(parsed_scr)
	scr_obj, is_scr_obj := parsed_scr.(json.Object)
	testing.expect(t, is_scr_obj, "scr_obj should be an object")
	if is_scr_obj {
		scr_text := scr_obj["text"].(json.String)
		testing.expect(t, strings.contains(scr_text, "dispatch_ok"), "screen must contain dispatch_ok")
	}

	// 4. Dispatch terminal_send_input
	input_args_json := fmt.tprintf(`{{"session_id":"%s","text":"echo send_input_ok\n"}}`, sess_str)
	val_input, _ := json.parse_string(input_args_json, parse_integers = true)
	defer json.destroy_value(val_input)

	input_res, input_err, _ := mcp.tools_dispatch_call(&sm, "terminal_send_input", val_input)
	defer delete(input_res)
	testing.expect(t, !input_err, "terminal_send_input should succeed")

	parsed_input, parse_input_err := json.parse_string(input_res, parse_integers = true)
	testing.expect(t, parse_input_err == .None, "terminal_send_input response must be valid JSON")
	defer json.destroy_value(parsed_input)
	input_obj, is_input_obj := parsed_input.(json.Object)
	testing.expect(t, is_input_obj, "input_obj should be an object")
	if is_input_obj {
		bytes_val, has_bw := input_obj["bytes_written"].(json.Integer)
		testing.expect(t, has_bw && bytes_val > 0, "bytes_written must be > 0")
	}

	// 5. Dispatch terminal_send_key
	key_args_json := fmt.tprintf(`{{"session_id":"%s","key":"Enter"}}`, sess_str)
	val_key, _ := json.parse_string(key_args_json, parse_integers = true)
	defer json.destroy_value(val_key)

	key_res, key_err, _ := mcp.tools_dispatch_call(&sm, "terminal_send_key", val_key)
	defer delete(key_res)
	testing.expect(t, !key_err, "terminal_send_key should succeed")
	testing.expect(t, strings.contains(key_res, `"sent":true`), "key sent should be true")

	// 6. Dispatch terminal_resize
	resize_args_json := fmt.tprintf(`{{"session_id":"%s","rows":30,"cols":100}}`, sess_str)
	val_resize, _ := json.parse_string(resize_args_json, parse_integers = true)
	defer json.destroy_value(val_resize)

	resize_res, resize_err, _ := mcp.tools_dispatch_call(&sm, "terminal_resize", val_resize)
	defer delete(resize_res)
	testing.expect(t, !resize_err, "terminal_resize should succeed")
	testing.expect(t, strings.contains(resize_res, `"resized":true`), "resize should be true")

	// 7. Dispatch terminal_close_session
	close_args_json := fmt.tprintf(`{{"session_id":"%s"}}`, sess_str)
	val_close, _ := json.parse_string(close_args_json, parse_integers = true)
	defer json.destroy_value(val_close)

	close_res, close_err, _ := mcp.tools_dispatch_call(&sm, "terminal_close_session", val_close)
	defer delete(close_res)
	testing.expect(t, !close_err, "terminal_close_session should succeed")
	testing.expect(t, strings.contains(close_res, `"closed":true`), "closed should be true")

	// 8. Dispatch terminal_create_session with explicit interactive mode
	inter_args_json := `{"mode":"interactive","rows":24,"cols":80}`
	val_inter_args, _ := json.parse_string(inter_args_json, parse_integers = true)
	defer json.destroy_value(val_inter_args)

	inter_res, inter_err, _ := mcp.tools_dispatch_call(&sm, "terminal_create_session", val_inter_args)
	defer delete(inter_res)
	testing.expect(t, !inter_err, "terminal_create_session with interactive mode should succeed")

	parsed_inter, _ := json.parse_string(inter_res)
	defer json.destroy_value(parsed_inter)
	inter_obj := parsed_inter.(json.Object)
	inter_sid := string(inter_obj["session_id"].(json.String))

	inter_sess, found_inter := mcp.session_manager_get(&sm, inter_sid)
	testing.expect(t, found_inter, "interactive session should be found")
	if found_inter {
		testing.expect(t, inter_sess.mode == .Interactive_GUI, "mode must be Interactive_GUI")
	}

	close_inter_json := fmt.tprintf(`{{"session_id":"%s"}}`, inter_sid)
	val_close_inter, _ := json.parse_string(close_inter_json, parse_integers = true)
	defer json.destroy_value(val_close_inter)
	close_inter_res, _, _ := mcp.tools_dispatch_call(&sm, "terminal_close_session", val_close_inter)
	delete(close_inter_res)
}

@test
test_mcp_auto_routing_and_persistence :: proc(t: ^testing.T) {
	sm: mcp.Session_Manager
	mcp.session_manager_init(&sm)
	defer mcp.session_manager_destroy_all(&sm)

	// 1. Calling terminal_run_command with no session_id should auto-create "default"
	run_args_json := `{"command":"export PERSISTENT_VAR=xyz123 && echo $PERSISTENT_VAR"}`
	val_args, _ := json.parse_string(run_args_json, parse_integers = true)
	defer json.destroy_value(val_args)

	res1, err1, _ := mcp.tools_dispatch_call(&sm, "terminal_run_command", val_args)
	defer delete(res1)
	testing.expect(t, !err1, "first auto run should succeed")

	parsed1, _ := json.parse_string(res1, parse_integers = true)
	defer json.destroy_value(parsed1)
	obj1 := parsed1.(json.Object)
	testing.expect(t, strings.contains(obj1["output"].(json.String), "xyz123"), "output should show persistent variable")
	testing.expect(t, obj1["session_id"].(json.String) == "default", "first session must be 'default'")

	// 2. Second command without session_id must reuse "default" and retain environment
	run2_args_json := `{"command":"echo persistent_$PERSISTENT_VAR"}`
	val2, _ := json.parse_string(run2_args_json, parse_integers = true)
	defer json.destroy_value(val2)

	res2, err2, _ := mcp.tools_dispatch_call(&sm, "terminal_run_command", val2)
	defer delete(res2)
	testing.expect(t, !err2, "second auto run should succeed")

	parsed2, _ := json.parse_string(res2, parse_integers = true)
	defer json.destroy_value(parsed2)
	obj2 := parsed2.(json.Object)
	testing.expect(t, strings.contains(obj2["output"].(json.String), "persistent_xyz123"), "environment must persist across calls")

	// 3. Mark default session as busy, auto-route should spawn a new session inheriting cwd
	def_s, _ := mcp.session_manager_get(&sm, "default")
	def_s.is_busy = true

	route_id, new_s, route_ok := mcp.session_manager_route_auto(&sm)
	testing.expect(t, route_ok, "auto-routing should spawn when active is busy")
	testing.expect(t, route_id != "default", "routed session must be different from busy session")
	testing.expect(t, new_s != nil, "new session pointer should not be nil")
	testing.expect(t, new_s.cwd == def_s.cwd, "new session must inherit parent cwd")

	// Unbusy
	def_s.is_busy = false
}

@test
test_mcp_output_noise_filtering :: proc(t: ^testing.T) {
	// 1. Blank line stripping and compaction
	raw_lines := []string{
		"",
		"   ",
		"line 1",
		"",
		"    ",
		"",
		"line 2",
		"",
		"  ",
	}

	out, total, trunc := session_core.session_filter_output_noise(raw_lines, 250)
	defer delete(out)

	testing.expect(t, !trunc, "should not be truncated")
	testing.expect(t, total == 3, "should be 3 lines: line 1, empty line, line 2")
	expected := "line 1\n\nline 2"
	testing.expect(t, out == expected, fmt.tprintf("expected '%s', got '%s'", expected, out))

	// 2. Dedup consecutive identical lines
	dedup_lines := []string{
		"header",
		"dup error",
		"dup error",
		"dup error",
		"dup error",
		"dup error",
		"footer",
	}
	out_d, total_d, _ := session_core.session_filter_output_noise(dedup_lines, 250)
	defer delete(out_d)
	testing.expect(t, strings.contains(out_d, "[... repeated 4 times ...]"), "must contain repeated marker")
	testing.expect(t, total_d == 4, "deduped lines count must be 4")

	// 3. Head/Tail Truncation
	many_lines := make([]string, 300, context.temp_allocator)
	for i in 0 ..< 300 {
		many_lines[i] = fmt.tprintf("entry %d", i)
	}
	out_t, total_t, trunc_t := session_core.session_filter_output_noise(many_lines, 250)
	defer delete(out_t)
	testing.expect(t, trunc_t, "should be truncated")
	testing.expect(t, total_t == 300, "total_lines should reflect 300")
	testing.expect(t, strings.contains(out_t, "[... 50 lines truncated to save tokens ...]"), "must contain truncation marker")
	testing.expect(t, strings.contains(out_t, "entry 0"), "head must contain entry 0")
	testing.expect(t, strings.contains(out_t, "entry 299"), "tail must contain entry 299")
}

@test
test_mcp_list_commands_and_get_output :: proc(t: ^testing.T) {
	sm: mcp.Session_Manager
	mcp.session_manager_init(&sm)
	defer mcp.session_manager_destroy_all(&sm)

	// Run command
	run_json := `{"command":"echo line_alpha && echo line_beta_needle && echo line_gamma"}`
	val_run, _ := json.parse_string(run_json, parse_integers = true)
	defer json.destroy_value(val_run)

	res_run, err_run, _ := mcp.tools_dispatch_call(&sm, "terminal_run_command", val_run)
	defer delete(res_run)
	testing.expect(t, !err_run, "run command should succeed")
	parsed_run, run_parse_err := json.parse_string(res_run, parse_integers = true)
	if !testing.expect(t, run_parse_err == .None) do return
	defer json.destroy_value(parsed_run)
	run_obj := parsed_run.(json.Object)
	expected_output :: "line_alpha\nline_beta_needle\nline_gamma"
	testing.expect_value(t, run_obj["output"].(json.String), expected_output)
	run_content := run_obj["content"].(json.Array)
	testing.expect_value(t, run_content[0].(json.Object)["text"].(json.String), "[exit: 0]\n" + expected_output)

	session_id := string(run_obj["session_id"].(json.String))
	session, found_session := mcp.session_manager_get(&sm, session_id)
	if !testing.expect(t, found_session && session != nil, "run session must exist") do return
	if !testing.expect(t, len(session.command_history) == 1, "run must record one command") do return
	recorded_lines := session.command_history[0].output_lines[:]
	expected_raw_output := strings.join(recorded_lines, "\n")
	defer delete(expected_raw_output)
	testing.expect_value(t, strings.trim_space(expected_raw_output), expected_output)

	// List commands
	list_res, list_err, _ := mcp.tools_dispatch_call(&sm, "terminal_list_commands", nil)
	defer delete(list_res)
	testing.expect(t, !list_err, "list commands should succeed")
	parsed_list, _ := json.parse_string(list_res, parse_integers = true)
	defer json.destroy_value(parsed_list)
	list_obj := parsed_list.(json.Object)
	cmds_arr := list_obj["commands"].(json.Array)
	testing.expect(t, len(cmds_arr) == 1, "must have 1 command recorded")

	// Get output without filter
	get_res, get_err, _ := mcp.tools_dispatch_call(&sm, "terminal_get_output", nil)
	defer delete(get_res)
	testing.expect(t, !get_err, "get output should succeed")
	testing.expect(t, strings.contains(get_res, "line_alpha"), "output must contain line_alpha")
	parsed_get, _ := json.parse_string(get_res, parse_integers = true)
	defer json.destroy_value(parsed_get)
	get_obj := parsed_get.(json.Object)
	testing.expect_value(t, get_obj["output"].(json.String), expected_raw_output)
	get_content := get_obj["content"].(json.Array)
	testing.expect_value(t, get_content[0].(json.Object)["text"].(json.String), expected_raw_output)
	testing.expect_value(t, get_obj["total_lines"].(json.Integer), json.Integer(len(recorded_lines)))
	testing.expect_value(t, get_obj["total_matched"].(json.Integer), json.Integer(len(recorded_lines)))

	// Get output with grep
	grep_json := `{"grep":"needle"}`
	val_grep, _ := json.parse_string(grep_json, parse_integers = true)
	defer json.destroy_value(val_grep)

	grep_res, grep_err, _ := mcp.tools_dispatch_call(&sm, "terminal_get_output", val_grep)
	defer delete(grep_res)
	testing.expect(t, !grep_err, "grep output should succeed")
	parsed_grep, _ := json.parse_string(grep_res, parse_integers = true)
	defer json.destroy_value(parsed_grep)
	grep_obj := parsed_grep.(json.Object)
	testing.expect(t, grep_obj["total_matched"].(json.Integer) == 1, fmt.tprintf("matched count must be 1; run=%s get=%s grep=%s", res_run, get_res, grep_res))
	testing.expect(t, strings.contains(grep_obj["output"].(json.String), "line_beta_needle"), "must match needle")
	testing.expect(t, !strings.contains(grep_obj["output"].(json.String), "line_alpha"), "must not contain non-matching lines")

	// Filtering precedes pagination, is case insensitive, and keeps historical output.
	second_args, _ := json.parse_string(`{"command":"echo next_command"}`)
	defer json.destroy_value(second_args)
	second_res, second_err, _ := mcp.tools_dispatch_call(&sm, "terminal_run_command", second_args)
	defer delete(second_res)
	testing.expect(t, !second_err)
	for query in ([]struct { args, output: string, matched: int }{
		{`{"command_id":1,"grep":"NEEDLE"}`, "line_beta_needle", 1},
		{`{"command_id":1,"grep":"LINE_","offset":1,"limit":1}`, "line_beta_needle", 3},
		{`{"command_id":1,"grep":"absent"}`, "", 0},
		{`{"command_id":1,"grep":"LINE_","offset":3,"limit":1}`, "", 3},
	}) {
		args, _ := json.parse_string(query.args, parse_integers = true)
		defer json.destroy_value(args)
		res, err, _ := mcp.tools_dispatch_call(&sm, "terminal_get_output", args)
		defer delete(res)
		if !testing.expect(t, !err, res) do continue
		parsed, _ := json.parse_string(res, parse_integers = true)
		defer json.destroy_value(parsed)
		obj := parsed.(json.Object)
		testing.expect_value(t, obj["output"].(json.String), query.output)
		testing.expect_value(t, obj["total_matched"].(json.Integer), json.Integer(query.matched))
		content := obj["content"].(json.Array)
		testing.expect_value(t, content[0].(json.Object)["text"].(json.String), query.output)
	}
}

@test
test_mcp_get_output_preserves_raw_lines :: proc(t: ^testing.T) {
	sm: mcp.Session_Manager
	mcp.session_manager_init(&sm)
	defer mcp.session_manager_destroy_all(&sm)

	session_id, session, created := mcp.session_manager_create(&sm, 24, 80, mode = .Fast_Headless)
	if !testing.expect(t, created && session != nil, "fixture session must be created") do return
	fixture_lines := []string{"", "raw repeated", "raw repeated", "raw repeated", "  ", "tail", ""}
	record := session_core.Command_Record{
		id = 1,
		command = strings.clone("raw output fixture"),
		completed = true,
		total_lines = len(fixture_lines),
		output_lines = make([dynamic]string),
	}
	for line in fixture_lines {
		append(&record.output_lines, strings.clone(line))
	}
	// Session destruction owns the record and each cloned string.
	append(&session.command_history, record)
	expected_raw_output := strings.join(fixture_lines, "\n")
	defer delete(expected_raw_output)

	args, args_err := json.parse_string(fmt.tprintf(`{{"session_id":"%s","command_id":%d}}`, session_id, record.id), parse_integers = true)
	if !testing.expect(t, args_err == .None) do return
	defer json.destroy_value(args)
	res, err, _ := mcp.tools_dispatch_call(&sm, "terminal_get_output", args)
	defer delete(res)
	if !testing.expect(t, !err, res) do return
	parsed, parse_err := json.parse_string(res, parse_integers = true)
	if !testing.expect(t, parse_err == .None) do return
	defer json.destroy_value(parsed)
	obj := parsed.(json.Object)
	testing.expect_value(t, obj["output"].(json.String), expected_raw_output)
	content := obj["content"].(json.Array)
	testing.expect_value(t, content[0].(json.Object)["text"].(json.String), expected_raw_output)
	testing.expect_value(t, obj["total_lines"].(json.Integer), json.Integer(len(fixture_lines)))
	testing.expect_value(t, obj["total_matched"].(json.Integer), json.Integer(len(fixture_lines)))
}

@test
test_mcp_run_parallel :: proc(t: ^testing.T) {
	sm: mcp.Session_Manager
	mcp.session_manager_init(&sm)
	defer mcp.session_manager_destroy_all(&sm)

	par_json := `{"commands":["echo p1_result","echo p2_result","echo p3_result"]}`
	val_par, _ := json.parse_string(par_json, parse_integers = true)
	defer json.destroy_value(val_par)

	res_par, err_par, _ := mcp.tools_dispatch_call(&sm, "terminal_run_parallel", val_par)
	defer delete(res_par)
	testing.expect(t, !err_par, "parallel command should succeed")

	parsed_par, parse_err := json.parse_string(res_par, parse_integers = true)
	testing.expect(t, parse_err == .None, "parallel response must be valid JSON")
	defer json.destroy_value(parsed_par)

	par_obj := parsed_par.(json.Object)
	res_arr, has_res := par_obj["results"].(json.Array)
	testing.expect(t, has_res, "results must be an array")
	testing.expect(t, len(res_arr) == 3, "must have 3 results")

	for item in res_arr {
		item_obj := item.(json.Object)
		testing.expect(t, item_obj["exit_code"].(json.Integer) == 0, "exit code must be 0")
		testing.expect(t, item_obj["completed"].(json.Boolean) == true, "completed must be true")
	}
}
