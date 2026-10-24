package term

import "core:testing"
import "vendor:sdl3"

@test
test_text_input_insert_and_delete :: proc(t: ^testing.T) {
	ti: Text_Input
	text_input_init(&ti)

	text_input_insert(&ti, "hello")
	testing.expect_value(t, text_input_as_string(&ti), "hello")
	testing.expect_value(t, ti.cursor, 5)

	text_input_insert(&ti, " world")
	testing.expect_value(t, text_input_as_string(&ti), "hello world")
	testing.expect_value(t, ti.cursor, 11)

	// Backspace 1 character
	ok := text_input_delete_back(&ti)
	testing.expect(t, ok)
	testing.expect_value(t, text_input_as_string(&ti), "hello worl")
	testing.expect_value(t, ti.cursor, 10)
}

@test
test_text_input_cmd_delete :: proc(t: ^testing.T) {
	ti: Text_Input
	text_input_init(&ti)
	text_input_insert(&ti, "git commit -m foo")

	// Cmd + Delete deletes from cursor to start of line
	changed, handled := text_input_handle_key(&ti, sdl3.K_BACKSPACE, sdl3.KMOD_GUI)
	testing.expect(t, handled)
	testing.expect(t, changed)
	testing.expect_value(t, text_input_as_string(&ti), "")
	testing.expect_value(t, ti.cursor, 0)
}

@test
test_text_input_word_delete :: proc(t: ^testing.T) {
	ti: Text_Input
	text_input_init(&ti)
	text_input_insert(&ti, "cargo build --release")

	// Option + Delete deletes "--release"
	changed1, handled1 := text_input_handle_key(&ti, sdl3.K_BACKSPACE, sdl3.KMOD_ALT)
	testing.expect(t, handled1)
	testing.expect(t, changed1)
	testing.expect_value(t, text_input_as_string(&ti), "cargo build ")

	// Ctrl + Delete deletes "build "
	changed2, handled2 := text_input_handle_key(&ti, sdl3.K_BACKSPACE, sdl3.KMOD_CTRL)
	testing.expect(t, handled2)
	testing.expect(t, changed2)
	testing.expect_value(t, text_input_as_string(&ti), "cargo ")
}

@test
test_text_input_selection_and_replace :: proc(t: ^testing.T) {
	ti: Text_Input
	text_input_init(&ti)
	text_input_insert(&ti, "replace me")

	// Select all via Cmd + A
	_, handled_a := text_input_handle_key(&ti, sdl3.K_A, sdl3.KMOD_GUI)
	testing.expect(t, handled_a)
	s, e, active := text_input_selection_range(&ti)
	testing.expect(t, active)
	testing.expect_value(t, s, 0)
	testing.expect_value(t, e, 10)

	// Typing while selection is active replaces entire selected text
	text_input_insert(&ti, "done")
	testing.expect_value(t, text_input_as_string(&ti), "done")
	testing.expect_value(t, ti.cursor, 4)
	testing.expect(t, !ti.sel_active)

	// Select with Shift + Left twice
	text_input_move_cursor(&ti, forward = false, word_jump = false, select = true)
	text_input_move_cursor(&ti, forward = false, word_jump = false, select = true)
	s2, e2, active2 := text_input_selection_range(&ti)
	testing.expect(t, active2)
	testing.expect_value(t, s2, 2)
	testing.expect_value(t, e2, 4)

	// Pressing Backspace deletes the selection
	changed_del, handled_del := text_input_handle_key(&ti, sdl3.K_BACKSPACE, sdl3.KMOD_NONE)
	testing.expect(t, handled_del)
	testing.expect(t, changed_del)
	testing.expect_value(t, text_input_as_string(&ti), "do")
	testing.expect_value(t, ti.cursor, 2)
	testing.expect(t, !ti.sel_active)
}
