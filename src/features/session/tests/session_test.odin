package feature_session_tests

import "core:fmt"
import "core:strings"
import "core:testing"
import ipc "../../../platform/ipc"
import extension "../../../core/terminal/extension"
import terminal "../../../core/terminal"
import session "../"

// Loopback_Link records what a session sends to its program.
Loopback_Link :: struct {
	written:  [dynamic]u8,
	size:     ipc.Size_Msg,
	resized:  int,
	consumed: int,
}

loopback_session :: proc(l: ^Loopback_Link, cols: u16 = 80, rows: u16 = 24) -> ^session.Terminal_Session {
	return session.session_create({cols = cols, rows = rows}, {
		write    = proc(user: rawptr, data: []u8) { append(&(^Loopback_Link)(user).written, ..data) },
		resize   = proc(user: rawptr, size: ipc.Size_Msg) {
			l := (^Loopback_Link)(user)
			l.size, l.resized = size, l.resized + 1
		},
		consumed = proc(user: rawptr, n: int) { (^Loopback_Link)(user).consumed += n },
		user     = l,
	})
}

// feed delivers program output the way the link's IO thread does, then drains it.
feed :: proc(sess: ^session.Terminal_Session, s: string) -> int {
	session.session_inbox_push(sess, transmute([]u8)s)
	return session.session_drain(sess)
}

row_text :: proc(sess: ^session.Terminal_Session, r: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in 0..<sess.term.cols {
		ch := session.session_get_cell(sess, r, c).char
		strings.write_byte(&b, u8(ch) if ch >= 32 && ch <= 126 else ' ')
	}
	return strings.trim_right_space(strings.to_string(b))
}

@test
test_session_drain_feeds_terminal_and_credits_link :: proc(t: ^testing.T) {
	l: Loopback_Link
	defer delete(l.written)
	sess := loopback_session(&l)
	defer session.session_destroy(sess)
	n := feed(sess, "REAL_SESSION_OK\r\n")
	testing.expect_value(t, n, 17)
	testing.expect_value(t, l.consumed, 17)
	testing.expect_value(t, row_text(sess, 0), "REAL_SESSION_OK")
	testing.expect_value(t, feed(sess, ""), 0)
}

@test
test_session_replies_go_back_through_the_link :: proc(t: ^testing.T) {
	l: Loopback_Link
	defer delete(l.written)
	sess := loopback_session(&l)
	defer session.session_destroy(sess)
	feed(sess, "ab\x1b[6n")
	testing.expect_value(t, string(l.written[:]), "\x1b[1;3R")
	session.session_write_string(sess, "ls\n")
	testing.expect(t, strings.has_suffix(string(l.written[:]), "ls\n"), "typed input reaches the link")
}

@test
test_session_inbox_is_bounded :: proc(t: ^testing.T) {
	l: Loopback_Link
	defer delete(l.written)
	sess := loopback_session(&l)
	defer session.session_destroy(sess)
	big := make([]u8, session.SESSION_INBOX_BYTES)
	defer delete(big)
	testing.expect(t, session.session_inbox_push(sess, big), "one window fits")
	testing.expect(t, !session.session_inbox_push(sess, big[:1]), "past the window is refused, never grown")
	testing.expect(t, session.session_inbox_pending(sess))
}

@test
test_session_osc_extensions :: proc(t: ^testing.T) {
	l: Loopback_Link
	defer delete(l.written)
	sess := loopback_session(&l)
	defer session.session_destroy(sess)
	feed(sess, "\x1b]0;My Cool Window\x07\x1b]7;file:///Users/dwlhm/project/term\x07\x1b]133;A\x07")
	testing.expect_value(t, session.session_get_title(sess), "My Cool Window")
	testing.expect_value(t, session.session_get_cwd(sess), "file:///Users/dwlhm/project/term")
	testing.expect_value(t, session.session_get_cwd_path(sess), "/Users/dwlhm/project/term")
	testing.expect(t, session.session_is_in_prompt(sess), "Expected in_prompt == true from OSC 133;A")

	copied_clipboard: string
	session.session_set_clipboard_sink(sess, proc(user_data: rawptr, text: string) -> bool {
		(^string)(user_data)^ = strings.clone(text)
		return true
	}, &copied_clipboard)
	feed(sess, "\x1b]52;c;TmVvdmltQ2xpcA==\x07")
	testing.expect_value(t, copied_clipboard, "NeovimClip")
	delete(copied_clipboard)

	feed(sess, "\x1b]22;pointer\x07\x1b]1337;ScrollSpeed=0.75\x07")
	testing.expect_value(t, session.session_get_pointer_shape(sess), "pointer")
	testing.expect_value(t, sess.custom_scroll_speed, 0.75)
}

@test
test_session_resize_reaches_terminal_and_link :: proc(t: ^testing.T) {
	l: Loopback_Link
	defer delete(l.written)
	sess := loopback_session(&l)
	defer session.session_destroy(sess)
	session.session_resize(sess, 120, 40, 1200, 800)
	testing.expect_value(t, sess.term.cols, 120)
	testing.expect_value(t, sess.term.rows, 40)
	testing.expect_value(t, l.resized, 1)
	testing.expect_value(t, l.size, ipc.Size_Msg{cols = 120, rows = 40, xpixel = 1200, ypixel = 800})
}

@test
test_session_title_resolution :: proc(t: ^testing.T) {
	l: Loopback_Link
	defer delete(l.written)
	sess := loopback_session(&l)
	defer session.session_destroy(sess)
	buf: [256]u8
	testing.expect_value(t, session.session_resolve_title(sess, buf[:], "Fallback"), "Fallback")
	session.session_set_info(sess, 42, 42, true, 0, "nvim", "/tmp")
	testing.expect_value(t, session.session_resolve_title(sess, buf[:], "Fallback"), "nvim")
	session.session_set_info(sess, 42, 42, true, 0, "zsh", "/tmp")
	testing.expect_value(t, session.session_resolve_title(sess, buf[:], "Fallback"), "/tmp")
	feed(sess, "\x1b]0;Custom OSC\x07")
	testing.expect_value(t, session.session_resolve_title(sess, buf[:], "Fallback"), "Custom OSC")
}

@test
test_session_kitty_graphics_stream :: proc(t: ^testing.T) {
	l: Loopback_Link
	defer delete(l.written)
	sess := loopback_session(&l)
	defer session.session_destroy(sess)
	feed(sess, "\x1b_Ga=T,i=400,f=32,s=2,v=2,m=1;AAAA\x1b\\\x1b_Gm=0;AAAA\x1b\\")
	found_image := false
	for i in 0..<sess.term.extensions.ext_count {
		e := &sess.term.extensions.extensions[i]
		if e.name != "kitty_graphics" || e.user_data == nil do continue
		img := extension.kitty_graphics_get_image(e.user_data, 400)
		found_image = img != nil && img.is_active
	}
	testing.expect(t, found_image, "Image 400 must be streamed and activated")
}

@test
test_session_takes_a_core_paint :: proc(t: ^testing.T) {
	l: Loopback_Link
	defer delete(l.written)
	src := loopback_session(&l)
	defer session.session_destroy(src)
	feed(src, "\x1b[31mred\x1b[0m prompt$ ")
	paint: [dynamic]u8
	defer delete(paint)
	terminal.terminal_paint(&src.term, &paint, 100)
	dst := loopback_session(&l)
	feed(dst, string(paint[:]))
	testing.expect_value(t, row_text(dst, 0), "red prompt$")
	session.session_destroy(dst)
}

@test
test_session_view_stays_inside_shrunken_history :: proc(t: ^testing.T) {
	l: Loopback_Link
	defer delete(l.written)
	sess := loopback_session(&l)
	defer session.session_destroy(sess)
	for i in 0..<60 do feed(sess, fmt.tprintf("line %d\r\n", i))
	sess.scroll_offset = sess.term.grid.history_count
	testing.expect(t, sess.scroll_offset > 0, "scrolled into history")
	feed(sess, "\x1b[3J") // `clear` (or a history resync) drops the history
	testing.expect_value(t, sess.term.grid.history_count, 0)
	testing.expect_value(t, sess.scroll_offset, 0)
}
