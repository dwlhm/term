package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

global_sm: Session_Manager

main :: proc() {
	session_manager_init(&global_sm)
	defer session_manager_destroy_all(&global_sm)

	fmt.eprintfln("[term-mcp] Server starting (PID: %d)", os.get_pid())

	read_buf: [4096]u8
	acc: [dynamic]u8
	defer delete(acc)

	for {
		n, err := os.read(os.stdin, read_buf[:])
		if err != nil || n <= 0 {
			break
		}

		for i in 0 ..< n {
			append(&acc, read_buf[i])
		}

		// Process all complete messages in accumulator
		for len(acc) > 0 {
			acc_str := string(acc[:])

			// 1. Check for Content-Length framing (LSP / MCP standard variant)
			if strings.has_prefix(acc_str, "Content-Length:") {
				header_end := strings.index(acc_str, "\r\n\r\n")
				sep_len := 4
				if header_end == -1 {
					header_end = strings.index(acc_str, "\n\n")
					sep_len = 2
				}

				if header_end != -1 {
					header_line := acc_str[len("Content-Length:") : header_end]
					content_len, _ := strconv.parse_int(strings.trim_space(header_line))
					body_start := header_end + sep_len
					if len(acc) >= body_start + content_len {
						body := string(acc[body_start : body_start + content_len])
						dispatch_message(body)

						// Shift accumulator past consumed message
						total_consumed := body_start + content_len
						copy(acc[:], acc[total_consumed:])
						resize(&acc, len(acc) - total_consumed)
						continue
					}
				}
				// Incomplete Content-Length payload: wait for more bytes
				break
			}

			// 2. Check for newline-delimited JSON (standard MCP stdio)
			newline_idx := strings.index_byte(acc_str, '\n')
			if newline_idx != -1 {
				line := strings.trim_space(acc_str[:newline_idx])
				total_consumed := newline_idx + 1

				copy(acc[:], acc[total_consumed:])
				resize(&acc, len(acc) - total_consumed)

				if len(line) > 0 {
					dispatch_message(line)
				}
				continue
			}

			// Incomplete line: wait for more bytes
			break
		}
	}

	fmt.eprintfln("[term-mcp] Shutting down cleanly")
}

// dispatch_message handles a single JSON-RPC message string.
dispatch_message :: proc(raw_json: string) {
	req, raw_val, ok, err_code, err_msg := parse_json_rpc_request(raw_json, context.allocator)
	defer {
		if raw_val != nil {
			json.destroy_value(raw_val, context.allocator)
		}
		free_all(context.temp_allocator)
	}

	if !ok {
		// Only respond with error if not a notification
		resp := make_json_rpc_error(nil, err_code, err_msg, context.temp_allocator)
		send_response(resp)
		return
	}

	// Notifications have no id and must not receive a response
	if req.is_notification {
		switch req.method {
		case "notifications/initialized", "initialized":
			// Handshake acknowledgment notification: no-op
		case:
			fmt.eprintfln("[term-mcp] Notification ignored: %s", req.method)
		}
		return
	}

	switch req.method {
	case "initialize":
		// Handle MCP initialize handshake
		result := fmt.tprintf(
			`{{"protocolVersion":"%s","capabilities":{{"tools":{{}}}},"serverInfo":{{"name":"%s","version":"%s"}}}}`,
			MCP_PROTOCOL_VERSION,
			MCP_SERVER_NAME,
			MCP_SERVER_VERSION,
		)
		resp := make_json_rpc_result(req.id, result, context.temp_allocator)
		send_response(resp)

	case "ping":
		resp := make_json_rpc_result(req.id, "{}", context.temp_allocator)
		send_response(resp)

	case "tools/list":
		resp := make_json_rpc_result(req.id, TOOLS_LIST_JSON, context.temp_allocator)
		send_response(resp)

	case "tools/call":
		params_obj, is_obj := req.params.(json.Object)
		if !is_obj {
			resp := make_json_rpc_error(req.id, RPC_INVALID_PARAMS, "params must be an object", context.temp_allocator)
			send_response(resp)
			return
		}

		tool_name := _json_get_string(params_obj, "name", "")
		if len(tool_name) == 0 {
			resp := make_json_rpc_error(req.id, RPC_INVALID_PARAMS, "Missing tool 'name'", context.temp_allocator)
			send_response(resp)
			return
		}

		args_val := params_obj["arguments"]
		result_json, is_err, err_detail := tools_dispatch_call(&global_sm, tool_name, args_val, context.temp_allocator)
		if is_err {
			resp := make_json_rpc_error(req.id, RPC_INVALID_PARAMS, err_detail, context.temp_allocator)
			send_response(resp)
		} else {
			resp := make_json_rpc_result(req.id, result_json, context.temp_allocator)
			send_response(resp)
		}

	case:
		resp := make_json_rpc_error(req.id, RPC_METHOD_NOT_FOUND, fmt.tprintf("Method not found: '%s'", req.method), context.temp_allocator)
		send_response(resp)
	}
}

// send_response writes a JSON-RPC response to stdout followed by a newline and flushes.
send_response :: proc(resp: string) {
	os.write_string(os.stdout, resp)
	os.write_string(os.stdout, "\n")
	os.flush(os.stdout)
}
