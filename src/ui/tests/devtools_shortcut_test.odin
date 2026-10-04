package ui_test

import "core:testing"

import ui "../"
import input "../../platform/input"

// devtools_shortcut_ev builds the key event the shortcut matcher consumes.
devtools_shortcut_ev :: proc(rune: rune, gui, alt, shift, ctrl: bool) -> input.Input_Event {
	ev: input.Input_Event
	ev.event_type = .Key
	ev.is_release = false
	ev.kind = .Printable
	ev.rune = rune
	ev.gui = gui
	ev.alt = alt
	ev.shift = shift
	ev.ctrl = ctrl
	return ev
}

// The DevTools toggle owns alt+cmd+i exactly: it must not fire on cmd+i alone,
// on the shift or ctrl variants, and above all it must not fire on any of the
// pre-existing cmd bindings, which are matched positionally in the hotkey
// router and would otherwise have their branch taken first.
@test
test_devtools_toggle_shortcut_exact_match :: proc(t: ^testing.T) {
	match := ui.ui_shortcut_matches

	testing.expect(t, match(.Toggle_Devtools, devtools_shortcut_ev('i', true, true, false, false)))

	testing.expect(t, !match(.Toggle_Devtools, devtools_shortcut_ev('i', true, false, false, false)))
	testing.expect(t, !match(.Toggle_Devtools, devtools_shortcut_ev('i', true, true, true, false)))
	testing.expect(t, !match(.Toggle_Devtools, devtools_shortcut_ev('i', true, true, false, true)))
	testing.expect(t, !match(.Toggle_Devtools, devtools_shortcut_ev('I', true, true, false, false)))
	testing.expect(t, !match(.Toggle_Devtools, devtools_shortcut_ev('i', false, true, false, false)))

	// The bindings the hotkey router resolves by rune alone must not be
	// claimed by the new action, in any of their modifier variants.
	testing.expect(t, !match(.Toggle_Devtools, devtools_shortcut_ev('d', true, false, false, false)))
	testing.expect(t, !match(.Toggle_Devtools, devtools_shortcut_ev('d', true, false, true, false)))
	testing.expect(t, !match(.Toggle_Devtools, devtools_shortcut_ev('d', true, true, false, false)))
	testing.expect(t, !match(.Toggle_Devtools, devtools_shortcut_ev('d', true, true, true, false)))
	testing.expect(t, !match(.Toggle_Devtools, devtools_shortcut_ev('t', true, false, false, false)))
	testing.expect(t, !match(.Toggle_Devtools, devtools_shortcut_ev('f', true, false, false, false)))

	// Key releases never trigger anything.
	release := devtools_shortcut_ev('i', true, true, false, false)
	release.is_release = true
	testing.expect(t, !match(.Toggle_Devtools, release))
}

// The toggle must not answer for any other action, and the exact-modifier
// actions that do exist must keep their own keys.
@test
test_devtools_toggle_does_not_shadow_other_shortcuts :: proc(t: ^testing.T) {
	match := ui.ui_shortcut_matches

	testing.expect(t, !match(.Close_Tab, devtools_shortcut_ev('d', true, false, false, false)))
	testing.expect(t, !match(.New_Tab, devtools_shortcut_ev('t', true, false, false, false)))
	testing.expect(t, !match(.Rename_Tab, devtools_shortcut_ev('r', true, false, false, false)))

	testing.expect(t, match(.Pane_Equalize, devtools_shortcut_ev('=', true, true, false, false)))
	testing.expect(t, match(.Split_Horizontal, devtools_shortcut_ev('\\', true, true, false, false)))
	testing.expect(t, match(.Overflow, devtools_shortcut_ev('\\', true, false, true, false)))
}

// devtools_label_glyph_actions are the labels whose glyphs the DevTools
// toggle may reuse. The list is built from other actions rather than from
// hard-coded codepoints because the invariant under test is "no new glyph":
// the existing glyph set is whatever the existing labels already use.
devtools_label_glyph_actions := [8]ui.Shortcut_Action{
	.Close_Others,
	.Close_To_Right,
	.Split_Horizontal,
	.Detach_Tab,
	.Pane_Equalize,
	.Pane_Zoom,
	.New_Tab,
	.Overflow,
}

// The label is the single source of truth for the hint text, and every glyph
// in it must already be pinned in the render atlas. Adding a non-ASCII
// codepoint would require an atlas change, which is out of scope, so the toggle
// may only assemble its label out of the modifier glyphs the other labels
// already contain; ASCII is excluded from the check because the atlas has to
// cover the printable ASCII range for the grid itself.
@test
test_devtools_toggle_label_reuses_pinned_glyphs :: proc(t: ^testing.T) {
	allowed: [32]rune
	allowed_n := 0
	for action in devtools_label_glyph_actions {
		for cp in ui.ui_shortcut_label(action) {
			if cp < 128 do continue
			if allowed_n < len(allowed) {
				allowed[allowed_n] = cp
				allowed_n += 1
			}
		}
	}
	testing.expect(t, allowed_n > 0)

	label := ui.ui_shortcut_label(.Toggle_Devtools)
	testing.expect(t, len(label) > 0)
	for cp in label {
		if cp < 128 do continue
		found := false
		for i in 0..<allowed_n {
			if allowed[i] == cp {
				found = true
				break
			}
		}
		testing.expect(t, found, "label glyph must already appear in an existing label")
	}
}
