package termgrid_test

import "core:testing"
import tg "../"

@(test)
test_grapheme_double_free_guarded :: proc(t: ^testing.T) {
	store: tg.Grapheme_Store
	tg.grapheme_store_init(&store)

	h := tg.grapheme_store_append(&store, 'A', 0x301)
	testing.expect(t, store.live_count == 1, "must have 1 live grapheme")

	// First release succeeds
	tg.grapheme_store_release(&store, h)
	testing.expect(t, store.live_count == 0, "must be 0 after release")
	free_cnt := store.free_count

	// Second release must be a no-op (no double-free corruption of free stack)
	tg.grapheme_store_release(&store, h)
	testing.expect(t, store.live_count == 0, "must remain 0")
	testing.expect(t, store.free_count == free_cnt, "free stack must not duplicate index")
}

@(test)
test_ascii_overwrite_releases_grapheme :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Allocate a grapheme in the terminal store
	h := tg.grapheme_store_append(&term.grapheme_store, 'e', 0x301)
	testing.expect(t, term.grapheme_store.live_count == 1, "grapheme allocated")

	// Put grapheme cell into grid at (0, 0)
	cell := tg.Semantic_Cell{content = h, style = 0, width = 1, flags = .None}
	tg.grid_set_cell(&term.grid, 0, 0, cell)

	// Overwrite (0, 0) with ASCII character via terminal_put_char
	term.cursor.row = 0
	term.cursor.col = 0
	tg.terminal_put_char(&term, 'x')

	// Grapheme must be released
	testing.expect(t, term.grapheme_store.live_count == 0, "ASCII overwrite must release prior grapheme")
	c0 := tg.terminal_get_cell(&term, 0, 0)
	testing.expect(t, c0.content == 'x', "content must be 'x'")
}
