package unicode_width_tests

import "core:testing"
import uw "../"
import ref "../reference"

// Every codepoint: the generated tables must equal the reference definition. This
// also catches stale tables after a core:unicode update (run `make gen-unicode`).
@(test)
test_props_match_reference_for_every_codepoint :: proc(t: ^testing.T) {
	mismatches := 0
	for cp in 0 ..= uw.MAX_CODEPOINT {
		r := rune(cp)
		if uw.props(r) != ref.props(r) {
			if mismatches < 8 do testing.expectf(t, false, "U+%04X: table %v, reference %v", cp, uw.props(r), ref.props(r))
			mismatches += 1
		}
	}
	testing.expect_value(t, mismatches, 0)
}

@(test)
test_out_of_range_runes_match_reference :: proc(t: ^testing.T) {
	for r in ([]rune{-1, min(rune), 0x110000, max(rune)}) {
		testing.expectf(t, uw.props(r) == ref.props(r), "%d: table %v, reference %v", r, uw.props(r), ref.props(r))
	}
}

// Emoji=Yes symbols without Emoji_Presentation (⏺ ✔ ➡ ▶ ⏵) are narrow text by
// default; only Emoji_Presentation=Yes codepoints are wide color emoji.
@(test)
test_emoji_presentation_width :: proc(t: ^testing.T) {
	for r in ([]rune{0x23FA, 0x23F5, 0x2714, 0x27A1, 0x25B6, 0x2764, 0x1F321, 0x1F000, 0x1FBB2}) {
		testing.expectf(t, uw.width(r) == 1, "U+%04X must be narrow", r)
		testing.expectf(t, !uw.is_emoji_presentation(r), "U+%04X must default to text presentation", r)
	}
	for r in ([]rune{0x23E9, 0x23F0, 0x2705, 0x2728, 0x2B50, 0x1F004, 0x1F600, 0x1F44D, 0x1FAF8, 0x1F3FB, 0x1F1E6}) {
		testing.expectf(t, uw.width(r) == 2, "U+%04X must be wide", r)
		testing.expectf(t, uw.is_emoji_presentation(r), "U+%04X must default to emoji presentation", r)
	}
	testing.expect_value(t, uw.width(0x1F210), 2) // EAW=Wide ideograph, not emoji
	testing.expect(t, !uw.is_emoji_presentation(0x1F210), "U+1F210 is not emoji presentation")
}

@(test)
test_terminal_width_overrides :: proc(t: ^testing.T) {
	testing.expect_value(t, uw.width('a'), 1)
	testing.expect_value(t, uw.width(0x2500), 1) // box drawing
	testing.expect_value(t, uw.width(0x28FF), 1) // braille
	testing.expect_value(t, uw.width(0xE0B0), 1) // Powerline (private use)
	testing.expect_value(t, uw.width(0x65E5), 2) // 日
	testing.expect_value(t, uw.width(0x0301), 0) // combining acute
	testing.expect_value(t, uw.width(0x200D), 0) // ZWJ
	testing.expect_value(t, uw.width(0x0903), 1) // spacing mark keeps a cell
}

@(test)
test_should_extend :: proc(t: ^testing.T) {
	testing.expect(t, uw.should_extend({'e'}, 0x0301), "combining mark joins")
	testing.expect(t, uw.should_extend({0x1F468}, 0x200D), "ZWJ joins")
	testing.expect(t, uw.should_extend({0x1F468, 0x200D}, 0x1F469), "GB11 ZWJ sequence")
	testing.expect(t, !uw.should_extend({'a', 0x200D}, 0x1F469), "GB11 needs an earlier pictograph")
	testing.expect(t, uw.should_extend({0x1F44D}, 0x1F3FD), "skin tone after pictograph")
	testing.expect(t, !uw.should_extend({'a'}, 0x1F3FD), "skin tone alone stays separate")
	testing.expect(t, uw.should_extend({0x1F1EE}, 0x1F1E9), "second regional indicator pairs")
	testing.expect(t, !uw.should_extend({0x1F1EE, 0x1F1E9}, 0x1F1F3), "third regional indicator starts a new flag")
	testing.expect(t, uw.should_extend({'1'}, uw.KEYCAP), "keycap")
	testing.expect(t, !uw.should_extend({'a'}, 0x65E5), "plain text never joins")
	testing.expect(t, !uw.should_extend({}, 0x0301), "empty cluster")
}

@(test)
test_cluster_width :: proc(t: ^testing.T) {
	testing.expect_value(t, uw.cluster_width({}), 1)
	testing.expect_value(t, uw.cluster_width({'e', 0x0301}), 1)
	testing.expect_value(t, uw.cluster_width({0x65E5}), 2)
	testing.expect_value(t, uw.cluster_width({'1', 0xFE0F, uw.KEYCAP}), 2)
	testing.expect_value(t, uw.cluster_width({0x1F1EE, 0x1F1E9}), 2)
	testing.expect_value(t, uw.cluster_width({0x2764}), 1) // ❤ text presentation
	testing.expect_value(t, uw.cluster_width({0x2764, uw.VS16}), 2) // ❤️ emoji presentation
	testing.expect_value(t, uw.cluster_width({0x1F468, 0x200D, 0x1F469}), 2)
}

// can_extend may only be false where should_extend can never return true.
@(test)
test_can_extend_is_conservative :: proc(t: ^testing.T) {
	anchors := []rune{'a', '1', 0xFE0F, 0x1F468, 0x200D, 0x1F1EE}
	for cp in 0 ..= uw.MAX_CODEPOINT {
		r := rune(cp)
		if uw.can_extend(uw.props(r)) do continue
		for a in anchors {
			if uw.should_extend({a}, r) || uw.should_extend({0x1F468, 0x200D}, r) {
				testing.expectf(t, false, "U+%04X can join but can_extend says no", cp)
				return
			}
		}
	}
}
