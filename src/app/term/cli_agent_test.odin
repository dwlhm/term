package term

import "core:testing"

@(test)
test_cli_unescape :: proc(t: ^testing.T) {
	buf: [32]u8
	n := app_cli_unescape(`ls -l\r\e[A\x41\\`, buf[:])
	testing.expect_value(t, string(buf[:n]), "ls -l\r\x1b[AA\\")
	testing.expect_value(t, app_cli_unescape(`bad\q`, buf[:]), -1)
	testing.expect_value(t, app_cli_unescape(`\x4`, buf[:]), -1)
	testing.expect_value(t, app_cli_unescape("trailing\\", buf[:]), -1)
	testing.expect_value(t, app_cli_unescape("0123456789012345678901234567890123", buf[:]), -1)
}
