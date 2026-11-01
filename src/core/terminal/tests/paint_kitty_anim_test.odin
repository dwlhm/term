package terminal_tests

// Paint must re-emit kitty animation frames and their state machine, not just
// the image and its placement, so an attached viewer sees the same animation.

import "core:slice"
import "core:testing"
import term "../"
import extension "../extension"

PAINT_ANIM_BASE :: "\x1b[3;4H\x1b_Ga=T,f=32,s=2,v=1,i=7,c=4,r=2,q=2;/wAA/wD/AP8=\x1b\\"
PAINT_ANIM_FRAME2 :: "\x1b_Ga=f,i=7,r=2,s=2,v=1,c=1,z=50,q=2;AAD/////AP8=\x1b\\"
PAINT_ANIM_CTRL :: "\x1b_Ga=a,i=7,s=3,v=2,c=1,z=50,q=2\x1b\\"

_paint_anim_image :: proc(t: ^testing.T, term_val: ^term.Terminal) -> ^extension.Kitty_Image {
	ks := (^extension.Kitty_Extension)(term_val.extensions.extensions[0].user_data)
	img := extension.kitty_graphics_get_image(ks, 7)
	if !testing.expect(t, img != nil, "image 7 missing") do return nil
	return img
}

@test
test_paint_kitty_animation_round_trip :: proc(t: ^testing.T) {
	src, dst: term.Terminal
	term.terminal_init(&src, 8, 24)
	term.terminal_init(&dst, 8, 24)
	defer term.terminal_destroy(&src)
	defer term.terminal_destroy(&dst)
	term.terminal_register_extension(&src, extension.kitty_graphics_extension_make())
	term.terminal_register_extension(&dst, extension.kitty_graphics_extension_make())

	term.terminal_feed_string(&src, PAINT_ANIM_BASE + PAINT_ANIM_FRAME2 + PAINT_ANIM_CTRL)
	src_img := _paint_anim_image(t, &src)
	if src_img == nil do return
	if !testing.expect_value(t, len(src_img.animation.frames), 2) do return

	out := make([dynamic]u8, 0, 4096)
	defer delete(out)
	term.terminal_paint(&src, &out, 0)
	term.terminal_feed_bytes(&dst, out[:])

	dst_img := _paint_anim_image(t, &dst)
	if dst_img == nil do return
	testing.expect_value(t, len(dst_img.animation.frames), len(src_img.animation.frames))
	testing.expect_value(t, dst_img.animation.current_frame, src_img.animation.current_frame)
	testing.expect_value(t, dst_img.animation.state, src_img.animation.state)
	testing.expect_value(t, dst_img.animation.loop_count, src_img.animation.loop_count)
	testing.expect(t, slice.equal(dst_img.pixels, src_img.pixels), "current frame pixels differ")

	for frame, i in src_img.animation.frames {
		if !testing.expectf(t, i < len(dst_img.animation.frames), "frame %d missing", i) do break
		got := dst_img.animation.frames[i]
		testing.expectf(t, got.frame_num == frame.frame_num, "frame %d number", i)
		testing.expectf(t, got.duration_ms == frame.duration_ms, "frame %d gap", i)
		testing.expectf(t, got.composition == frame.composition, "frame %d composition", i)
		testing.expectf(t, got.width == frame.width && got.height == frame.height, "frame %d size", i)
		testing.expectf(t, got.x == frame.x && got.y == frame.y, "frame %d offset", i)
		testing.expectf(t, got.w == frame.w && got.h == frame.h, "frame %d source rect", i)
		testing.expectf(t, slice.equal(got.pixels, frame.pixels), "frame %d pixels", i)
	}
	testing.expect_value(t, dst.parser.response_len, 0)
}
