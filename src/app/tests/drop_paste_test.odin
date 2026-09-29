package app_test

import "core:testing"
import "core:strings"
import posix "core:sys/posix"
import app "../"
import input "../../platform/input"

@test
test_drop_payload_uses_active_paste_protocol :: proc(t: ^testing.T) {
	Case :: struct {
		kind: input.Input_Drop_Kind,
		payload, expected: string,
		bracketed, exited: bool,
	}
	cases := []Case{
		{.File, "/tmp/my image.png", "\x1b[200~'/tmp/my image.png'\x1b[201~", true, false},
		{.File, "/tmp/it's an image.png", "'/tmp/it'\\''s an image.png'", false, false},
		{.Text, "some dropped text", "\x1b[200~some dropped text\x1b[201~", true, false},
		{.Text, "plain text", "plain text", false, false},
		{.Text, "before\x1b[201~after", "\x1b[200~beforeafter\x1b[201~", true, false},
		{.Text, "", "", true, false},
		{.File, "/tmp/ignored.png", "", true, true},
	}
	for c in cases {
		a := new(app.App)
		defer free(a)
		pipefd: [2]posix.FD
		if posix.pipe(&pipefd) != .OK {
			testing.expect(t, false, "paste capture pipe must open")
			return
		}
		defer posix.close(pipefd[0])
		a.pty.master = int(pipefd[1])
		a.pty.state = .Exited if c.exited else .Running
		a.terminal.bracketed_paste = c.bracketed
		event := input.Input_Event{
			event_type = .Drop,
			drop = {kind = c.kind, text = strings.clone(c.payload)},
		}
		_, ok := app.app_dispatch_input_events(a, {event})
		testing.expect(t, ok)
		// EOF also lets empty/exited regressions fail without a blocking read.
		posix.close(pipefd[1])
		buf: [256]u8
		n := posix.read(pipefd[0], raw_data(buf[:]), len(buf))
		testing.expect(t, n >= 0)
		if n >= 0 { testing.expect_value(t, string(buf[:n]), c.expected) }
	}
}
