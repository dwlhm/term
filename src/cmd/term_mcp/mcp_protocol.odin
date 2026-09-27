package main

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"

// MCP and JSON-RPC 2.0 Protocol Constants
JSON_RPC_VERSION :: "2.0"
MCP_PROTOCOL_VERSION :: "2024-11-05"
MCP_SERVER_NAME :: "term-mcp"
MCP_SERVER_VERSION :: "1.0.0"

// Standard JSON-RPC 2.0 Error Codes
RPC_PARSE_ERROR :: -32700
RPC_INVALID_REQUEST :: -32600
RPC_METHOD_NOT_FOUND :: -32601
RPC_INVALID_PARAMS :: -32602
RPC_INTERNAL_ERROR :: -32603

// Parsed JSON-RPC Request Representation
JSON_RPC_Request :: struct {
	jsonrpc:         string,
	id:              json.Value,
	method:          string,
	params:          json.Value,
	is_notification: bool,
}

// JSON-RPC Error Payload
JSON_RPC_Error :: struct {
	code:    int,
	message: string,
	data:    json.Value,
}

// MCP Client Information
MCP_Client_Info :: struct {
	name:    string,
	version: string,
}

// MCP Initialize Parameters
MCP_Initialize_Params :: struct {
	protocol_version: string,
	client_info:      MCP_Client_Info,
}

// MCP Text Content inside CallToolResult
MCP_Text_Content :: struct {
	type: string,
	text: string,
}

// MCP Call Tool Result
MCP_Call_Tool_Result :: struct {
	content:  [dynamic]MCP_Text_Content,
	is_error: bool,
}

// parse_json_rpc_request parses a raw incoming JSON string into a JSON_RPC_Request.
// The caller is responsible for calling json.destroy_value(raw_val) when finished with the request.
parse_json_rpc_request :: proc(raw: string, allocator := context.allocator) -> (req: JSON_RPC_Request, raw_val: json.Value, ok: bool, err_code: int, err_msg: string) {
	val, err := json.parse_string(raw, parse_integers = true, allocator = allocator)
	if err != .None {
		return req, val, false, RPC_PARSE_ERROR, "Parse error: invalid JSON"
	}
	raw_val = val

	root_obj, is_obj := val.(json.Object)
	if !is_obj {
		return req, raw_val, false, RPC_INVALID_REQUEST, "Invalid Request: root must be an object"
	}

	// Check jsonrpc field
	if rpc_ver_val, has_ver := root_obj["jsonrpc"]; has_ver {
		if ver_str, is_str := rpc_ver_val.(json.String); is_str {
			req.jsonrpc = ver_str
		}
	}
	if req.jsonrpc != JSON_RPC_VERSION {
		return req, raw_val, false, RPC_INVALID_REQUEST, "Invalid Request: jsonrpc must be '2.0'"
	}

	// Check method field
	method_val, has_method := root_obj["method"]
	if !has_method {
		return req, raw_val, false, RPC_INVALID_REQUEST, "Invalid Request: missing method"
	}
	method_str, method_is_str := method_val.(json.String)
	if !method_is_str {
		return req, raw_val, false, RPC_INVALID_REQUEST, "Invalid Request: method must be string"
	}
	req.method = method_str

	// Check id field (optional for notifications)
	if id_val, has_id := root_obj["id"]; has_id {
		req.id = id_val
		req.is_notification = false
	} else {
		req.id = nil
		req.is_notification = true
	}

	// Check params field (optional)
	if params_val, has_params := root_obj["params"]; has_params {
		req.params = params_val
	} else {
		req.params = nil
	}

	return req, raw_val, true, 0, ""
}

// json_value_to_id_string writes out the JSON representation of an id (int, string, or null).
json_value_to_id_string :: proc(b: ^strings.Builder, id: json.Value) {
	#partial switch v in id {
	case json.Integer:
		strings.write_i64(b, v)
	case json.Float:
		strings.write_f64(b, v, 'f')
	case json.String:
		strings.write_byte(b, '"')
		escape_json_string(b, v)
		strings.write_byte(b, '"')
	case:
		strings.write_string(b, "null")
	}
}

// escape_json_string escapes control characters and quotes for standard JSON output.
escape_json_string :: proc(b: ^strings.Builder, s: string) {
	for i in 0 ..< len(s) {
		ch := s[i]
		switch ch {
		case '"':
			strings.write_string(b, "\\\"")
		case '\\':
			strings.write_string(b, "\\\\")
		case '\b':
			strings.write_string(b, "\\b")
		case 12: // form feed \f
			strings.write_string(b, "\\f")
		case '\n':
			strings.write_string(b, "\\n")
		case '\r':
			strings.write_string(b, "\\r")
		case '\t':
			strings.write_string(b, "\\t")
		case 0 ..< 32:
			strings.write_string(b, fmt.tprintf("\\u%04x", ch))
		case:
			strings.write_byte(b, ch)
		}
	}
}

// make_json_rpc_result formats a JSON-RPC 2.0 success response string.
make_json_rpc_result :: proc(id: json.Value, result_json: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"jsonrpc\":\"2.0\",\"id\":")
	json_value_to_id_string(&b, id)
	strings.write_string(&b, ",\"result\":")
	strings.write_string(&b, result_json)
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

// make_json_rpc_error formats a JSON-RPC 2.0 error response string.
make_json_rpc_error :: proc(id: json.Value, code: int, message: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"jsonrpc\":\"2.0\",\"id\":")
	json_value_to_id_string(&b, id)
	strings.write_string(&b, ",\"error\":{\"code\":")
	strings.write_int(&b, code)
	strings.write_string(&b, ",\"message\":\"")
	escape_json_string(&b, message)
	strings.write_string(&b, "\"}}")
	return strings.to_string(b)
}
