#+build linux
package platform_font

// Linux Font Discovery Fallbacks
// Platform Font Subsystem (src/platform/font/*).

import "base:runtime"
import "core:os"
import "core:strings"

@(private = "file")
LINUX_FIXED_PITCH_PATHS := []string{
	"/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
	"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
	"/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
	"/usr/share/fonts/opentype/noto/NotoSansMono-Regular.otf",
}

@(private = "file")
LINUX_CASCADE_PATHS := []string{
	"/usr/share/fonts/opentype/noto/NotoSansArabic-Regular.otf",
	"/usr/share/fonts/truetype/noto/NotoSansArabic-Regular.ttf",
	"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
	"/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
	"/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
	"/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf",
}

linux_query_os_fixed_pitch_font :: proc(allocator := context.temp_allocator) -> (path: string, ok: bool) {
	for p in LINUX_FIXED_PITCH_PATHS {
		if os.is_file(p) do return strings.clone(p, allocator), true
	}
	return "", false
}

linux_query_os_cascade_fonts :: proc(max_count: int, allocator := context.temp_allocator) -> []string {
	results := make([dynamic]string, 0, max_count, allocator)
	for p in LINUX_CASCADE_PATHS {
		if len(results) >= max_count do break
		if os.is_file(p) do append(&results, strings.clone(p, allocator))
	}
	return results[:]
}

linux_query_font_by_name :: proc(name: string, allocator := context.temp_allocator) -> (path: string, ok: bool) {
	return "", false
}

// Per-codepoint discovery needs Fontconfig (FcFontSort + FcCharSet), which is
// not bound yet; Linux relies on the static cascade above.
linux_query_font_for_codepoint :: proc(cp: u32, allocator := context.temp_allocator) -> (path: string, ok: bool) {
	return "", false
}
