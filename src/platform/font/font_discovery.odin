package platform_font

// Platform-Neutral Operating System Font Discovery
// Platform Font Subsystem (src/platform/font/*).
//
// Invariant: Queries OS font systems (CoreText on macOS, Fontconfig on Linux)
// dynamically so font fallbacks follow native system preferences instead of
// brittle hardcoded paths.

import "base:runtime"

platform_query_os_fixed_pitch_font :: proc(allocator := context.temp_allocator) -> (path: string, ok: bool) {
	when ODIN_OS == .Darwin {
		return darwin_query_os_fixed_pitch_font(allocator)
	} else when ODIN_OS == .Linux {
		return linux_query_os_fixed_pitch_font(allocator)
	} else {
		return "", false
	}
}

platform_query_os_cascade_fonts :: proc(max_count: int, allocator := context.temp_allocator) -> []string {
	when ODIN_OS == .Darwin {
		return darwin_query_os_cascade_fonts(max_count, allocator)
	} else when ODIN_OS == .Linux {
		return linux_query_os_cascade_fonts(max_count, allocator)
	} else {
		return nil
	}
}

platform_query_font_by_name :: proc(name: string, allocator := context.temp_allocator) -> (path: string, ok: bool) {
	when ODIN_OS == .Darwin {
		return darwin_query_font_by_name(name, allocator)
	} else when ODIN_OS == .Linux {
		return linux_query_font_by_name(name, allocator)
	} else {
		return "", false
	}
}

platform_query_font_for_codepoint :: proc(cp: u32, allocator := context.temp_allocator) -> (path: string, ok: bool) {
	when ODIN_OS == .Darwin {
		return darwin_query_font_for_codepoint(cp, allocator)
	} else when ODIN_OS == .Linux {
		return linux_query_font_for_codepoint(cp, allocator)
	} else {
		return "", false
	}
}
