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

// preview_tabs_extreme emits overflowed tabs (default 128) and a 1024-rune long Unicode title.
preview_tabs_extreme :: proc(dl: ^draw_list.Ui_Draw_List, bar_rect: [4]f32, count: int = 128) {
	if dl == nil do return

	m: Chrome_Tabs_Model
	tabs_model_init(&m, bar_rect)
	defer tabs_model_destroy(&m)

	if count <= 0 do return

	// Construct 1024-rune Unicode title with emojis and accents (16 runes * 64 repetitions = 1024 runes)
	b := strings.builder_make(context.temp_allocator)
	sample_runes := []rune{'🚀', '⚡', 'ñ', 'á', 'é', 'í', 'ó', 'ú', '漢', '字', '🔥', '✨', 'ä', 'ö', 'ü', 'ß'}
	for _ in 0..<64 {
		for r in sample_runes {
			strings.write_rune(&b, r)
		}
	}
	long_title := strings.to_string(b)

	tabs_add(&m, 1, long_title)

	for i in 1..<count {
		title := fmt.tprintf("tab-%d", i)
		tabs_add(&m, u32(i + 1), title)
	}

	tabs_set_active(&m, 0)
	tabs_emit_draw_list(&m, dl)
}
