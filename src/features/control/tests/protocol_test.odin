package feature_control_tests

import "core:strings"
import "core:testing"
import control ".."

Parse_Case :: struct {
	line:  string,
	verb:  control.Control_Verb,
	id:    u32,
	force: bool,
}

Parse_Error_Case :: struct {
	line: string,
	err:  control.Control_Parse_Error,
}

Format_Case :: struct {
	verb:  control.Control_Verb,
	id:    u32,
	force: bool,
}

Split_Case :: struct {
	reply:       string,
	ok:          bool,
	code:        string,
	message:     string,
	body:        string,
	well_formed: bool,
}

@test
test_parse_valid :: proc(t: ^testing.T) {
	cases := []Parse_Case{
		{"ping", .Ping, 0, false},
		{"show", .Show, 0, false},
		{"quit", .Quit, 0, false},
		{"quit --force", .Quit, 0, true},
		{"quit -f", .Quit, 0, true},
		{"quit force", .Quit, 0, true},
		{"quit --all", .Quit, 0, true},
		{"quit -a", .Quit, 0, true},
		{"ls", .List, 0, false},
		{"  attach 42  ", .Attach, 42, false},
		{"kill   7", .Kill, 7, false},
	}
	for c in cases {
		req, err := control.control_parse_request(c.line)
		testing.expectf(t, err == .None, "%q: expected no error, got %v", c.line, err)
		testing.expectf(t, req.verb == c.verb, "%q: expected verb %v, got %v", c.line, c.verb, req.verb)
		testing.expectf(t, req.id == c.id, "%q: expected id %d, got %d", c.line, c.id, req.id)
		testing.expectf(t, req.force == c.force, "%q: expected force %v, got %v", c.line, c.force, req.force)
	}
}

@test
test_parse_errors :: proc(t: ^testing.T) {
	cases := []Parse_Error_Case{
		{"", .Empty},
		{"   ", .Empty},
		{"foo", .Unknown_Verb},
		{"attach", .Missing_Id},
		{"attach x", .Bad_Id},
		{"attach 0", .Bad_Id},
		{"attach 4294967296", .Bad_Id},
		{"attach -1", .Bad_Id},
		{"ls extra", .Extra_Args},
		{"kill 1 2", .Extra_Args},
		{"ATTACH 1", .Unknown_Verb},
	}
	for c in cases {
		_, err := control.control_parse_request(c.line)
		testing.expectf(t, err == c.err, "%q: expected %v, got %v", c.line, c.err, err)
	}
}

@test
test_format_roundtrip :: proc(t: ^testing.T) {
	cases := []Format_Case{
		{.Ping, 0, false},
		{.Show, 0, false},
		{.Quit, 0, false},
		{.Quit, 0, true},
		{.List, 0, false},
		{.Attach, 7, false},
		{.Kill, 42, false},
	}
	for c in cases {
		req := control.Control_Request{verb = c.verb, id = c.id, force = c.force}
		buf: [64]u8
		line := control.control_format_request(req, buf[:])
		parsed, err := control.control_parse_request(line)
		testing.expectf(t, err == .None, "%v: roundtrip parse error %v (%q)", c.verb, err, line)
		testing.expectf(t, parsed == req, "%v: expected %v, got %v (%q)", c.verb, req, parsed, line)
	}
}

@test
test_write_err_and_split_reply :: proc(t: ^testing.T) {
	b: strings.Builder
	strings.builder_init(&b)
	defer strings.builder_destroy(&b)

	control.control_write_err(&b, .Not_Found, "no such\nsession")
	written := strings.to_string(b)
	testing.expect_value(t, written, "err not_found no such session\n")

	ok, code, message, body, well_formed := control.control_split_reply(written)
	testing.expect(t, !ok, "err reply must not be ok")
	testing.expect(t, well_formed, "err reply must be well formed")
	testing.expect_value(t, code, "not_found")
	testing.expect_value(t, message, "no such session")
	testing.expect_value(t, body, "")

	cases := []Split_Case{
		{"ok\n", true, "", "", "", true},
		{"ok\nterm 2.1.1\n", true, "", "", "term 2.1.1\n", true},
		{"err busy\n", false, "busy", "", "", true},
		{"nonsense", false, "", "", "", false},
	}
	for c in cases {
		got_ok, got_code, got_message, got_body, got_wf := control.control_split_reply(c.reply)
		testing.expectf(t, got_ok == c.ok, "%q: ok %v", c.reply, got_ok)
		testing.expectf(t, got_wf == c.well_formed, "%q: well_formed %v", c.reply, got_wf)
		testing.expectf(t, got_code == c.code, "%q: code %q", c.reply, got_code)
		testing.expectf(t, got_message == c.message, "%q: message %q", c.reply, got_message)
		testing.expectf(t, got_body == c.body, "%q: body %q", c.reply, got_body)
	}
}
