package platform_font

// Asynchronous Background Glyph Rasterization Worker
// Platform Font Subsystem (src/platform/font/*).
//
// Invariant: Zero heap allocations during enqueue, rasterization, and drain.
// Mitigates cold-miss frame spikes (e.g. initial output of large CJK / Arabic runs)
// by offloading rasterization to a background worker thread.

import "base:runtime"
import "core:sync"
import "core:thread"
import core_atlas "../../core/render/atlas"

ASYNC_RASTER_QUEUE_CAP :: 128

Async_Raster_Request :: struct {
	slot_idx:   u32,
	cp:         rune,
	is_wide:    bool,
	is_cluster: bool,
	runes:      [4]rune,
	rune_count: u8,
}

Async_Raster_Completion :: struct {
	slot_idx: u32,
	draw_w:   f32,
	offset_x: f32,
	rendered: bool,
	pixels:   [core_atlas.ATLAS_GLYPH_SIZE * core_atlas.ATLAS_GLYPH_SIZE]u8,
}

Async_Raster_Worker :: struct {
	mutex:      sync.Mutex,
	cond:       sync.Cond,
	thread:     ^thread.Thread,
	running:    bool,
	fc:         ^Font_Context,

	// Request ring buffer (render thread pushes, worker thread pops)
	reqs:       [ASYNC_RASTER_QUEUE_CAP]Async_Raster_Request,
	req_head:   int,
	req_tail:   int,
	req_count:  int,

	// Completion ring buffer (worker thread pushes, render thread pops)
	comps:      [ASYNC_RASTER_QUEUE_CAP]Async_Raster_Completion,
	comp_head:  int,
	comp_tail:  int,
	comp_count: int,
}

@(private = "file")
_async_raster_execute_job :: proc(w: ^Async_Raster_Worker, req: ^Async_Raster_Request) -> Async_Raster_Completion {
	comp := Async_Raster_Completion{slot_idx = req.slot_idx}
	if w.fc == nil do return comp

	if req.is_cluster && req.rune_count > 0 {
		comp.draw_w, comp.offset_x = font_rasterize_cluster_into(
			w.fc,
			req.runes[:req.rune_count],
			comp.pixels[:],
			core_atlas.ATLAS_GLYPH_SIZE,
			0, 0,
			core_atlas.ATLAS_GLYPH_SIZE,
			core_atlas.ATLAS_GLYPH_SIZE,
			req.is_wide,
		)
		comp.rendered = true
	} else {
		u := u32(req.cp)
		if u >= CONTENT_LIGATURE_BASE {
			g_idx := u - CONTENT_LIGATURE_BASE
			font_rasterize_glyph_index_into(
				&w.fc.rasterizer,
				g_idx,
				comp.pixels[:],
				core_atlas.ATLAS_GLYPH_SIZE,
				0, 0,
				core_atlas.ATLAS_GLYPH_SIZE,
				core_atlas.ATLAS_GLYPH_SIZE,
			)
			cell_w := f32(w.fc.rasterizer.metrics.cell_width) if w.fc.rasterizer.metrics.cell_width > 0 else 19.0
			comp.draw_w = cell_w * 2.0 if req.is_wide else cell_w
			comp.offset_x = 0.0
			comp.rendered = true
		} else if font_has_codepoint(w.fc, u) {
			comp.draw_w, comp.offset_x = font_rasterize_codepoint(
				w.fc,
				u,
				comp.pixels[:],
				core_atlas.ATLAS_GLYPH_SIZE,
				0, 0,
				core_atlas.ATLAS_GLYPH_SIZE,
				core_atlas.ATLAS_GLYPH_SIZE,
				req.is_wide,
			)
			comp.rendered = true
		}
	}
	return comp
}

@(private = "file")
_async_raster_worker_loop :: proc(data: rawptr) {
	w := (^Async_Raster_Worker)(data)
	if w == nil do return

	for {
		req: Async_Raster_Request
		has_req := false

		sync.mutex_lock(&w.mutex)
		for w.running && w.req_count == 0 {
			sync.cond_wait(&w.cond, &w.mutex)
		}
		if !w.running && w.req_count == 0 {
			sync.mutex_unlock(&w.mutex)
			break
		}
		if w.req_count > 0 {
			req = w.reqs[w.req_head]
			w.req_head = (w.req_head + 1) % ASYNC_RASTER_QUEUE_CAP
			w.req_count -= 1
			has_req = true
		}
		sync.mutex_unlock(&w.mutex)

		if !has_req do continue

		comp := _async_raster_execute_job(w, &req)

		sync.mutex_lock(&w.mutex)
		if w.comp_count < ASYNC_RASTER_QUEUE_CAP {
			w.comps[w.comp_tail] = comp
			w.comp_tail = (w.comp_tail + 1) % ASYNC_RASTER_QUEUE_CAP
			w.comp_count += 1
		}
		sync.mutex_unlock(&w.mutex)
	}
}

async_raster_worker_init :: proc(w: ^Async_Raster_Worker, fc: ^Font_Context) -> bool {
	if w == nil do return false
	w^ = Async_Raster_Worker{}
	w.fc = fc
	w.running = true
	w.thread = thread.create_and_start_with_data(rawptr(w), _async_raster_worker_loop)
	return w.thread != nil
}

async_raster_worker_destroy :: proc(w: ^Async_Raster_Worker) {
	if w == nil do return
	sync.mutex_lock(&w.mutex)
	w.running = false
	sync.cond_signal(&w.cond)
	sync.mutex_unlock(&w.mutex)

	if w.thread != nil {
		thread.join(w.thread)
		thread.destroy(w.thread)
		w.thread = nil
	}
}

async_raster_enqueue :: proc(w: ^Async_Raster_Worker, req: Async_Raster_Request) -> bool {
	if w == nil do return false
	sync.mutex_lock(&w.mutex)
	defer sync.mutex_unlock(&w.mutex)

	if w.req_count >= ASYNC_RASTER_QUEUE_CAP do return false
	w.reqs[w.req_tail] = req
	w.req_tail = (w.req_tail + 1) % ASYNC_RASTER_QUEUE_CAP
	w.req_count += 1
	sync.cond_signal(&w.cond)
	return true
}
