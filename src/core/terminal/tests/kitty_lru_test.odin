package terminal_tests

import "core:fmt"
import "core:testing"
import term "../"
import extension "../extension"

@ (test)
test_kitty_lru_cache_eviction :: proc(t: ^testing.T) {
	terminal: term.Terminal
	_kitty_test_init(&terminal)
	defer term.terminal_destroy(&terminal)
	state := _kitty_test_state(t, &terminal)

	// 1. Fill all 32 image slots with 1x1 RGBA images (4 bytes each).
	// Image 1..32
	for id in 1 ..= extension.MAX_KITTY_IMAGES {
		apc := fmt.tprintf("\x1b_Ga=T,i=%d,f=32,s=1,v=1;AAAA\x1b\\", id)
		term.terminal_feed_string(&terminal, apc)
	}

	// Verify all 32 images exist
	for id in 1 ..= extension.MAX_KITTY_IMAGES {
		img := extension._kitty_find_image(state, u32(id))
		testing.expect(t, img != nil, fmt.tprintf("Image %d should exist in slots", id))
	}

	// 2. Access / place image 1 so its last_used is updated to be the most recent!
	// Send put command for image 1: a=p,i=1
	term.terminal_feed_string(&terminal, "\x1b_Ga=p,i=1\x1b\\")

	// Verify image 1 has higher last_used than image 2
	img1 := extension._kitty_find_image(state, 1)
	img2 := extension._kitty_find_image(state, 2)
	testing.expect(t, img1 != nil && img2 != nil, "img1 and img2 must exist")
	testing.expect(t, img1.last_used > img2.last_used, "img1 was recently placed so last_used must be newer")

	// 3. Store 33rd image (i=33). Since image 2 is the oldest unused image, it should be evicted!
	term.terminal_feed_string(&terminal, "\x1b_Ga=T,i=33,f=32,s=1,v=1;AAAA\x1b\\")

	// Image 33 must exist
	img33 := extension._kitty_find_image(state, 33)
	testing.expect(t, img33 != nil, "Image 33 should exist")

	// Image 1 was placed recently, so it must still exist!
	img1_after := extension._kitty_find_image(state, 1)
	testing.expect(t, img1_after != nil, "Image 1 was accessed recently so it must NOT be evicted")

	// Image 2 was the oldest, so it must have been evicted!
	img2_after := extension._kitty_find_image(state, 2)
	testing.expect(t, img2_after == nil, "Image 2 should have been evicted by LRU policy")

	// 4. Store 34th image (i=34). Image 3 should now be the oldest and be evicted!
	term.terminal_feed_string(&terminal, "\x1b_Ga=T,i=34,f=32,s=1,v=1;AAAA\x1b\\")
	img3_after := extension._kitty_find_image(state, 3)
	testing.expect(t, img3_after == nil, "Image 3 should have been evicted by LRU policy")
	img34 := extension._kitty_find_image(state, 34)
	testing.expect(t, img34 != nil, "Image 34 should exist")
}
