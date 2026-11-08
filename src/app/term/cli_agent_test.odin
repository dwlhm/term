package term

import "core:testing"
import proto "../../features/session_proto"

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

@(test)
test_cli_parse_new :: proc(t: ^testing.T) {
	spec: proto.Spawn_Msg
	testing.expect(t, app_cli_parse_new({"-d", "/tmp", "-s", "200x50", "-e", "A=1", "-e", "B=", "--", "make", "test"}, &spec))
	testing.expect_value(t, spec.cwd, "/tmp")
	testing.expect_value(t, spec.size, proto.Size_Msg{cols = 200, rows = 50})
	testing.expect_value(t, spec.envc, 2)
	testing.expect_value(t, spec.env[1], "B=")
	testing.expect_value(t, spec.argc, 2)
	testing.expect_value(t, spec.argv[0], "make")

	testing.expect(t, app_cli_parse_new({}, &spec), "no args = shell")
	testing.expect_value(t, spec.argc, 2)
	testing.expect_value(t, spec.argv[1], "-l") // a login shell, said explicitly
	testing.expect_value(t, spec.size, proto.Size_Msg{cols = 120, rows = 36})

	bad := [][]string{{"-s"}, {"-s", "200"}, {"-s", "0x5"}, {"-s", "x5"}, {"-s", "10000x5"}, {"-s", "5x-1"}, {"-e", "=v"}, {"-e", "NOEQ"}, {"-x", "1"}, {"-d"}}
	for args in bad do testing.expectf(t, !app_cli_parse_new(args, &spec), "rejects %v", args)
	many := make([]string, proto.STREAM_MAX_ARGV + 2, context.temp_allocator)
	many[0] = "--"
	for i in 1..<len(many) do many[i] = "a"
	testing.expect(t, !app_cli_parse_new(many, &spec), "too many args is an error, not a silent cut")
}

@(test)
test_cli_parse_signal :: proc(t: ^testing.T) {
	cases := []struct{s: string, sig: i32}{{"INT", 2}, {"sigterm", 15}, {"SIGKILL", 9}, {"hup", 1}, {"9", 9}, {"64", 64}}
	for c in cases {
		sig, ok := app_cli_parse_signal(c.s)
		testing.expectf(t, ok && sig == c.sig, "%s → %d (got %d %v)", c.s, c.sig, sig, ok)
	}
	for bad in ([]string{"", "0", "65", "SIG", "NOPE", "-2", "SIGSIGINT"}) {
		_, ok := app_cli_parse_signal(bad)
		testing.expectf(t, !ok, "rejects %q", bad)
	}
}
