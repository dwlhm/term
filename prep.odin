_prepare_pane_instances_v2 :: proc(
	r:              ^Renderer,
	lut:            ^Style_LUT,
	panes:          []Pane_Viewport,
	compiled_panes: []Compiled_Frame_V2,
) -> (bg_count: u32, glyph_count: u32, emoji_count: u32, decor_count: u32) {
	cell_w := r.cell_width
	cell_h := r.cell_height
	atlas := &r.atlas
	inst := &r.instances

	bg_count = 0
	glyph_count = 0
	emoji_count = 0
	decor_count = 0
	grid_limit := inst.max_instances > 1 ? inst.max_instances - 1 : 0

	// Pass 1: backgrounds across all panes
	for i in 0 ..< len(panes) {
		p := &panes[i]
		if p.terminal == nil || i >= len(compiled_panes) do continue
		cells := compiled_panes[i].cells
		cols := i32(p.cols)
		dim := p.dim_factor

		for idx in 0 ..< len(cells) {
			if bg_count >= grid_limit do break
			row := i32(idx) / cols
			col := i32(idx) % cols
			x := p.x + f32(col) * cell_w
			y := p.y + f32(row) * cell_h

			dc := termgrid.terminal_view_get_direct_color(p.terminal, p.view, int(row), int(col))
			emit_bg, _, _, _ := render_cell_expand_instance(
				cells[idx], lut, atlas, x, y, cell_w, cell_h,
				&inst.instance_data[bg_count], nil,
				direct_color = dc,
			)
			if emit_bg {
				if dim < 1.0 {
					inst.instance_data[bg_count].r *= dim
					inst.instance_data[bg_count].g *= dim
					inst.instance_data[bg_count].b *= dim
				}
				bg_count += 1
			}
		}
	}

	// Pass 2: glyphs and emojis across all panes
	for i in 0 ..< len(panes) {
		p := &panes[i]
		if p.terminal == nil || i >= len(compiled_panes) do continue
		cells := compiled_panes[i].cells
		cols := i32(p.cols)
		dim := p.dim_factor

		for idx in 0 ..< len(cells) {
			glyph_idx := bg_count + glyph_count
			if glyph_idx >= grid_limit do break
			row := i32(idx) / cols
			col := i32(idx) % cols
			x := p.x + f32(col) * cell_w
			y := p.y + f32(row) * cell_h

			emoji_inst_ptr: ^instance.Instance_Data = nil
			emoji_atlas_ptr: ^Emoji_Atlas = nil
			if r.emoji_atlas.has_font {
				if emoji_count < grid_limit && inst.emoji_data != nil {
					emoji_inst_ptr = &inst.emoji_data[emoji_count]
				}
				emoji_atlas_ptr = &r.emoji_atlas
			}

			dc := termgrid.terminal_view_get_direct_color(p.terminal, p.view, int(row), int(col))
			_, emit_glyph, emit_emoji, _ := render_cell_expand_instance(
				cells[idx], lut, atlas, x, y, cell_w, cell_h,
				nil, &inst.instance_data[glyph_idx],
				emoji_inst_ptr,
				emoji_atlas_ptr,
				&p.terminal.grapheme_store,
				direct_color = dc,
			)
			if emit_emoji {
				if dim < 1.0 && emoji_inst_ptr != nil {
					emoji_inst_ptr.r *= dim
					emoji_inst_ptr.g *= dim
					emoji_inst_ptr.b *= dim
				}
				emoji_count += 1
			} else if emit_glyph {
				if dim < 1.0 {
					inst.instance_data[glyph_idx].r *= dim
					inst.instance_data[glyph_idx].g *= dim
					inst.instance_data[glyph_idx].b *= dim
				}
				glyph_count += 1
			}
		}
	}

	// Pass 3: decorations across all panes
	for i in 0 ..< len(panes) {
		p := &panes[i]
		if p.terminal == nil || i >= len(compiled_panes) do continue
		cells := compiled_panes[i].cells
		cols := i32(p.cols)
		dim := p.dim_factor

		for idx in 0 ..< len(cells) {
			decor_idx := bg_count + glyph_count + decor_count
			if decor_idx >= grid_limit do break
			row := i32(idx) / cols
			col := i32(idx) % cols
			x := p.x + f32(col) * cell_w
			y := p.y + f32(row) * cell_h

			dc := termgrid.terminal_view_get_direct_color(p.terminal, p.view, int(row), int(col))
			_, _, _, emit_decor := render_cell_expand_instance(
				cells[idx], lut, atlas, x, y, cell_w, cell_h,
				nil, nil, nil, nil, nil,
				&inst.instance_data[decor_idx],
				direct_color = dc,
			)
			if emit_decor {
				if dim < 1.0 {
					inst.instance_data[decor_idx].r *= dim
					inst.instance_data[decor_idx].g *= dim
					inst.instance_data[decor_idx].b *= dim
				}
				decor_count += 1
			}
		}
	}

	return bg_count, glyph_count, emoji_count, decor_count
}
