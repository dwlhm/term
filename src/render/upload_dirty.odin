package render

// Phase 8 dirty upload: persistent GPU instance buffer with offset writes.
//
// Cell (r, c) maps to stable slots: bg slot i = r*cols+c in [0, N),
// glyph slot N+i in [N, 2N), where N = rows*cols. Every frame draws the
// same 2 draws with constant counts (N, N); empty/continuation cells hold
// zero-area degenerate instances so they draw nothing. Only widened dirty
// ranges are written via backend.write_buffer at byte offsets; the upload
// ring is retained as the legacy-fallback carrier only.

import "base:runtime"
import gpu "gpu"
import instance "instance"
import termgrid "../terminal"

// Dirty_Upload_Range is one contiguous GPU buffer sub-range to upload.
Dirty_Upload_Range :: struct {
	offset: u64,
	size:   u64,
}

// DIRTY_UPLOAD_MAX_RANGES caps collected ranges per frame; overflow falls back to legacy.
DIRTY_UPLOAD_MAX_RANGES :: 2048

// DIRTY_UPLOAD_MERGE_GAP merges widened spans separated by at most this many columns.
DIRTY_UPLOAD_MERGE_GAP :: 1

// Dirty_Upload is the persistent GPU instance buffer plus its CPU mirror.
// Mirror layout: bg instances in [0, N), glyph instances in [N, 2N).
Dirty_Upload :: struct {
	buffer: gpu.Gpu_Buffer,
	mirror: []instance.Instance_Data,
	cells:  int,
	armed:  bool,
}

// dirty_upload_init allocates the 2N mirror, creates the 2N*48 GPU buffer,
// and rebases (full expand + full upload). Returns false when 2N exceeds
// max_instances or the GPU buffer cannot be created (nil backend skips GPU
// creation for CPU-only use); the caller falls back to the legacy ring path.
dirty_upload_init :: proc(d: ^Dirty_Upload, r: ^Renderer, allocator: runtime.Allocator = context.allocator) -> bool {
	n := int(r.rows) * int(r.cols)
	if n <= 0 {
		return false
	}
	if u64(2 * n) > u64(r.instances.max_instances) {
		return false
	}
	d.cells = n
	d.mirror = make([]instance.Instance_Data, 2 * n, allocator)
	d.buffer = gpu.Gpu_Buffer(nil)
	d.armed = false
	if r.backend != nil && rawptr(r.device) != nil {
		d.buffer = r.backend.create_buffer(
			r.device,
			u64(2 * n) * instance.INSTANCE_STRIDE,
			gpu.Gpu_Buffer_Usage.Vertex | gpu.Gpu_Buffer_Usage.Copy_Dst,
			false,
		)
		if rawptr(d.buffer) == nil {
			delete(d.mirror)
			d.mirror = nil
			d.cells = 0
			return false
		}
	}
	dirty_upload_rebase(d, r, &r.style_lut)
	return true
}

// dirty_upload_destroy frees the CPU mirror and resets state.
// The GPU buffer is destroyed by the caller (renderer_destroy owns the backend handle).
dirty_upload_destroy :: proc(d: ^Dirty_Upload, allocator: runtime.Allocator = context.allocator) {
	if d.mirror != nil {
		delete(d.mirror)
		d.mirror = nil
	}
	d.buffer = gpu.Gpu_Buffer(nil)
	d.cells = 0
	d.armed = false
}

// dirty_upload_validate_mirror checks the fixed bg/glyph mirror contract.
dirty_upload_validate_mirror :: proc(d: ^Dirty_Upload, r: ^Renderer) -> bool {
	if d == nil || r == nil || d.mirror == nil { return false }
	n := int(r.rows) * int(r.cols)
	if n <= 0 || d.cells != n || len(d.mirror) != 2 * n { return false }
	mirror_bytes := u64(len(d.mirror)) * instance.INSTANCE_STRIDE
	if mirror_bytes != u64(2 * n) * instance.INSTANCE_STRIDE { return false }
	for i in 0..<n {
		bg := i
		glyph := n + i
		if bg < 0 || bg >= len(d.mirror) || glyph < n || glyph >= len(d.mirror) { return false }
	}
	return true
}

// dirty_upload_rebase fully expands r.compiled_v2 into the mirror and
// performs ONE full write_buffer at offset 0, then arms the upload.
// Skipped cells (empty/continuation) are zeroed so no stale data survives.
dirty_upload_rebase :: proc(d: ^Dirty_Upload, r: ^Renderer, lut: ^Style_LUT) {
	if d.mirror == nil || d.cells <= 0 {
		return
	}
	if len(r.compiled_v2.cells) < d.cells {
		return
	}
	cols := int(r.cols)
	cw := r.cell_width
	ch := r.cell_height
	n := d.cells
	for idx in 0..<n {
		row := idx / cols
		col := idx % cols
		x := r.pad_x + f32(col) * cw
		y := r.pad_y + f32(row) * ch
		emit_bg, emit_glyph := render_cell_expand_instance(
			r.compiled_v2.cells[idx], lut, &r.atlas, x, y, cw, ch,
			&d.mirror[idx], &d.mirror[n+idx],
		)
		if !emit_bg {
			d.mirror[idx] = instance.Instance_Data{}
		}
		if !emit_glyph {
			d.mirror[n+idx] = instance.Instance_Data{}
		}
	}
	if r.backend != nil && rawptr(r.queue) != nil && rawptr(d.buffer) != nil && len(d.mirror) > 0 {
		total := u64(len(d.mirror)) * instance.INSTANCE_STRIDE
		r.backend.write_buffer(r.queue, d.buffer, 0, raw_data(d.mirror), total)
	}
	d.armed = true
}

// dirty_upload_frame compiles dirty ranges, expands one merged widened run
// per span group into the stable mirror slots (zeroing skips), collects
// bg+glyph byte ranges, and issues one write_buffer per range at offset.
// Returns fell_back=true when scroll_ops are present or range capacity
// overflows; the caller then takes the legacy full path.
dirty_upload_frame :: proc(
	d: ^Dirty_Upload,
	r: ^Renderer,
	terminal: ^termgrid.Terminal,
	journal: ^termgrid.Damage_Journal,
	lut: ^Style_LUT,
	ranges: ^[DIRTY_UPLOAD_MAX_RANGES]Dirty_Upload_Range,
) -> (flushed_ranges: int, flushed_bytes: u64, fell_back: bool) {
	if len(journal.scroll_ops) > 0 {
		return 0, 0, true
	}
	if d.mirror == nil || !d.armed {
		return 0, 0, true
	}
	if terminal.grid.style_table.count != lut.count {
		style_lut_rebuild(lut, &terminal.grid.style_table)
	}
	render_compile_v2(&r.compiled_v2, terminal, journal, &r.fallback, &r.shape_cache, &r.atlas, &r.fallback_counters, &r.raster)

	rows := int(r.rows)
	cols := int(r.cols)
	range_count := 0
	for row_idx in 0..<rows {
		if row_idx >= len(journal.dirty_rows) {
			break
		}
		dr := &journal.dirty_rows[row_idx]
		if !dr.full && dr.span_count == 0 {
			continue
		}
		if dr.full {
			if !_dirty_expand_row(d, r, terminal, lut, row_idx, 0, cols, ranges, &range_count) {
				return 0, 0, true
			}
			continue
		}
		// Widen spans +-1 col (pulls lead/continuation pairs into the run).
		starts: [termgrid.DIRTY_ROW_MAX_SPANS]int
		ends:   [termgrid.DIRTY_ROW_MAX_SPANS]int
		nspans := int(dr.span_count)
		if nspans > len(starts) {
			nspans = len(starts)
		}
		m := 0
		for s in 0..<nspans {
			sp := dr.spans[s]
			cs := int(sp.col_start) - 1
			ce := int(sp.col_end) + 1
			if cs < 0 {
				cs = 0
			}
			if ce > cols {
				ce = cols
			}
			if cs >= ce {
				continue
			}
			starts[m] = cs
			ends[m] = ce
			m += 1
		}
		if m == 0 {
			continue
		}
		// Sort by start (insertion sort; at most 4 spans).
		for a in 1..<m {
			for b := a; b > 0 && starts[b] < starts[b-1]; b -= 1 {
				starts[b], starts[b-1] = starts[b-1], starts[b]
				ends[b], ends[b-1] = ends[b-1], ends[b]
			}
		}
		// Merge runs separated by at most DIRTY_UPLOAD_MERGE_GAP.
		ms := starts[0]
		me := ends[0]
		for s in 1..<m {
			if starts[s] <= me + DIRTY_UPLOAD_MERGE_GAP {
				if ends[s] > me {
					me = ends[s]
				}
			} else {
				if !_dirty_expand_row(d, r, terminal, lut, row_idx, ms, me, ranges, &range_count) {
					return 0, 0, true
				}
				ms = starts[s]
				me = ends[s]
			}
		}
		if !_dirty_expand_row(d, r, terminal, lut, row_idx, ms, me, ranges, &range_count) {
			return 0, 0, true
		}
	}

	flushed_bytes = 0
	if r.backend != nil && rawptr(r.queue) != nil && rawptr(d.buffer) != nil {
		base := raw_data(d.mirror)
		for k in 0..<range_count {
			ptr := rawptr(uintptr(base) + uintptr(ranges[k].offset))
			r.backend.write_buffer(r.queue, d.buffer, ranges[k].offset, ptr, ranges[k].size)
			flushed_bytes += ranges[k].size
		}
	} else {
		for k in 0..<range_count {
			flushed_bytes += ranges[k].size
		}
	}
	return range_count, flushed_bytes, false
}

// _dirty_expand_row expands one merged widened run into the stable mirror
// slots (zeroing skips so occupied->empty leaves no ghosts) and appends at
// most 2 ranges (bg + glyph). Returns false on range capacity overflow.
_dirty_expand_row :: proc(
	d: ^Dirty_Upload,
	r: ^Renderer,
	terminal: ^termgrid.Terminal,
	lut: ^Style_LUT,
	row: int,
	col_start: int,
	col_end: int,
	ranges: ^[DIRTY_UPLOAD_MAX_RANGES]Dirty_Upload_Range,
	range_count: ^int,
) -> bool {
	cols := int(r.cols)
	cs := col_start
	ce := col_end
	if cs < 0 {
		cs = 0
	}
	if ce > cols {
		ce = cols
	}
	if cs >= ce {
		return true
	}
	if range_count^ + 2 > DIRTY_UPLOAD_MAX_RANGES {
		return false
	}
	n := d.cells
	cw := r.cell_width
	ch := r.cell_height
	for col in cs..<ce {
		idx := row * cols + col
		x := r.pad_x + f32(col) * cw
		y := r.pad_y + f32(row) * ch
		emit_bg, emit_glyph := render_cell_expand_instance(
			r.compiled_v2.cells[idx], lut, &r.atlas, x, y, cw, ch,
			&d.mirror[idx], &d.mirror[n+idx],
		)
		if !emit_bg {
			d.mirror[idx] = instance.Instance_Data{}
		}
		if !emit_glyph {
			d.mirror[n+idx] = instance.Instance_Data{}
		}
	}
	rs := row * cols + cs
	count := ce - cs
	ranges[range_count^] = Dirty_Upload_Range{
		offset = u64(rs) * instance.INSTANCE_STRIDE,
		size   = u64(count) * instance.INSTANCE_STRIDE,
	}
	range_count^ += 1
	ranges[range_count^] = Dirty_Upload_Range{
		offset = u64(n + rs) * instance.INSTANCE_STRIDE,
		size   = u64(count) * instance.INSTANCE_STRIDE,
	}
	range_count^ += 1
	return true
}
