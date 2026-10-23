package platform_font_tests

// Behavioral unit tests for Asynchronous Glyph Rasterization (B9).

import "core:os"
import "core:testing"
import "core:time"
import core_atlas "../../../core/render/atlas"
import font "../"

@test
test_async_raster_worker_lifecycle :: proc(t: ^testing.T) {
	fc: font.Font_Context
	ok := font.font_context_init(&fc, 24.0)
	testing.expect(t, ok, "font context must initialize")
	defer font.font_context_destroy(&fc)

	worker := new(font.Async_Raster_Worker)
	defer free(worker)
	init_ok := font.async_raster_worker_init(worker, &fc)
	testing.expect(t, init_ok, "async raster worker must initialize and start thread")
	defer font.async_raster_worker_destroy(worker)

	// Enqueue cold glyph: CJK ideograph U+4E2D ('中')
	req := font.Async_Raster_Request{
		slot_idx = 350,
		cp       = 0x4E2D,
		is_wide  = true,
	}
	enq_ok := font.async_raster_enqueue(worker, req)
	testing.expect(t, enq_ok, "enqueue must succeed")

	// Wait up to 100ms for background worker thread to complete rasterization
	completed := false
	start := time.now()
	for time.duration_milliseconds(time.diff(start, time.now())) < 200.0 {
		if worker.comp_count > 0 {
			completed = true
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, completed, "worker thread must produce a completion entry")
	testing.expect_value(t, worker.comps[worker.comp_head].slot_idx, u32(350))
	testing.expect(t, worker.comps[worker.comp_head].rendered, "cold glyph must be rendered")
}

@test
test_glyph_atlas_async_cold_miss_and_drain :: proc(t: ^testing.T) {
	fc: font.Font_Context
	ok := font.font_context_init(&fc, 24.0)
	testing.expect(t, ok, "font context must initialize")
	defer font.font_context_destroy(&fc)

	gam: font.Glyph_Atlas_Manager
	atlas_ok := font.glyph_atlas_init(&gam, &fc)
	testing.expect(t, atlas_ok, "glyph atlas manager must initialize")
	defer font.glyph_atlas_destroy(&gam)

	testing.expect(t, gam.async_worker != nil, "async worker must be attached to atlas manager")

	// Cold miss: request CJK character not in pinned slots
	slot, req_ok := font.glyph_atlas_get_or_rasterize(&gam, 0x4E2D, true)
	testing.expect(t, req_ok, "request must return a valid slot immediately")
	testing.expect(t, slot >= core_atlas.FALLBACK_BASE, "slot must be in fallback region")

	// Verify immediate non-blocking return (atlas has valid placeholder, pending worker finish)
	testing.expect(t, gam.atlas.slots[slot].valid, "slot must have immediate valid placeholder")

	// Wait up to 150ms for worker completion
	time.sleep(50 * time.Millisecond)

	drained := font.glyph_atlas_drain_async(&gam)
	testing.expect(t, drained, "glyph_atlas_drain_async must drain completed bitmap")
	testing.expect(t, gam.atlas.gpu_dirty, "atlas must be marked dirty after drain")
	testing.expect(t, gam.atlas.slots[slot].valid, "slot must remain valid with final bitmap")
}
