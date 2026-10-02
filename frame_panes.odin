renderer_frame_panes :: proc(
	r:     ^Renderer,
	panes: []Pane_Viewport,
	lut:   ^Style_LUT = nil,
) -> bool {
	if r == nil || len(panes) == 0 {
		return false
	}
	r.frame_count += 1
	lut_ptr := lut != nil ? lut : &r.style_lut

	active_term: ^termgrid.Terminal = nil
	for p in panes {
		if p.is_active && p.terminal != nil {
			active_term = p.terminal
			break
		}
	}
	if active_term == nil && len(panes) > 0 {
		active_term = panes[0].terminal
	}
	if active_term != nil {
		if _style_lut_needs_rebuild(lut_ptr, &active_term.grid.style_table) {
			_style_lut_rebuild(lut_ptr, &active_term.grid.style_table)
		}
		lut_ptr.bg_r5g6b5[0] = color_to_r5g6b5(active_term.grid.style_table.theme.background)
	}

	compiled_panes := make([]Compiled_Frame_V2, len(panes), context.temp_allocator)
	for i in 0 ..< len(panes) {
		p := &panes[i]
		if p.terminal == nil || p.rows <= 0 || p.cols <= 0 do continue
		render_compiler_init_v2(&compiled_panes[i], i32(p.rows), i32(p.cols), context.temp_allocator)
		render_compile_full_v2(&compiled_panes[i], p.terminal, &r.fallback, &r.shape_cache, &r.atlas, &r.fallback_counters, &r.raster, p.view)
	}

	r.dirty.armed = false
	bg_count, glyph_count, emoji_count, decor_count := _prepare_pane_instances_v2(r, lut_ptr, panes, compiled_panes)

	if r.unlock_cb != nil {
		r.unlock_cb(r.unlock_data)
	}
	when ODIN_OS == .Darwin {
		if r.emoji_atlas.gpu_dirty {
			emoji_atlas_upload_gpu(&r.emoji_atlas, r.backend, r.device, r.queue)
		}
		if emoji_count > 0 && rawptr(r.instances.emoji_buffer) != nil && r.instances.emoji_data != nil {
			r.backend.write_buffer(r.queue, r.instances.emoji_buffer, 0, raw_data(r.instances.emoji_data), u64(emoji_count) * instance.INSTANCE_STRIDE)
		}
	}
	if r.atlas.gpu_dirty {
		atlas_upload_gpu(&r.atlas, r.backend, r.device, r.queue)
	}

	frame, ok := _renderer_surface_begin(r)
	if !ok {
		return false
	}
	if !_renderer_upload_instances(r, bg_count + glyph_count + decor_count, &frame) {
		_renderer_surface_abort(r, &frame)
		return false
	}
	decor_offset := u64(bg_count + glyph_count) * instance.INSTANCE_STRIDE
	if !_draw_instance_buffer(r, &frame, frame.cursor_buffer, bg_count, glyph_count, u64(bg_count) * instance.INSTANCE_STRIDE, emoji_count, false, decor_count, decor_offset) {
		_renderer_surface_abort(r, &frame)
		return false
	}
	if !_renderer_surface_commit(r, &frame) {
		return false
	}
	r.full_redraw_pending = false
	_renderer_frame_published(r, nil)
	return true
}

// renderer_set_strategy selects the frame path. Switching to Compute_Tiles

--- TARGET:
	return _renderer_frame_v2_journal(r, terminal, &journal, lut, view, view_changed)
}

// renderer_set_strategy selects the frame path. Switching to Compute_Tiles
