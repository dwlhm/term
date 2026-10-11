package termgrid_test

import "base:runtime"
import "core:testing"
import termgrid "../"
import graphics "../../graphics"

@(test)
test_terminal_graphics_active_store_lifecycle :: proc(t: ^testing.T) {
	term: termgrid.Terminal
	termgrid.terminal_init(&term, 4, 8, allocator = runtime.heap_allocator())
	defer termgrid.terminal_destroy(&term, runtime.heap_allocator())

	main_store := termgrid.terminal_graphics_active(&term)
	testing.expect(t, main_store == term.graphics, "main screen must select the main graphics store")

	control := "a=t,f=24,s=1,v=1"
	payload := "ESIz"
	result := termgrid.terminal_graphics_feed(
		&term,
		transmute([]u8)control,
		transmute([]u8)payload,
		graphics.Response_Sink{},
	)
	testing.expect(t, result == .Ok, "graphics feed must succeed on the main screen")
	testing.expect_value(t, term.graphics.image_count, 1)
	testing.expect_value(t, term.graphics_alt.image_count, 0)

	termgrid.terminal_enter_alt_screen(&term)
	testing.expect(t, termgrid.terminal_graphics_active(&term) == term.graphics_alt, "alt screen must select the alt graphics store")
	testing.expect_value(t, term.graphics_alt.image_count, 0)

	result = termgrid.terminal_graphics_feed(
		&term,
		transmute([]u8)control,
		transmute([]u8)payload,
		graphics.Response_Sink{},
	)
	testing.expect(t, result == .Ok, "graphics feed must reach the active alt store")
	testing.expect_value(t, term.graphics.image_count, 1)
	testing.expect_value(t, term.graphics_alt.image_count, 1)

	termgrid.terminal_leave_alt_screen(&term)
	testing.expect(t, termgrid.terminal_graphics_active(&term) == term.graphics, "leaving alt screen must select the main graphics store")
	testing.expect_value(t, term.graphics.image_count, 1)
	testing.expect_value(t, term.graphics_alt.image_count, 0)

	termgrid.terminal_reset(&term)
	testing.expect_value(t, term.graphics.image_count, 0)
	testing.expect_value(t, term.graphics_alt.image_count, 0)
}
