package feature_automation_tests

// Inference on snapshots of real programs (recorded with `term auto snapshot
// --save` from the apps pinned in flake.nix): every element must match the
// reviewed golden file. TERM_UPDATE_GOLDEN=1 rewrites them for review.

import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"
import auto ".."

@(private = "file")
TESTDATA :: #directory + "testdata/"

@(private = "file")
FIXTURES :: [?]string{
	"dialog_checklist", "dialog_radiolist", "dialog_yesno", "dialog_inputbox",
	"gum_choose", "gum_confirm", "gum_input", "textual_demo",
	"lazygit", "yazi", "vim", "nano", "fzf", "less",
}

describe_snapshot :: proc(path: string, allocator := context.allocator) -> (text: string, ok: bool) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	snap := auto.snapshot_load(path, a) or_return
	s := auto.screen_build(snap, a)
	es := auto.screen_elements(&s, a)
	b := strings.builder_make(allocator)
	for _, i in es {
		strings.write_string(&b, auto.element_describe(es, i, a))
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b), true
}

@test
test_infer_matches_golden :: proc(t: ^testing.T) {
	update := os.get_env("TERM_UPDATE_GOLDEN", context.temp_allocator) == "1"
	for name in FIXTURES {
		got, ok := describe_snapshot(strings.concatenate({TESTDATA, name, ".json"}, context.temp_allocator), context.temp_allocator)
		testing.expectf(t, ok, "%s: snapshot loads", name)
		golden := strings.concatenate({TESTDATA, name, ".golden"}, context.temp_allocator)
		if update {
			_ = os.write_entire_file(golden, transmute([]u8)got)
			continue
		}
		want, err := os.read_entire_file(golden, context.temp_allocator)
		testing.expectf(t, err == nil, "%s: golden exists (TERM_UPDATE_GOLDEN=1 writes it)", name)
		testing.expectf(t, string(want) == got, "%s: elements changed:\n%s", name, got)
	}
}
