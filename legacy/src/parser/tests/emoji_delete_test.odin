package parser_test

import "core:testing"
import tg "../../terminal"
import p "../../parser"

// Regression: destructive single-cell backspace (BS, space, BS — exactly
// what zsh emits when deleting a 2-cell emoji) must blank the whole wide
// pair. The ASCII fast path must run the same wide-overwrite repair as the
// slow path, or the lead half survives as an undeletable ghost.
@(test)
test_emoji_delete_single_cell_backspace :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Type U+26A0 U+FE0F (warning emoji) as raw UTF-8, like PTY bytes.
	p.parse_chunk(&parser, &term, []u8{0xE2, 0x9A, 0xA0, 0xEF, 0xB8, 0x8F})
	cur := tg.terminal_get_cursor(&term)
	testing.expect(t, cur.col == 2, "emoji must occupy 2 cells")
	lead := tg.grid_get_cell(&term.grid, 0, 0)
	testing.expect(t, lead.width == 2, "lead must be wide")

	// Exact bytes zsh sends for backspace-delete: BS, space, BS.
	p.parse_chunk(&parser, &term, []u8{0x08, 0x20, 0x08})

	c0 := tg.grid_get_cell(&term.grid, 0, 0)
	testing.expect(t, c0 == tg.CELL_DEFAULT, "lead cell must be blanked, no ghost")
	// The shell's destructive space lands on the continuation cell.
	c1 := tg.grid_get_cell(&term.grid, 0, 1)
	testing.expect(t, c1.content == ' ', "space must overwrite the continuation")
	cur = tg.terminal_get_cursor(&term)
	testing.expect(t, cur.col == 1, "cursor must sit after the destructive space")
}

// Mirror case: ASCII written over a wide LEAD must blank its continuation.
@(test)
test_emoji_delete_overwrite_lead :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	p.parse_chunk(&parser, &term, []u8{0xE2, 0x9A, 0xA0, 0xEF, 0xB8, 0x8F})
	// Move back onto the lead and overwrite with ASCII.
	p.parse_chunk(&parser, &term, []u8{0x08, 0x08, 'X'})

	testing.expect(
		t,
		tg.grid_get_cell(&term.grid, 0, 0).content == 'X',
		"ASCII must overwrite the lead",
	)
	c1 := tg.grid_get_cell(&term.grid, 0, 1)
	testing.expect(t, c1 == tg.CELL_DEFAULT, "orphaned continuation must be blanked")
}
