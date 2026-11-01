package terminal_tests

import "core:testing"
import extension "../extension"

@(test)
test_osc_7501_encode_roundtrips :: proc(t: ^testing.T) {
	src, ok := extension.osc_7501_parse("state=blocked:app=claude-code:kind=permission:msg=UnVuIGxzPw==")
	testing.expect(t, ok)
	out: [dynamic]u8
	defer delete(out)
	extension.osc_7501_encode(&src, &out)
	s := string(out[:])
	testing.expect(t, len(s) > 9 && s[:8] == "\x1b]7501;" + "s" && s[len(s) - 2:] == "\x1b\\")
	back, ok2 := extension.osc_7501_parse(s[len("\x1b]7501;"):len(s) - 2])
	testing.expect(t, ok2)
	testing.expect_value(t, back.state, src.state)
	testing.expect_value(t, extension.program_status_app(&back), "claude-code")
	testing.expect_value(t, extension.program_status_msg(&back), "Run ls?")
	clear(&out)
	none: extension.Program_Status
	extension.osc_7501_encode(&none, &out)
	testing.expect_value(t, len(out), 0)
}
