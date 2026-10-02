package render

import instance "instance"
import termgrid "../terminal"
import interaction "../interaction"

// Primary highlight color for active search match (bright orange/yellow).
INTERACTION_MATCH_PRIMARY_R: f32 : 1.0
INTERACTION_MATCH_PRIMARY_G: f32 : 0.8
INTERACTION_MATCH_PRIMARY_B: f32 : 0.2

// Secondary highlight color for non-active search matches (muted amber).
INTERACTION_MATCH_SECONDARY_R: f32 : 0.8
INTERACTION_MATCH_SECONDARY_G: f32 : 0.6
INTERACTION_MATCH_SECONDARY_B: f32 : 0.2

// interaction_overlay_draw stages highlight quads for visible search matches
// into the instance staging buffer.
//
// Guarantees (per cursor_overlay contract):
//   - Never mutates terminal damage tracking.
//   - Never touches terminal state or grid cells.
//   - Zero allocation steady-state.
//   - Preserves existing dense background and glyph data.
//   - Returns true iff at least one quad was staged.
interaction_overlay_draw :: proc(
	r: ^Renderer,
	s: ^interaction.Interaction_State,
	v: ^termgrid.Terminal_View,
	t: ^termgrid.Terminal,
	offset_x: f32 = 0,
	offset_y: f32 = 0,
	viewport_rows: int = 0,
	viewport_cols: int = 0,
	clip_rect: [4]f32 = {},
) -> bool {
	if r == nil {
		return false
	}
	r.interaction_staged = false
	r.interaction_quad_count = 0
	r.interaction_slot_start = 0

	if s == nil || !s.search_active || s.search_match_count <= 0 {
		return false
	}

	rows := viewport_rows if viewport_rows > 0 else int(r.rows)
	cols := viewport_cols if viewport_cols > 0 else int(r.cols)
	if rows <= 0 || cols <= 0 {
		return false
	}

	inst := &r.instances
	if inst.max_instances <= 2 || len(inst.instance_data) == 0 {
		return false
	}

	// Determine base document row for the viewport.
	// Document row corresponds to row + scrollback_offset when viewing history.
	base_doc_row := 0
	if t != nil {
		offset := 0
		if v != nil {
			offset = clamp(v.scrollback_offset, 0, termgrid.terminal_view_max_offset(t))
		}
		base_doc_row = termgrid.scrollback_len(&t.scrollback) - offset
	} else if v != nil {
		base_doc_row = v.scrollback_offset
	}

	// Max slots available for overlay without overwriting dense region or cursor (slot max_instances-1).
	max_overlay_slots := int(inst.max_instances) - 2

	// Pass 1: Count total visible quads needed
	needed_quads := 0
	match_count := min(s.search_match_count, len(s.search_matches))
	for i in 0..<match_count {
		m := s.search_matches[i]
		vp_row := m.row - base_doc_row
		if vp_row < 0 || vp_row >= rows {
			continue
		}
		c_start := max(0, m.col_start)
		c_end := min(cols - 1, m.col_end)
		if c_start > c_end {
			continue
		}
		needed_quads += (c_end - c_start + 1)
	}

	if needed_quads == 0 {
		return false
	}

	total_to_stage := min(needed_quads, max_overlay_slots)
	// Staging region ends right before cursor slot (inst.max_instances - 1)
	start_slot := u32(int(inst.max_instances) - 1 - total_to_stage)

	staged := 0
	for i in 0..<match_count {
		if staged >= total_to_stage {
			break
		}
		m := s.search_matches[i]
		vp_row := m.row - base_doc_row
		if vp_row < 0 || vp_row >= rows {
			continue
		}
		c_start := max(0, m.col_start)
		c_end := min(cols - 1, m.col_end)
		if c_start > c_end {
			continue
		}

		is_active := (i == s.search_match_idx)
		cr := is_active ? INTERACTION_MATCH_PRIMARY_R : INTERACTION_MATCH_SECONDARY_R
		cg := is_active ? INTERACTION_MATCH_PRIMARY_G : INTERACTION_MATCH_SECONDARY_G
		cb := is_active ? INTERACTION_MATCH_PRIMARY_B : INTERACTION_MATCH_SECONDARY_B

		y := r.pad_y + offset_y + f32(vp_row) * r.cell_height
		h := r.cell_height
		w := r.cell_width

		for col := c_start; col <= c_end; col += 1 {
			if staged >= total_to_stage {
				break
			}
			x := r.pad_x + offset_x + f32(col) * r.cell_width
			if clip_rect[2] > clip_rect[0] {
				if x < clip_rect[0] || y < clip_rect[1] || x+w > clip_rect[2] || y+h > clip_rect[3] do continue
			}
			slot := start_slot + u32(staged)
			instance.instance_renderer_fill_bg(inst, slot, x, y, w, h, cr, cg, cb)
			staged += 1
		}
	}

	if staged > 0 {
		r.interaction_staged = true
		r.interaction_slot_start = start_slot
		r.interaction_quad_count = staged
		return true
	}

	return false
}
