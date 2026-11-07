package feature_automation_tests

// Marked elements come from what the program said: OSC 133 prompt rows, the
// line being typed and the last command's output; OSC 8 links.

import "core:testing"
import auto ".."
import ipc "../../../platform/ipc"

@(private = "file")
_row :: proc(text: string, prompt := false, link: u16 = 0) -> ipc.Snap_Row {
	runs := make([]ipc.Snap_Run, 1, context.temp_allocator)
	runs[0] = {cells = u16(len(text)), text = text, style = {fg = 7, link = link}}
	return {prompt = prompt, runs = runs}
}

@test
test_marked_prompt_output_and_links :: proc(t: ^testing.T) {
	rows := []ipc.Snap_Row{
		_row("~/repo main", prompt = true),
		_row("❯ ls", prompt = true),
		_row("a.txt  b.txt"),
		_row("see docs", link = 3),
		_row("~/repo main", prompt = true),
		_row("❯ git st", prompt = true),
	}
	snap := ipc.Snapshot{cols = 20, rows = 6, top_line = 100, screen = rows, cursor_row = 5, cursor_col = 8, cursor_visible = true,
		prompt_state = .Input, output_start = 102, output_end = 104, links = {{3, "https://docs.test"}}}
	s := auto.screen_build(snap, context.temp_allocator)
	es := auto.screen_elements(&s, context.temp_allocator)
	want := [?]string{
		`@e1 Prompt "~/repo main \u276f ls" [1,1 20x2] Osc133`,
		`@e2 Prompt "~/repo main \u276f git st" [5,1 20x2] Osc133`,
		`@e3 Input "" [6,1 20x1] text="\u276f git st" focused Osc133`,
		`@e4 Output "" [3,1 20x2] Osc133`,
		`@e5 Link "see docs" [4,1 8x1] text="https://docs.test" Osc8`,
	}
	testing.expect_value(t, len(es), len(want))
	for w, i in want do if i < len(es) do testing.expect_value(t, auto.element_describe(es, i), w)
}
