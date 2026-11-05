package platform_font_tests

// Unit tests for Procedural Box Drawing & Block Elements (U+2500 - U+259F)
// Verifies full-bleed pixel connectivity and zero-gap continuity across cell boundaries.

import "core:mem"
import "core:testing"
import font "../"

@test
test_procedural_box_continuity :: proc(t: ^testing.T) {
	cell_w := 12
	cell_h := 24
	pitch := 32
	pixels := make([]u8, pitch * cell_h * 2)
	defer delete(pixels)

	// 1. Vertical line (U+2502 │) must connect top y=0 and bottom y=cell_h-1
	mem.zero_slice(pixels)
	font.draw_procedural_box(pixels, pitch, 0, 0, cell_w, cell_h, 0x2502)
	mid_x := cell_w / 2
	testing.expect(t, pixels[0 * pitch + mid_x] > 0, "U+2502 must fill top pixel row (y=0)")
	testing.expect(t, pixels[(cell_h - 1) * pitch + mid_x] > 0, "U+2502 must fill bottom pixel row (y=cell_h-1)")

	// 2. Horizontal line (U+2500 ─) must connect left x=0 and right x=cell_w-1
	mem.zero_slice(pixels)
	font.draw_procedural_box(pixels, pitch, 0, 0, cell_w, cell_h, 0x2500)
	mid_y := cell_h / 2
	testing.expect(t, pixels[mid_y * pitch + 0] > 0, "U+2500 must fill left-most pixel (x=0)")
	testing.expect(t, pixels[mid_y * pitch + (cell_w - 1)] > 0, "U+2500 must fill right-most pixel (x=cell_w-1)")

	// 3. Prompt corner continuity: Row 0 ╭ (U+256D) meeting Row 1 ╰ (U+2570)
	mem.zero_slice(pixels)
	// Row 0 at py = 0
	font.draw_procedural_box(pixels, pitch, 0, 0, cell_w, cell_h, 0x256D)
	// Row 1 at py = cell_h
	font.draw_procedural_box(pixels, pitch, 0, cell_h, cell_w, cell_h, 0x2570)

	// Row 0 bottom pixel and Row 1 top pixel at column mid_x must both be inked (zero vertical gap)
	r0_bottom := pixels[(cell_h - 1) * pitch + mid_x]
	r1_top := pixels[cell_h * pitch + mid_x]
	testing.expect(t, r0_bottom > 0, "Row 0 ╭ bottom edge must be non-zero")
	testing.expect(t, r1_top > 0, "Row 1 ╰ top edge must be non-zero")

	// 4. Double line (U+2551 ║) must connect vertically
	mem.zero_slice(pixels)
	font.draw_procedural_box(pixels, pitch, 0, 0, cell_w, cell_h, 0x2551)
	testing.expect(t, pixels[0 * pitch + mid_x + 1] > 0, "U+2551 top edge must be inked")
	testing.expect(t, pixels[(cell_h - 1) * pitch + mid_x + 1] > 0, "U+2551 bottom edge must be inked")
}

@test
test_procedural_box_all_codepoints_safe :: proc(t: ^testing.T) {
	cell_w := 10
	cell_h := 20
	pitch := 64
	pixels := make([]u8, pitch * 64)
	defer delete(pixels)

	// All 128 box drawing codepoints must render without panic / out-of-bounds
	for cp in u32(0x2500)..=0x257F {
		mem.zero_slice(pixels)
		font.draw_procedural_box(pixels, pitch, 4, 4, cell_w, cell_h, cp)
	}
}

@test
test_procedural_block_all_codepoints_safe :: proc(t: ^testing.T) {
	cell_w := 10
	cell_h := 20
	pitch := 64
	pixels := make([]u8, pitch * 64)
	defer delete(pixels)

	// 1. Full block (U+2588 █) must fill entire cell rect
	mem.zero_slice(pixels)
	font.draw_procedural_block(pixels, pitch, 0, 0, cell_w, cell_h, 0x2588)
	testing.expect_value(t, pixels[0 * pitch + 0], 255)
	testing.expect_value(t, pixels[(cell_h - 1) * pitch + (cell_w - 1)], 255)

	// 2. Half blocks
	mem.zero_slice(pixels)
	font.draw_procedural_block(pixels, pitch, 0, 0, cell_w, cell_h, 0x2580) // Upper half
	testing.expect_value(t, pixels[0 * pitch + 0], 255)
	testing.expect_value(t, pixels[(cell_h - 1) * pitch + 0], 0)

	mem.zero_slice(pixels)
	font.draw_procedural_block(pixels, pitch, 0, 0, cell_w, cell_h, 0x2584) // Lower half
	testing.expect_value(t, pixels[0 * pitch + 0], 0)
	testing.expect_value(t, pixels[(cell_h - 1) * pitch + 0], 255)

	// 3. All 32 block element codepoints must render safely
	for cp in u32(0x2580)..=0x259F {
		mem.zero_slice(pixels)
		font.draw_procedural_block(pixels, pitch, 2, 2, cell_w, cell_h, cp)
	}
}
