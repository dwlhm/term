package term

import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_RD3_read_missing_session_error :: proc(t: ^testing.T) {
	// Outside term session, reading without ID must error "which session? read <id>"
	orig_id := os.get_env("TERM_SESSION_ID", context.temp_allocator)
	os.unset_env("TERM_SESSION_ID")
	defer if len(orig_id) > 0 do os.set_env("TERM_SESSION_ID", orig_id)

	opts, ok := app_cli_parse_read({})
	testing.expect(t, !ok, "fails without ID when not inside term")
	testing.expect_value(t, opts.err_msg, "which session? read <id>")
}

@(test)
test_RD2_read_own_session :: proc(t: ^testing.T) {
	orig_id := os.get_env("TERM_SESSION_ID", context.temp_allocator)
	os.set_env("TERM_SESSION_ID", "42")
	defer {
		if len(orig_id) > 0 do os.set_env("TERM_SESSION_ID", orig_id)
		else do os.unset_env("TERM_SESSION_ID")
	}

	opts, ok := app_cli_parse_read({})
	testing.expect(t, ok, "succeeds using TERM_SESSION_ID")
	testing.expect_value(t, opts.id, u32(42))
}

@(test)
test_RD6_read_invalid_n_error :: proc(t: ^testing.T) {
	bad_args := [][]string{{"1", "-n"}, {"1", "-n", "-1"}, {"1", "-n", "abc"}}
	for a in bad_args {
		opts, ok := app_cli_parse_read(a)
		testing.expect(t, !ok, "rejects invalid -n")
		testing.expect_value(t, opts.err_msg, "-n takes a number of lines")
	}
}

@(test)
test_RD18_clean_text_strips_box_borders :: proc(t: ^testing.T) {
	box_text := "┌────────────┐\n│ Hello Box  │\n└────────────┘\n"
	cleaned := app_clean_text(box_text, context.temp_allocator)
	testing.expect(t, strings.contains(cleaned, "Hello Box"), "content preserved")
	testing.expect(t, !strings.contains(cleaned, "┌"), "box corner stripped")
	testing.expect(t, !strings.contains(cleaned, "│"), "box vertical border stripped")
	testing.expect(t, !strings.contains(cleaned, "─"), "box horizontal border stripped")
}

@(test)
test_RD19_clean_text_leaves_plain_text :: proc(t: ^testing.T) {
	plain := "hello world\nsecond line\n"
	cleaned := app_clean_text(plain, context.temp_allocator)
	testing.expect_value(t, cleaned, "hello world\nsecond line\n")
}
