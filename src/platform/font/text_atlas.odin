package platform_font

// Unified Text & Texture Atlas Facade
// Platform Font Subsystem (src/platform/font/*).

import "core:sync"
import core_atlas "../../core/render/atlas"
import contract "../../core/render/contract"

Text_Atlas :: struct {
	font_ctx:       Font_Context,
	ui_font_ctx:    Font_Context,
	glyph_atlas:    Glyph_Atlas_Manager,
	ui_glyph_atlas: Glyph_Atlas_Manager,
	emoji_atlas:    Emoji_Atlas_Manager,
	glyph_view:     contract.Gpu_TextureView,
	ui_glyph_view:  contract.Gpu_TextureView,
	emoji_view:     contract.Gpu_TextureView,
	pixel_size:     f32,
	cell_w:         f32,
	cell_h:         f32,
	ui_cell_w:      f32,
	ui_cell_h:      f32,
}

text_atlas_init :: proc(ta: ^Text_Atlas, pixel_size: f32) -> bool {
	if ta == nil do return false
	ta.pixel_size = pixel_size

	if !font_context_init(&ta.font_ctx, pixel_size, .Mono) {
		return false
	}
	if ta.font_ctx.has_font && ta.font_ctx.rasterizer.metrics.cell_width > 0 {
		ta.cell_w = ta.font_ctx.rasterizer.metrics.cell_width
		ta.cell_h = ta.font_ctx.rasterizer.metrics.cell_height
	} else {
		ta.cell_w = 19
		ta.cell_h = 43
	}

	if !glyph_atlas_init(&ta.glyph_atlas, &ta.font_ctx) {
		font_context_destroy(&ta.font_ctx)
		return false
	}

	ui_px := clamp(pixel_size * 1.15, pixel_size, 36.0)
	if !font_context_init(&ta.ui_font_ctx, ui_px, .Sans) {
		glyph_atlas_destroy(&ta.glyph_atlas)
		font_context_destroy(&ta.font_ctx)
		return false
	}
	if ta.ui_font_ctx.has_font && ta.ui_font_ctx.rasterizer.metrics.cell_width > 0 {
		ta.ui_cell_w = ta.ui_font_ctx.rasterizer.metrics.cell_width
		ta.ui_cell_h = ta.ui_font_ctx.rasterizer.metrics.cell_height
	} else {
		ta.ui_cell_w = ta.cell_w
		ta.ui_cell_h = ta.cell_h
	}
	if !glyph_atlas_init(&ta.ui_glyph_atlas, &ta.ui_font_ctx) {
		font_context_destroy(&ta.ui_font_ctx)
		glyph_atlas_destroy(&ta.glyph_atlas)
		font_context_destroy(&ta.font_ctx)
		return false
	}

	if !emoji_atlas_init(&ta.emoji_atlas, pixel_size) {
		glyph_atlas_destroy(&ta.ui_glyph_atlas)
		font_context_destroy(&ta.ui_font_ctx)
		glyph_atlas_destroy(&ta.glyph_atlas)
		font_context_destroy(&ta.font_ctx)
		return false
	}

	return true
}

text_atlas_destroy :: proc(ta: ^Text_Atlas) {
	if ta == nil do return
	glyph_atlas_destroy(&ta.ui_glyph_atlas)
	font_context_destroy(&ta.ui_font_ctx)
	glyph_atlas_destroy(&ta.glyph_atlas)
	emoji_atlas_destroy(&ta.emoji_atlas)
	font_context_destroy(&ta.font_ctx)
}

text_atlas_upload :: proc(ta: ^Text_Atlas, device: contract.Gpu_Device, queue: contract.Gpu_Queue) -> bool {
	if ta == nil do return false
	if !glyph_atlas_upload(&ta.glyph_atlas, device, queue) do return false
	if !glyph_atlas_upload(&ta.ui_glyph_atlas, device, queue) do return false
	if !emoji_atlas_upload(&ta.emoji_atlas, device, queue) do return false
	ta.glyph_view = ta.glyph_atlas.atlas.gpu_view
	ta.ui_glyph_view = ta.ui_glyph_atlas.atlas.gpu_view
	ta.emoji_view = ta.emoji_atlas.gpu_view
	return true
}

text_atlas_sync_gpu :: proc(ta: ^Text_Atlas, device: contract.Gpu_Device, queue: contract.Gpu_Queue) -> bool {
	if ta == nil do return false
	synced := false
	if glyph_atlas_drain_async(&ta.glyph_atlas) {
		synced = true
	}
	if glyph_atlas_drain_async(&ta.ui_glyph_atlas) {
		synced = true
	}
	if ta.glyph_atlas.atlas.gpu_dirty {
		if glyph_atlas_upload(&ta.glyph_atlas, device, queue) {
			ta.glyph_view = ta.glyph_atlas.atlas.gpu_view
			synced = true
		}
	}
	if ta.ui_glyph_atlas.atlas.gpu_dirty {
		if glyph_atlas_upload(&ta.ui_glyph_atlas, device, queue) {
			ta.ui_glyph_view = ta.ui_glyph_atlas.atlas.gpu_view
			synced = true
		}
	}
	if ta.emoji_atlas.gpu_dirty {
		if emoji_atlas_upload(&ta.emoji_atlas, device, queue) {
			ta.emoji_view = ta.emoji_atlas.gpu_view
			synced = true
		}
	}
	return synced
}

text_atlas_set_pixel_size :: proc(ta: ^Text_Atlas, pixel_size: f32, device: contract.Gpu_Device, queue: contract.Gpu_Queue) -> bool {
	if ta == nil || pixel_size <= 0 do return false
	ta.pixel_size = pixel_size

	if !font_context_set_pixel_size(&ta.font_ctx, pixel_size) {
		return false
	}
	if ta.font_ctx.has_font && ta.font_ctx.rasterizer.metrics.cell_width > 0 {
		ta.cell_w = ta.font_ctx.rasterizer.metrics.cell_width
		ta.cell_h = ta.font_ctx.rasterizer.metrics.cell_height
	}
	ui_px := clamp(pixel_size * 1.15, pixel_size, 36.0)
	if font_context_set_pixel_size(&ta.ui_font_ctx, ui_px) {
		if ta.ui_font_ctx.has_font && ta.ui_font_ctx.rasterizer.metrics.cell_width > 0 {
			ta.ui_cell_w = ta.ui_font_ctx.rasterizer.metrics.cell_width
			ta.ui_cell_h = ta.ui_font_ctx.rasterizer.metrics.cell_height
		}
		glyph_atlas_clear_and_prewarm(&ta.ui_glyph_atlas)
	}

	glyph_atlas_clear_and_prewarm(&ta.glyph_atlas)
	emoji_atlas_reset(&ta.emoji_atlas, pixel_size)

	return text_atlas_upload(ta, device, queue)
}

text_atlas_set_wakeup :: proc(ta: ^Text_Atlas, user: rawptr, cb: proc "contextless" (user: rawptr)) {
	if ta == nil do return
	if ta.glyph_atlas.async_worker != nil {
		async_raster_worker_set_wakeup(ta.glyph_atlas.async_worker, user, cb)
	}
	if ta.ui_glyph_atlas.async_worker != nil {
		async_raster_worker_set_wakeup(ta.ui_glyph_atlas.async_worker, user, cb)
	}
}

text_atlas_has_completions :: proc(ta: ^Text_Atlas) -> bool {
	if ta == nil do return false
	if ta.glyph_atlas.async_worker != nil {
		w := ta.glyph_atlas.async_worker
		if sync.mutex_try_lock(&w.mutex) {
			has := w.comp_count > 0
			sync.mutex_unlock(&w.mutex)
			if has do return true
		}
	}
	if ta.ui_glyph_atlas.async_worker != nil {
		w := ta.ui_glyph_atlas.async_worker
		if sync.mutex_try_lock(&w.mutex) {
			has := w.comp_count > 0
			sync.mutex_unlock(&w.mutex)
			if has do return true
		}
	}
	return false
}
