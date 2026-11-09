package term

// Tests R3, N7: parse size COLSxROWS within 2x1..1000x500 (spec 4.5, 4.7).

import "core:testing"

@(test)
test_R3_N7_valid_size_accepted :: proc(t: ^testing.T) {
	cases := []struct {
		input: string,
		cols:  u16,
		rows:  u16,
	}{
		{"2x1", 2, 1},
		{"80x24", 80, 24},
		{"100x30", 100, 30},
		{"1000x500", 1000, 500},
	}
	for c in cases {
		size, ok := app_cli_parse_size(c.input)
		testing.expect(t, ok, "valid size accepted")
		testing.expect_value(t, size.cols, c.cols)
		testing.expect_value(t, size.rows, c.rows)
	}
}

@(test)
test_R3_N7_invalid_size_rejected :: proc(t: ^testing.T) {
	bad := []string{
		"abc",
		"0x0",
		"1x1", // cols < 2
		"2x0", // rows < 1
		"1001x30", // cols > 1000
		"80x501", // rows > 500
		"99999x99999",
		"-10x20",
		"80",
		"80x",
		"x24",
	}
	for b in bad {
		_, ok := app_cli_parse_size(b)
		testing.expect(t, !ok, "invalid size rejected")
	}
}
