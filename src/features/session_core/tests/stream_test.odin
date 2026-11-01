package feature_session_core_tests

// What viewers see of the stream: queries answered once by the core, the
// size owner among several viewers, and a viewer that stops reading.

import "core:log"
import "core:strings"
import "core:testing"
import "core:time"
import client "../../session_client"
import session "../../session"

@(test)
test_query_answered_once_by_core :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "stty -echo -icanon min 0 time 5; printf '\\033[6n'; sleep 1; " +
		"n=$(dd bs=256 count=1 2>/dev/null | tr -cd R | wc -c); printf 'replies=%d' $((n)); sleep 30")
	testing.expect(t, view_attached(v, s) != 0, "attached")
	testing.expect(t, view_wait_screen(v, s, "replies=", 5000), "program reports")
	testing.expect(t, contains(screen_text(s), "replies=1"), "exactly one cursor report reached the program")
	view_close(v)
	testing.expect(t, tiers_stop(tiers), "tiers end")
}

// last_size is the last "sz=<rows> <cols>" line on the screen.
@(private = "file")
last_size :: proc(sess: ^session.Terminal_Session) -> string {
	text := screen_text(sess)
	i := strings.last_index(text, "sz=")
	if i < 0 do return ""
	end := strings.index_byte(text[i:], '\n')
	return text[i + 3:i + end] if end >= 0 else text[i + 3:]
}

@(private = "file")
wait_size :: proc(v: ^View, sess: ^session.Terminal_Session, want: string, others: ..^View) -> bool {
	deadline := time.tick_now()._nsec + 3_000_000_000
	for time.tick_now()._nsec < deadline {
		if last_size(sess) == want do return true
		view_pump(v, 5)
		for o in others do view_pump(o, 1)
	}
	return false
}

@(test)
test_resize_leader :: proc(t: ^testing.T) {
	tiers := tiers_start()
	a, b, o := view_open(), view_open(), view_open()
	sa := view_sh(a, "stty -echo; while read x; do printf 'sz=%s\\n' \"$(stty size)\"; done")
	id := view_attached(a, sa)
	sb := client.client_attach(&b.c, {id = id, size = {cols = 100, rows = 30}})
	testing.expect(t, view_attached(b, sb) == id, "B attached")
	session.session_write_string(sb, "\n")
	testing.expect(t, wait_size(a, sa, "30 100", b, o), "the newest viewer leads")

	session.session_write_string(sa, "\n")
	testing.expect(t, wait_size(a, sa, "24 80", b, o), "the typist takes the size back")

	so := client.client_attach(&o.c, {id = id, size = {cols = 120, rows = 40}, observe = true})
	testing.expect(t, view_attached(o, so) == id, "observer attached")
	session.session_write_string(so, "\n")
	view_pump(o, 300)
	session.session_write_string(sa, "\n")
	view_pump(a, 300)
	testing.expect_value(t, strings.count(screen_text(sa), "sz=24 80"), 3)
	testing.expect(t, !contains(screen_text(sa), "40 120"), "an observer never leads")
	for x in ([]^View{o, b, a}) do view_close(x)
	testing.expect(t, tiers_stop(tiers), "tiers end")
}

// screens_equal compares the visible grids cell by cell (no allocation, so it
// can be polled while both viewers drain).
@(private = "file")
screens_equal :: proc(a, b: ^session.Terminal_Session) -> bool {
	if a == nil || b == nil do return a == b
	if a.term.cols != b.term.cols || a.term.rows != b.term.rows do return false
	for row in 0..<a.term.rows {
		for col in 0..<a.term.cols {
			if session.session_get_cell(a, row, col).char != session.session_get_cell(b, row, col).char do return false
		}
	}
	return true
}

// wait_same_screen pumps both viewers until they agree: a repaint can land a
// frame after the flood, so this waits for the state instead of guessing a time.
@(private = "file")
wait_same_screen :: proc(a: ^View, sa: ^session.Terminal_Session, b: ^View, sb: ^session.Terminal_Session, ms := 20_000) -> bool {
	deadline := time.tick_now()._nsec + i64(ms) * 1_000_000
	for time.tick_now()._nsec < deadline {
		if screens_equal(sa, sb) do return true
		view_pump(b, 5)
		view_pump(a, 5)
	}
	return screens_equal(sa, sb)
}

@(test)
test_slow_viewer_gets_repaint :: proc(t: ^testing.T) {
	tiers := tiers_start()
	a, b := view_open(), view_open()
	sa := view_sh(a, "read go; yes 0123456789abcdef | head -c 12000000; printf 'DONE-%s' end; sleep 30")
	id := view_attached(a, sa)
	b.drain = false
	sb := client.client_attach(&b.c, {id = id, size = {cols = 80, rows = 24}})
	view_pump(b, 100)
	session.session_write_string(sa, "\n")
	start := time.tick_now()
	testing.expect(t, view_wait_screen(a, sa, "DONE-end", 60000), "a stalled viewer does not block the program")
	log.infof("12 MB flood with one viewer stalled: %v", time.tick_since(start))
	b.drain = true
	testing.expect(t, view_wait_screen(b, sb, "DONE-end", 20000), "the stalled viewer catches up by repaint")
	testing.expect(t, wait_same_screen(a, sa, b, sb), "the repaint matches the live screen")
	view_close(b)
	view_close(a)
	testing.expect(t, tiers_stop(tiers), "tiers end")
}
