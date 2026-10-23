package terminal_tests

// Security regression tests for the Kitty graphics protocol.
//
// Everything here is reachable from a hostile PTY stream: oversized geometry,
// arbitrary paths, non-regular files, unknown shared-memory objects and an
// exhausted pixel budget must all be neutralised without crashing the terminal
// or touching user data.

import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import term "../"
import extension "../extension"

_kitty_test_state :: proc(t: ^testing.T, terminal: ^term.Terminal) -> ^extension.Kitty_Extension {
	for i in 0..<terminal.extensions.ext_count {
		e := &terminal.extensions.extensions[i]
		if e.name == "kitty_graphics" && e.user_data != nil {
			return (^extension.Kitty_Extension)(e.user_data)
		}
	}
	panic("kitty graphics extension must be registered")
}

// The Terminal stores self-referential pointers (parser.user_data), so it must
// never be copied by value: initialise it in place at its final address.
_kitty_test_init :: proc(terminal: ^term.Terminal) {
	term.terminal_init(terminal, 24, 80)
	term.terminal_register_extension(terminal, extension.kitty_graphics_extension_make())
}

_kitty_send_path :: proc(terminal: ^term.Terminal, medium: u8, path: string) {
	encoded := base64.encode(transmute([]u8)path, base64.ENC_TABLE, context.temp_allocator)
	apc := fmt.tprintf("\x1b_Gt=%c,f=32,s=1,v=1;%s\x1b\\", medium, encoded)
	term.terminal_feed_string(terminal, apc)
}

@test
test_kitty_rejects_oversized_geometry :: proc(t: ^testing.T) {
	terminal: term.Terminal
	_kitty_test_init(&terminal)
	defer term.terminal_destroy(&terminal)
	state := _kitty_test_state(t, &terminal)

	cases := [?]string{
		"\x1b_Ga=T,i=1,f=32,s=100000,v=1;AAAA\x1b\\", // width above hard limit
		"\x1b_Ga=T,i=2,f=32,s=8192,v=8192;AAAA\x1b\\", // pixel count above per-image cap
		"\x1b_Ga=T,i=3,f=32,s=0,v=0;AAAA\x1b\\", // degenerate geometry
		"\x1b_Ga=T,i=4,f=32,s=-5,v=10;AAAA\x1b\\", // negative geometry
	}
	for apc in cases {
		term.terminal_feed_string(&terminal, apc)
	}

	for id in ([?]u32{1, 2, 3, 4}) {
		testing.expect(t, extension.kitty_graphics_get_image(rawptr(state), id) == nil, "oversized image must be rejected")
	}
	testing.expect_value(t, state.total_pixel_bytes, 0)
}

@test
test_kitty_pixel_budget_is_enforced :: proc(t: ^testing.T) {
	terminal: term.Terminal
	_kitty_test_init(&terminal)
	defer term.terminal_destroy(&terminal)
	state := _kitty_test_state(t, &terminal)

	// 4000x4000 RGBA = 64 MB per image, declared with a 3-byte payload. Two fit
	// the 128 MB budget, the third one must be refused with ENOSPC.
	for id in ([?]u32{10, 11, 12}) {
		apc := fmt.tprintf("\x1b_Ga=T,i=%d,f=32,s=4000,v=4000;AAAA\x1b\\", id)
		term.terminal_feed_string(&terminal, apc)
	}

	testing.expect(t, state.total_pixel_bytes <= extension.KITTY_MAX_TOTAL_PIXEL_BYTES, "budget must never be exceeded")
	testing.expect(t, extension.kitty_graphics_get_image(rawptr(state), 10) != nil, "first image fits")
	testing.expect(t, extension.kitty_graphics_get_image(rawptr(state), 11) != nil, "second image fits")
	testing.expect(t, extension.kitty_graphics_get_image(rawptr(state), 12) == nil, "third image exceeds the budget")
}

@test
test_kitty_pixel_accounting_returns_to_zero :: proc(t: ^testing.T) {
	terminal: term.Terminal
	_kitty_test_init(&terminal)
	defer term.terminal_destroy(&terminal)
	state := _kitty_test_state(t, &terminal)

	term.terminal_feed_string(&terminal, "\x1b_Ga=T,i=20,f=32,s=64,v=64;AAAA\x1b\\")
	term.terminal_feed_string(&terminal, "\x1b_Ga=T,i=21,f=32,s=64,v=64;AAAA\x1b\\")
	img := extension.kitty_graphics_get_image(rawptr(state), 20)
	testing.expect(t, img != nil, "image must be stored")
	testing.expect_value(t, state.total_pixel_bytes, 2 * 64 * 64 * 4)

	term.terminal_feed_string(&terminal, "\x1b_Ga=d,d=A\x1b\\")
	testing.expect_value(t, state.total_pixel_bytes, 0)
}

@test
test_kitty_temp_file_outside_tempdir_is_not_deleted :: proc(t: ^testing.T) {
	terminal: term.Terminal
	_kitty_test_init(&terminal)
	defer term.terminal_destroy(&terminal)

	cwd, cwd_err := os.getwd(context.temp_allocator)
	testing.expect(t, cwd_err == nil, "cwd must be readable")
	victim := fmt.tprintf("%s/.kitty-delete-guard-test", cwd)
	testing.expect(t, os.write_entire_file(victim, "VICTIM") == nil, "victim file must be created")
	defer os.remove(victim)

	_kitty_send_path(&terminal, 't', victim)

	testing.expect(t, os.exists(victim), "t=t must never unlink a file outside the temp directory")
}

@test
test_kitty_temp_file_inside_tempdir_is_deleted :: proc(t: ^testing.T) {
	terminal: term.Terminal
	_kitty_test_init(&terminal)
	defer term.terminal_destroy(&terminal)

	temp_dir := fmt.aprintf("%s/term-kitty-tmp-test", _kitty_test_temp_dir(), allocator = context.temp_allocator)
	testing.expect(t, os.write_entire_file(temp_dir, "DOOMED") == nil, "temp file must be created")

	_kitty_send_path(&terminal, 't', temp_dir)

	testing.expect(t, !os.exists(temp_dir), "t=t must unlink the transferred temporary file")
}

@test
test_kitty_file_medium_rejects_non_regular_files :: proc(t: ^testing.T) {
	terminal: term.Terminal
	_kitty_test_init(&terminal)
	defer term.terminal_destroy(&terminal)
	state := _kitty_test_state(t, &terminal)

	// /dev/zero would otherwise be read until memory is exhausted.
	_kitty_send_path(&terminal, 'f', "/dev/zero")
	_kitty_send_path(&terminal, 'f', "/")

	testing.expect_value(t, state.total_pixel_bytes, 0)
}

@test
test_kitty_shm_unknown_object_is_ignored :: proc(t: ^testing.T) {
	terminal: term.Terminal
	_kitty_test_init(&terminal)
	defer term.terminal_destroy(&terminal)
	state := _kitty_test_state(t, &terminal)

	_kitty_send_path(&terminal, 's', "term-no-such-shm-object")
	_kitty_send_path(&terminal, 's', "/etc/hosts")

	testing.expect_value(t, state.total_pixel_bytes, 0)
}

@test
test_kitty_path_guards :: proc(t: ^testing.T) {
	testing.expect(t, !extension.kitty_path_in_temp_dir("../escape"), "relative paths are rejected")
	testing.expect(t, !extension.kitty_path_in_temp_dir("/tmp/../etc/passwd"), "parent traversal is rejected")
	testing.expect(t, !extension.kitty_path_in_temp_dir("/tmp/sub/dir/file"), "nested temp paths are rejected")
	testing.expect(t, !extension.kitty_path_in_temp_dir("/"), "root is rejected")

	temp_root := _kitty_test_temp_dir()
	inside := fmt.aprintf("%s/kitty-child", temp_root, allocator = context.temp_allocator)
	testing.expect(t, extension.kitty_path_in_temp_dir(inside), "direct temp child is accepted")
}

_kitty_test_temp_dir :: proc() -> string {
	dir, found := os.lookup_env("TMPDIR", context.temp_allocator)
	if !found || len(dir) == 0 do return "/tmp"
	return strings.trim_right(dir, "/")
}
