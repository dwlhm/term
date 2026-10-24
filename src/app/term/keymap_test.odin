package term

// Behavioral tests for keymap shortcut resolution and action dispatch.
// Part of Tier 3 Application Shell (src/app/term/*).

import "core:testing"
import "vendor:sdl3"

@test
test_keymap_detach_attach_shortcuts :: proc(t: ^testing.T) {
	// Option + Command + B (Detach to Background), Option + Command + A (Attach Latest)
	mod_opt_cmd := sdl3.KMOD_GUI | sdl3.KMOD_ALT

	act_b, ok_b := keymap_evaluate(sdl3.K_B, mod_opt_cmd)
	testing.expect(t, ok_b, "⌥⌘B must be recognized")
	testing.expect_value(t, act_b, Action_Id.Tab_Detach)

	act_a, ok_a := keymap_evaluate(sdl3.K_A, mod_opt_cmd)
	testing.expect(t, ok_a, "⌥⌘A must be recognized")
	testing.expect_value(t, act_a, Action_Id.Tab_Attach_Latest)

	// Ensure standard ⌘A is Select_All
	mod_cmd := sdl3.KMOD_GUI
	act_select_all, ok_sel := keymap_evaluate(sdl3.K_A, mod_cmd)
	testing.expect(t, ok_sel, "⌘A must be recognized")
	testing.expect_value(t, act_select_all, Action_Id.Select_All)

	// Ensure metadata exists in ACTION_CATALOG
	meta_detach, found_d := action_get_metadata(.Tab_Detach)
	testing.expect(t, found_d, "Tab_Detach metadata must exist")
	testing.expect_value(t, meta_detach.shortcut, "⌥⌘B")

	meta_attach, found_a := action_get_metadata(.Tab_Attach_Latest)
	testing.expect(t, found_a, "Tab_Attach_Latest metadata must exist")
	testing.expect_value(t, meta_attach.shortcut, "⌥⌘A")
}
