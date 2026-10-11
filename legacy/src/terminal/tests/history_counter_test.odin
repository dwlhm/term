package termgrid_test

import "core:testing"
import tg "../"

@(test)
test_history_push_counter_survives_capacity_clear_and_resize :: proc(t: ^testing.T) {
	s: tg.Scrollback
	tg.scrollback_init(&s, 2, 3)
	defer tg.scrollback_destroy(&s, nil)
	cells := [2]tg.Semantic_Cell{tg.CELL_DEFAULT, tg.CELL_DEFAULT}
	tg.scrollback_push(&s, cells[:1], nil)
	testing.expect_value(t, s.total_pushed, u64(0))
	for _ in 0 ..< 11 { tg.scrollback_push(&s, cells[:], nil) }
	testing.expect_value(t, s.count, 3)
	testing.expect_value(t, s.total_pushed, u64(11))
	tg.scrollback_clear(&s, nil)
	testing.expect_value(t, s.clear_generation, u64(1))
	testing.expect_value(t, s.total_pushed, u64(11))
	tg.scrollback_resize(&s, 4, nil)
	testing.expect_value(t, s.clear_generation, u64(1))
	testing.expect_value(t, s.total_pushed, u64(11))
	tg.scrollback_push(&s, s.rows[0].cells, nil)
	testing.expect_value(t, s.total_pushed, u64(12))
}
