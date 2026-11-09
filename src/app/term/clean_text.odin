package term

// Pure text transformation: strips box drawing, block elements, and padding,
// collapsing consecutive blank lines (spec 4.4, RD18–RD20).

import "core:strings"

app_clean_text :: proc(
	input: string,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	raw := input
	has_nl := strings.has_suffix(raw, "\n")
	if has_nl do raw = raw[:len(raw) - 1]
	lines := strings.split(raw, "\n", context.temp_allocator)
	empty_count := 0

	for line in lines {
		lb := strings.builder_make(context.temp_allocator)
		for r in line {
			if r >= 0x2500 && r <= 0x257F do continue // Box drawing
			if r >= 0x2580 && r <= 0x259F do continue // Block elements
			strings.write_rune(&lb, r)
		}
		cleaned := strings.trim_right_space(strings.to_string(lb))
		if len(cleaned) == 0 {
			empty_count += 1
			if empty_count == 1 && len(b.buf) > 0 {
				strings.write_byte(&b, '\n')
			}
		} else {
			empty_count = 0
			strings.write_string(&b, cleaned)
			strings.write_byte(&b, '\n')
		}
	}
	if !has_nl && len(b.buf) > 0 && b.buf[len(b.buf) - 1] == '\n' {
		pop(&b.buf)
	}
	return strings.to_string(b)
}
