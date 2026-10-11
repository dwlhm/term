package tabs

// Pure Declarative UI Geometry Engine - Tabs Preview Fixtures.
// Part of core_chrome: Tier 1 Autonomous Core Primitives.
//
// Invariant: ZERO GPU Dependencies.

import "core:fmt"
import "core:strings"
import "../draw_list"

// preview_tabs_normal emits 4 typical tabs ("zsh", "nvim main.odin", "make test", "git status") with tab 1 active.
preview_tabs_normal :: proc(dl: ^draw_list.Ui_Draw_List, bar_rect: [4]f32) {
	if dl == nil do return

	m: Chrome_Tabs_Model
	tabs_model_init(&m, bar_rect)
	defer tabs_model_destroy(&m)

	tabs_add(&m, 1, "zsh")
	tabs_add(&m, 2, "nvim main.odin")
	tabs_add(&m, 3, "make test")
	tabs_add(&m, 4, "git status")

	// Set tab 1 ("nvim main.odin") active
	tabs_set_active(&m, 1)

	tabs_emit_draw_list(&m, dl)
}

// PREVIEW_TABS_EXTREME_TITLE_RUNES is the exact rune length of the extreme preview title.
PREVIEW_TABS_EXTREME_TITLE_RUNES :: 1024

// preview_tabs_extreme_title builds a title of exactly PREVIEW_TABS_EXTREME_TITLE_RUNES runes by cycling
// a ZWJ family sequence, stacked combining marks, CJK wide runes, a regional-indicator flag pair, and ASCII.
// The final repetition is truncated at rune granularity to hit the exact length.
preview_tabs_extreme_title :: proc(allocator := context.temp_allocator) -> string {
	sample_runes := [?]rune{
		0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467, // ZWJ family
		'e', 0x0301,                               // e + combining acute
		'a', 0x0308, 0x0304,                       // a + stacked diaeresis + macron
		'漢', '字',                                 // CJK wide
		0x1F1EE, 0x1F1E9,                          // flag pair
		'a', 'b', 'c',                             // ASCII
	}

	b := strings.builder_make(allocator)
	for i in 0..<PREVIEW_TABS_EXTREME_TITLE_RUNES {
		strings.write_rune(&b, sample_runes[i % len(sample_runes)])
	}
	return strings.to_string(b)
}

// preview_tabs_extreme emits overflowed tabs (default 128) and a 1024-rune long Unicode title.
preview_tabs_extreme :: proc(dl: ^draw_list.Ui_Draw_List, bar_rect: [4]f32, count: int = 128) {
	if dl == nil do return

	m: Chrome_Tabs_Model
	tabs_model_init(&m, bar_rect)
	defer tabs_model_destroy(&m)

	if count <= 0 do return

	long_title := preview_tabs_extreme_title()

	tabs_add(&m, 1, long_title)

	for i in 1..<count {
		title := fmt.tprintf("tab-%d", i)
		tabs_add(&m, u32(i + 1), title)
	}

	tabs_set_active(&m, 0)
	tabs_emit_draw_list(&m, dl)
}
