package platform_font

// Unified Text & Texture Atlas Facade
// Platform Font Subsystem (src/platform/font/*).

import core_atlas "../../core/render/atlas"
import contract "../../core/render/contract"

Text_Atlas :: struct {
	font_ctx:    Font_Context,
	glyph_atlas: Glyph_Atlas_Manager,
	emoji_atlas: Emoji_Atlas_Manager,
	glyph_view:  contract.Gpu_TextureView,
	emoji_view:  contract.Gpu_TextureView,
	pixel_size:  f32,
	cell_w:      f32,
	cell_h:      f32,
}

text_atlas_init :: proc(ta: ^Text_Atlas, pixel_size: f32) -> bool {
	if ta == nil do return false
	ta.pixel_size = pixel_size

	if !font_context_init(&ta.font_ctx, pixel_size) {
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
		return false
	}
	if !emoji_atlas_init(&ta.emoji_atlas, pixel_size) {
		return false
	}

	return true
}

text_atlas_destroy :: proc(ta: ^Text_Atlas) {
	if ta == nil do return
	glyph_atlas_destroy(&ta.glyph_atlas)
	emoji_atlas_destroy(&ta.emoji_atlas)
	font_context_destroy(&ta.font_ctx)
}

text_atlas_upload :: proc(ta: ^Text_Atlas, device: contract.Gpu_Device, queue: contract.Gpu_Queue) -> bool {
	if ta == nil do return false
	if !glyph_atlas_upload(&ta.glyph_atlas, device, queue) do return false
	if !emoji_atlas_upload(&ta.emoji_atlas, device, queue) do return false
	ta.glyph_view = ta.glyph_atlas.atlas.gpu_view
	ta.emoji_view = ta.emoji_atlas.gpu_view
	return true
}

text_atlas_sync_gpu :: proc(ta: ^Text_Atlas, device: contract.Gpu_Device, queue: contract.Gpu_Queue) -> bool {
	if ta == nil do return false
	synced := false
	if ta.glyph_atlas.atlas.gpu_dirty {
		if glyph_atlas_upload(&ta.glyph_atlas, device, queue) {
			ta.glyph_view = ta.glyph_atlas.atlas.gpu_view
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

	glyph_atlas_clear_and_prewarm(&ta.glyph_atlas)
	emoji_atlas_reset(&ta.emoji_atlas, pixel_size)

	return text_atlas_upload(ta, device, queue)
}
